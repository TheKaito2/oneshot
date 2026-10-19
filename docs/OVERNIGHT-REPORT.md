# Overnight report: 19 → 20 October 2026

Everything below is committed and pushed to the private repo **github.com/TheKaito2/oneshot**. The hand-in zip
`~/Hackday/OneShot.zip` was rebuilt from the last commit.

## The short version

- **The shipped detector is still YOLO11n (AGPL).** No Create ML model came close on the exam tonight, so the gate
  kept the old one, as the plan said. Numbers are below; full detail is in `docs/MODEL-COMPARISON.md`.
- **Everything else in the no-input part of the plan is done:**
  - iPhone support;
  - backup and restore of everything;
  - crash diagnostics;
  - privacy manifest;
  - a live privacy/support page;
  - Swift 6 mode;
  - `os.Logger`;
  - the race timer removed;
  - device-neutral wording;
  - a Swift exam grader with no Ultralytics in it.
- **Tests:** 74 unit tests pass. The UI tour passes on the iPad (portrait and landscape, 27 screenshots) and the
  iPhone (portrait, 13 screenshots).
- **iPhone "Rishi":** the Release build installs and is signed. Launch was refused because the phone was locked. See
  "What needs you".

## Detector: can Create ML replace YOLO11n?

All models were measured with `tools/grade` on the 42-photo exam, running the app's real lock path.

| Model | Exact bills | Wrong prices | Right |
|---|---|---|---|
| **YOLO11n, today's app** | **40/42** | 2 | 339/339 |
| Create ML transfer learning (299 px) | 5/42 | 107 | 272/339 |
| Transfer learning, tiled (frame + 4 tiles) | 8/42 | 30 | 260/339 |
| Create ML full network (darknetYolo, 416 px, tiled), iteration 200 of 1,500 | 5/42 | 73 | 261/339 |
| darknetYolo, latest checkpoint | see `runs/createml/cm-darknet-grades.txt` (still training) | | |

**Why transfer learning loses:** its input is fixed at 299 × 299. A full counter of 12+ packs shrinks to about 70 px
per pack, and the ObjectPrint features can't separate look-alikes such as the Lay's flavours and sizes. Tiling
helped recall but not the misreads.

**darknetYolo** is Create ML's full network. It trains much more slowly on this Mac, about 2.6 iterations a minute.
It keeps running, and `tools/watch_checkpoints.sh` grades every checkpoint as it lands. It's improving: iteration 100
got 177 right, iteration 200 got 261. If a checkpoint reaches **≤ 1 wrong and ≥ 38/42 exact**, that's the one to ship
(see "How to swap in a Create ML model" below). If none does, the realistic options are:

1. **More real counter photos.** Today there are only 32 real training tables, and the other 800 images are
   synthetic. That's the biggest lever for any model.
2. **A permissively licensed detector** (YOLOX or D-FINE, Apache-2.0) trained in PyTorch and converted with
   coremltools. That's a bigger job, but the model is ours.
3. **Pay Ultralytics**, or open-source OneShot under AGPL.

**Also found:**
- The "class-agnostic detector + FeaturePrint names it" idea doesn't work: 11/42 exact at best, with 46 wrong prices.
- On a fresh install, the gallery vote turns 13 exact bills into yellows (not wrong prices). Recheck this on a device
  that has taught products before changing `gallerySure`.

### How to swap in a Create ML model
```bash
git rm -r OneShot/Resources/Detector.mlpackage
cp models/cm-darknet-<iteration>.mlmodel OneShot/Resources/Detector.mlmodel   # Xcode compiles it to Detector.mlmodelc
xcodegen generate
```
`Detector.swift` switches to tiled lock-time detection by itself when the model's input is under 600 px. Live
detection stays one pass a frame.

## What changed (commits)

| Commit | What |
|---|---|
| `99498e7` | iPhone support: compact layouts, stacked ticket rows, portrait-only phone |
| `6a2b3bd` | One-folder **backup** (books plus taught products, prices, costs, barcodes, photos), in-app **restore** with preview, MetricKit **diagnostics**, **PrivacyInfo.xcprivacy**, `os.Logger`, race timer removed, Swift grader |
| `c106ac6` | **Swift 6** language mode (3 fixes); tiled detection for small-input models |
| `93009d6` | iPhone bill shows full rows; "iPad" wording made device-neutral (Thai too); 15 new strings translated, 29 dead keys dropped; tour waits instead of sleeping |
| `7290732` | Tour retries swallowed taps; fresh screenshots in `docs/screens/en-dark` (iPad) and `docs/screens/iphone` |

- **Privacy and support page:** <https://oneshot-pos.pages.dev> (source `site/index.html`). It's linked in
  Settings › About.
- **Production plan:** `docs/PRODUCTION-PLAN.md`.

## What needs you

1. **Unlock the iPhone (Rishi) and open OneShot.** It's installed. Check:
   - cold launch;
   - Demo → Ring up (FeaturePrint works on a real device, unlike the simulator);
   - Settings › Backup.
2. **Support contact for the policy page.** I left your email off the public page on purpose. Give me the address or
   LINE OA to show, and I'll redeploy.
3. **Apple Developer Program** ($99/year; the account holder must be 18+, so a parent can enrol). The bundle ID
   `com.krist.hackday.oneshot` should change to your own before App Store submission.
4. **Packshot copyright.** The brand and retailer product photos are fine for a demo but risky in a shipped app. You
   chose to keep the 12 snacks; decide whether their pictures switch to our own photos.
5. **The landscape sidebar on iPad.** The app launches with the top tab bar. After rotating to landscape, iPadOS shows
   the sidebar (it applies the default placement only at launch). Making it never show means dropping the sidebar
   entirely (`.tabBarOnly`). Your call.
6. **The detector decision**, after darknet finishes, from the table above.

## Small things noted

- The wrangler cache (Cloudflare account ID, no tokens) was committed once and then removed. It's still in the
  private repo's history.
- YOLO11n's weights are in the repo history (private repo, fine). Once a Create ML model ships, the AGPL weights
  leave HEAD.
