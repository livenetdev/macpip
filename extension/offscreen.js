// Holds one tab capture per floated tab. Main job: keep-alive. While a tab is captured, Chrome renders
// it as if visible (no background throttling) even when its window is hidden behind a fullscreen app.
// Frames are only encoded in fallback "crop" mode (cross-origin video the page can't read).
const caps = new Map(); // tabId → { track, reader, crop, enc }
let port = null;

chrome.runtime.onMessage.addListener((m) => {
  if (m.target !== 'offscreen') return;
  const c = caps.get(m.tabId);
  if (m.type === 'start') start(m.tabId, m.streamId);
  else if (m.type === 'stop') stop(m.tabId);
  else if (!c) return;
  else if (m.type === 'rect') c.crop = m;
  else if (m.type === 'crop') { c.crop = c.crop || {}; c.track.applyConstraints({ width: { max: 3840 }, height: { max: 2160 }, frameRate: { max: 60 } }).catch(() => {}); }
  else if (m.type === 'key') c.enc.key();
  else if (m.type === 'size') c.enc.setMax(m.w, m.h);
});

async function start(tabId, streamId) {
  stop(tabId);
  const stream = await navigator.mediaDevices.getUserMedia({
    audio: false, // tab audio keeps playing normally
    video: { mandatory: { chromeMediaSource: 'tab', chromeMediaSourceId: streamId, maxWidth: 640, maxHeight: 360, maxFrameRate: 60 } }, // small but full rate: a hidden tab only draws as often as it is captured
  });
  port ??= chrome.runtime.connect({ name: 'offscreen' });
  const c = { track: stream.getVideoTracks()[0], crop: null };
  c.enc = new MacPiPEncoder((msg) => port?.postMessage({ ...msg, s: tabId }));
  c.reader = new MediaStreamTrackProcessor({ track: c.track }).readable.getReader();
  caps.set(tabId, c);
  for (;;) {
    const { value: f, done } = await c.reader.read().catch(() => ({ done: true }));
    if (done) break;
    const crop = c.crop;
    if (!crop || !crop.vw || crop.w < 2 || crop.h < 2) { f.close(); continue; }
    const sx = f.displayWidth / crop.vw, sy = f.displayHeight / crop.vh;
    const even = (n) => Math.max(0, Math.floor(n / 2) * 2);
    const x = even(Math.max(0, crop.x * sx)), y = even(Math.max(0, crop.y * sy));
    const w = even(Math.min(f.displayWidth - x, crop.w * sx)), h = even(Math.min(f.displayHeight - y, crop.h * sy));
    if (w < 2 || h < 2) { f.close(); continue; }
    try { c.enc.encode(new VideoFrame(f, { visibleRect: { x, y, width: w, height: h } })); } catch (_) {}
    f.close();
  }
}

function stop(tabId) {
  const c = caps.get(tabId);
  if (!c) return;
  caps.delete(tabId);
  try { c.reader?.cancel(); } catch (_) {}
  try { c.track?.stop(); } catch (_) {}
  c.enc?.close();
}
