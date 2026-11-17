#!/bin/bash
set -euo pipefail
rm -rf "$HOME/Library/Application Support/MacPiP"
find "$HOME/Library/Application Support" -maxdepth 5 -path "*NativeMessagingHosts/io.github.macpip.json" -print -delete 2>/dev/null || true
defaults delete macpip 2>/dev/null || true
echo "Removed. Remove the extension at chrome://extensions."
