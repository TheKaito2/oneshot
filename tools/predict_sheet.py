"""Run a trained detector over a folder and draw review sheets; optionally write YOLO pseudo-labels.

  Grade the exam:   .venv/bin/python tools/predict_sheet.py runs/v1/weights/best.pt data/raw/mixed-test sheets/r1-test
  Pseudo-label:     ... data/raw/mixed-train sheets/r1-train --labels data/labels/mixed-train-r1 --label-conf 0.5

Sheets show every box at conf >= 0.25 with "class conf" (green >= --label-conf, yellow below), 6 photos per sheet.
"""
import argparse
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont
from ultralytics import YOLO

parser = argparse.ArgumentParser()
parser.add_argument("weights")
parser.add_argument("images")
parser.add_argument("out")
parser.add_argument("--labels", help="write YOLO labels for boxes >= --label-conf here")
parser.add_argument("--label-conf", type=float, default=0.5)
args = parser.parse_args()

model = YOLO(args.weights)
out = Path(args.out)
out.mkdir(parents=True, exist_ok=True)
if args.labels:
    Path(args.labels).mkdir(parents=True, exist_ok=True)
font = ImageFont.load_default(size=28)
files = sorted(Path(args.images).glob("*.jpg"))
tiles, summary = [], []
for f in files:
    r = model.predict(str(f), conf=0.25, iou=0.7, imgsz=640, device="mps", verbose=False)[0]
    im = Image.open(f).convert("RGB")
    d = ImageDraw.Draw(im)
    lines = []
    for (x1, y1, x2, y2), c, k in zip(r.boxes.xyxy.tolist(), r.boxes.conf.tolist(), r.boxes.cls.tolist()):
        name = model.names[int(k)]
        sure = c >= args.label_conf
        color = (0, 200, 0) if sure else (255, 200, 0)
        d.rectangle([x1, y1, x2, y2], outline=color, width=6)
        d.rectangle([x1, max(0, y1 - 32), x1 + 14 * len(name) + 90, y1], fill=color)
        d.text((x1 + 4, max(0, y1 - 31)), f"{name} {c:.2f}", fill="black", font=font)
        if sure:
            W, H = im.size
            lines.append(f"{int(k)} {(x1 + x2) / 2 / W:.6f} {(y1 + y2) / 2 / H:.6f} {(x2 - x1) / W:.6f} {(y2 - y1) / H:.6f}")
        summary.append(f"{f.name}\t{name}\t{c:.3f}")
    if args.labels:
        (Path(args.labels) / (f.stem + ".txt")).write_text("\n".join(lines))
    d.text((10, 10), f.name, fill="white", font=font, stroke_width=3, stroke_fill="black")
    im.thumbnail((900, 900))
    tiles.append(im)

for i in range(0, len(tiles), 6):
    group = tiles[i:i + 6]
    sheet = Image.new("RGB", (900 * 3, 900 * 2), "white")
    for j, t in enumerate(group):
        sheet.paste(t, ((j % 3) * 900, (j // 3) * 900))
    sheet.save(out / f"sheet-{i // 6 + 1:02d}.jpg", quality=80)
(out / "predictions.tsv").write_text("\n".join(summary) + "\n")
print(f"{len(files)} photos, {len(summary)} boxes -> {out}")
