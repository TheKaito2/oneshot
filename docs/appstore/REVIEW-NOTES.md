# Notes for App Review (draft)

Paste into App Store Connect › App Review Information › Notes.

---

OneShot is a point-of-sale app for small shops. The camera recognises the packaged products on a counter from one
photo and bills them; customers pay by PromptPay QR or cash.

**Testing without products or a counter.** Recognition needs real products in front of the camera, so OneShot
includes a Demo mode:

1. Settings (gear on Home) › Demo › turn on **Demo camera**.
2. Open **Checkout** and tap **Ring up**. A bundled table photo stands in for the camera and is billed through the
   same recognition pipeline.
3. Tap **Next photo** for another table.

Onboarding's "Try it with 12 sample snacks" adds the products those photos contain. Settings › Demo › "Add two
weeks of sample sales" fills Home and Reports (only while the books are empty).

**Account (optional).** The app works fully without an account. Signing in with Apple or Google adds backup and
sync across the owner's devices. App Review can use Sign in with Apple with any Apple ID; no demo account is needed.

Account deletion: Settings › Account › Delete account. It removes the account and all its server data at once
(guideline 5.1.1(v)).

**Training photos (optional, off by default).** Settings › Help improve OneShot, or a one-time card on Home
after 5 sales (signed in only), asks the owner to share counter photos of paid sales to train OneShot's own
recognition models. Nothing is collected before the owner taps Allow or turns the switch on. Faces are blurred on
the device before upload; Wi-Fi only, at most 50 a day; no prices, shop name or payment details. Turning it off
deletes every photo already sent; account deletion does too. Not shared with any third party or third-party AI
(guidelines 5.1.1, 5.1.2). Policy: https://oneshot-pos.pages.dev/#training

**Payments.** PromptPay QR codes request payment for the physical goods the shop sells, from the customer's bank app
to the shop's account. OneShot never handles money and sells no digital content (guideline 3.1.3(e)).

**Permissions.**
- **Camera:** recognising products and teaching new ones.
- **Photos:** only when the user picks a photo to bill (the "Photo" button).

---

## Before submitting (Krist)

1. Check that Sign in with Apple works in the review build (it needs the production bundle ID).
2. Check that Demo mode is on in the review build's Settings and that the backend is
   running.
3. Support email on https://oneshot-pos.pages.dev.
4. App Store Connect › App Privacy: Photos or Videos → purposes App Functionality **and Analytics** (training photos),
   linked to the user, not used for tracking. Matches OneShot/PrivacyInfo.xcprivacy.
