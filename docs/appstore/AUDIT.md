# App Review Guidelines audit (OneShot 1.0)

Checked on 23 October 2026 against Apple's App Review Guidelines, last updated 16 October 2026
(https://developer.apple.com/app-store/review/guidelines/), every section from 1 to 5.

- **Fixed** means it was changed in commit `23dd5ee` or earlier today.
- **You** means a step only Krist can do, in App Store Connect or with a decision.

## Blockers: fix before submitting

| # | Guideline | Problem | What to do |
|---|---|---|---|
| 1 | 5.2.1 (IP), licences | **The bundled detector is Ultralytics YOLO11n (AGPL-3.0).** Its terms conflict with App Store distribution. | **Finish the YOLOX-Tiny (Apache-2.0) training and swap it in.** Training stopped at epoch 14/60 (`runs/yolox/tiny416.out`). Gate: wrong ≤2, exact ≥38/42. |
| 2 | 5.2.1 (IP) | **The chameleon logo and app icon come from an image found on Google**, with no licence. | **Replace them with original art** (a friend's drawing is planned). `tools/make_brand.py` rebuilds every icon from a new SVG/PNG. |
| 3 | 2.3.3, 2.3.9, 5.2.1 | **App Store screenshots** would show other companies' trademarks (Lay's, KitKat, M&M's…). | **Make the store screenshots** with own-brand or unbranded products, or crop/blur the logos. The in-app sample snacks stay; onboarding no longer names the brands. |
| 4 | 2.1(a) | **The backend must be live during review.** Supabase's free plan pauses after 7 idle days. | **Upgrade Supabase to Pro**, or open the app daily while it's in review. |

## Section by section

### 1 Safety

| Guideline | Status | Evidence |
|---|---|---|
| 1.1 Objectionable content | Pass | A cashier tool; no such content. |
| 1.2 User-generated content | Pass | Nothing one user posts is shown to others. Training photos go only to the developer. |
| 1.3 Kids | N/A | Not in the Kids category. |
| 1.4 Physical harm | Pass | No medical or dangerous use. |
| 1.5 Developer information | **Fixed** | Settings › Help › **Contact support** opens the support form at oneshot-pos.pages.dev/#support (`support` Edge Function). Support URL for App Store Connect: `https://oneshot-pos.pages.dev/#support`. |
| 1.6 Data security | Pass | RLS on every table and bucket (78/78 tests on the live project). The service key never ships. HTTPS only. Security review of training photos done and fixed (`dda534d`). |
| 1.7 Reporting crime | N/A | |

### 2 Performance

| Guideline | Status | Evidence |
|---|---|---|
| 2.1(a) Completeness | Pass, with blocker 4 | iPhone and iPad tours pass. The demo camera lets review try scanning without the snacks. Sign in with Apple works with any Apple ID, so no demo account is needed. Steps are in `REVIEW-NOTES.md`. |
| 2.1(b) IAP | N/A | No in-app purchases. |
| 2.2 Beta | Pass | A final build, not a beta or trial. |
| 2.3 Metadata | Pass, with blocker 3 | `LISTING.md` describes only real features and says "Scan". |
| 2.3.6 Age rating | **You** | Answer "None" to every content question → 4+. |
| 2.3.7 Name | **You** | "OneShot POS" (11 characters). Check it's free when creating the app record. |
| 2.4.1 iPad | Pass | A universal app with iPad layouts. |
| 2.4.2 Power | Pass | The camera pauses off Checkout. Training uploads only on Wi-Fi. No background modes. |
| 2.5.1 Public APIs | Pass | Public SDK only. Foundation Models is on-device. |
| 2.5.2 Self-contained | Pass | No downloaded code. Photos synced from the account are data. |
| 2.5.4 Background | Pass | No `UIBackgroundModes`. |
| 2.5.5 IPv6 | Pass | URLSession to HTTPS hostnames only. |
| 2.5.14 Recording | **Fixed** | Training photos are opt-in. When they're on, the cart shows "This photo helps improve OneShot". |
| 2.5.19 Hidden features | **Fixed** | The Debug section is compiled out of release builds. The `-debugMenu` switch is gone. |

### 3 Business

| Guideline | Status | Evidence |
|---|---|---|
| 3.1.1 IAP | N/A | Free, no digital goods. |
| 3.1.3(e) Physical goods | Pass | The PromptPay QR collects payment for the shop's own physical goods. OneShot never handles money. |
| 3.2.1(viii) Financial apps | Pass | A point-of-sale tool, not a financial service. It makes standard PromptPay QR codes. |

### 4 Design

| Guideline | Status | Evidence |
|---|---|---|
| 4.1 Copycats | Pass, with blocker 2 | The app's own design. The icon is being replaced. |
| 4.2 Minimum functionality | Pass | A full native app. |
| 4.8 Login services | Pass | Google sign-in is offered alongside **Sign in with Apple** (email can be hidden; name and email only). |
| 4.10 Built-in capabilities | Pass | The camera isn't monetised. |

### 5 Legal

| Guideline | Status | Evidence |
|---|---|---|
| 5.1.1(i) Privacy policy | Pass, **Fixed** | Linked in Settings and at oneshot-pos.pages.dev. Covers what's collected, why, retention (account data until the account is deleted; training photos up to 2 years, enforced by a daily job) and deletion. Privacy-policy URL for App Store Connect: `https://oneshot-pos.pages.dev`. |
| 5.1.1(ii) Permission | Pass | The camera purpose string is clear. Training photos only after explicit opt-in, and it's easy to turn off. |
| 5.1.1(iii) Minimisation | Pass | The photo-library picker is out of process (`PhotosPicker`, no library permission). |
| 5.1.1(v) Account sign-in and deletion | Pass | The account is optional. Settings › Account › Delete account removes the server data and revokes the Apple token, verified on iPhone 22 Oct. Sign out disconnects. |
| 5.1.1(x) Contact info | Pass | Nothing required. |
| 5.1.2(i) Use and sharing | Pass | No third parties and no tracking. Training is first-party and opt-in, with no third-party AI. |
| 5.1.2(ii) Repurposing | Pass | Training needs its own consent (`training_consent`). |
| 5.1.2(vi) Camera data | Pass | No depth data. Photos aren't used for marketing. |
| Privacy manifest | **Fixed** | `PrivacyInfo.xcprivacy` declares the collected types and the required-reason APIs: UserDefaults CA92.1, file timestamp C617.1, boot time 35F9.1. |
| App privacy label | **You** | In App Store Connect: Email, User ID, Phone number (PromptPay ID), Photos (App Functionality + **Analytics**) and Other user content (sales). All are linked to the user, and none is used for tracking. |
| 5.2.1 IP | Blockers 1–3 | Fonts are LINE Seed (OFL, notice in About). Charts and the PDF are our own. |
| 5.2.4 Apple endorsement | Pass | No such claim. |
| 5.3–5.5 | N/A | No gambling, VPN or MDM. |
| 5.6 Code of conduct | Pass | No review prompts, no dark patterns. |

## Export compliance

`ITSAppUsesNonExemptEncryption = NO` is set: the app uses HTTPS and SHA-256 only, which counts as exempt.
