#!/bin/bash
# Builds MacPiP.app into ~/Applications and starts it. No prompts, no network, no logs.
set -euo pipefail
cd "$(dirname "$0")"
./build.sh
mkdir -p "$HOME/Applications"
pkill -x macpip 2>/dev/null || true
rm -rf "$HOME/Applications/MacPiP.app"
cp -R build/MacPiP.app "$HOME/Applications/"
open "$HOME/Applications/MacPiP.app"
echo "Installed ~/Applications/MacPiP.app — allow Screen Recording when asked, then relaunch it."
