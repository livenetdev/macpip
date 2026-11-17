#!/bin/bash
set -euo pipefail
pkill -x macpip 2>/dev/null || true
rm -rf "$HOME/Applications/MacPiP.app" "/Applications/MacPiP.app" "$HOME/Library/Application Support/MacPiP" 2>/dev/null || true
find "$HOME/Library/Application Support" -maxdepth 5 -path "*NativeMessagingHosts/io.github.macpip.json" -delete 2>/dev/null || true
defaults delete io.github.macpip 2>/dev/null || true
echo "Removed MacPiP. Remove the extension at chrome://extensions."
