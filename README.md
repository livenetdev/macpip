# MacPiP

Makes your browser's **own** picture-in-picture window visible over **fullscreen** macOS apps.

Rule: *if it plays in your browser's PiP, it plays over fullscreen apps.* Nothing is re-loaded. The browser keeps playing with its own login, DRM session, codecs and audio, and MacPiP shows a live view of that window.

```
browser PiP window ──(you enter a fullscreen app: PiP is hidden)──▶ MacPiP
   plays video, audio, owns session                                  ├─ ScreenCaptureKit: that one window, GPU zero-copy
                                                                     └─ NSPanel: .floating + fullScreenAuxiliary + all Spaces
back on the desktop: original visible → mirror closes, capture stops
```

## Why not FullFloatPiP's approach

| | FullFloatPiP | MacPiP |
|---|---|---|
| How it works | re-opens the page in its own WebKit view | mirrors the browser's native PiP window |
| Logins / Premium / members-only | ✗ (forwards your YouTube + Google cookies to attempt it) | ✓ untouched, your browser keeps the session |
| Bot checks ("Sign in to confirm you're not a bot") | hits them as a fresh client | ✓ none, nothing new is loaded |
| Site support | per-site hacks (embeds, ad-skip, DOM isolation) | any site, any browser, any player |
| Browser extension | required; content script on every site | none |
| Network requests made | yes (local HTTP server + page reloads) | **none** |
| Data stored | WebKit storage, log file | position + opacity prefs only |
| Permission | — | Screen Recording (captures only the single window it mirrors, locally) |
| Code | ~4.2k lines | ~430 lines Swift |
| CPU when idle | background process + port | 1 window-list check/s; capture only while mirror shown |

## Install

**Download:** [`dist/MacPiP.dmg`](dist/MacPiP.dmg) (universal: Apple Silicon + Intel, macOS 12.3+, 187 KB). SHA-256 in [`dist/SHA256`](dist/SHA256).

1. Open the DMG and drag **MacPiP** to **Applications**.
2. First launch: the app is ad-hoc signed, not notarized, so macOS blocks it. Go to System Settings ▸ Privacy & Security ▸ **Open Anyway**. Or run:
   ```bash
   xattr -dr com.apple.quarantine /Applications/MacPiP.app
   ```
3. Allow **Screen Recording** when asked, then relaunch MacPiP.

**From source:** `./install.sh` (needs Xcode CLT). `DMG=1 ./build.sh` rebuilds the DMG.

## Use

1. Start PiP in your browser as usual (PiP button, right-click ▸ Picture in Picture, or Chrome's auto-PiP).
2. Go into any fullscreen app. The PiP stays on top.

| Action | How |
|---|---|
| Move | drag anywhere on the mirror |
| Resize | edges (aspect locked) |
| Play / pause | keyboard media keys (go to the browser) |
| Go to original | double-click, or ↗ in hover bar |
| Opacity / click-through | hover bar or menu bar ▸ Opacity / Click-through |
| Snap to corner | menu bar ▸ Move to |
| Float any other window (IINA, VLC, Zoom…) over fullscreen apps | menu bar ▸ Float a window |
| Stop | Esc, ✕, menu bar ▸ Stop floating |
| Auto-start | menu bar ▸ Launch at login (macOS 13+) |

## Limits

- The mirror is view-only: use media keys, or double-click to jump back to the original.
- DRM video (Netflix, Disney+, Apple TV+) may mirror as black, because macOS blocks capture of protected video (unverified).
- macOS 15+ periodically re-asks for Screen Recording permission (OS behaviour).
- Ad-hoc signed: rebuilding resets the Screen Recording permission.

## Uninstall

```bash
./uninstall.sh
```

MIT. Inspired by FullFloatPiP (MIT, © Sigmame).
