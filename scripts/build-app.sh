#!/bin/bash
# Builds "M7 Control.app" into ./build. Pass --install to also copy it to /Applications and open it.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP="build/M7 Control.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/M7Control "$APP/Contents/MacOS/M7Control"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc signature: enough to run locally. macOS ties the Accessibility grant to this exact
# build, so the permission has to be given again after every rebuild.
codesign --force --sign - --identifier com.metroglitch.m7control "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x M7Control 2>/dev/null || true
    rm -rf "/Applications/M7 Control.app"
    cp -R "$APP" "/Applications/M7 Control.app"
    open "/Applications/M7 Control.app"
    echo "Installed to /Applications and opened"
fi
