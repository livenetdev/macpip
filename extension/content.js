// Injected into the clicked tab only. Streams the main <video>'s own frames (native
// resolution, independent of layout/scroll) and obeys play/pause/seek from MacPiP.
(() => {
  globalThis.__macpip?.stop();

  const area = (e) => { const r = e.getBoundingClientRect(); return r.width * r.height; };
  const vids = [...document.querySelectorAll('video')].filter((v) => v.readyState > 0 || area(v) > 0);
  const playing = vids.filter((v) => !v.paused && !v.ended);
  const pick = (l) => l.reduce((b, e) => (!b || area(e) > area(b) ? e : b), null);
  const v = pick(playing) || pick(vids);

  const port = chrome.runtime.connect({ name: 'content' });
  if (!v) { port.postMessage({ k: 'none' }); port.disconnect(); return; }

  let stopped = false, crop = false, raf = 0, errs = 0;
  const enc = new MacPiPEncoder((m) => { if (!stopped) port.postMessage(m); });

  const state = () => port.postMessage({ k: 'state', paused: v.paused, muted: v.muted, t: v.currentTime, dur: isFinite(v.duration) ? v.duration : 0 });
  const events = ['play', 'pause', 'volumechange', 'seeked'];
  events.forEach((e) => v.addEventListener(e, state));

  // Cross-origin video without CORS can't be read directly: fall back to cropping the tab capture.
  const rect = () => {
    const r = v.getBoundingClientRect();
    port.postMessage({ k: 'rect', x: r.x, y: r.y, w: r.width, h: r.height, vw: innerWidth, vh: innerHeight });
  };
  const onLayout = () => { cancelAnimationFrame(raf); raf = requestAnimationFrame(rect); };

  function grab() {
    if (stopped) return;
    if (v.readyState >= 2) {
      try {
        enc.encode(new VideoFrame(v, { timestamp: Math.round(performance.now() * 1000) }));
      } catch (e) {
        if (errs++ < 5) port.postMessage({ k: 'log', msg: `VideoFrame: ${e.name} ${e.message}` });
        if (e.name === 'SecurityError') {
          crop = true;
          port.postMessage({ k: 'crop' });
          rect();
          addEventListener('scroll', onLayout, true);
          addEventListener('resize', onLayout);
          new ResizeObserver(onLayout).observe(v);
          return;
        }
      }
    }
    v.requestVideoFrameCallback(grab);
  }

  port.onMessage.addListener((m) => {
    if (m.cmd === 'toggle') v.paused ? v.play().catch(() => {}) : v.pause();
    else if (m.cmd === 'seek') v.currentTime = Math.max(0, v.currentTime + m.d);
    else if (m.cmd === 'mute') v.muted = !v.muted;
    else if (m.cmd === 'key') enc.key();
    else if (m.cmd === 'stop') stop();
  });
  port.onDisconnect.addListener(() => stop());

  function stop() {
    if (stopped) return;
    stopped = true;
    events.forEach((e) => v.removeEventListener(e, state));
    removeEventListener('scroll', onLayout, true);
    removeEventListener('resize', onLayout);
    enc.close();
    try { port.disconnect(); } catch (_) {}
    if (globalThis.__macpip?.stop === stop) delete globalThis.__macpip;
  }
  globalThis.__macpip = { stop };

  port.postMessage({ k: 'hello', title: document.title, w: v.videoWidth, h: v.videoHeight });
  state();
  grab();
})();
