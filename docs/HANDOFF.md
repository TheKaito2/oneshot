# OneShot handoff (23 Oct 2026)

Repo `~/Hackday/oneshot` (public, github.com/TheKaito2/oneshot). Branch `main` is pushed; the latest commit is
`8d1d99e`. Nothing is uncommitted.

## What's in progress: hackathon demo video

Krist's request:
1. **Shot list:** a step-by-step of where to go and when, for a live demo video. **Done:**
   `docs/demo/DEMO-SCRIPT.md`.
2. **Intro clips:** heavily edited, to open the video. Krist wants **both** styles, all in English:
   - **A. Apple-style launch film:** about 15 s, 1920×1080, 60 fps. Archetype B in the video-editor skill's
     `references/style-atlas.md`.
   - **B. Hype showreel:** about 11 s, 120 BPM, colour floods, one-word cuts. Archetype A; the template is
     `~/.claude/skills/video-editor/templates/showreel/`.

The whole video runs 2–6 min. Krist records the live demo on **both iPhone and iPad**. The intro has no
upload size limit, so aim for the highest quality.

**Where the intro work stopped:**
- The `video-editor` skill is loaded; read its SKILL.md and `references/motion-piece-workflow.md` first.
- Footage folder created: `~/Projects/video-editor-lab/drills/oneshot-intro/footage/` (empty).
- The iPad Pro 13" simulator (`81333DED-706D-48AF-B364-E6A9C03CDF20`) is booted.
  - OneShot is installed with the demo camera on. The status bar is overridden to 9:41.
  - Next: record hero clips with `xcrun simctl io <udid> recordVideo --codec h264 --force <file>.mp4` (stop with
    SIGINT), driving taps with the iOS simulator tool.
  - Landscape rotation was attempted (menu Device › Rotate Left was clicked) but not confirmed; check before
    recording. The raw framebuffer may need `transpose` in ffmpeg.
- The iPhone 17 simulator is `B06728DC-456F-487C-9056-5916E993974E`.
  - Debug app build: `build/dd-tour/Build/Products/Debug-iphonesimulator/OneShot.app`.
  - Build it with `xcodebuild build -scheme OneShotTour -destination id=<sim> -derivedDataPath build/dd-tour`.

**Hero clips to record:**
1. **iPad Checkout:** live boxes, then Scan (shutter, green boxes, chime), then the cart fills and shows the total.
2. **iPad payment:** Charge, then the PromptPay QR with the Thai total.
3. **iPhone Scan:** the cart slides in, then a swipe between Scanner and Cart.
4. **iPhone Reports:** expand a chart (⤢) and scrub.
5. **Products grid and Home** with numbers. Make a few sales first, so today's KPIs aren't ฿0.

**Then:**
1. `python3 ~/.claude/skills/video-editor/scripts/mx.py new -o <proj> --theme oneshot-dark|light --dur 15`.
2. Invoke the `hyperframes` skill before writing any composition HTML.
3. Build with `MX.device` frames around the clips, the type moves and the wordmark squash.
4. Sound with `synth_beat.py` + `mux_audio.py` (−14 LUFS, true peak ≤ −1 dBTP).
5. Check with `look.py` and a critic sub-agent loop, as the skill's §6 says.

**Disk:** about 6 GB free after deleting regenerable build output. Keep only one heavy job at a time (8 GB RAM).

## Done today (all pushed)

| Commit | What |
|---|---|
| `3c2b1f8` | **Zip retired:** the 35 MB hand-in zip is no longer required. The full-quality app icon, logo and chameleon art are restored, and tour screenshots export at full size. Product photos stay our own shots (App Store 5.2). Memory rule updated. |
| `b1712f7`, `23dd5ee` | **Bottom bar:** iPhone pages' scroll content now clears the custom bottom bar (`.contentMargins(.bottom, PhoneTabBar.clearance)`); the scanner/cart pager is set back to 0. |
| `23dd5ee` | **App Store audit fixes:** Debug compiled out of release; a training-photo indicator in the cart; Settings › Contact support goes to a web form (Edge Function `support` + table `support_messages`, live); onboarding no longer names snack brands; the privacy manifest has the required-reason APIs; policy retention wording. |
| `3146ac2` | **`docs/appstore/AUDIT.md`:** the full guideline-by-guideline audit (16 Oct 2026 edition). |
| `dda534d`, `361edd7` | **Opt-in training photos:** Supabase `training-frames` bucket, `training_consent` table, RLS 78/78, a daily retention job (`training-retention` function via pg_cron, secret in Vault). Verified on iPhone: labels correct, face blur works, withdrawal deletes everything. |

## Still blocking the App Store (`docs/appstore/AUDIT.md`)

1. **Detector licence:** the detector is still YOLO11n (AGPL-3.0). The YOLOX-Tiny training stopped at epoch
   14/60 (`runs/yolox/tiny416.out`). Gate: wrong ≤ 2 and exact ≥ 38/42.
2. **Logo and app icon:** they come from a Google image. A friend will redraw them.
   - AI candidates (FLUX.1 schnell) are in the old session's scratchpad.
   - Rebuild every icon with `tools/make_brand.py`.
3. **Store screenshots:** they must not show brand logos.
4. **Backend uptime:** Supabase Pro, or keep the project active during review.
5. **Krist in App Store Connect:**
   - privacy label (Photos: + Analytics);
   - age rating 4+;
   - support URL `https://oneshot-pos.pages.dev/#support`;
   - privacy URL `https://oneshot-pos.pages.dev`;
   - review notes from `REVIEW-NOTES.md`.

## Standing preferences

- **Replies:** caveman terse in chat. Docs and commits in normal prose.
- **Code:** ponytail-minimal.
- **New features:** research first, ask permissions in one round, then plan mode to write the plan, then execute.
- **Commits:** commit and push after each fix (established). End commits with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- **Verification:** verify on the simulator or device, never "looks right".
- **Never** put secrets in files or chat. The service key stays in env/Vault only.
