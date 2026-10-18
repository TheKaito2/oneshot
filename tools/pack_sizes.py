"""Measures each product's real size relative to Lay's Nori medium, for tools/compose_piles.py.

Packs lying apart in the mixed-train photos are cut out (build/cutouts data/raw/mixed-train data/cutouts-mixed),
named by the round-1 detector, and sized as sqrt(mask area), which ignores rotation. Packs in the same photo share
one camera distance, so their ratios are real; a least-squares fit joins the ratios across photos.

Run: .venv/bin/python tools/pack_sizes.py runs/detect/runs/v1/weights/best.pt data/cutouts-mixed
"""
import sys
from collections import defaultdict
from pathlib import Path

import numpy as np
from PIL import Image
from ultralytics import YOLO

model = YOLO(sys.argv[1])
names = model.names
wood = Image.open(sorted(Path("data/raw/empty").glob("*.jpg"))[0]).convert("RGB")   # the detector never saw black
by_photo = defaultdict(lambda: defaultdict(list))   # photo -> class -> [sqrt area]
for f in sorted(Path(sys.argv[2]).glob("*.png")):
    rgba = Image.open(f).convert("RGBA")
    alpha = np.array(rgba.getchannel("A")) > 128
    flat = wood.resize((max(rgba.width + 200, 640), max(rgba.height + 200, 640)))
    flat.paste(rgba, (100, 100), mask=rgba.getchannel("A"))
    r = model.predict(flat, conf=0.25, imgsz=640, device="mps", verbose=False)[0]
    if len(r.boxes) != 1 or r.boxes.conf[0] < 0.8:
        continue                                     # merged blob, hand, or unsure
    x1, y1, x2, y2 = r.boxes.xyxy[0].tolist()
    if x2 - x1 < 0.8 * rgba.width or y2 - y1 < 0.8 * rgba.height:
        continue                                     # the box covers only part of the blob
    by_photo[f.stem.rsplit("-", 1)[0]][names[int(r.boxes.cls[0])]].append(alpha.sum() ** 0.5)

classes = sorted({c for p in by_photo.values() for c in p})
idx = {c: i for i, c in enumerate(classes)}
rows, rhs = [], []
for photo in by_photo.values():
    logs = {c: np.log(np.mean(v)) for c, v in photo.items()}
    for a in logs:
        for b in logs:
            if a < b:
                row = np.zeros(len(classes))
                row[idx[a]], row[idx[b]] = 1, -1
                rows.append(row)
                rhs.append(logs[a] - logs[b])
anchor = np.zeros(len(classes))
anchor[idx["lays-nori-medium"]] = 1                  # medium = 1.0
rows.append(anchor * 100)
rhs.append(0)
fit, *_ = np.linalg.lstsq(np.array(rows), np.array(rhs), rcond=None)
counts = {c: sum(c in p for p in by_photo.values()) for c in classes}
for c in sorted(classes, key=lambda c: -fit[idx[c]]):
    print(f'    "{c}": {np.exp(fit[idx[c]]):.2f},   # {counts[c]} photos')
medium = [v for p in by_photo.values() for v in p.get("lays-nori-medium", [])]
print(f"{sum(len(v) for p in by_photo.values() for v in p.values())} packs measured in {len(by_photo)} photos;"
      f" medium sqrt-area / 1280 px: {min(medium) / 1280:.2f}-{max(medium) / 1280:.2f}")
