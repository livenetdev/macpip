# MacPiP

Picture-in-picture that floats over **native fullscreen** macOS apps. The video keeps playing in **your browser tab**, with your login, Premium, your audio and your session. MacPiP shows it above everything.

```
your tab (Chrome, Brave, Edge, Arc, Vivaldi)          MacPiP.app
 └─ <video> playing, your session                      └─ window allowed into fullscreen Spaces
     └─ extension: video frames → H.264 (WebCodecs) ──native messaging──▶ hardware decode → display
     └─ tab capture held → Chrome keeps rendering the hidden tab at full rate
                                        ◀── play/pause, ±10 s, mute ──
```

## Why this design

| Approach | Over native fullscreen | Your session/login | Problem |
|---|---|---|---|
| Browser's own PiP (Chrome, Firefox…) | ✗ | ✓ | macOS keeps it out of fullscreen Spaces |
| Re-load the video in a separate player (FullFloatPiP) | ✓ | ✗ | no login/DRM, bot checks, per-site hacks |
| Capture the browser's PiP window | ✗ freezes | ✓ | macOS and Chrome stop updating hidden windows ([OBS #7051](https://github.com/obsproject/obs-studio/issues/7051), [cua #4996](https://github.com/trycua/cua/pull/4996)) |
| Fill the screen on the same Space | not real fullscreen | ✓ | not a fullscreen Space |
| **Stream the tab's video to MacPiP** | ✓ | ✓ | needs an extension + app |

## Verified on macOS 26 CI (Chrome for Testing 158, 1080p Big Buck Bunny, Terminal in native fullscreen)

| Video tab while hidden behind a fullscreen app | visibility | frames/s |
|---|---|---|
| **No** MacPiP (the original freeze) | hidden | **0** |
| **MacPiP floating** | visible | **~56** |

Per-second pipeline while hidden: tab ~55 → encoded ~55 (0 dropped) → shown ~55 fps, ~1.8 Mbps. That's on CI's *software* encoder; real Macs use the hardware encoder. MacPiP's window is drawn above the fullscreen Terminal and stays live.

## Install

**Download:** [`dist/MacPiP.dmg`](dist/MacPiP.dmg): universal (Apple Silicon + Intel), macOS 12.3+. SHA-256 in [`dist/SHA256`](dist/SHA256).

1. Drag **MacPiP** to **Applications**, then open it. It isn't notarized, so the first time use System Settings ▸ Privacy & Security ▸ **Open Anyway**, or run `xattr -dr com.apple.quarantine /Applications/MacPiP.app`.
2. MacPiP links itself to your Chromium browsers and shows the extension folder.
3. In the browser: `chrome://extensions` → **Developer mode** → **Load unpacked** → choose that folder (one time).

From source: `./install.sh` (Xcode CLT). `DMG=1 ./build.sh` rebuilds the DMG.

## Use

| Action | How |
|---|---|
| Float the video in this tab | toolbar button or **⌥⇧P** (again to stop) |
| Play / pause | click the PiP, or Space |
| Seek ±10 s / mute | hover controls, or ← → / M |
| Move / resize | drag anywhere / edges (aspect locked) |
| Opacity, click-through, snap to corner | hover ◐, or menu bar ▸ MacPiP |
| Close | Esc, ✕, or stop from the toolbar |
| Diagnose stutter | menu bar ▸ MacPiP ▸ **Show Frame Rate**: tab → encoded (dropped) → sent → shown fps |

## Trade-offs

- **Privacy:** while floating, the extension reads the video in that one tab and holds a tab capture (Chrome shows its "being shared" indicator). Nothing leaves your Mac: frames go only to MacPiP over local native messaging. No network, no logs.
- **DRM** (Netflix, Disney+…): protected frames can't be read, so the video can't be floated.
- The tab must stay open (it can be in the background, minimized, or behind fullscreen apps).
- Cross-origin video without CORS falls back to cropping the tab capture (lower quality, follows the on-page player). This fallback hasn't been tested.
- Firefox / Safari: not supported (Safari's own PiP already floats over fullscreen apps).

## Uninstall

```bash
./uninstall.sh
```

MIT. Inspired by FullFloatPiP (MIT, © Sigmame).
