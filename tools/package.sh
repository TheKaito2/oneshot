#!/bin/zsh
# Builds the hand-in zip: the committed source (git archive of HEAD, screenshots included) plus a simulator build
# that installs with `xcrun simctl install booted OneShot.app`. Usage: tools/package.sh [out.zip]
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=${1:-$PWD/../OneShot.zip}
STAGE=$(mktemp -d)
mkdir -p "$STAGE/OneShot"
# Devpost's file upload caps at 35 MB: the light and Thai screenshot sets, the iPhone onboarding/teach shots and the training labels stay on GitHub only.
git archive HEAD -- . ':!docs/screens/en-light' ':!docs/screens/th-dark' ':!data/labels' ':(glob,exclude)docs/screens/iphone/portrait-1[4-9]-*' ':(glob,exclude)docs/screens/iphone/portrait-2?-*' | tar -x -C "$STAGE/OneShot"
xcodebuild -project OneShot.xcodeproj -scheme OneShot -configuration Release \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath build -quiet build
cp -R build/Build/Products/Release-iphonesimulator/OneShot.app "$STAGE/OneShot-simulator.app"
# Symbols out (29 -> 12 MB with the Supabase SDK linked: the zip has a 35 MB upload cap), then the simulator's ad-hoc
# signature again, which stripping invalidates.
xcrun strip "$STAGE/OneShot-simulator.app/OneShot" 2>/dev/null
codesign --force --sign - "$STAGE/OneShot-simulator.app"
cat > "$STAGE/README-FIRST.txt" <<'TXT'
OneShot — iPad cashier with on-device AI

OneShot/                 Source code (open OneShot/README.md). Build: xcodegen generate, then open OneShot.xcodeproj.
OneShot/docs/screens/    Screenshots of every page (dark, iPad and iPhone). Light and Thai sets: github.com/TheKaito2/oneshot.
OneShot-simulator.app    Ready-made build for the iPad simulator:
                           xcrun simctl install booted OneShot-simulator.app
                           xcrun simctl launch booted com.kristpaul.oneshot
                         The demo camera is on in the simulator (table photos stand in for the camera).
                         Settings › Demo adds two weeks of sample sales for Home and Reports.
TXT
rm -f "$OUT"
(cd "$STAGE" && zip -9qry "$OUT" .)   # -y keeps the .app's symlinks; -9: the 35 MB cap is close
rm -rf "$STAGE"
ls -lh "$OUT"
