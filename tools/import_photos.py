"""Import the shoot (HEIC from the iPad) into data/raw as upright JPEGs, max 1280 px.

Source layout (the shot list): <src>/sku/<product>/, <src>/mixed-test, mixed-train, empty, unknown, nori-pair.
Output: data/raw/sku/<id>/, data/raw/mixed-test/, ... with ids made path- and class-safe
("lay's-nori-small" -> "lays-nori-small", "m&m-peanut" -> "mms-peanut").

Run: ~/Downloads/AI-Cashier-v4/.venv-coreml/bin/python tools/import_photos.py ~/Downloads
"""
import re
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from PIL import Image, ImageOps

MAX_SIDE = 1280
ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "data" / "raw"


def slug(name: str) -> str:
    name = name.lower().replace("&", "").replace("'", "")
    return re.sub(r"[^a-z0-9]+", "-", name).strip("-")


def convert(src: Path, dst: Path) -> None:
    if dst.exists():
        return
    dst.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        jpg = Path(tmp) / "x.jpg"
        subprocess.run(["sips", "-s", "format", "jpeg", str(src), "--out", str(jpg)], check=True, capture_output=True)
        with Image.open(jpg) as im:
            im = ImageOps.exif_transpose(im)  # bake the orientation into the pixels
            im.thumbnail((MAX_SIDE, MAX_SIDE))
            im.convert("RGB").save(dst, "JPEG", quality=90)


def photos(folder: Path):
    """HEIC from the iPad, or JPEG if the camera was set to Most Compatible; a missing folder is just empty."""
    return sorted(f for f in folder.glob("*") if f.suffix.lower() in {".heic", ".jpg", ".jpeg"})


def jobs(src_root: Path):
    for product in sorted((src_root / "sku").iterdir()):
        if product.is_dir():
            for f in photos(product):
                yield f, OUT / "sku" / slug(product.name) / (f.stem + ".jpg")
    for split in ["mixed-test", "mixed-train", "empty", "unknown", "nori-pair"]:
        for f in photos(src_root / split):
            yield f, OUT / split / (f.stem + ".jpg")


if __name__ == "__main__":
    work = list(jobs(Path(sys.argv[1]).expanduser()))
    with ThreadPoolExecutor(4) as pool:
        list(pool.map(lambda job: convert(*job), work))
    print(f"imported {len(work)} photos into {OUT}")
