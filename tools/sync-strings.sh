#!/bin/zsh
# After changing UI text: build once, then pull new/removed keys into the String Catalog.
# New keys arrive without Thai; translate them in Localizable.xcstrings (LocalizationTests catches a missing bundle).
set -euo pipefail
cd "$(dirname "$0")/.."
xcodebuild -project OneShot.xcodeproj -scheme OneShot -destination 'generic/platform=iOS Simulator' -derivedDataPath build -quiet build
xcrun xcstringstool sync OneShot/Resources/Localizable.xcstrings --stringsdata $(find build -name "*.stringsdata" -path "*OneShot.build*")
