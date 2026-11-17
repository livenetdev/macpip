import WebKit

/// Everything the floating web view loads besides the video itself.
enum Web {
    /// Fake https origin for wrapper pages. Never fetched; only used as the
    /// Referer YouTube requires for embeds (otherwise "Error 153").
    static let origin = URL(string: "https://macpip.local/")!

    // MARK: Tracker blocking (compiled once per process into a temp store, nothing persisted)

    private(set) static var rules: WKContentRuleList?
    private static var compiled = false

    static func prepare(_ done: @escaping () -> Void) {
        if compiled { return done() }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("macpip-rules-\(getpid())")
        guard let store = WKContentRuleListStore(url: dir) else { compiled = true; return done() }
        store.compileContentRuleList(forIdentifier: "block", encodedContentRuleList: blockList) { list, _ in
            rules = list
            compiled = true
            try? FileManager.default.removeItem(at: dir)
            done()
        }
    }

    private static let blockedDomains = [
        "doubleclick.net", "googlesyndication.com", "googleadservices.com", "google-analytics.com",
        "googletagmanager.com", "googletagservices.com", "adservice.google.com", "facebook.net",
        "scorecardresearch.com", "quantserve.com", "hotjar.com", "segment.io", "cdn.segment.com",
        "mixpanel.com", "amplitude.com", "criteo.com", "criteo.net", "taboola.com", "outbrain.com",
        "adnxs.com", "rubiconproject.com", "pubmatic.com", "amazon-adsystem.com", "moatads.com",
        "chartbeat.com", "nr-data.net",
    ]
    private static let blockedPaths = ["/api/stats/ads", "/ptracking", "/pagead/", "/youtubei/v1/log_event"]

    private static var blockList: String {
        let esc = { (s: String) in s.replacingOccurrences(of: ".", with: "\\\\.") }
        let domains = blockedDomains.map { #"{"trigger":{"url-filter":"^[^:]+://+([^:/]+\\.)?\#(esc($0))[:/]"},"action":{"type":"block"}}"# }
        let paths = blockedPaths.map { #"{"trigger":{"url-filter":"^https?://[^/]*youtube[^/]*\#($0)"},"action":{"type":"block"}}"# }
        return "[" + (domains + paths).joined(separator: ",") + "]"
    }

    // MARK: Wrapper pages

    private static func attr(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
         .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    private static let head = """
    <!doctype html><html><head><meta charset="utf-8"><meta name="referrer" content="strict-origin-when-cross-origin">
    <style>html,body{margin:0;height:100%;background:#000;overflow:hidden}
    iframe,video{position:fixed;inset:0;width:100%;height:100%;border:0;object-fit:contain;background:#000}</style></head><body>
    """

    static func embedHTML(_ u: URL) -> String {
        head + #"<iframe src="\#(attr(u.absoluteString))" allow="autoplay; encrypted-media; picture-in-picture" referrerpolicy="strict-origin-when-cross-origin"></iframe></body></html>"#
    }

    static func videoHTML(_ u: URL) -> String {
        head + #"<video src="\#(attr(u.absoluteString))" autoplay controls playsinline></video></body></html>"#
    }

    // MARK: Frame script
    //
    // Runs in every frame, inside an isolated JS world: page scripts can neither
    // see it nor forge its messages. Finds the main <video>, reports its size and
    // position, seeks to the start time, and in page mode hides everything else.

    static func script(mode: Mode, time: Double) -> String {
        let cfg = "{mode:'\(mode.rawValue)',t:\(time.isFinite ? time : 0)}"
        return frameJS.replacingOccurrences(of: "__CFG__", with: cfg)
    }

    private static let frameJS = #"""
(() => {
  const C = __CFG__;
  const isTop = window === window.top;
  const post = (m) => { try { webkit.messageHandlers.macpip.postMessage(m); } catch (_) {} };
  const area = (e) => { const r = e.getBoundingClientRect(); return r.width * r.height; };
  const largest = (sel) => {
    let best = null, ba = -1;
    for (const e of document.querySelectorAll(sel)) {
      const a = area(e) || (e.videoWidth ? 1 : 0);
      if (a > ba) { ba = a; best = e; }
    }
    return best;
  };
  const CSS = `html,body{overflow:hidden!important;background:#000!important}
body,body *{visibility:hidden!important}
[data-macpip=a]{transform:none!important;filter:none!important;contain:none!important;will-change:auto!important;clip-path:none!important;perspective:none!important;backdrop-filter:none!important;z-index:2147483647!important}
[data-macpip=v]{visibility:visible!important;position:fixed!important;inset:0!important;width:100vw!important;height:100vh!important;max-width:none!important;max-height:none!important;min-width:0!important;min-height:0!important;margin:0!important;padding:0!important;border:0!important;z-index:2147483647!important;object-fit:contain!important;background:#000!important;transform:none!important;opacity:1!important}`;

  let v = null, isolated = null, seeked = false, sentT = -1, ticks = 0, reported = false;
  const hooked = new WeakSet();

  function addStyle() {
    if (document.getElementById('macpip-css')) return;
    try {
      const sheet = new CSSStyleSheet();
      sheet.replaceSync(CSS);
      document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
    } catch (_) {}
    const s = document.createElement('style');
    s.id = 'macpip-css';
    s.textContent = CSS;
    (document.head || document.documentElement).appendChild(s);
  }

  function isolate(el) {
    if (isolated === el && el.getAttribute('data-macpip') === 'v') return;
    for (const e of document.querySelectorAll('[data-macpip]')) e.removeAttribute('data-macpip');
    el.setAttribute('data-macpip', 'v');
    for (let p = el.parentElement; p; p = p.parentElement) p.setAttribute('data-macpip', 'a');
    addStyle();
    if (el.tagName === 'VIDEO') el.controls = true;
    isolated = el;
  }

  function hook(el) {
    if (hooked.has(el)) return;
    hooked.add(el);
    const meta = () => { if (el === v && el.videoWidth) post({ k: 'meta', w: el.videoWidth, h: el.videoHeight }); };
    el.addEventListener('loadedmetadata', meta);
    el.addEventListener('resize', meta);
    meta();
    if (C.mode === 'direct') el.addEventListener('error', () => post({ k: 'err' }));
    if (!seeked && C.mode !== 'embed' && C.t > 1) {
      const seek = () => {
        if (seeked) return;
        seeked = true;
        if (!isFinite(el.duration) || C.t < el.duration) el.currentTime = C.t;
      };
      el.readyState >= 1 ? seek() : el.addEventListener('loadedmetadata', seek, { once: true });
    }
    const p = el.play && el.play();
    if (p && p.catch) p.catch(() => {});
  }

  function tick() {
    ticks++;
    const n = largest('video');
    if (n && n !== v) { v = n; hook(v); }
    if (C.mode === 'page') {
      if (v) isolate(v);
      else if (isTop && ticks >= 3) {
        const f = largest('iframe');
        if (f && area(f) > innerWidth * innerHeight * 0.15) isolate(f);
      }
    }
    if (v && !v.paused && Math.abs(v.currentTime - sentT) >= 1) {
      sentT = v.currentTime;
      post({ k: 't', t: sentT });
    }
    if (!reported && C.mode === 'embed' && /youtube/.test(location.hostname)) {
      const e = document.querySelector('.ytp-error');
      if (e && e.getClientRects().length) { reported = true; post({ k: 'err' }); }
    }
    if (!isTop && !v && ticks > 15) clearInterval(timer);
  }

  const timer = setInterval(tick, 1000);
  tick();
})();
"""#
}
