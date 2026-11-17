import AppKit
import WebKit

/// The floating window. Key properties for floating over fullscreen apps:
///   • accessory app (no Dock icon) + non-activating NSPanel
///   • collectionBehavior .canJoinAllSpaces + .fullScreenAuxiliary
///   • window level above everything
final class PlayerWindow: NSPanel, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    var onClose: ((Double) -> Void)?
    var clickThrough = false {
        didSet { ignoresMouseEvents = clickThrough; bar.alphaValue = 0 }
    }

    private var web: WKWebView?
    private var plan: Plan?
    private var lastTime = 0.0
    private var aspect = CGSize(width: 16, height: 9)
    private let root = HoverView()
    private let bar = Bar()
    private var keyMonitor: Any?
    private var closing = false
    private let defaults = UserDefaults.standard

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 480, height: 270),
                   styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isFloatingPanel = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { standardWindowButton(b)?.isHidden = true }
        backgroundColor = .black
        hasShadow = true
        minSize = NSSize(width: 160, height: 90)
        contentAspectRatio = aspect
        alphaValue = CGFloat(defaults.object(forKey: "opacity") as? Double ?? 1)
        delegate = self

        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.black.cgColor
        root.onHover = { [weak self] inside in
            guard let self, !self.clickThrough else { return }
            NSAnimationContext.runAnimationGroup { $0.duration = 0.15; self.bar.animator().alphaValue = inside ? 1 : 0 }
        }
        contentView = root

        bar.frame = NSRect(x: 0, y: root.bounds.height - Bar.height, width: root.bounds.width, height: Bar.height)
        bar.autoresizingMask = [.width, .minYMargin]
        bar.alphaValue = 0
        bar.onClose = { [weak self] in self?.close() }
        bar.onOpacity = { [weak self] in
            guard let self else { return }
            let steps: [CGFloat] = [1, 0.75, 0.5, 0.3]
            let i = steps.firstIndex { abs($0 - self.alphaValue) < 0.05 } ?? 0
            self.setOpacity(steps[(i + 1) % steps.count])
        }
        bar.onGhost = { [weak self] in self?.clickThrough = true }
        root.addSubview(bar)

        // Esc / ⌘W close. Everything else goes to the player.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, e.window === self else { return e }
            if e.keyCode == 53 || (e.modifierFlags.contains(.command) && e.charactersIgnoringModifiers == "w") {
                self.close(); return nil
            }
            return e
        }
    }

    // MARK: Loading

    func play(_ req: Request) {
        title = req.title
        lastTime = req.time
        if let s = req.size { setAspect(s) }
        if !isVisible {
            placeInitially()
            orderFrontRegardless()
        }
        Web.prepare { [weak self] in self?.start(req.plan, time: req.time) }
    }

    private func start(_ p: Plan, time: Double) {
        plan = p
        teardownWeb()

        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()              // fresh, memory-only cookies/cache/storage
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = false
        cfg.applicationNameForUserAgent = "Version/18.0 Safari/605.1.15"  // look like Safari, not a unique embedder
        let world = WKContentWorld.world(name: "macpip")
        let ucc = cfg.userContentController
        ucc.addUserScript(WKUserScript(source: Web.script(mode: p.mode, time: time),
                                       injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: world))
        ucc.add(self, contentWorld: world, name: "macpip")
        if let r = Web.rules { ucc.add(r) }

        let w = WKWebView(frame: root.bounds, configuration: cfg)
        w.autoresizingMask = [.width, .height]
        w.navigationDelegate = self
        w.uiDelegate = self
        w.underPageBackgroundColor = .black
        root.addSubview(w, positioned: .below, relativeTo: bar)
        web = w

        switch p.mode {
        case .embed:  w.loadHTMLString(Web.embedHTML(p.url), baseURL: Web.origin)
        case .direct: w.loadHTMLString(Web.videoHTML(p.url), baseURL: p.fallback ?? p.url)
        case .page:   w.load(URLRequest(url: p.url))
        }
    }

    private func teardownWeb() {
        guard let w = web else { return }
        w.configuration.userContentController.removeAllScriptMessageHandlers()
        w.navigationDelegate = nil
        w.uiDelegate = nil
        w.removeFromSuperview()
        web = nil
    }

    private func fallback() {
        guard let p = plan, p.mode != .page, let f = p.fallback else { return }
        start(Plan(mode: .page, url: f, fallback: nil), time: lastTime)
    }

    // MARK: Messages from the frame script

    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        guard m.webView === web, let d = m.body as? [String: Any], let k = d["k"] as? String else { return }
        switch k {
        case "t":
            if let t = (d["t"] as? NSNumber)?.doubleValue, t.isFinite, t >= 0 { lastTime = t }
        case "meta":
            if let w = (d["w"] as? NSNumber)?.doubleValue, let h = (d["h"] as? NSNumber)?.doubleValue, w > 0, h > 0 {
                setAspect(CGSize(width: w, height: h))
            }
        case "err":
            fallback()
        default: break
        }
    }

    // MARK: Web view policy: http(s) only, no popups, no camera/mic

    func webView(_ w: WKWebView, decidePolicyFor a: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let s = a.request.url?.scheme?.lowercased() ?? ""
        decisionHandler(["https", "http", "about", "blob", "data"].contains(s) ? .allow : .cancel)
    }

    func webView(_ w: WKWebView, createWebViewWith c: WKWebViewConfiguration, for a: WKNavigationAction,
                 windowFeatures f: WKWindowFeatures) -> WKWebView? {
        // A link the user clicked (e.g. "Watch on YouTube") opens in their default browser.
        if a.navigationType == .linkActivated, let u = a.request.url, ["https", "http"].contains(u.scheme ?? "") {
            NSWorkspace.shared.open(u)
        }
        return nil
    }

    func webView(_ w: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.deny)
    }

    func webViewWebContentProcessDidTerminate(_ w: WKWebView) {
        if let p = plan { start(p, time: lastTime) }
    }

    // MARK: Geometry

    private func visible(for f: NSRect) -> NSRect {
        (NSScreen.screens.first { $0.visibleFrame.intersects(f) } ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? f
    }

    private func placeInitially() {
        var c: NSRect
        if let s = defaults.string(forKey: "frame") {
            c = contentRect(forFrameRect: NSRectFromString(s))
        } else {
            let vis = visible(for: .zero)
            let w = min(480, vis.width / 3)
            c = NSRect(x: vis.maxX - w - 16, y: vis.minY + 16, width: w, height: 0)
        }
        c.size.height = c.width * aspect.height / aspect.width
        setFrame(fit(frameRect(forContentRect: c)), display: false)
    }

    private func setAspect(_ s: CGSize) {
        let r = s.width / s.height
        guard r > 0.2, r < 5, abs(r - aspect.width / aspect.height) > 0.01 else { return }
        aspect = s
        contentAspectRatio = s
        guard isVisible else { return }
        var c = contentRect(forFrameRect: frame)
        let top = c.maxY
        c.size.height = c.width / r
        // Keep the edge nearest the screen edge fixed.
        if frame.midY > visible(for: frame).midY { c.origin.y = top - c.height }
        setFrame(fit(frameRect(forContentRect: c)), display: true, animate: true)
    }

    /// Shrinks to the screen (keeping aspect) and moves fully on-screen.
    private func fit(_ f: NSRect) -> NSRect {
        let vis = visible(for: f)
        var f = f
        if f.width > vis.width || f.height > vis.height {
            let s = min(vis.width / f.width, vis.height / f.height)
            f.size = NSSize(width: f.width * s, height: f.height * s)
        }
        f.origin.x = min(max(f.minX, vis.minX), vis.maxX - f.width)
        f.origin.y = min(max(f.minY, vis.minY), vis.maxY - f.height)
        return f
    }

    func snap(_ corner: Int) {
        let vis = visible(for: frame), m: CGFloat = 16
        var f = frame
        f.origin.x = corner % 2 == 0 ? vis.minX + m : vis.maxX - f.width - m
        f.origin.y = corner < 2 ? vis.maxY - f.height - m : vis.minY + m
        setFrame(f, display: true, animate: true)
        saveFrame()
    }

    func setOpacity(_ a: CGFloat) {
        alphaValue = a
        defaults.set(Double(a), forKey: "opacity")
    }

    private func saveFrame() { defaults.set(NSStringFromRect(frame), forKey: "frame") }
    func windowDidMove(_ n: Notification) { saveFrame() }
    func windowDidEndLiveResize(_ n: Notification) { saveFrame() }

    // ⌘-drag anywhere moves the window (the hover bar also drags).
    override func sendEvent(_ e: NSEvent) {
        if e.type == .leftMouseDown, e.modifierFlags.contains(.command) {
            performDrag(with: e)
            return
        }
        super.sendEvent(e)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func close() {
        guard !closing else { return }
        closing = true
        saveFrame()
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        teardownWeb()
        super.close()
        onClose?(lastTime)
    }
}

// MARK: - Hover detection (tracking area, no polling)

final class HoverView: NSView {
    var onHover: ((Bool) -> Void)?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with e: NSEvent) { onHover?(true) }
    override func mouseExited(with e: NSEvent) { onHover?(false) }
}

// MARK: - Top bar shown on hover: drag area + click-through, opacity, close

final class Bar: NSView {
    static let height: CGFloat = 28
    var onClose: (() -> Void)?
    var onOpacity: (() -> Void)?
    var onGhost: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let stack = NSStackView(views: [
            button("hand.raised.slash", "Click-through (undo from menu bar)", #selector(ghost)),
            button("circle.lefthalf.filled", "Opacity", #selector(opacity)),
            button("xmark", "Close (Esc)", #selector(closeTapped)),
        ])
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func makeBackingLayer() -> CALayer {
        let g = CAGradientLayer()
        g.colors = [NSColor.black.withAlphaComponent(0).cgColor, NSColor.black.withAlphaComponent(0.6).cgColor]
        return g
    }

    private func button(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage()
        let b = NSButton(image: img, target: self, action: action)
        b.isBordered = false
        b.contentTintColor = .white
        b.toolTip = tip
        return b
    }

    @objc private func ghost() { onGhost?() }
    @objc private func opacity() { onOpacity?() }
    @objc private func closeTapped() { onClose?() }

    override func mouseDown(with e: NSEvent) { window?.performDrag(with: e) }
    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
}
