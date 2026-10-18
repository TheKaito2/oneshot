"""Grades a detector on the exam (data/raw/mixed-test) as the till would ring it up, against data/exam-truth.tsv.

Mirrors the app's lock path, detector vote only (the gallery vote is not simulated):
floor (--floor, app 0.1), per-class NMS (--iou), then Gallery.mergeOverlaps (IoU >= 0.6 across classes, labels pooled), then
Resolver: a region is billed when its top label >= tau and no second label also >= tau (torn -> yellow).
Per photo, against the units on the table:
  right  = billed units matching a unit on the table
  wrong  = billed units beyond that: wrong product or double count -> a wrong price
  missed = units on the table not billed right (the cashier picks them from a yellow, or they never show)
  exact  = every unit billed right, nothing wrong

Run: .venv/bin/python tools/grade.py <weights> [--tau 0.5]   (no --tau: sweeps tau)
     Nori-pair test: ... --photos data/raw/nori-pair-test --truth data/pair-truth.tsv
"""
import argparse
from collections import Counter
from pathlib import Path

from ultralytics import YOLO

ROOT = Path(__file__).resolve().parent.parent
p = argparse.ArgumentParser()
p.add_argument("weights")
p.add_argument("--tau", type=float, help="print each photo's misses and wrongs at this threshold")
p.add_argument("--iou", type=float, default=0.7, help="NMS IoU; the app leaves the Core ML default, 0.7")
p.add_argument("--floor", type=float, default=0.1, help="lowest box confidence kept (CameraController.lockFloor)")
p.add_argument("--photos", default="data/raw/mixed-test", help="e.g. data/raw/nori-pair-test")
p.add_argument("--truth", default="data/exam-truth.tsv", help="e.g. data/pair-truth.tsv")
args = p.parse_args()

truth = {}
photos = sorted((ROOT / args.photos).glob("*.jpg"))
for line in (ROOT / args.truth).read_text().splitlines():
    if line.startswith("#") or not line.strip():
        continue
    first, last, items = line.split("\t")
    for f in photos:
        if first <= f.stem <= last:
            truth[f.name] = Counter(i for i in items.split(",") if i)   # empty = nothing from the catalog
assert len(truth) == len(photos), f"truth covers {len(truth)} of {len(photos)} photos"


def iou(a, b):
    w = min(a[2], b[2]) - max(a[0], b[0])
    h = min(a[3], b[3]) - max(a[1], b[1])
    if w <= 0 or h <= 0:
        return 0.0
    shared = w * h
    return shared / ((a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - shared)


def regions(result, names):
    """Gallery.mergeOverlaps: [(box, [(label, conf)] best first)]."""
    kept = []
    boxes = sorted(zip(result.boxes.xyxy.tolist(), result.boxes.conf.tolist(), result.boxes.cls.tolist()), key=lambda b: -b[1])
    for box, conf, cls in boxes:
        hit = next((r for r in kept if iou(r[0], box) >= 0.6), None)
        if hit is None:
            kept.append((box, {names[int(cls)]: conf}))
        else:
            hit[1][names[int(cls)]] = max(hit[1].get(names[int(cls)], 0), conf)
    return [(box, sorted(g.items(), key=lambda kv: -kv[1])[:3]) for box, g in kept]


model = YOLO(args.weights)
found = {}
for f in photos:
    r = model.predict(str(f), conf=args.floor, iou=args.iou, imgsz=640, device="mps", verbose=False)[0]
    found[f.name] = regions(r, model.names)


def grade(tau, detail=False):
    right = wrong = missed = yellow = exact = 0
    for name, table in truth.items():
        billed, green, yellows = Counter(), [], []
        for box, guesses in found[name]:
            torn = len(guesses) > 1 and guesses[1][1] >= tau
            if guesses[0][1] >= tau and not torn:
                billed[guesses[0][0]] += 1
                green.append(box)
            else:
                yellow += 1
                yellows.append((box, guesses))
        ok = sum((billed & table).values())
        bad, miss = sum((billed - table).values()), sum((table - billed).values())
        right, wrong, missed, exact = right + ok, wrong + bad, missed + miss, exact + (bad == 0 and miss == 0)
        if detail and (bad or miss):
            print(f"  {name}: missed {dict(table - billed)}  wrong {dict(billed - table)}")
        if detail:
            for box, guesses in yellows:
                # On top of a green item (a duplicate the cashier has to dismiss) or on its own (maybe a real miss).
                where = "on a green item" if any(iou(box, g) >= 0.3 for g in green) else "alone"
                print(f"  {name}: yellow {where}: " + ", ".join(f"{k} {c:.2f}" for k, c in guesses))
    units = sum(sum(t.values()) for t in truth.values())
    return f"tau {tau:.2f}: right {right}/{units} ({right / max(units, 1):.0%})  wrong {wrong}  missed {missed}  yellow {yellow}  exact bills {exact}/{len(truth)}"


if args.tau is not None:
    print(grade(args.tau, detail=True))
else:
    for tau in (0.3, 0.4, 0.5, 0.55, 0.6, 0.65, 0.7, 0.8, 0.9):
        print(grade(tau))
