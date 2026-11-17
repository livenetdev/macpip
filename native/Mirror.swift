import AppKit
import ScreenCaptureKit

/// A live, GPU zero-copy mirror of one window, shown in a panel that is allowed
/// into fullscreen Spaces. The source keeps playing in its own app with its own
/// session, codecs and audio; MacPiP only displays its pixels.
final class Mirror: NSPanel, NSWindowDelegate, SCStreamOutput, SCStreamDelegate {
    let source: CGWindowID
    private let sourcePID: pid_t
    var onDismiss: (() -> Void)?
    var onFrameChange: ((NSRect) -> Void)?
    var clickThrough = false { didSet { ignoresMouseEvents = clickThrough; bar.alphaValue = 0 } }

    private var stream: SCStream?
    private var sourceSize: CGSize
    private let video = CALayer()
    private let root = HoverView()
    private let bar = Bar()
    private let frames = DispatchQueue(label: "macpip.frames", qos: .userInteractive)
    private var closing = false

    init(source w: Win, frame saved: NSRect?, opacity: CGFloat, clickThrough ct: Bool) {
        source = w.id
        sourcePID = w.pid
        sourceSize = w.bounds.size
        super.init(contentRect: Windows.appKitRect(w.bounds),
                   styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        // Verified on macOS CI: floats above a fullscreen app.
        isFloatingPanel = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { standardWindowButton(b)?.isHidden = true }
        backgroundColor = .black
        hasShadow = true
        minSize = NSSize(width: 120, height: 68)
        contentAspectRatio = sourceSize
        alphaValue = opacity
        delegate = self

        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.black.cgColor
        video.contentsGravity = .resizeAspect
        video.frame = root.bounds
        video.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        root.layer?.addSublayer(video)
        root.onHover = { [weak self] inside in
            guard let self, !self.clickThrough else { return }
            NSAnimationContext.runAnimationGroup { $0.duration = 0.15; self.bar.animator().alphaValue = inside ? 1 : 0 }
        }
        root.onDoubleClick = { [weak self] in self?.revealSource() }
        contentView = root

        bar.frame = NSRect(x: 0, y: root.bounds.height - Bar.height, width: root.bounds.width, height: Bar.height)
        bar.autoresizingMask = [.width, .minYMargin]
        bar.alphaValue = 0
        bar.onReveal = { [weak self] in self?.revealSource() }
        bar.onOpacity = { [weak self] in
            guard let self else { return }
            let steps: [CGFloat] = [1, 0.75, 0.5, 0.3]
            let i = steps.firstIndex { abs($0 - self.alphaValue) < 0.05 } ?? 0
            self.alphaValue = steps[(i + 1) % steps.count]
            UserDefaults.standard.set(Double(self.alphaValue), forKey: "opacity")
        }
        bar.onGhost = { [weak self] in self?.clickThrough = true }
        bar.onClose = { [weak self] in self?.onDismiss?() }
        root.addSubview(bar)

        if let saved { setFrame(fit(fitAspect(saved)), display: false) }
        clickThrough = ct
        orderFrontRegardless()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Capture

    func start() {
        let scale = screen?.backingScaleFactor ?? 2
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { [weak self] content, error in
            guard let self else { return }
            guard let w = content?.windows.first(where: { $0.windowID == self.source }) else {
                log("source window unavailable: \(error?.localizedDescription ?? "not found")")
                return
            }
            let s = SCStream(filter: SCContentFilter(desktopIndependentWindow: w),
                             configuration: self.config(size: w.frame.size, scale: scale), delegate: self)
            do {
                try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.frames)
            } catch {
                log("addStreamOutput: \(error.localizedDescription)"); return
            }
            s.startCapture { err in if let err { log("startCapture: \(err.localizedDescription)") } }
            DispatchQueue.main.async { self.stream = s }
        }
    }

    private func config(size: CGSize, scale: CGFloat) -> SCStreamConfiguration {
        let c = SCStreamConfiguration()
        c.width = max(2, Int(size.width * scale))
        c.height = max(2, Int(size.height * scale))
        c.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        c.queueDepth = 3
        c.showsCursor = false
        c.pixelFormat = kCVPixelFormatType_32BGRA
        if #available(macOS 14.0, *) { c.ignoreShadowsSingleWindow = true }
        return c
    }

    /// Source window moved/resized (called once a second by the watcher).
    func sourceChanged(_ w: Win) {
        guard abs(w.bounds.width - sourceSize.width) > 1 || abs(w.bounds.height - sourceSize.height) > 1 else { return }
        sourceSize = w.bounds.size
        stream?.updateConfiguration(config(size: sourceSize, scale: screen?.backingScaleFactor ?? 2)) { _ in }
        contentAspectRatio = sourceSize
        setFrame(fit(fitAspect(frame)), display: true, animate: true)
    }

    func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid,
              let att = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = att.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let px = CMSampleBufferGetImageBuffer(sb),
              let surface = CVPixelBufferGetIOSurface(px)?.takeUnretainedValue() else { return }
        DispatchQueue.main.async { [video] in
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            video.contents = surface
            CATransaction.commit()
        }
    }

    func stream(_ s: SCStream, didStopWithError error: Error) {
        log("stream stopped: \(error.localizedDescription)")
    }

    func stop() {
        guard !closing else { return }
        closing = true
        stream?.stopCapture { _ in }
        stream = nil
        onFrameChange?(frame)
        close()
    }

    /// Jump to the original (switches to its Space).
    private func revealSource() {
        NSRunningApplication(processIdentifier: sourcePID)?.activate(options: [])
    }

    // MARK: Geometry

    private func fitAspect(_ f: NSRect) -> NSRect {
        var c = contentRect(forFrameRect: f)
        c.size.height = c.width * sourceSize.height / max(sourceSize.width, 1)
        return frameRect(forContentRect: c)
    }

    private func fit(_ f: NSRect) -> NSRect {
        guard let vis = (NSScreen.screens.first { $0.visibleFrame.intersects(f) } ?? NSScreen.main)?.visibleFrame else { return f }
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
        guard let vis = (screen ?? NSScreen.main)?.visibleFrame else { return }
        var f = frame
        f.origin.x = corner % 2 == 0 ? vis.minX + 16 : vis.maxX - f.width - 16
        f.origin.y = corner < 2 ? vis.maxY - f.height - 16 : vis.minY + 16
        setFrame(f, display: true, animate: true)
        onFrameChange?(frame)
    }

    func windowDidMove(_ n: Notification) { onFrameChange?(frame) }
    func windowDidEndLiveResize(_ n: Notification) { onFrameChange?(frame) }

    // ⌘-drag anywhere moves the window; Esc dismisses.
    override func sendEvent(_ e: NSEvent) {
        if e.type == .leftMouseDown, e.modifierFlags.contains(.command) { performDrag(with: e); return }
        if e.type == .keyDown, e.keyCode == 53 { onDismiss?(); return }
        super.sendEvent(e)
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Hover detection + drag (tracking area, no polling)

final class HoverView: NSView {
    var onHover: ((Bool) -> Void)?
    var onDoubleClick: (() -> Void)?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with e: NSEvent) { onHover?(true) }
    override func mouseExited(with e: NSEvent) { onHover?(false) }
    override func mouseDown(with e: NSEvent) {
        if e.clickCount == 2 { onDoubleClick?() } else { window?.performDrag(with: e) }
    }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
}

// MARK: - Top bar shown on hover

final class Bar: NSView {
    static let height: CGFloat = 28
    var onReveal: (() -> Void)?
    var onOpacity: (() -> Void)?
    var onGhost: (() -> Void)?
    var onClose: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let stack = NSStackView(views: [
            button("arrow.up.forward.app", "Go to original (double-click)", #selector(reveal)),
            button("hand.raised.slash", "Click-through (undo from menu bar)", #selector(ghost)),
            button("circle.lefthalf.filled", "Opacity", #selector(opacity)),
            button("xmark", "Stop floating this window (Esc)", #selector(closeTapped)),
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
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage(),
                         target: self, action: action)
        b.isBordered = false
        b.contentTintColor = .white
        b.toolTip = tip
        return b
    }

    @objc private func reveal() { onReveal?() }
    @objc private func ghost() { onGhost?() }
    @objc private func opacity() { onOpacity?() }
    @objc private func closeTapped() { onClose?() }

    override func mouseDown(with e: NSEvent) { window?.performDrag(with: e) }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
}
