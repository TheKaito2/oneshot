"""Writes Create ML object-detection annotation files from the YOLO dataset (data/yolo), so Create ML trains on exactly
the images and boxes YOLO11n did.

Create ML JSON: [{"image": "<file>", "annotations": [{"label", "coordinates": {x, y, width, height}}]}], pixels,
origin top-left, anchor centre. Images with no boxes (empty counters, unknown-only) are left out: Create ML's detector
can't take an image without annotations.

  python3 tools/createml_data.py            # 12 product classes  -> data/yolo/createml-<split>.json
  python3 tools/createml_data.py --item     # one class, "item"   -> data/yolo/createml-item-<split>.json
"""
import argparse
import json
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent / "data" / "yolo"
p = argparse.ArgumentParser()
p.add_argument("--item", action="store_true", help="class-agnostic: every box labelled 'item'")
args = p.parse_args()

names = {}
for line in (ROOT / "data.yaml").read_text().splitlines():
    key, _, value = line.strip().partition(": ")
    if key.isdigit():
        names[int(key)] = value

for split in ("train", "val"):
    rows, boxes, skipped = [], 0, 0
    for image in sorted((ROOT / "images" / split).glob("*.jpg")):
        label_file = ROOT / "labels" / split / (image.stem + ".txt")
        lines = label_file.read_text().split() if label_file.exists() else []
        if not lines:
            skipped += 1
            continue
        width, height = Image.open(image).size
        annotations = []
        for i in range(0, len(lines), 5):
            cls, cx, cy, w, h = int(lines[i]), *map(float, lines[i + 1:i + 5])
            annotations.append({
                "label": "item" if args.item else names[cls],
                "coordinates": {"x": cx * width, "y": cy * height, "width": w * width, "height": h * height},
            })
        boxes += len(annotations)
        rows.append({"image": image.name, "annotations": annotations})
    out = ROOT / f"createml-{'item-' if args.item else ''}{split}.json"
    out.write_text(json.dumps(rows))
    print(f"{split}: {len(rows)} images, {boxes} boxes, {skipped} without boxes left out -> {out.name}")
