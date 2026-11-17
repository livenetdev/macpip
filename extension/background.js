// MacPiP service worker: wires tab ⇄ native app. Click (or ⌥⇧P) on a tab with a video to float it;
// click again to stop. The video keeps playing in the tab; MacPiP shows it over everything.
const HOST = 'io.github.macpip';
let native = null, content = null, tabId = null;

const toOffscreen = (m) => chrome.runtime.sendMessage({ target: 'offscreen', ...m }).catch(() => {});

async function ensureOffscreen() {
  if (await chrome.offscreen.hasDocument()) return;
  await chrome.offscreen.createDocument({
    url: 'offscreen.html', reasons: ['USER_MEDIA'],
    justification: 'Keep the floated tab rendering while it is hidden behind a fullscreen app.',
  });
}

function flash(id, msg) {
  if (id == null) return;
  chrome.action.setBadgeBackgroundColor({ color: '#d33', tabId: id });
  chrome.action.setBadgeText({ text: '!', tabId: id });
  chrome.action.setTitle({ title: `MacPiP: ${msg}`, tabId: id });
  setTimeout(() => { chrome.action.setBadgeText({ text: '', tabId: id }); chrome.action.setTitle({ title: 'Float video (⌥⇧P)', tabId: id }); }, 5000);
}

async function stop() {
  const id = tabId;
  tabId = null;
  try { content?.postMessage({ cmd: 'stop' }); content?.disconnect(); } catch (_) {}
  try { native?.postMessage({ k: 'bye' }); native?.disconnect(); } catch (_) {}
  content = native = null;
  toOffscreen({ type: 'stop' });
  if (await chrome.offscreen.hasDocument()) await chrome.offscreen.closeDocument().catch(() => {});
  if (id != null) chrome.action.setBadgeText({ text: '', tabId: id });
}

function connectNative(id) {
  const p = chrome.runtime.connectNative(HOST);
  p.onMessage.addListener((m) => {
    if (m.cmd === 'key') toOffscreen({ type: 'key' });
    if (m.cmd === 'stop') return stop();
    try { content?.postMessage(m); } catch (_) {}
  });
  p.onDisconnect.addListener(() => {
    const err = chrome.runtime.lastError?.message || '';
    if (/not found|forbidden/i.test(err)) flash(id, 'Open MacPiP.app once to finish setup');
    if (native === p) stop();
  });
  return p;
}

chrome.action.onClicked.addListener(async (tab) => {
  if (tabId === tab.id) return stop();
  await stop();
  tabId = tab.id;
  try {
    const streamId = await chrome.tabCapture.getMediaStreamId({ targetTabId: tab.id });
    await ensureOffscreen();
    native = connectNative(tab.id);
    await toOffscreen({ type: 'start', streamId });
    await chrome.scripting.executeScript({ target: { tabId: tab.id }, files: ['encoder.js', 'content.js'] });
    chrome.action.setBadgeBackgroundColor({ color: '#0a84ff', tabId: tab.id });
    chrome.action.setBadgeText({ text: 'PiP', tabId: tab.id });
  } catch (e) {
    flash(tab.id, e.message || 'Cannot float this page');
    stop();
  }
});

chrome.runtime.onConnect.addListener((p) => {
  if (p.name === 'content') {
    content = p;
    p.onMessage.addListener((m) => {
      if (m.k === 'none') { flash(tabId, 'No video on this page'); return stop(); }
      if (m.k === 'crop') return toOffscreen({ type: 'crop' });
      if (m.k === 'rect') return toOffscreen({ type: 'rect', ...m });
      native?.postMessage(m);
    });
    p.onDisconnect.addListener(() => { if (content === p) stop(); }); // tab closed or navigated
  } else if (p.name === 'offscreen') {
    p.onMessage.addListener((m) => native?.postMessage(m));
  }
});

chrome.tabs.onRemoved.addListener((id) => { if (id === tabId) stop(); });
