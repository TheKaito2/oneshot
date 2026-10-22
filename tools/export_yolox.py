"""Exports a tools/train_yolox.py checkpoint as OneShot's Detector.mlpackage.

Pipeline, like the Ultralytics export it replaces, so Vision returns VNRecognizedObjectObservation and
OneShot/Recognition/Detector.swift needs no change:
  image (BGR 0-255, letterboxed by Vision's scaleFit) -> YOLOX with decode on
  -> confidence (N x classes = objectness x class score) + coordinates (N x 4, cx cy w h normalised to the input)
  -> Core ML NonMaximumSuppression (per class) with optional confidenceThreshold / iouThreshold inputs.

    third_party/.venv/bin/python tools/export_yolox.py runs/yolox/tiny416/best.pth models/yolox-tiny416.mlpackage
"""
import sys
from pathlib import Path

import coremltools as ct
import numpy as np
import torch
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
from train_yolox import make_exp  # noqa: E402

IOU, CONFIDENCE = 0.45, 0.25   # the NMS defaults when the app doesn't feed them (same as the YOLO11n export)


class Decoded(torch.nn.Module):
    def __init__(self, model, size):
        super().__init__()
        self.model, self.size = model, size

    def forward(self, x):
        out = self.model(x)[0]   # N x (4 + 1 + classes): cx cy w h in input pixels, objectness, class scores
        return out[:, 5:] * out[:, 4:5], out[:, :4] / self.size


def main(checkpoint, destination):
    state = torch.load(checkpoint, map_location="cpu", weights_only=False)
    names, size = state["names"], state["size"]
    exp, _ = make_exp(state["exp"], len(names))
    model = exp.get_model()
    model.load_state_dict(state["model"])
    model.eval()
    model.head.decode_in_inference = True
    wrapper = Decoded(model, size).eval()
    traced = torch.jit.trace(wrapper, torch.rand(1, 3, size, size) * 255)

    detector = ct.convert(
        traced,
        inputs=[ct.ImageType(name="image", shape=(1, 3, size, size), color_layout=ct.colorlayout.BGR)],
        outputs=[ct.TensorType(name="raw_confidence", dtype=np.float32),
                 ct.TensorType(name="raw_coordinates", dtype=np.float32)],   # NMS takes float32 only
        minimum_deployment_target=ct.target.iOS17,
    )
    # NMS needs fixed output shapes on the detector side; read them off one prediction.
    spec = detector.get_spec()
    out = detector.predict({"image": Image.new("RGB", (size, size))})
    for output in spec.description.output:
        output.type.multiArrayType.shape[:] = out[output.name].shape
    detector = ct.models.MLModel(spec, weights_dir=detector.weights_dir)

    nms_spec = ct.proto.Model_pb2.Model()
    nms_spec.specificationVersion = spec.specificationVersion
    for i, (output, final, width) in enumerate(zip(spec.description.output, ["confidence", "coordinates"],
                                                   [len(names), 4])):
        nms_spec.description.input.add().ParseFromString(output.SerializeToString())
        result = nms_spec.description.output.add()
        result.ParseFromString(output.SerializeToString())
        result.name = final
        array = result.type.multiArrayType
        del array.shape[:]
        boxes = array.shapeRange.sizeRanges.add()
        boxes.lowerBound, boxes.upperBound = 0, -1
        columns = array.shapeRange.sizeRanges.add()
        columns.lowerBound = columns.upperBound = width
    nms = nms_spec.nonMaximumSuppression
    nms.confidenceInputFeatureName, nms.coordinatesInputFeatureName = "raw_confidence", "raw_coordinates"
    nms.confidenceOutputFeatureName, nms.coordinatesOutputFeatureName = "confidence", "coordinates"
    nms.iouThresholdInputFeatureName, nms.confidenceThresholdInputFeatureName = "iouThreshold", "confidenceThreshold"
    nms.iouThreshold, nms.confidenceThreshold = IOU, CONFIDENCE
    nms.pickTop.perClass = True
    nms.stringClassLabels.vector.extend(names)
    nms_model = ct.models.MLModel(nms_spec)

    pipeline = ct.models.pipeline.Pipeline(
        input_features=[("image", ct.models.datatypes.Array(3, size, size)),
                        ("iouThreshold", ct.models.datatypes.Double()),
                        ("confidenceThreshold", ct.models.datatypes.Double())],
        output_features=["confidence", "coordinates"])
    pipeline.add_model(detector)
    pipeline.add_model(nms_model)
    described = pipeline.spec.description
    described.input[0].ParseFromString(spec.description.input[0].SerializeToString())
    for i in range(2):
        described.output[i].ParseFromString(nms_spec.description.output[i].SerializeToString())
    for feature in described.input[1:]:
        feature.type.isOptional = True
    pipeline.spec.specificationVersion = spec.specificationVersion

    final = ct.models.MLModel(pipeline.spec, weights_dir=detector.weights_dir)
    final.author = "OneShot"
    final.license = "Apache-2.0 (YOLOX architecture and training code by Megvii; weights trained by OneShot)"
    final.short_description = (f"{state['exp']} {size}px snack detector, {len(names)} classes, fine-tuned from COCO "
                               f"on OneShot's own counter photos and composited piles (data/yolo), epoch "
                               f"{state['epoch']}.")
    final.version = "1.0"
    final.input_description["image"] = "Counter photo, letterboxed to the input (Vision scaleFit)"
    final.input_description["iouThreshold"] = f"(optional) IoU threshold override (default: {IOU})"
    final.input_description["confidenceThreshold"] = f"(optional) Confidence threshold override (default: {CONFIDENCE})"
    final.output_description["confidence"] = "Boxes × class confidence (objectness × class score)"
    final.output_description["coordinates"] = "Boxes × [x, y, width, height] (relative to the input)"
    final.user_defined_metadata["names"] = str(dict(enumerate(names)))
    final.user_defined_metadata["imgsz"] = str([size, size])
    final.save(destination)

    # Self-check on a val photo: Core ML's best box should match PyTorch's best score (fp16 rounding aside).
    import cv2
    from train_yolox import YoloFolder
    val = YoloFolder("val", size)
    pixels, _ = val[0]
    image = Image.fromarray(cv2.cvtColor(pixels.numpy().transpose(1, 2, 0).astype(np.uint8), cv2.COLOR_BGR2RGB))
    result = final.predict({"image": image})
    with torch.no_grad():
        confidence, _ = wrapper(pixels[None])
    print(f"saved {destination}. {val.images[0].name}: Core ML {len(result['confidence'])} boxes, best "
          f"{float(result['confidence'].max()):.3f}; PyTorch best {float(confidence.max()):.3f}, "
          f"{int((confidence.max(1).values > CONFIDENCE).sum())} raw boxes over {CONFIDENCE}")

if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("usage: export_yolox.py <checkpoint.pth> <out.mlpackage>")
    main(sys.argv[1], sys.argv[2])
