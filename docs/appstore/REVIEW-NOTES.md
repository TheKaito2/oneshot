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

**Account (optional).** The app works fully without an account. Signing in (an emailed one-time code) adds backup and
sync across the owner's devices. Demo account for review:

- Email: `<review account email>`
- Password: `<review account password>`. On the sign-in screen, tap "Use a password instead".

Account deletion: Settings › Account › Delete account. It removes the account and all its server data at once
(guideline 5.1.1(v)).

**Payments.** PromptPay QR codes request payment for the physical goods the shop sells, from the customer's bank app
to the shop's account. OneShot never handles money and sells no digital content (guideline 3.1.3(e)).

**Permissions.**
- **Camera:** recognising products and teaching new ones.
- **Photos:** only when the user picks a photo to bill (the "Photo" button).

---

## Before submitting (Krist)

1. Create the review account with a password in the Supabase dashboard (Authentication › Users › Add user), and
   give it a sample shop: sign in once on a simulator, add the 12 samples and two weeks of sample sales, and sync.
2. Fill in the email above. Check that Demo mode is on in the review build's Settings and that the backend is
   running.
3. Support email on https://oneshot-pos.pages.dev.
