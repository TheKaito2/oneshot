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
    with urllib.request.urlopen(request) as response:
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
(out / "images").mkdir(parents=True, exist_ok=True)
(out / "labels").mkdir(parents=True, exist_ok=True)
new_skus, fetched = {}, 0
for shop in (item["name"] for item in listing("") if item.get("id") is None):   # folders = shops
    for item in listing(shop):
        name = item["name"]
        if not name.endswith(".json"):
            continue
        stem = name[:-5]
        target = f"{shop[:8]}-{stem}"
        if (out / "images" / f"{target}.jpg").exists():
            continue
        sample = json.loads(call(f"{base}/training-frames/{shop}/{name}"))
        lines = []
        for box in sample["boxes"]:
            if box["sku"] in index:
                lines.append(f'{index[box["sku"]]} {box["cx"]:.6f} {box["cy"]:.6f} {box["w"]:.6f} {box["h"]:.6f}')
            else:
                new_skus[box["sku"]] = new_skus.get(box["sku"], 0) + 1
        (out / "images" / f"{target}.jpg").write_bytes(call(f"{base}/training-frames/{shop}/{stem}.jpg"))
        (out / "labels" / f"{target}.txt").write_text("\n".join(lines) + ("\n" if lines else ""))
        fetched += 1
(out / "new_skus.txt").write_text("".join(f"{sku}\t{n}\n" for sku, n in sorted(new_skus.items(), key=lambda x: -x[1])))
print(f"{fetched} new photos -> {out}; {len(new_skus)} products without a class (see new_skus.txt)")
