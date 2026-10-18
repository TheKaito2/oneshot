"""OneShot brand assets from the chameleon logo (a Canva SVG): app icons, logo tile, engraving art.

The SVG holds two PNGs: the engraving (RGB) and its mask (grey = opacity), drawn with
matrix(1.197931, 0, 0, 1.197926, -236.646582, 200.509187) on a 1500-unit #FF914D square.

Writes into OneShot/Resources/Assets.xcassets:
  AppIcon.appiconset   icon-1024.png (the logo), icon-1024-dark.png (chalk lines on the app's dark grid), icon-1024-tinted.png
  Logo.imageset        logo.png (the logo, square; the app rounds it)
  Chameleon.imageset   chameleon-ink.png (light appearance) and chameleon-chalk.png (dark): the cut-out engraving

Run: ~/Downloads/AI-Cashier-v4/.venv/bin/python tools/make_brand.py ["~/Downloads/Untitled design.svg"]
"""
import base64
import io
import json
import re
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageOps

ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / "OneShot/Resources/Assets.xcassets"
ORANGE = (255, 145, 77)                    # #FF914D, the logo
SCALE, DX, DY = 1.197931, -236.646582, 200.509187
UNITS = 1500


def layers(svg: Path):
    """(art RGB, mask L) in the order the SVG draws them: the mask's image first, then the art."""
    images = [Image.open(io.BytesIO(base64.b64decode(b)))
              for b in re.findall(r"data:image/png;base64,([A-Za-z0-9+/=]+)", svg.read_text())]
    mask, art = images
    assert mask.size == art.size, "mask and art should line up"
    return art.convert("RGB"), mask.convert("L")


def place(background: Image.Image, cutout: Image.Image) -> Image.Image:
    """Draws the cut-out where the SVG puts it, on a square background of any size."""
    k = background.width / UNITS
    w, h = round(cutout.width * SCALE * k), round(cutout.height * SCALE * k)
    art = cutout.resize((w, h), Image.Resampling.LANCZOS)
    out = background.convert("RGBA")
    out.paste(art, (round(DX * k), round(DY * k)), art)   # paste clips the part left of the square, as the SVG does
    return out


def grid_ground(size: int) -> Image.Image:
    """The dark app icon's ground, as in the app: flat #181715 under faint hairlines (no gradient)."""
    ground = Image.new("RGB", (size, size), (24, 23, 21))
    draw = ImageDraw.Draw(ground)
    cell = size // 8
    line = (44, 41, 36)   # the site's hairline #2C2924
    for i in range(0, size + 1, cell):
        draw.line([(i, 0), (i, size)], fill=line, width=max(1, size // 512))
        draw.line([(0, i), (size, i)], fill=line, width=max(1, size // 512))
    return ground


def imageset(name: str, files: dict[str, str | None]):
    """files: filename -> appearance ("dark" or None for any)."""
    folder = ASSETS / f"{name}.imageset"
    folder.mkdir(exist_ok=True)
    images = []
    for filename, appearance in files.items():
        entry: dict[str, object] = {"filename": filename, "idiom": "universal"}
        if appearance:
            entry["appearances"] = [{"appearance": "luminosity", "value": appearance}]
        images.append(entry)
    (folder / "Contents.json").write_text(json.dumps({"images": images, "info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
    return folder


def main():
    svg = Path(sys.argv[1] if len(sys.argv) > 1 else "~/Downloads/Untitled design.svg").expanduser()
    art, mask = layers(svg)
    ink = art.convert("RGBA")
    ink.putalpha(mask)
    chalk = ImageOps.invert(art).convert("RGBA")   # light lines, dark scales: the engraving for dark mode
    chalk.putalpha(mask)

    # App icons (no alpha allowed): the logo, chalk on the dark grid, and a grey one the system tints.
    light = place(Image.new("RGB", (1024, 1024), ORANGE), ink).convert("RGB")
    dark = place(grid_ground(1024), chalk).convert("RGB")
    icons = ASSETS / "AppIcon.appiconset"
    light.save(icons / "icon-1024.png")
    dark.save(icons / "icon-1024-dark.png")
    ImageOps.grayscale(dark).convert("RGB").save(icons / "icon-1024-tinted.png")
    (icons / "Contents.json").write_text(json.dumps({"images": [
        {"filename": "icon-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"},
        {"appearances": [{"appearance": "luminosity", "value": "dark"}], "filename": "icon-1024-dark.png",
         "idiom": "universal", "platform": "ios", "size": "1024x1024"},
        {"appearances": [{"appearance": "luminosity", "value": "tinted"}], "filename": "icon-1024-tinted.png",
         "idiom": "universal", "platform": "ios", "size": "1024x1024"},
    ], "info": {"author": "xcode", "version": 1}}, indent=2) + "\n")

    # The logo tile used in the app header, receipt and statement.
    logo = imageset("Logo", {"logo.png": None})
    light.resize((512, 512), Image.Resampling.LANCZOS).save(logo / "logo.png")

    # The engraving on its own, cropped to the drawing, for hero panels and empty states.
    box = mask.getbbox()
    art_set = imageset("Chameleon", {"chameleon-ink.png": None, "chameleon-chalk.png": "dark"})
    for image, filename in ((ink, "chameleon-ink.png"), (chalk, "chameleon-chalk.png")):
        cut = image.crop(box)
        cut.thumbnail((1200, 1200), Image.Resampling.LANCZOS)
        cut.save(art_set / filename, optimize=True)
    print(f"icons 3, logo 512, chameleon {cut.size} (from {svg.name}, art {art.size}, drawing bbox {box})")


if __name__ == "__main__":
    main()
