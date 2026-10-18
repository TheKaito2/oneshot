#!/bin/zsh
# Wait for the iPad, install the last Release build, launch it and capture its console.
# Usage: tools/devlog.sh <seconds> <logfile>      (build first: tools/deploy.sh or xcodebuild)
set -uo pipefail
cd "$(dirname "$0")/.."
DEVICE=${DEVICE:-FD881C02-02B9-55CA-AA5E-DF679CA06F56}
SECONDS_TO_LOG=${1:-180}
LOG=${2:-/dev/stdout}

for i in {1..180}; do
  xcrun devicectl list devices 2>/dev/null | grep "$DEVICE" | grep -Eq "available \(paired\)|connected" && break
  sleep 10
done
xcrun devicectl device install app --device "$DEVICE" build/Build/Products/Release-iphoneos/OneShot.app | grep -E "installed|rror"
xcrun devicectl device process launch --console --terminate-existing --device "$DEVICE" com.krist.hackday.oneshot > "$LOG" 2>&1 &
PID=$!
sleep "$SECONDS_TO_LOG"
kill $PID 2>/dev/null
grep -vE "^hud|Acquired|Enabling|Waiting" "$LOG"
