"""Tiled copy of the YOLO dataset for Create ML transfer learning, whose detector input is a fixed 299x299: a whole
1280x960 counter shrinks its packs to ~70 px and the model fragments and misreads them (exam: 3/42 exact bills,
20 Oct). Each image becomes itself plus 4 overlapping tiles (60% of each side, at 0 and 40%), so packs train
~1.7x bigger; the app then runs the detector on the same full frame + 4 tiles (Detector.tiles) and merges.

A box is kept in a tile when at least half of it is inside, clipped to the tile; otherwise it is left out.

  python3 tools/createml_tiles.py      -> data/yolo-tiles/images/<split>/*.jpg + data/yolo-tiles/createml-tiles-<split>.json
"""
import json
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent / "data"
SRC, OUT = ROOT / "yolo", ROOT / "yolo-tiles"
SIDE, STARTS = 0.6, (0.0, 0.4)
names = {}
for line in (SRC / "data.yaml").read_text().splitlines():
    key, _, value = line.strip().partition(": ")
    if key.isdigit():
        names[int(key)] = value


def tiles(width, height):
    yield 0, 0, width, height
    for fy in STARTS:
        for fx in STARTS:
            yield round(fx * width), round(fy * height), round(SIDE * width), round(SIDE * height)


for split in ("train", "val"):
    (OUT / "images" / split).mkdir(parents=True, exist_ok=True)
    rows = []
    for image_path in sorted((SRC / "images" / split).glob("*.jpg")):
        label_file = SRC / "labels" / split / (image_path.stem + ".txt")
        values = label_file.read_text().split() if label_file.exists() else []
        image = Image.open(image_path).convert("RGB")
        width, height = image.size
        boxes = []
        for i in range(0, len(values), 5):
            cls, cx, cy, w, h = int(values[i]), *map(float, values[i + 1:i + 5])
            boxes.append((names[cls], (cx - w / 2) * width, (cy - h / 2) * height, (cx + w / 2) * width, (cy + h / 2) * height))
        for index, (x0, y0, tw, th) in enumerate(tiles(width, height)):
            annotations = []
            for label, bx0, by0, bx1, by1 in boxes:
                ix0, iy0, ix1, iy1 = max(bx0, x0), max(by0, y0), min(bx1, x0 + tw), min(by1, y0 + th)
                if ix1 <= ix0 or iy1 <= iy0 or (ix1 - ix0) * (iy1 - iy0) < 0.5 * (bx1 - bx0) * (by1 - by0):
                    continue
                annotations.append({"label": label, "coordinates": {
                    "x": (ix0 + ix1) / 2 - x0, "y": (iy0 + iy1) / 2 - y0, "width": ix1 - ix0, "height": iy1 - iy0}})
            if not annotations:
                continue   # Create ML's detector can't take an image without boxes
            name = f"{image_path.stem}__t{index}.jpg"
            image.crop((x0, y0, x0 + tw, y0 + th)).save(OUT / "images" / split / name, quality=90)
            rows.append({"image": name, "annotations": annotations})
    (OUT / f"createml-tiles-{split}.json").write_text(json.dumps(rows))
    print(f"{split}: {len(rows)} images, {sum(len(r['annotations']) for r in rows)} boxes")
