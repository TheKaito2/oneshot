# OneShot: production-readiness plan

Written 19 Oct 2026, after the YIDH finals (2nd place). The goal: a build a real Thai corner shop can run all day,
that we can ship on the App Store, with nothing in it we don't have the right to ship.

## Where it stands (measured from the repo today)

| Area | State | Production problem |
|---|---|---|
| Detector | `Resources/Detector.mlpackage` = Ultralytics YOLO11n, **AGPL-3.0** (in the model metadata). 12 fixed SKUs, trained on 1,193 synthetic piles + 32 real tables. Exam (`tools/grade.py`, 42 real tables): 338/339 right, 40/42 exact bills. | Shipping it closed-source needs an Ultralytics Enterprise licence. And 12 baked-in classes can't fit a real shop with hundreds of products. |
| Naming new products | FeaturePrint gallery + instance splitter; "Teach a product" in ~10 s, no retraining. | This is already the scalable part. Its accuracy at hundreds of SKUs is unmeasured. |
| Catalog | Bundled `catalog.json` (12 products) plus loose JSON files in Documents: `quickadd.json`, `prices.json`, `costs.json`, `barcodes.json`, `gallery.json`, `Crops/`. | A shop starts with someone else's 12 snacks. There's no product edit or delete flow for the whole catalog. Data sits in six formats, and the backup misses most of it. |
| Books | SwiftData with versioned schema + migrations (`Store.swift`), unreadable store set aside, Keychain refund PIN, backup of sales/closes/stock as JSON. | The backup leaves out the catalog, prices, costs, barcodes and taught photos. Restore means copying files by hand in the Files app. If the store can't be moved aside, the app hits `fatalError`. |
| Images | Brand/retailer packshots (Lotus's, 7-Eleven, lactasoy.com, Gourmet Market). | That's copyrighted material we don't hold a licence for. |
| Hackathon-only bits | Stage race timer (`Race.swift`, `RaceView.swift`), demo camera, sample sales, debug overlay. | Judges' tools, not shop tools. The demo mode is still useful for App Review. |
| Quality | 77 unit tests, UI tour (iPad + iPhone), Swift 5 language mode, `print` logging. No crash reporting, no privacy manifest. | No field diagnostics. Required App Store pieces are missing. |
| Repo | 19 commits, **no git remote**. iPhone layout work uncommitted. | One disk failure loses everything. |
| Environment | M1 MacBook Air, 8 GB RAM, 25 GB free, Xcode 26.6. | Create ML training fits, but one heavy job at a time. |

## Licence picture

| Part | Licence | Action |
|---|---|---|
| YOLO11n detector + `ultralytics` training code | AGPL-3.0 | **Replace** with a Create ML model (owned by us, no fee, no attribution). |
| Create ML, Core ML, Vision (FeaturePrint, instance masks), Foundation Models, AVFoundation | Apple SDK | Free with the Apple Developer Program. |
| LINE Seed Sans TH | SIL OFL 1.1 | Keep; the credit is already in Settings. |
| Product packshots | Brands' / retailers' copyright | **Remove.** Products show the shop's own taught photos; demo uses our own shoot. |
| PromptPay QR | EMVCo / BOT open standard | Free to generate. Use the word "PromptPay" only; don't ship the logo without checking its usage rules. |
| Training photos (`data/raw`) | Ours | Keep. |

## Phases

Each phase ends with a gate: a measured check that has to pass before the next phase starts.

### Phase 0: Secure what exists (small)

1. Commit the iPhone layout work (compact layouts, ticket-row fit, hide dead controls on short screens, tour retry).
2. Create a **private** GitHub repo and push. The training data (464 MB) stays out of git; archive `data/` + `runs/`
   to an external disk or iCloud.
3. Rebuild the zip.

**Gate:** `git push` succeeds, iPhone + iPad tours pass, 77 tests pass.

### Phase 1: Licence-clean recognition (the core work)

1. **Grading harness that doesn't use Ultralytics.** A macOS Swift command-line tool
   (`tools/grade.swift`) runs any `.mlmodel` through Vision the way the app does. It uses the same floor, NMS, merge
   and Resolver, and grades `data/raw/mixed-test` against `data/exam-truth.tsv`. First calibration check: it has to
   reproduce today's YOLO11n numbers (338/339, 40/42 exact). Until it does, it can't judge a replacement.
2. **Convert the dataset.** Turn the YOLO labels (`data/yolo`) into Create ML's JSON annotation format with a short
   script. This covers train (1,193) and val (130).
3. **Train two Create ML candidates** (`CreateML` framework, `MLObjectDetector`, scripted so it's reproducible):
   - **A. 12-class drop-in.** Same job as today, compared head to head with YOLO11n.
   - **B. Class-agnostic "item" detector** (one class). It finds packs; the FeaturePrint gallery names them. This
     is the shape that scales to a real shop: a new product needs a teach, never a retrain. Also train it with the
     `unknown` / distractor photos so it boxes products it has never seen.
   - Try both Create ML algorithms (transfer learning on Apple's feature extractor, and full network), within what 8 GB
     allows.
4. **Measure A and B** with the harness: exact bills, wrong-price units (the number that must stay near 0), misses,
   yellows. For B, also measure the gallery's naming at scale: teach 30–50 extra real products and re-run.
5. **Swap in the winner.** Update `Detector.swift` decoding if the output shape differs, drop the YOLO model and the
   `ultralytics` tools (`grade.py`, `predict_sheet.py`) from the shipped repo, and record the model card (data,
   date, scores) in `docs/`.
6. **Live check** on a real iPad: fps and Hz in the debug HUD (target: today's ~30 fps / 15 Hz), and 20 real
   counter rings.

**Gate:** zero AGPL code or weights in the app or repo. Exam: wrong-price units ≤ today's (1), exact bills ≥ 38/42.
If neither candidate gets there, more real training photos come before shipping. We don't ship a worse till.

### Phase 2: The shop owns its data

1. **Catalog in SwiftData.** Products (name, Thai name, price, cost, size, category, barcode, photos, stock,
   reorder point) move into the store as `StoreV3` with a `MigrationStage`. The loose JSON files are imported once,
   then retired.
2. **Products screen** becomes full management: add, edit, archive (old sales still name it), delete-if-never-sold.
   Plus **CSV import** for a shop's price list, and a barcode scan to fill in a product.
3. **First-run onboarding:** shop name, PromptPay ID, refund PIN (optional), then teach or import the first
   products. A fresh install starts empty. The bundled 12 products only appear in the demo.
4. **One backup, one restore.** A single `.oneshotbackup` archive holds the books, catalog, prices, taught photos and
   gallery. Restore runs from inside the app, with a preview ("312 sales, 84 products, last sale 18 Oct") before it
   replaces anything. Add an optional automatic daily backup to iCloud Drive.
5. **No `fatalError` on user data.** If the store can't open, show a recovery screen (restore a backup, or export
   the unreadable files) instead of crashing.

**Gate:** migration tests (V2 → V3 store with real-shaped data opens, nothing lost). Backup round trip test
(back up → wipe → restore → identical reports). Fresh-install walkthrough on the iPad, as the owner, with no
help.

### Phase 3: Hardening

1. **Remove hackathon-only features:** race timer, stage controls, sample sales button. Keep **Demo mode**, moved
   under Settings › Demo, so App Review and shop demos work without products.
2. **Logging and diagnostics:** `os.Logger` instead of `print`, plus **MetricKit** crash and hang reports (Apple,
   free, no third-party SDK) shown in Settings › Diagnostics for the owner to share.
3. **Swift 6 language mode:** turn on complete concurrency checking and fix what it finds. Camera, detector and
   gallery threading is where the freezes came from before.
4. **Error paths a cashier can act on:** camera denied, detector failed to load, disk full, store busy. Each one
   gets plain text and a next step, in Thai and English.
5. **Real-shop conditions on the iPad:** low light, glare on foil packs, a cluttered counter, a hand in frame, 40+
   items in one ring. Fix what breaks, or say on screen what to do ("more light").
6. **Endurance:** an 8-hour soak on the iPad (camera on, a ring every few minutes). Watch memory, heat, battery,
   and the database size after 10,000 sales (report speed).
7. **Accessibility pass:** VoiceOver labels, Dynamic Type (the checkout is capped at xxxLarge; check the rest),
   contrast, Reduce Motion.

**Gate:** soak completes with no crash, no growth in memory, no thermal throttling that drops below 10 Hz. All
tests pass in Swift 6 mode.

### Phase 4: Compliance and shipping

1. **Apple Developer Program** (US$99/year; the account holder must be 18 or older, so a parent can enrol if
   needed). Own bundle ID, not `com.krist.hackday.*`.
2. **Privacy manifest** (`PrivacyInfo.xcprivacy`): declare UserDefaults (reason CA92.1) and file timestamp use,
   no tracking, no collected data. App Store privacy label: **Data Not Collected**. Everything stays on the device.
3. **Privacy policy + support page:** a two-page site on Cloudflare Pages, in Thai and English (PDPA: no
   personal data leaves the device; the shop's data is the shop's).
4. **App Store listing** in Thai and English: screenshots from the tour (iPad, and iPhone if it ships in v1),
   description, keywords. Notes for App Review explain Demo mode.
5. **TestFlight pilot:** 1–2 real shops for 2 weeks. Log wrong prices, yellows per ring, rings per day and
   crashes, then fix and repeat.
6. **1.0 release**, then a simple release routine: version/build bump, tests, tour, archive, TestFlight, release.

**Gate:** pilot shops run a full week with zero wrong-price incidents they didn't catch on the screen.

## Known limits we accept for v1 (stated, not hidden)

- **PromptPay isn't verified automatically.** The cashier still taps Paid after seeing the bank notification.
  Automatic verification needs a bank or slip-check API, which means a business account and a per-check fee.
  Revisit after the pilot.
- **No VAT tax invoice** (ใบกำกับภาษี). Most corner shops aren't VAT-registered. Add it only if a pilot shop needs it.
- **One device per shop.** No sync between iPads and no cloud account. Backups move data.
- **Recognition is for packaged goods.** Loose produce and items sold by weight go through Add item by hand.

## Open decisions (defaults in bold, change any)

1. Detector shape: **train both A and B, ship whichever the exam picks**, preferring B if it's within 1 exact bill.
2. iPhone in v1: **yes**. The layouts are already done; the tour covers it.
3. Pilot shop: needs a real shop. Whose?
4. Minimum iPadOS: **26** (as now; Foundation Models and Liquid Glass need it).
5. Price: **free for the pilot**. Decide pricing after it.
