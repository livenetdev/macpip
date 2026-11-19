// Usage: node ci/cdp.mjs play|measure — talks to the video tab over DevTools.
const tabs = await (await fetch('http://127.0.0.1:9222/json')).json();
const want = process.argv[3] || 'mp4';
const tab = tabs.find((t) => t.type === 'page' && t.url.includes(want));
const ws = new WebSocket(tab.webSocketDebuggerUrl);
await new Promise((r) => (ws.onopen = r));
const exprs = {
  play: `(async () => { const v = document.querySelector('video'); v.loop = true; await v.play(); return 'playing ' + v.videoWidth + 'x' + v.videoHeight; })()`,
  measure: `(async () => { const v = document.querySelector('video'); let n = 0;
    const cb = () => { n++; v.requestVideoFrameCallback(cb); }; v.requestVideoFrameCallback(cb);
    const t0 = v.currentTime, w0 = performance.now(); await new Promise((r) => setTimeout(r, 3000));
    const s = (performance.now() - w0) / 1000;
    return JSON.stringify({ visibility: document.visibilityState, framesPerSec: +(n / s).toFixed(1), videoAdvancedSec: +((v.currentTime - t0 + v.duration) % v.duration).toFixed(1), wallSec: +s.toFixed(1), paused: v.paused }); })()`,
};
const res = await new Promise((r) => {
  ws.onmessage = (e) => { const m = JSON.parse(e.data); if (m.id === 1) r(m); };
  ws.send(JSON.stringify({ id: 1, method: 'Runtime.evaluate', params: { expression: exprs[process.argv[2]], awaitPromise: true, userGesture: true } }));
});
console.log(process.argv[2], want, res.result?.result?.value ?? JSON.stringify(res));
ws.close();
