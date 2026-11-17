#!/bin/bash
# Builds the native app and registers it with every installed Chromium browser.
# No prompts, no logs. Writes only ~/Library/Application Support/{MacPiP,<browser>/NativeMessagingHosts}.
set -euo pipefail
cd "$(dirname "$0")"

HOST=io.github.macpip
EXT_ID=jopkiidhnpobkkoidfmmeeegeagionim   # fixed by the "key" in extension/manifest.json
DEST="$HOME/Library/Application Support/MacPiP"
BIN="$DEST/macpip"

command -v swiftc >/dev/null || { echo "Need Xcode Command Line Tools: xcode-select --install"; exit 1; }
mkdir -p "$DEST"
swiftc -O -wmo -target "$(uname -m)-apple-macos12" -o "$BIN" native/*.swift
echo "built   $BIN"

for b in "Google/Chrome" "Google/Chrome Beta" "Google/Chrome Canary" "Chromium" \
         "BraveSoftware/Brave-Browser" "Microsoft Edge" "Vivaldi" "Arc/User Data"; do
  dir="$HOME/Library/Application Support/$b"
  [ -d "$dir" ] || continue
  mkdir -p "$dir/NativeMessagingHosts"
  cat > "$dir/NativeMessagingHosts/$HOST.json" <<JSON
{
  "name": "$HOST",
  "description": "MacPiP",
  "path": "$BIN",
  "type": "stdio",
  "allowed_origins": ["chrome-extension://$EXT_ID/"]
}
JSON
  echo "linked  $b"
done

echo
echo "Load the extension: chrome://extensions → Developer mode → Load unpacked → $PWD/extension"
echo "CLI (Safari, anything else): \"$BIN\" <url> [start-seconds]"
