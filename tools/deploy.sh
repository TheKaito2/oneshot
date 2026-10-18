#!/bin/zsh
# Build Release, install and launch OneShot on the iPad Air ("Punn 01").
# Other iPad: DEVICE=<devicectl identifier> tools/deploy.sh
set -euo pipefail
cd "$(dirname "$0")/.."
DEVICE=${DEVICE:-FD881C02-02B9-55CA-AA5E-DF679CA06F56}

xcodegen generate --quiet
xcodebuild -project OneShot.xcodeproj -scheme OneShot -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath build -allowProvisioningUpdates -quiet build
xcrun devicectl device install app --device "$DEVICE" build/Build/Products/Release-iphoneos/OneShot.app
xcrun devicectl device process launch --device "$DEVICE" --terminate-existing com.krist.hackday.oneshot
