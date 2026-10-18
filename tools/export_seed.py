"""Bundle product imagery cut from the labelled shoot.

  OneShot/Resources/Seed/product-<sku>.jpg   the product's picture (Products grid, ticket, pick list)
  OneShot/Resources/Seed/seed-<sku>-<n>.jpg  ~10 views per product; the iPad embeds them into the gallery
                                             at first launch, so the gallery votes for every product from day one

Picks views spread across each product's photos (angles, distances, sides). Uses data/labels/review.jsonl.
Run: ~/Downloads/AI-Cashier-v4/.venv-coreml/bin/python tools/export_seed.py
"""
import json
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "OneShot" / "Resources" / "Seed"
SEEDS_PER_SKU = 10
# Product pictures that came out upside down (checked by eye on the 18 Oct shoot).
UPRIGHT = {"hersheys-nugget-cookiencream": 180, "mm-peanut": 180, "lays-ridges-hot-chilli-squid": 180}
PAD = 0.04  # a little context around the box, like the app's crops

rows = [json.loads(line) for line in open(ROOT / "data" / "labels" / "review.jsonl")]
OUT.mkdir(parents=True, exist_ok=True)
for old in OUT.glob("*.jpg"):
    old.unlink()


def crop(row, size):
    im = Image.open(ROOT / "data" / "raw" / row["image"]).convert("RGB")
    W, H = im.size
    x, y, w, h = row["boxes"][0]
    box = (max(0, (x - PAD) * W), max(0, (y - PAD) * H), min(W, (x + w + PAD) * W), min(H, (y + h + PAD) * H))
    c = im.crop(box)
    c.thumbnail((size, size))
    return c


skus = open(ROOT / "data" / "labels" / "classes.txt").read().split()
for sku in skus:
    singles = [r for r in rows if r["image"].startswith(f"sku/{sku}/") and len(r["boxes"]) == 1]
    # The product picture: the biggest, most frontal-looking box (largest area) reads best on a card.
    hero = max(singles, key=lambda r: r["boxes"][0][2] * r["boxes"][0][3])
    crop(hero, 512).rotate(UPRIGHT.get(sku, 0)).save(OUT / f"product-{sku}.jpg", quality=88)
    step = max(1, len(singles) // SEEDS_PER_SKU)
    for n, row in enumerate(singles[::step][:SEEDS_PER_SKU]):
        crop(row, 320).save(OUT / f"seed-{sku}-{n}.jpg", quality=85)
print(f"{len(skus)} products -> {OUT} ({len(list(OUT.glob('*.jpg')))} files)")
