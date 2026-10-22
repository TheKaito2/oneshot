"""Download the opt-in training photos into a YOLO dataset: tools/fetch_training.py [out_dir]

Reads training-frames/<shop>/<name>.jpg|.json from Supabase Storage with the service-role key, which bypasses RLS and
must never ship in the app or the repo: export SUPABASE_SERVICE_ROLE_KEY=... first (Dashboard › Project Settings › API).
Writes <out>/images/<shop8>-<name>.jpg and <out>/labels/<same>.txt (class cx cy w h, 0-1, top-left origin), with class
indices from data/labels/classes.txt. Products not in that list (taught by shops) are listed in <out>/new_skus.txt with
their counts, and their boxes are left out of the labels until they get a class.
"""
import json
import os
import pathlib
import re
import sys
import math
import urllib.parse
import urllib.request

root = pathlib.Path(__file__).resolve().parent.parent
out = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else root / "data/collected")
key = os.environ.get("SUPABASE_SERVICE_ROLE_KEY")
if not key:
    sys.exit("Set SUPABASE_SERVICE_ROLE_KEY (the service-role key; never commit it).")
found = re.search(r"SUPABASE_HOST\s*=\s*(\S+)", (root / "OneShot/Secrets.xcconfig").read_text())
if not found:
    sys.exit("No SUPABASE_HOST in OneShot/Secrets.xcconfig.")
host = found.group(1)
base = f"https://{host}/storage/v1/object"
headers = {"Authorization": f"Bearer {key}", "apikey": key}


def call(url, body=None):
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(url, data=data, headers={**headers, "Content-Type": "application/json"},
                                     method="POST" if body is not None else "GET")
    with urllib.request.urlopen(request, timeout=60) as response:
        return response.read()


def listing(prefix):
    items, offset = [], 0
    while True:
        page = json.loads(call(f"{base}/list/training-frames", {"prefix": prefix, "limit": 1000, "offset": offset}))
        items += page
        if len(page) < 1000:
            return items
        offset += 1000


classes = [line.strip() for line in (root / "data/labels/classes.txt").read_text().splitlines() if line.strip()]
index = {name: i for i, name in enumerate(classes)}
uuid_name = re.compile(r"^[0-9a-f-]{36}$")
sku_name = re.compile(r"^[A-Za-z0-9_.-]{1,64}$")


def box_line(box):
    """A YOLO line for a known product, None for an unknown one; raises on anything malformed."""
    values = [float(box[k]) for k in ("cx", "cy", "w", "h")]
    if not all(math.isfinite(v) and 0 <= v <= 1 for v in values) or values[2] <= 0 or values[3] <= 0:
        raise ValueError(f"box out of range: {values}")
    sku = str(box["sku"])
    if not sku_name.match(sku):
        raise ValueError(f"odd sku: {sku!r}")
    return (f"{index[sku]} " + " ".join(f"{v:.6f}" for v in values)) if sku in index else sku


(out / "images").mkdir(parents=True, exist_ok=True)
(out / "labels").mkdir(parents=True, exist_ok=True)
new_skus, fetched, skipped = {}, 0, 0
shops = [item["name"] for item in listing("") if item.get("id") is None and uuid_name.match(item["name"])]
for shop in shops:
    for item in listing(shop):
        name = item["name"]
        if not name.endswith(".json") or not uuid_name.match(name[:-5]):
            continue
        stem = name[:-5]
        target = f"{shop[:8]}-{stem}"
        if (out / "images" / f"{target}.jpg").exists():
            continue
        try:
            sample = json.loads(call(f"{base}/training-frames/{urllib.parse.quote(shop)}/{urllib.parse.quote(name)}"))
            lines, unknown = [], []
            for box in sample["boxes"]:
                line = box_line(box)
                (lines if " " in line else unknown).append(line)
            image = call(f"{base}/training-frames/{urllib.parse.quote(shop)}/{urllib.parse.quote(stem)}.jpg")
            if not image.startswith(b"\xff\xd8"):
                raise ValueError("not a JPEG")
        except Exception as error:   # one bad upload never stops the rest
            print(f"skipped {shop}/{stem}: {error}", file=sys.stderr)
            skipped += 1
            continue
        for sku in unknown:
            new_skus[sku] = new_skus.get(sku, 0) + 1
        (out / "images" / f"{target}.jpg").write_bytes(image)
        (out / "labels" / f"{target}.txt").write_text("\n".join(lines) + ("\n" if lines else ""))
        fetched += 1

# A shop that withdrew had its photos deleted on the server: drop the copies pulled before, too.
kept = {shop[:8] for shop in shops}
dropped = 0
for path in list((out / "images").glob("*.jpg")) + list((out / "labels").glob("*.txt")):
    if path.name[:8] not in kept:
        path.unlink()
        dropped += 1
(out / "new_skus.txt").write_text("".join(f"{sku}\t{n}\n" for sku, n in sorted(new_skus.items(), key=lambda x: -x[1])))
print(f"{fetched} new photos, {skipped} skipped, {dropped} withdrawn files removed -> {out}; "
      f"{len(new_skus)} products without a class (see new_skus.txt)")
