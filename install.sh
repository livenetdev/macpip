#!/bin/bash
# Builds MacPiP.app into ~/Applications and runs its one-time setup.
set -euo pipefail
cd "$(dirname "$0")"
./build.sh
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/MacPiP.app"
cp -R build/MacPiP.app "$HOME/Applications/"
open "$HOME/Applications/MacPiP.app"
