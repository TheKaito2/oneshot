# OneShot

An iPad cashier for a Thai corner shop. Hold the iPad over the counter and tap **Ring up**: every pack in view is named
and billed from one photo, on the device, with no internet. Then the customer pays by PromptPay QR or cash, and the shop
gets receipts, stock, a day close and reports.

Built for the Swift Coding Club TH finals (Young iOS Developer Hackathon). iPadOS 26, SwiftUI, Swift 5.

## What it does

- **One-tap checkout.** A YOLO11n Core ML detector (`Resources/Detector.mlpackage`) boxes each pack. A few-shot
  gallery of Vision FeaturePrints votes on each box too (`Recognition/Gallery.swift`). When the two agree the item goes
  on the bill (green). When they don't, it turns yellow and the cashier picks it: OneShot never guesses a price.
- **Add items.** On a frozen bill: scan more (the next frame is added to the same sale) or add an item by hand.
- **Teach a product** in about 10 seconds: 8 photos and a price, no retraining. Taught products, and learned photos
  from cashier picks, can be deleted again in Products.
- **Pay.** A dynamic PromptPay QR (EMVCo, amount locked) or cash with change. The total and change are spoken in
  Thai, and the receipt can be shared or printed.
- **Books.** A SwiftData store with sales, refunds (with an optional PIN), stock with reorder points, day close with
  over/short, and a backup.
- **Reports.** Today, yesterday, this week and this month, each against the same span before: net, gross, refunds,
  profit, by item, category and payment, bought together, OneShot speed, and a monthly statement PDF for the bank.
- **On-device AI summary** with Apple Intelligence (Foundation Models) where the iPad supports it. Elsewhere it shows
  the plain numbers.
- **English and Thai** UI, in LINE Seed Sans TH.

## Build and run

```bash
brew install xcodegen      # once
xcodegen generate          # writes OneShot.xcodeproj from project.yml
open OneShot.xcodeproj     # scheme OneShot, an iPad or the iPad simulator
```

The device build needs a development team; set `DEVELOPMENT_TEAM` in `project.yml`.

### Presenting from the simulator

The simulator has no camera, so **Demo camera** is on by default there. Four table photos from the unseen test set
(`Resources/Demo`) stand in for the live feed. **Ring up** bills the photo on screen through the same recognition
pipeline, and **Next photo** moves to the next table. On an iPad, turn it on in Checkout (**Demo**) or in Settings.

For Home and Reports to have something to show on a fresh install, use **Settings › Demo › Add two weeks of sample
sales**. It only works while the books are empty, so sample sales never mix with real ones.

Teaching a new product needs the iPad's camera.

## Tests

```bash
# 77 unit tests: bill maths, PromptPay, reports, store, stock, gallery, fonts, localization
xcodebuild test -scheme OneShot -destination 'platform=iOS Simulator,name=iPad Air 11-inch (M4)' \
  -testLanguage en -testRegion en_US

# UI tour: every page in portrait and landscape, a screenshot of each (attachments in the .xcresult)
xcodebuild test -scheme OneShotTour -destination 'platform=iOS Simulator,name=iPad Air 11-inch (M4)' \
  -resultBundlePath build/tour.xcresult
python3 tools/tour_shots.py build/tour.xcresult docs/screens/en-dark   # half-size JPEGs
```

Set `TEST_RUNNER_TOUR_LANG=th` for the Thai tour. The screenshots from the last run are in `docs/screens`
(`en-dark`, `en-light`, `th-dark`).

## Layout

| Path | What |
|---|---|
| `OneShot/Camera` | Capture session, live detection at 15 Hz, the demo feed |
| `OneShot/Recognition` | Detector, FeaturePrint gallery, instance splitter, the resolver that votes |
| `OneShot/Data` | Catalog, bill, payments (PromptPay, cash, Thai voice phrases), sales log, store, stock, reports |
| `OneShot/Views` | SwiftUI screens; `Theme.swift` and `Typography.swift` hold the design system |
| `OneShotTests`, `OneShotUITests` | Unit tests and the UI tour |
| `tools` | Training-data and asset tools (cut-outs, synthetic piles, grading, packshots, brand assets) |

The training data, runs and model sources are not in this package (several hundred MB); `tools/` shows how they were made.

## Credits

- Font: LINE Seed Sans TH © LY Corporation, SIL Open Font License 1.1 (`Resources/Fonts/OFL-LINE-Seed.txt`).
- Product pictures: retailer and brand packshots (Lotus's, 7-Eleven 7Online, lactasoy.com, Gourmet Market) with the
  backgrounds cut away, used for this demo only. They belong to their owners.
