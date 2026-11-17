#!/bin/bash
# Builds build/MacPiP.app (ad-hoc signed). Needs Xcode Command Line Tools.
#   UNIVERSAL=1 ./build.sh   → arm64 + x86_64
#   DMG=1 ./build.sh         → also build/MacPiP.dmg (implies UNIVERSAL)
set -euo pipefail
cd "$(dirname "$0")"
command -v swiftc >/dev/null || { echo "Need Xcode Command Line Tools: xcode-select --install"; exit 1; }
APP=build/MacPiP.app
BIN="$APP/Contents/MacOS/macpip"
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp app/Info.plist "$APP/Contents/"
cp app/AppIcon.icns "$APP/Contents/Resources/"
cp -R extension "$APP/Contents/Resources/extension"

[ "${DMG:-}" = 1 ] && UNIVERSAL=1
if [ "${UNIVERSAL:-}" = 1 ]; then ARCHS="arm64 x86_64"; else ARCHS="$(uname -m)"; fi
for a in $ARCHS; do
  swiftc -O -wmo ${SWIFTFLAGS:-} -target "$a-apple-macos12.3" -o "build/macpip-$a" native/*.swift
done
lipo -create build/macpip-* -output "$BIN" && rm build/macpip-*
codesign --force --sign - "$APP"
echo "$APP ($(lipo -archs "$BIN"))"

if [ "${DMG:-}" = 1 ]; then
  stage=build/dmg && mkdir -p "$stage"
  cp -R "$APP" "$stage/" && ln -s /Applications "$stage/Applications"
  hdiutil create -quiet -volname MacPiP -srcfolder "$stage" -fs HFS+ -format UDZO -ov build/MacPiP.dmg
  rm -rf "$stage"
  echo "build/MacPiP.dmg"
fi
