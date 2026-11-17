// Opens Chrome's native PiP on the first tab's <video> via DevTools (userGesture satisfies the activation rule).
const tabs = await (await fetch('http://127.0.0.1:9222/json')).json();
const ws = new WebSocket(tabs.find((t) => t.type === 'page').webSocketDebuggerUrl);
await new Promise((r) => (ws.onopen = r));
const res = await new Promise((r) => {
  ws.onmessage = (e) => { const m = JSON.parse(e.data); if (m.id === 1) r(m); };
  ws.send(JSON.stringify({ id: 1, method: 'Runtime.evaluate', params: {
    expression: `(async () => { const v = document.querySelector('video'); v.loop = true; v.muted = true;
      await v.play(); await v.requestPictureInPicture(); return 'pip ' + v.videoWidth + 'x' + v.videoHeight; })()`,
    awaitPromise: true, userGesture: true } }));
});
console.log(JSON.stringify(res.result));
ws.close();
