# Detector comparison: YOLO11n (AGPL) against Create ML (owned)

Measured 20 Oct 2026 with `tools/grade` on the exam: 42 real counter photos, 339 units, `data/raw/mixed-test`
against `data/exam-truth.tsv`. The grader runs the app's own lock path on the Mac: detector boxes down to the
0.25 floor, `Gallery.mergeOverlaps`, mask instances, FeaturePrint gallery from the bundled seed photos, and
`Resolver.verdict`. Rebuild and rerun:

```bash
swiftc -O tools/grade/main.swift OneShot/Recognition/{Resolver,Detector,Splitter}.swift OneShot/Log.swift -o build/grade
build/grade <model>            # add --merge 0.3 to change Gallery.mergeOverlaps' IoU
```

**Wrong** means billed units that aren't on the table: a wrong price. That's the number that must stay near zero.
**Exact** means bills with nothing wrong and nothing missed.

## Results

| Model | Input | Training | Best setting | Right | Wrong | Exact bills | ms/photo (Mac) |
|---|---|---|---|---|---|---|---|
| **YOLO11n** (Ultralytics, AGPL-3.0, today's app) | 640 | 1,176 images, fine-tuned from COCO | detector 0.7, gallery 0.85 | 339/339 | 2 | **40/42** | 17 |
| Create ML transfer learning | 299 | same images, 1,500 iter, 34 min | detector 0.7, gallery 0.8 | 272/339 | 107 | 5/42 | 14 |
| Create ML transfer learning on tiles, tiled inference | 299 ×5 | 5,089 tiles, 1,500 iter, 44 min | merge 0.3, detector 0.8 | 260/339 | 30 | 8/42 | 125 |
| Create ML full network (darknetYolo) on tiles, tiled | 416 ×5 | 5,089 tiles, 1,500 iter (running) | — | — | — | — | — |

## What the numbers say

- **The Swift grader matches the old Python one** within one unit on YOLO11n: 40/42 exact both ways. So it's fair to
  judge Create ML models with it.
- **Create ML transfer learning can't do a full counter.** Its input is a fixed 299 × 299. A 1280 px photo of 12+
  packs shrinks each pack to about 70 px, and the model fragments and misreads them: 491 boxes for 339 units.
  Tiling (frame + 4 overlapping tiles, `Detector.tiles`) recovers recall. The misreads remain, and transfer
  learning on ObjectPrint features can't separate the look-alikes (Lay's flavours and sizes).
- **The class-agnostic "item" detector idea is dead for now.** Naming every box with the seed-only FeaturePrint
  gallery bills at best 11/42 exactly, with 46 wrong prices. FeaturePrint is too generic to tell the 12 snacks apart
  from a few views.
- **The gallery vote costs exact bills on a fresh install.** With seed photos only, `gallerySure` 0.78 drops
  YOLO11n from 40/42 to 27/42. Those become yellows, not wrong prices: the gallery is sure of a different product,
  so the Resolver asks the cashier. On the iPad, real taught crops scored 0.84–0.87, so raising the threshold would
  stop taught products from going green. Leave it until it's measured on a device with taught products.
