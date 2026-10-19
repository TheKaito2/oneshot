"""Copy the named screenshots out of a OneShotTour result: tools/tour_shots.py <xcresult> <out dir> [sheet.png]."""
import json
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

result, out = sys.argv[1], Path(sys.argv[2])
out.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory() as tmp:
    subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", result, "--output-path", tmp], check=True,
                   capture_output=True)
    names = []
    for test in json.load(open(Path(tmp) / "manifest.json")):
        for a in test.get("attachments", []):
            human = a.get("suggestedHumanReadableName", "")
            m = re.match(r"((?:th-)?(?:portrait|landscape)-\d\d-[\w-]+?)_\d+_", human)
            if m and a["exportedFileName"].endswith(".png"):
                # Half size as JPEG: 81 full-size PNGs were 76 MB.
                from PIL import Image
                im = Image.open(Path(tmp) / a["exportedFileName"]).convert("RGB")
                im.resize((im.width // 2, im.height // 2), Image.LANCZOS).save(out / f"{m.group(1)}.jpg", quality=85)

                names.append(m.group(1))
print(f"{len(names)} screenshots -> {out}")
if len(sys.argv) > 3:
    from PIL import Image, ImageDraw
    files = sorted(out.glob("*.jpg"))
    w = 330
    cols = 6
    rows = (len(files) + cols - 1) // cols
    sheet = Image.new("RGB", (w * cols, w * rows), "black")
    draw = ImageDraw.Draw(sheet)
    for i, f in enumerate(files):
        im = Image.open(f).convert("RGB")
        im.thumbnail((w - 8, w - 22))
        x, y = (i % cols) * w, (i // cols) * w
        sheet.paste(im, (x + 4, y + 18))
        draw.text((x + 4, y + 2), f.stem, fill="yellow")
    sheet.save(sys.argv[3])
