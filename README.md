# MacPiP

Picture-in-picture that floats above **fullscreen** macOS apps and across all Spaces. Privacy-first, minimal rewrite of [FullFloatPiP](https://github.com/Sigmame/full-float-pip).

```
click extension / ⌥⇧P ──activeTab──▶ probe video ──stdio──▶ macpip (Swift)
                                                             └─ NSPanel, level max, canJoinAllSpaces + fullScreenAuxiliary
                                                                └─ WKWebView: ephemeral store, tracker rules, isolated JS world
```

## vs FullFloatPiP

| | FullFloatPiP | MacPiP |
|---|---|---|
| Page access | content script on **every site**, always running | none until you click (`activeTab`) |
| Permissions | `cookies`, `scripting`, `activeTab`, `nativeMessaging`, host perms (youtube, google) | `activeTab`, `scripting`, `nativeMessaging` |
| Your login cookies | **all `.youtube.com` + `.google.com` cookies copied** into the player | never read |
| WebKit storage | default (persistent on disk) | `nonPersistent()` — memory only, gone on close |
| YouTube | full watch page + ad-skip click injection | `youtube-nocookie.com` embed; watch page only as fallback |
| Trackers | — | 26 ad/analytics domains + YouTube telemetry paths blocked |
| Open ports | local HTTP server | none |
| Logs | `~/Library/Logs/FloatVideo/native-host.log` | none |
| Injected JS | page world | isolated `WKContentWorld` (pages can't read/forge it) |
| Popups / camera / mic | default | blocked / blocked / denied |
| Native host access | prompted ID, wildcard fallback | fixed extension ID pinned via manifest `key` |
| Process | stays alive | exits when window closes |
| Code | ~4.2k lines | ~600 lines |
| Browsers | Chrome | Chrome, Brave, Edge, Arc, Vivaldi, Chromium + CLI (Safari, scripts) |

## Install

Requires macOS 12+, Xcode CLT (`xcode-select --install`).

```bash
./install.sh
```

Then `chrome://extensions` → Developer mode → Load unpacked → `extension/`.

## Use

| Action | How |
|---|---|
| Float | toolbar icon or ⌥⇧P (tab video pauses; resumes at PiP position on close) |
| Any URL / Safari | `~/Library/Application\ Support/MacPiP/macpip <url> [seconds]` |
| Move | drag top bar, or ⌘-drag anywhere |
| Resize | window edges (aspect locked) |
| Opacity | ◐ in top bar, or menu bar ▸ Opacity |
| Click-through | ✋ in top bar; undo in menu bar |
| Snap to corner | menu bar ▸ Move to |
| Close | Esc, ⌘W, ✕ |

## Loading strategy

| Source | Mode |
|---|---|
| YouTube (watch, shorts, live, youtu.be, embeds) | `youtube-nocookie` embed → watch page if embedding disabled |
| Vimeo | `player.vimeo.com` with `dnt=1` |
| `<video>` with http(s) src | bare `<video>` → page on error |
| Anything else (MSE/blob streams, Twitch…) | load page, hide everything but the largest video/iframe |
| No video on page | floats the page itself |

## Limits

- No logins (ephemeral session by design) → members-only/premium content won't play.
- DRM (Netflix, Disney+) won't play.
- EU YouTube fallback page may show a consent dialog once per window.
- Dropped vs upstream: custom control bar, no audio-track/subtitle menu; uses each player's own controls.

## Uninstall

```bash
./uninstall.sh
```

MIT. Derived from FullFloatPiP (MIT, © Sigmame).
