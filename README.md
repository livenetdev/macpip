# MacPiP

Keep your browser's **own** picture-in-picture visible while you work fullscreen on macOS.

**⌃⌥⌘F** fills the screen with the front window and auto-hides the menu bar and Dock, all on the **current Space**. Chrome, Firefox, Arc, Brave and Edge PiP windows float above every normal window on their Space, so the PiP stays on top: live, clickable, with sound, signed in. Press ⌃⌥⌘F again to put everything back.

```
native fullscreen (⌃⌘F)          MacPiP fill (⌃⌥⌘F)
┌─ separate Space ──────┐         ┌─ same Space ──────────┐
│ app                   │         │ app (fills screen)    │
│   browser PiP: ✗ gone │         │        ┌──────────┐   │
└───────────────────────┘         │        │ PiP ✓ live│  │
                                  └────────┴──────────┴───┘
```

## Why not mirror or re-load the video

| Approach | Problem |
|---|---|
| Re-open the video in a separate player (FullFloatPiP) | no login / DRM / Premium, bot checks, per-site hacks, copies your cookies |
| Capture the browser's PiP window into an overlay (ScreenCaptureKit) | macOS stops updating windows on other Spaces, so the overlay **freezes** ([OBS #7051](https://github.com/obsproject/obs-studio/issues/7051), [cua #4996](https://github.com/trycua/cua/pull/4996)) |
| Put the browser's PiP into the fullscreen Space | needs private window-server APIs with SIP disabled |
| **Don't create a new Space** (MacPiP) | ✓ nothing to capture or re-load; it's the browser's real PiP |

Safari's PiP already floats over fullscreen apps (per guides; not tested here). MacPiP is for the other browsers.

## Install

**Download:** [`dist/MacPiP.dmg`](dist/MacPiP.dmg): universal (Apple Silicon + Intel), macOS 12.3+, 128 KB. SHA-256 in [`dist/SHA256`](dist/SHA256).

1. Open the DMG and drag **MacPiP** to **Applications**.
2. First launch: the app is ad-hoc signed, not notarized, so macOS blocks it. Go to System Settings ▸ Privacy & Security ▸ **Open Anyway**. Or run:
   ```bash
   xattr -dr com.apple.quarantine /Applications/MacPiP.app
   ```
3. Allow **Accessibility** (to resize the front window). The first fill asks to control **System Events** (menu bar / Dock auto-hide); allow it.

**From source:** `./install.sh` (needs Xcode CLT). `DMG=1 ./build.sh` rebuilds the DMG.

## Use

| Action | How |
|---|---|
| Start PiP | in your browser as usual (PiP button, right-click ▸ Picture in Picture, Chrome auto-PiP) |
| Fill screen / restore | **⌃⌥⌘F** in any app, or menu bar ▸ Fill Screen with Front Window |
| Window already in native fullscreen | ⌃⌥⌘F takes it out of native fullscreen and fills the screen instead |
| Keep menu bar & Dock visible | menu bar ▸ untick Hide Menu Bar & Dock While Filled |
| Auto-start | menu bar ▸ Launch at Login (macOS 13+) |

Your menu bar / Dock auto-hide settings come back on restore, on quit, if the filled app quits, and on next launch after a crash.

## Verified on macOS 26 CI

Chrome's native PiP + Terminal: ⌃⌥⌘F → Terminal fills the screen, menu bar and Dock hidden, PiP on top and still playing (two screenshots 2 s apart differ) → ⌃⌥⌘F → original size and auto-hide settings restored. Starting from native fullscreen also works.

## Privacy

No network, no extension, no screen capture, no telemetry, no logs. Stores 2 preferences (and your previous auto-hide values while a window is filled). ~260 lines of Swift.

## Limits

- Not a macOS fullscreen Space: no swipe-to-Space, and the window keeps its title bar.
- Apps with a maximum window size can't fill the screen.
- Rebuilding / re-downloading resets the Accessibility permission (ad-hoc signature).

## Uninstall

```bash
./uninstall.sh
```

MIT. Inspired by FullFloatPiP (MIT, © Sigmame).
