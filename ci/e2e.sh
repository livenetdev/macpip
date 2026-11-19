#!/bin/bash
# End-to-end on a macOS runner: Chrome for Testing + MacPiP extension + MacPiP.app,
# video tab hidden behind a fullscreen Terminal. Prints measurements and screenshots.
set -uo pipefail
BIN="$PWD/build/MacPiP.app/Contents/MacOS/macpip"
PROFILE=/tmp/cft-profile; mkdir -p "$PROFILE"
shot() { screencapture -x "$1.png"; sips -Z 900 -s format jpeg "$1.png" --out "$1.jpg" >/dev/null; echo "IMG $1 $(base64 -i "$1.jpg" | tr -d '\n')"; }
wins() { swift - <<'SW'
import CoreGraphics
let l = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
for w in l where ["macpip", "MacPiP"].contains(w[kCGWindowOwnerName as String] as? String ?? "") { print("macpip window layer=\(w[kCGWindowLayer as String]!) bounds=\(w[kCGWindowBounds as String]!)") }
SW
}
fullscreenTerminal() { open -a Terminal; sleep 3; osascript -e 'tell application "System Events" to keystroke "f" using {control down, command down}'; sleep 6; }
leaveFullscreen() { osascript -e 'tell application "System Events" to keystroke "f" using {control down, command down}'; sleep 5; }

npx -y @puppeteer/browsers install chrome@stable --path /tmp/cft > /tmp/cft.log 2>&1
CFT=$(find /tmp/cft -path "*Contents/MacOS/Google Chrome for Testing" | head -1); echo "CfT: $CFT"
"$BIN" --setup-quiet "$PROFILE"
EXT="$HOME/Library/Application Support/MacPiP/extension"
defaults write io.github.macpip showStats -bool true
URL="https://test-videos.co.uk/vids/bigbuckbunny/mp4/h264/1080/Big_Buck_Bunny_1080_10s_5MB.mp4"
curl -sfI "$URL" >/dev/null || URL="https://www.w3schools.com/html/mov_bbb.mp4"; echo "video: $URL"

MACPIP_DEBUG=1 "$CFT" --user-data-dir="$PROFILE" --load-extension="$EXT" --disable-features=DisableLoadExtensionCommandLineSwitch \
  --remote-debugging-port=9222 --no-first-run --no-default-browser-check --autoplay-policy=no-user-gesture-required \
  "$URL" > /tmp/cft-out.log 2>&1 &
for i in $(seq 40); do curl -sf localhost:9222/json >/dev/null && break; sleep 1; done; sleep 4
node ci/cdp.mjs play
node ci/cdp.mjs measure   # baseline: tab visible

echo "== control: no capture, Chrome hidden behind fullscreen Terminal"
fullscreenTerminal
node ci/cdp.mjs measure
leaveFullscreen

echo "== MacPiP: float via ⌥⇧P"
osascript -e 'tell application "Google Chrome for Testing" to activate'; sleep 2
osascript -e 'tell application "System Events" to keystroke "p" using {option down, shift down}'; sleep 5
wins; shot floating
pgrep -fl macpip || echo "macpip not running"

echo "== second window: another tab"
URL2="https://www.w3schools.com/html/mov_bbb.mp4"
curl -sf -X PUT "localhost:9222/json/new?$URL2" >/dev/null; sleep 5
node ci/cdp.mjs play w3schools
osascript -e 'tell application "Google Chrome for Testing" to activate'; sleep 2
osascript -e 'tell application "System Events" to keystroke "p" using {option down, shift down}'; sleep 5
wins; shot two

echo "== MacPiP active, Chrome hidden behind fullscreen Terminal"
fullscreenTerminal
node ci/cdp.mjs measure test-videos
node ci/cdp.mjs measure w3schools
wins; shot fs1; sleep 2; shot fs2
sleep 4
cpu() { ps -A -o %cpu=,comm= | grep -E "MacOS/macpip|Google Chrome for Testing" | awk '{c[$2~/macpip/?"macpip":"chrome(all)"]+=$1} END {for (k in c) printf "cpu %s %.0f%%\n", k, c[k]}'; }
echo "== per-second pipeline counters, controls hidden (normal use), Chrome hidden behind fullscreen Terminal"
grep -a "macpip: \[" /tmp/cft-out.log | tail -6 || true
cpu
echo "== controls pinned visible (SIGUSR1)"
pkill -USR1 -f "MacOS/macpip chrome-extension" || true; sleep 5
grep -a "macpip: \[" /tmp/cft-out.log | tail -6 || true
cpu
shot controls
grep -a "recv " /tmp/cft-out.log | sort | uniq -c | head
grep -a "macpip: extension" /tmp/cft-out.log | tail -5 || true
