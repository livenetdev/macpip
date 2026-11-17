// Holds the tab capture. Its main job is keep-alive: while a tab is captured, Chrome renders it as
// if visible (no background throttling) even when its window is hidden behind a fullscreen app.
// Frames are only encoded in fallback "crop" mode (cross-origin video the page can't read).
let track = null, reader = null, crop = null, enc = null, port = null;

chrome.runtime.onMessage.addListener((m) => {
  if (m.target !== 'offscreen') return;
  if (m.type === 'start') start(m.streamId);
  else if (m.type === 'rect') crop = m;
  else if (m.type === 'crop') { crop = crop || {}; track?.applyConstraints({ frameRate: { max: 60 } }).catch(() => {}); }
  else if (m.type === 'key') enc?.key();
  else if (m.type === 'stop') stop();
});

async function start(streamId) {
  stop();
  const stream = await navigator.mediaDevices.getUserMedia({
    audio: false, // tab audio keeps playing normally
    video: { mandatory: { chromeMediaSource: 'tab', chromeMediaSourceId: streamId, maxWidth: 3840, maxHeight: 2160, maxFrameRate: 5 } }, // 5 fps: keep-alive only; raised in crop mode
  });
  track = stream.getVideoTracks()[0];
  port = chrome.runtime.connect({ name: 'offscreen' });
  enc = new MacPiPEncoder((msg) => port?.postMessage(msg));
  reader = new MediaStreamTrackProcessor({ track }).readable.getReader();
  for (;;) {
    const { value: f, done } = await reader.read().catch(() => ({ done: true }));
    if (done) break;
    if (!crop || !crop.vw || crop.w < 2 || crop.h < 2) { f.close(); continue; }
    const sx = f.displayWidth / crop.vw, sy = f.displayHeight / crop.vh;
    const even = (n) => Math.max(0, Math.floor(n / 2) * 2);
    const x = even(Math.max(0, crop.x * sx)), y = even(Math.max(0, crop.y * sy));
    const w = even(Math.min(f.displayWidth - x, crop.w * sx)), h = even(Math.min(f.displayHeight - y, crop.h * sy));
    if (w < 2 || h < 2) { f.close(); continue; }
    try { enc.encode(new VideoFrame(f, { visibleRect: { x, y, width: w, height: h } })); } catch (_) {}
    f.close();
  }
}

function stop() {
  try { reader?.cancel(); } catch (_) {}
  try { track?.stop(); } catch (_) {}
  enc?.close();
  try { port?.disconnect(); } catch (_) {}
  track = reader = enc = port = null;
  crop = null;
}
