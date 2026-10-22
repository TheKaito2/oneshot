# App Store listing (draft)

Fields as App Store Connect asks for them. Character limits are in brackets; every value below fits.

## Names

| Field | English | Thai |
|---|---|---|
| Name [30] | OneShot POS | OneShot POS |
| Subtitle [30] | One photo scans the counter | ถ่ายครั้งเดียว คิดเงินทั้งเคาน์เตอร์ |

"OneShot" alone may already be taken on the App Store; check in App Store Connect when creating the app record.

## Promotional text [170]

- **EN:** Hold the camera over the counter and tap once: every pack is named and priced. PromptPay QR, cash with
  change, stock and reports, all on your device.
- **TH:** ส่องกล้องเหนือเคาน์เตอร์แล้วแตะครั้งเดียว สินค้าทุกชิ้นขึ้นบิลพร้อมราคา รับเงินพร้อมเพย์หรือเงินสด
  ดูสต็อกและรายงาน ทั้งหมดอยู่บนเครื่องของคุณ

## Description [4000]

**EN**

OneShot is a cashier for small shops. Hold your iPad or iPhone over the counter and tap Scan: every pack in view
is recognised and priced from one photo. No barcode scanning one item at a time.

- One-tap checkout: the whole pile at once, recognised on the device.
- Never a guessed price: anything OneShot isn't sure about turns yellow for you to pick.
- Teach a new product in about 10 seconds: 8 photos and a price, no retraining.
- PromptPay QR with the amount filled in, or cash with the change worked out, and the total spoken in Thai.
- Receipts to share or print.
- Stock with low-stock alerts, refunds with an optional PIN, and a day close with over/short.
- Reports by day, week and month, plus a monthly statement PDF for the bank.
- Works fully offline. An optional account backs your shop up and keeps your iPad and iPhone in step.
- English and Thai.

**TH**

OneShot คือแอปแคชเชียร์สำหรับร้านค้าขนาดเล็ก ถือ iPad หรือ iPhone เหนือเคาน์เตอร์แล้วแตะ "สแกน"
สินค้าทุกชิ้นในภาพจะถูกจดจำและคิดราคาจากภาพเดียว ไม่ต้องสแกนบาร์โค้ดทีละชิ้น

- คิดเงินแตะเดียว: ทั้งกองในครั้งเดียว ประมวลผลบนเครื่อง
- ไม่เดาราคา: ชิ้นที่ไม่แน่ใจจะเป็นสีเหลืองให้คุณเลือก
- สอนสินค้าใหม่ในราว 10 วินาที: ถ่าย 8 รูปและใส่ราคา ไม่ต้องเทรนใหม่
- QR พร้อมเพย์พร้อมยอดเงิน หรือเงินสดพร้อมคำนวณเงินทอน และอ่านยอดเป็นภาษาไทย
- ใบเสร็จแชร์หรือพิมพ์ได้
- สต็อกพร้อมแจ้งเตือนของใกล้หมด คืนเงินพร้อมรหัส PIN และปิดยอดรายวัน
- รายงานรายวัน รายสัปดาห์ และรายเดือน พร้อมสรุปรายเดือนเป็น PDF สำหรับธนาคาร
- ใช้งานได้แม้ไม่มีอินเทอร์เน็ต บัญชี (ไม่บังคับ) ช่วยสำรองข้อมูลและซิงก์ iPad กับ iPhone
- ภาษาอังกฤษและภาษาไทย

## Keywords [100, comma-separated, no spaces needed]

- **EN:** `pos,cashier,shop,store,checkout,promptpay,thai,register,retail,stock,inventory,receipt,sales`
- **TH:** `แคชเชียร์,ขายของ,ร้านค้า,พร้อมเพย์,คิดเงิน,สต็อก,ใบเสร็จ,ยอดขาย,pos,ร้านโชห่วย`

## Other fields

| Field | Value |
|---|---|
| Category | Business (secondary: Finance) |
| Age rating | 4+ (no objectionable content; answer "None" throughout) |
| Price | Free |
| Support URL | https://oneshot-pos.pages.dev/#support (add the support email to the page first) |
| Privacy policy URL | https://oneshot-pos.pages.dev |
| Copyright | 2026 Krist Paul Mendoza |

## App Privacy ("nutrition label")

Matches `OneShot/PrivacyInfo.xcprivacy`:

- **Tracking:** No.
- **Data linked to you, for App Functionality only:**
  - Contact Info: Email Address, Phone Number (the PromptPay ID is often one);
  - Identifiers: User ID;
  - User Content: Photos, Other User Content (products, sales, closes, stock).
- **Collected only if the user signs in.** Without an account, nothing leaves the device.

## Screenshots

Required sizes: **6.9" iPhone** (iPhone 17 Pro Max simulator, 1320 × 2868) and **13" iPad** (iPad Pro 13-inch
simulator, 2064 × 2752).

- Source: the UI tour (`OneShotTour` scheme) on those simulators.
- Pages to use:
  1. Home
  2. Checkout with a bill
  3. Pay (QR)
  4. Products
  5. Reports
  6. Onboarding welcome
- Keep third-party brands out of the screenshots and metadata (rule 5.2). The demo tables show branded snacks, so
  use bills of taught, unbranded or own-brand items for the store images, or crop or blur pack logos.
