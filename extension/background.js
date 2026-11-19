// MacPiP service worker: wires tabs ⇄ native app. Click (or ⌥⇧P) on a tab with a video to float it
// in its own window; click again on that tab to stop it. Any number of tabs can float at once.
const HOST = 'io.github.macpip';
let native = null;
const sessions = new Map(); // tabId → content port (null until the content script connects)

const toOffscreen = (m) => chrome.runtime.sendMessage({ target: 'offscreen', ...m }).catch(() => {});

async function ensureOffscreen() {
  if (await chrome.offscreen.hasDocument()) return;
  await chrome.offscreen.createDocument({
    url: 'offscreen.html', reasons: ['USER_MEDIA'],
    justification: 'Keep floated tabs rendering while they are hidden behind a fullscreen app.',
  });
}

function badge(tabId, text, color, title) {
  chrome.action.setBadgeBackgroundColor({ color, tabId }).catch(() => {});
  chrome.action.setBadgeText({ text, tabId }).catch(() => {});
  if (title) chrome.action.setTitle({ title, tabId }).catch(() => {});
}

function flash(tabId, msg) {
  if (tabId == null) return;
  badge(tabId, '!', '#d33', `MacPiP: ${msg}`);
  setTimeout(() => badge(tabId, '', '#d33', 'Float video (⌥⇧P)'), 5000);
}

async function stop(tabId, fromNative = false) {
  if (!sessions.has(tabId)) return;
  const port = sessions.get(tabId);
  sessions.delete(tabId);
  try { port?.postMessage({ cmd: 'stop' }); port?.disconnect(); } catch (_) {}
  if (!fromNative) native?.postMessage({ k: 'end', s: tabId });
  toOffscreen({ type: 'stop', tabId });
  badge(tabId, '', '#0a84ff');
  if (sessions.size === 0) {
    try { native?.disconnect(); } catch (_) {}
    native = null;
    if (await chrome.offscreen.hasDocument()) await chrome.offscreen.closeDocument().catch(() => {});
  }
}

function stopAll() { for (const id of [...sessions.keys()]) stop(id, true); }

function connectNative() {
  const p = chrome.runtime.connectNative(HOST);
  p.onMessage.addListener((m) => {
    const s = m.s;
    if (m.cmd === 'stop') return stop(s, true);
    if (m.cmd === 'key' || m.cmd === 'size') toOffscreen({ type: m.cmd, tabId: s, w: m.w, h: m.h });
    try { sessions.get(s)?.postMessage(m); } catch (_) {}
  });
  p.onDisconnect.addListener(() => {
    const err = chrome.runtime.lastError?.message || '';
    if (/not found|forbidden/i.test(err)) for (const id of sessions.keys()) flash(id, 'Open MacPiP.app once to finish setup');
    if (native === p) { native = null; stopAll(); }
  });
  return p;
}

chrome.action.onClicked.addListener(async (tab) => {
  if (sessions.has(tab.id)) return stop(tab.id);
  sessions.set(tab.id, null);
  try {
    const streamId = await chrome.tabCapture.getMediaStreamId({ targetTabId: tab.id });
    await ensureOffscreen();
    native ??= connectNative();
    await toOffscreen({ type: 'start', tabId: tab.id, streamId });
    await chrome.scripting.executeScript({ target: { tabId: tab.id }, files: ['encoder.js', 'content.js'] });
    badge(tab.id, 'PiP', '#0a84ff');
  } catch (e) {
    flash(tab.id, e.message || 'Cannot float this page');
    stop(tab.id);
  }
});

chrome.runtime.onConnect.addListener((p) => {
  const tabId = p.sender?.tab?.id;
  if (p.name === 'content' && sessions.has(tabId)) {
    sessions.set(tabId, p);
    p.onMessage.addListener((m) => {
      if (m.k === 'none') { flash(tabId, 'No video on this page'); return stop(tabId); }
      if (m.k === 'crop') return toOffscreen({ type: 'crop', tabId });
      if (m.k === 'rect') return toOffscreen({ type: 'rect', tabId, ...m });
      native?.postMessage({ ...m, s: tabId });
    });
    p.onDisconnect.addListener(() => { if (sessions.get(tabId) === p) stop(tabId); }); // tab closed or navigated
  } else if (p.name === 'offscreen') {
    p.onMessage.addListener((m) => native?.postMessage(m)); // crop-mode frames, already tagged with s
  }
});

chrome.tabs.onRemoved.addListener((id) => stop(id));
