#!/bin/bash
set -euo pipefail
pkill -x macpip 2>/dev/null || true
rm -rf "$HOME/Applications/MacPiP.app" "/Applications/MacPiP.app" 2>/dev/null || true
defaults delete io.github.macpip 2>/dev/null || true
tccutil reset Accessibility io.github.macpip 2>/dev/null || true
tccutil reset AppleEvents io.github.macpip 2>/dev/null || true
echo "Removed MacPiP."
