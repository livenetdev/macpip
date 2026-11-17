#!/bin/bash
# Builds build/MacPiP.app (ad-hoc signed). Needs Xcode Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")"
command -v swiftc >/dev/null || { echo "Need Xcode Command Line Tools: xcode-select --install"; exit 1; }
APP=build/MacPiP.app
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS"
cp app/Info.plist "$APP/Contents/"
swiftc -O -wmo ${SWIFTFLAGS:-} -target "$(uname -m)-apple-macos12.3" -o "$APP/Contents/MacOS/macpip" native/*.swift
codesign --force --sign - "$APP"
echo "$APP"
