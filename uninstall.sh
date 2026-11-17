#!/bin/bash
set -euo pipefail
pkill -x macpip 2>/dev/null || true
rm -rf "$HOME/Applications/MacPiP.app"
defaults delete io.github.macpip 2>/dev/null || true
tccutil reset ScreenCapture io.github.macpip 2>/dev/null || true
echo "Removed MacPiP."
