// MacPiP — the whole extension.
// No content scripts, no host permissions: page access exists only for the tab
// you click (activeTab), and only to read the one video you float.

const HOST = 'io.github.macpip';
let port = null;
let sourceTab = null;

// Runs in the clicked tab. Picks the main video (or video iframe) and marks it.
function probe() {
  const area = (e) => { const r = e.getBoundingClientRect(); return r.width * r.height; };
  const biggest = (list) => list.reduce((b, e) => (!b || area(e) > area(b) ? e : b), null);
  const vids = [...document.querySelectorAll('video')].filter((v) => area(v) > 0 || v.readyState > 0);
  const playing = biggest(vids.filter((v) => !v.paused && !v.ended));
  const frame = biggest([...document.querySelectorAll('iframe')].filter((f) => /^https?:/.test(f.src) && area(f) > 40000));
  let v = playing || biggest(vids);
  if (v && !playing && frame && area(frame) > area(v)) v = null;

  const base = { url: location.href, title: document.title };
  document.querySelectorAll('[data-macpip-origin]').forEach((e) => e.removeAttribute('data-macpip-origin'));
  if (v) {
    v.setAttribute('data-macpip-origin', '');
    const src = v.currentSrc || v.src || '';
    return {
      ...base,
      src: /^https?:/.test(src) ? src : '',
      t: isFinite(v.duration) ? v.currentTime : 0,
      w: v.videoWidth || v.clientWidth,
      h: v.videoHeight || v.clientHeight,
    };
  }
  if (frame) return { ...base, url: frame.src, w: frame.clientWidth, h: frame.clientHeight };
  return base; // no video: float the page itself
}

const pauseOrigin = () => document.querySelector('[data-macpip-origin]')?.pause();
const resumeAt = (t) => {
  const v = document.querySelector('[data-macpip-origin]');
  if (v && t > 0 && isFinite(v.duration)) v.currentTime = t;
};

function run(tabId, func, args = []) {
  return chrome.scripting.executeScript({ target: { tabId }, func, args }).catch(() => null);
}

function flash(tabId, msg) {
  if (tabId == null) return;
  chrome.action.setBadgeBackgroundColor({ color: '#d33', tabId });
  chrome.action.setBadgeText({ text: '!', tabId });
  chrome.action.setTitle({ title: `MacPiP: ${msg}`, tabId });
  setTimeout(() => {
    chrome.action.setBadgeText({ text: '', tabId });
    chrome.action.setTitle({ title: 'Float video (⌥⇧P)', tabId });
  }, 4000);
}

function connect() {
  const p = chrome.runtime.connectNative(HOST);
  p.onMessage.addListener((m) => {
    if (m.type === 'opened') run(sourceTab, pauseOrigin);
    else if (m.type === 'error') flash(sourceTab, 'Unsupported page');
    else if (m.type === 'closed') run(sourceTab, resumeAt, [m.t || 0]);
  });
  p.onDisconnect.addListener(() => {
    const err = chrome.runtime.lastError;
    if (err && /not found|forbidden/i.test(err.message || '')) flash(sourceTab, 'Native app missing — run install.sh');
    if (port === p) port = null;
  });
  return p;
}

chrome.action.onClicked.addListener(async (tab) => {
  const res = await run(tab.id, probe);
  const info = res?.[0]?.result;
  if (!info) return flash(tab.id, 'Cannot read this page');
  sourceTab = tab.id;
  port ??= connect();
  port.postMessage({ action: 'open', ...info });
});
