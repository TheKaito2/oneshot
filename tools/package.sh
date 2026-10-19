#!/bin/zsh
# Builds the hand-in zip: the committed source (git archive of HEAD, screenshots included) plus a simulator build
# that installs with `xcrun simctl install booted OneShot.app`. Usage: tools/package.sh [out.zip]
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=${1:-$PWD/../OneShot.zip}
STAGE=$(mktemp -d)
mkdir -p "$STAGE/OneShot"
git archive HEAD | tar -x -C "$STAGE/OneShot"
xcodebuild -project OneShot.xcodeproj -scheme OneShot -configuration Release \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath build -quiet build
cp -R build/Build/Products/Release-iphonesimulator/OneShot.app "$STAGE/OneShot-simulator.app"
cat > "$STAGE/README-FIRST.txt" <<'TXT'
OneShot — iPad cashier with on-device AI

OneShot/                 Source code (open OneShot/README.md). Build: xcodegen generate, then open OneShot.xcodeproj.
OneShot/docs/screens/    Screenshots of every page, portrait and landscape, dark, light and Thai.
OneShot-simulator.app    Ready-made build for the iPad simulator:
                           xcrun simctl install booted OneShot-simulator.app
                           xcrun simctl launch booted com.krist.hackday.oneshot
                         The demo camera is on in the simulator (table photos stand in for the camera).
                         Settings › Demo adds two weeks of sample sales for Home and Reports.
TXT
rm -f "$OUT"
(cd "$STAGE" && zip -qry "$OUT" .)   # -y keeps the .app's symlinks
rm -rf "$STAGE"
ls -lh "$OUT"
