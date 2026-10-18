"""Synthetic checkout piles for round 2: paste single-pack cutouts (tools/cutouts.swift) onto empty-surface photos.

Round 1 trained on one pack per photo and fell apart on piles (0 boxes on touching packs). Here packs overlap,
touch and spread; each label is the box of the pixels still visible after later packs land on top.
Packs keep their measured relative size, so a Nori medium next to a small one looks bigger, as in a real pile.

Writes synth__*.jpg + YOLO labels into data/yolo/{images,labels}/{train,val}.
Run: python tools/compose_piles.py [--train 800] [--val 80] [--sheet sheets/synth.jpg]
"""
import argparse
import random
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
CLASSES = (ROOT / "data/yolo/data.yaml").read_text().split("names:")[1].split()[1::2]
# Size = sqrt(mask area) relative to Lay's Nori medium; area ignores rotation, unlike the box.
# Measured on mixed-train packs lying apart (tools/pack_sizes.py + the cutout contact sheet, Oct 18):
#   nori small 0.76 (5 photos, 0.67-0.87), BBQ 0.70, hot chilli 0.68-0.72, M&M's 0.56 (2), KitKat 0.39-0.46 (2),
#   Jolly Cola ~0.68 x BBQ (6). Never lying alone, so estimated from wrapper area vs KitKat: Mars, Hershey's,
#   Julie's, Lactasoy, Stick-o. ponytail: re-measure those if their boxes come out too big or small.
SIZE = {
    "lays-nori-medium": 1.0, "lays-nori-small": 0.76, "lays-ridges-bbq": 0.70, "lays-ridges-hot-chilli-squid": 0.70,
    "sticko-fingers-vanilla": 0.60, "mm-peanut": 0.56, "jolly-cola": 0.48, "kitkat-original": 0.41, "mars-bar": 0.36,
    "hersheys-nugget-cookiencream": 0.38, "julies-cheddar-cheese": 0.36, "lactasoy-melon": 0.35,
}
W, H = 1280, 960
MIN_VISIBLE = 0.25   # a pack hidden more than this gets no label (the cashier can't see it either)
# Share of piles holding both Nori bags. Round 2's exam (epoch 3) billed every Nori medium that lay next to a
# small one as small; the pair has to be seen side by side to learn it.
PAIR = 0.4
# Things not in the catalog (phone, water bottle, from data/raw/unknown 0417-0427) dropped into this share of piles,
# unlabelled: v2 called a phone "mars-bar" at up to 0.58. Size = sqrt(area) vs Nori medium, from wrapper-size estimates.
DISTRACT = 0.3
DISTRACTOR_SIZE = {"phone": 0.43, "bottle": 0.57}


def load_cutouts():
    cuts = {}
    for sku in CLASSES:
        cuts[sku] = sorted((ROOT / "data/cutouts" / sku).glob("*.png"))
        assert cuts[sku], f"no cutouts for {sku}"
    return cuts


def background(paths, rng):
    bg = Image.open(rng.choice(paths)).convert("RGB")
    if bg.height > bg.width:
        bg = bg.rotate(90, expand=True)
    if rng.random() < 0.5:
        bg = bg.rotate(180)
    return bg.resize((W, H))


def compose(rng, cuts, bgs, distractors):
    canvas = background(bgs, rng)
    owner = np.full((H, W), -1, np.int16)
    medium = rng.uniform(0.13, 0.40) * W            # camera distance: mixed-train shows 0.25-0.33, exam far/close shots wider
    mode = rng.choices(["pile", "touching", "spread"], [0.5, 0.3, 0.2])[0]
    spread = {"pile": 0.12, "touching": 0.2, "spread": 0.32}[mode]
    cx, cy = rng.uniform(0.35, 0.65) * W, rng.uniform(0.35, 0.65) * H
    skus = [rng.choice(CLASSES) for _ in range(rng.randint(3, 12))]
    if rng.random() < PAIR:
        skus[:2] = ["lays-nori-medium", "lays-nori-small"]
    if rng.random() < DISTRACT:
        skus += [None] * rng.randint(1, 2)          # None = a distractor: pasted, occludes, never labelled
    rng.shuffle(skus)
    placed = []
    for sku in skus:
        if sku is None:
            path = rng.choice(distractors)
            cut, target = Image.open(path).convert("RGBA"), DISTRACTOR_SIZE[path.name.split("-")[0]]
        else:
            cut, target = Image.open(rng.choice(cuts[sku])).convert("RGBA"), SIZE[sku]
        size = (np.array(cut.getchannel("A")) > 128).sum() ** 0.5
        scale = medium * target * rng.uniform(0.9, 1.1) / size
        cut = cut.resize((max(1, round(cut.width * scale)), max(1, round(cut.height * scale))), Image.Resampling.LANCZOS)
        cut = cut.rotate(rng.uniform(0, 360), expand=True, resample=Image.Resampling.BICUBIC)
        x = int(rng.gauss(cx, spread * W) - cut.width / 2)
        y = int(rng.gauss(cy, spread * H) - cut.height / 2)
        alpha = cut.getchannel("A")
        shadow = Image.new("RGBA", cut.size, (0, 0, 0, 0))
        shadow.putalpha(alpha.point(lambda a: a * 0.35).filter(ImageFilter.GaussianBlur(6)))
        canvas.paste(shadow, (x + 6, y + 6), shadow)
        canvas.paste(cut, (x, y), cut)
        # Mark the pixels this pack now owns (clipped to the canvas).
        a = np.array(alpha) > 128
        x0, y0, x1, y1 = max(x, 0), max(y, 0), min(x + cut.width, W), min(y + cut.height, H)
        if x1 <= x0 or y1 <= y0:
            continue
        sub = a[y0 - y:y1 - y, x0 - x:x1 - x]
        owner[y0:y1, x0:x1][sub] = len(placed)
        placed.append((sku, int(a.sum())))
    labels = []
    for i, (sku, full) in enumerate(placed):
        if sku is None:
            continue
        ys, xs = np.nonzero(owner == i)
        if full == 0 or len(xs) < MIN_VISIBLE * full:
            continue
        bx0, bx1, by0, by1 = xs.min(), xs.max() + 1, ys.min(), ys.max() + 1
        labels.append((CLASSES.index(sku), (bx0 + bx1) / 2 / W, (by0 + by1) / 2 / H, (bx1 - bx0) / W, (by1 - by0) / H))
    return canvas, labels


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--train", type=int, default=800)
    p.add_argument("--val", type=int, default=80)
    p.add_argument("--sheet", help="also draw the first 6 train images with labels here")
    args = p.parse_args()
    rng = random.Random(7)
    cuts = load_cutouts()
    bgs = sorted((ROOT / "data/raw/empty").glob("*.jpg"))
    distractors = sorted((ROOT / "data/cutouts-distractors").glob("*.png"))
    yolo = ROOT / "data/yolo"
    for old in yolo.glob("*/*/synth__*"):
        old.unlink()
    previews = []
    for split, n in (("train", args.train), ("val", args.val)):
        for k in range(n):
            img, labels = compose(rng, cuts, bgs, distractors)
            name = f"synth__{split}{k:04d}"
            img.save(yolo / f"images/{split}/{name}.jpg", quality=88)
            (yolo / f"labels/{split}/{name}.txt").write_text(
                "\n".join(f"{c} {x:.6f} {y:.6f} {w:.6f} {h:.6f}" for c, x, y, w, h in labels))
            if split == "train" and len(previews) < 6:
                previews.append((img, labels))
    print(f"{args.train} train + {args.val} val synthetic piles -> {yolo}")
    if args.sheet:
        sheet = Image.new("RGB", (W * 3, H * 2), "white")
        for i, (img, labels) in enumerate(previews):
            img = img.copy()
            d = ImageDraw.Draw(img)
            for c, x, y, w, h in labels:
                d.rectangle([(x - w / 2) * W, (y - h / 2) * H, (x + w / 2) * W, (y + h / 2) * H], outline="lime", width=4)
                d.text(((x - w / 2) * W + 4, (y - h / 2) * H + 2), CLASSES[c], fill="lime")
            sheet.paste(img, ((i % 3) * W, (i // 3) * H))
        sheet.save(args.sheet, quality=80)
        print(f"preview -> {args.sheet}")


if __name__ == "__main__":
    main()
