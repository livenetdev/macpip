import AppKit
import AVFoundation

/// Floating video window. Verified on macOS CI to sit above fullscreen apps:
/// accessory app + non-activating NSPanel + .canJoinAllSpaces/.fullScreenAuxiliary.
/// Frames arrive as H.264 from the browser tab and are decoded by AVSampleBufferDisplayLayer (hardware).
final class Player: NSPanel, NSWindowDelegate {
    var onCommand: (([String: Any]) -> Void)?
    var onClose: (() -> Void)?
    var onActivate: (() -> Void)?

    private let video = AVSampleBufferDisplayLayer()
    private var format: CMVideoFormatDescription?
    private var aspect = CGSize(width: 16, height: 9)
    private let root = HoverView()
    private let bar = Controls()
    private var hideWork: DispatchWorkItem?
    private var pinControls = false // CI screenshots (SIGUSR1)
    private let hint = NSTextField(labelWithString: "Hold ⌥ to interact")
    private var peekTimer: Timer?
    private var peeking = false

    /// Click-through: the window ignores the mouse so clicks reach the app underneath.
    /// Holding ⌥ while the cursor is over the window makes it interactive again (polled: no permissions needed).
    var clickThrough = false {
        didSet {
            guard clickThrough != oldValue else { return }
            bar.setClickThrough(clickThrough)
            peeking = false
            ignoresMouseEvents = clickThrough
            peekTimer?.invalidate()
            peekTimer = nil
            if clickThrough {
                showControls(false)
                let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.peek() }
                RunLoop.main.add(t, forMode: .common)
                peekTimer = t
            } else {
                setHint(false)
                showControls(frame.contains(NSEvent.mouseLocation))
            }
        }
    }

    private func peek() {
        let inside = frame.contains(NSEvent.mouseLocation)
        let wantsPeek = inside && NSEvent.modifierFlags.contains(.option)
        setHint(inside && !wantsPeek)
        guard wantsPeek != peeking else { return }
        peeking = wantsPeek
        ignoresMouseEvents = !wantsPeek
        showControls(wantsPeek)
    }

    private func setHint(_ on: Bool) {
        guard (hint.alphaValue > 0) != on else { return }
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; hint.animator().alphaValue = on ? 1 : 0 }
    }
    private let stats = NSTextField(labelWithString: "")
    private var shown = 0
    private var keyMonitor: Any?
    private var closing = false
    private let defaults = UserDefaults.standard

    /// `cascadeFrom`: frame of an existing PiP window; the new one is placed next to it.
    init(cascadeFrom: NSRect? = nil) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 480, height: 270),
                   styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { standardWindowButton(b)?.isHidden = true }
        backgroundColor = .black
        hasShadow = true
        minSize = NSSize(width: 260, height: 146)
        contentAspectRatio = aspect
        alphaValue = CGFloat(defaults.object(forKey: "opacity") as? Double ?? 1)
        delegate = self

        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.black.cgColor
        video.videoGravity = .resizeAspect
        video.frame = root.bounds
        video.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        root.layer?.addSublayer(video)
        root.onHover = { [weak self] inside in
            guard let self, !self.ignoresMouseEvents else { return }
            if inside { self.onActivate?() }
            self.showControls(inside)
        }
        root.onMove = { [weak self] in
            guard let self, !self.ignoresMouseEvents else { return }
            self.showControls(true)
        }
        root.onClick = { [weak self] in self?.onCommand?(["cmd": "toggle"]) }
        contentView = root

        bar.frame = root.bounds
        bar.autoresizingMask = [.width, .height]
        bar.alphaValue = 0
        bar.setOpacity(alphaValue)
        bar.onOpacity = { [weak self] a in self?.setOpacity(CGFloat(a)) }
        bar.onSeek = { [weak self] t in self?.onCommand?(["cmd": "seekTo", "t": t]) }
        bar.onCommand = { [weak self] c in
            guard let self else { return }
            switch c {
            case "close": self.close()
            case "ghost": self.clickThrough.toggle()
            default: self.onCommand?(c == "back" ? ["cmd": "seek", "d": -10] : c == "fwd" ? ["cmd": "seek", "d": 10] : ["cmd": c])
            }
        }
        root.addSubview(bar)

        stats.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        stats.textColor = .white
        stats.backgroundColor = NSColor.black.withAlphaComponent(0.55)
        stats.drawsBackground = true
        stats.isHidden = true
        stats.lineBreakMode = .byTruncatingTail
        stats.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) // never widen the window
        stats.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stats.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stats)
        NSLayoutConstraint.activate([
            stats.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6),
            stats.topAnchor.constraint(equalTo: root.topAnchor, constant: 34), // below the title row
            stats.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -6),
        ])

        hint.font = .systemFont(ofSize: 11, weight: .semibold)
        hint.textColor = .white
        hint.alignment = .center
        hint.wantsLayer = true
        hint.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        hint.layer?.cornerRadius = 9
        hint.alphaValue = 0
        hint.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(hint)
        NSLayoutConstraint.activate([
            hint.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            hint.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            hint.widthAnchor.constraint(equalToConstant: 132),
            hint.heightAnchor.constraint(equalToConstant: 18),
        ])

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, e.window === self else { return e }
            switch e.keyCode {
            case 53: self.close()                                         // Esc
            case 49: self.onCommand?(["cmd": "toggle"])                   // Space
            case 123: self.onCommand?(["cmd": "seek", "d": -10])          // ←
            case 124: self.onCommand?(["cmd": "seek", "d": 10])           // →
            case 46: self.onCommand?(["cmd": "mute"])                     // M
            default: return e
            }
            return nil
        }
        placeInitially(cascadeFrom: cascadeFrom)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Stream

    func setTitle(_ t: String) { title = t; bar.setTitle(t) }

    /// Keep controls visible (CI screenshots; toggled with SIGUSR1).
    func togglePinnedControls() {
        pinControls.toggle()
        hideWork?.cancel()
        bar.alphaValue = pinControls ? 1 : 0
    }

    /// Controls fade in on hover/mouse movement and out after 2.5 s of stillness (cursor hides too).
    private func showControls(_ on: Bool) {
        hideWork?.cancel()
        guard !pinControls else { return }
        if bar.alphaValue < 1 || !on {
            NSAnimationContext.runAnimationGroup { $0.duration = on ? 0.12 : 0.25; bar.animator().alphaValue = on ? 1 : 0 }
        }
        guard on else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.bar.isInteracting { return self.showControls(true) }
            NSAnimationContext.runAnimationGroup { $0.duration = 0.25; self.bar.animator().alphaValue = 0 }
            if self.frame.contains(NSEvent.mouseLocation) { NSCursor.setHiddenUntilMouseMoves(true) }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    func configure(width: Int, height: Int, avcc: Data) {
        var fd: CMVideoFormatDescription?
        let ext = [kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: ["avcC": avcc]] as CFDictionary
        CMVideoFormatDescriptionCreate(allocator: nil, codecType: kCMVideoCodecType_H264,
                                       width: Int32(width), height: Int32(height), extensions: ext, formatDescriptionOut: &fd)
        format = fd
        setAspect(CGSize(width: width, height: height))
        if !isVisible { orderFrontRegardless() }
        if !sentSize { sentSize = true; reportSize() }
    }

    private var sentSize = false
    /// Tell the encoder the window's pixel size so it never encodes more than is shown.
    private func reportSize() {
        let px = convertToBacking(contentRect(forFrameRect: frame))
        onCommand?(["cmd": "size", "w": Int(px.width), "h": Int(px.height)])
    }

    func enqueue(_ data: Data, key: Bool) {
        guard let format, let sb = Self.sample(data, key: key, format: format) else { return }
        if renderStatus == .failed { flushRenderer(); onCommand?(["cmd": "key"]) ; return }
        enqueueSample(sb)
        shown += 1
    }

    func takeShown() -> Int { defer { shown = 0 }; return shown }

    /// Pipeline counters overlay (menu bar ▸ Show Frame Rate). nil = just apply the on/off setting.
    func showStats(_ line: String?) {
        stats.isHidden = !defaults.bool(forKey: "showStats")
        if let line { stats.stringValue = " " + line + " " }
    }

    func setState(paused: Bool, muted: Bool) { bar.setState(paused: paused, muted: muted) }
    func setTime(_ t: Double, duration: Double) { bar.setTime(t, duration: duration) }

    private var renderStatus: AVQueuedSampleBufferRenderingStatus {
        if #available(macOS 14.0, *) { return video.sampleBufferRenderer.status }
        return video.status
    }
    private func flushRenderer() {
        if #available(macOS 14.0, *) { video.sampleBufferRenderer.flush() } else { video.flush() }
    }
    private func enqueueSample(_ sb: CMSampleBuffer) {
        if #available(macOS 14.0, *) { video.sampleBufferRenderer.enqueue(sb) } else { video.enqueue(sb) }
    }

    private static func sample(_ data: Data, key: Bool, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        let n = data.count
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: n, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: n, flags: 0,
                                                 blockBufferOut: &block) == noErr, let block else { return nil }
        let ok = data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: n) == noErr
        }
        guard ok else { return nil }
        var sb: CMSampleBuffer?
        var size = n
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                        sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
                                        sampleSizeArray: &size, sampleBufferOut: &sb) == noErr, let sb else { return nil }
        if let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true), CFArrayGetCount(arr) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(arr, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            if !key {
                CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                     Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
        }
        return sb
    }

    // MARK: Geometry (position/size remembered; aspect follows the video)

    private func visible(for f: NSRect) -> NSRect {
        (NSScreen.screens.first { $0.visibleFrame.intersects(f) } ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? f
    }

    private func placeInitially(cascadeFrom other: NSRect?) {
        var c: NSRect
        if let other {
            // Next to the existing window: above it if there is room, otherwise to its left.
            let vis = visible(for: other)
            c = contentRect(forFrameRect: other)
            if other.maxY + 12 + other.height <= vis.maxY { c.origin.y = other.maxY + 12 }
            else { c.origin.x = other.minX - 12 - other.width }
        } else if let s = defaults.string(forKey: "frame") {
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
        var c = contentRect(forFrameRect: frame)
        let top = c.maxY
        c.size.height = c.width / r
        if frame.midY > visible(for: frame).midY { c.origin.y = top - c.height }
        setFrame(fit(frameRect(forContentRect: c)), display: true, animate: isVisible)
    }

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
        let vis = visible(for: frame)
        var f = frame
        f.origin.x = corner % 2 == 0 ? vis.minX + 16 : vis.maxX - f.width - 16
        f.origin.y = corner < 2 ? vis.maxY - f.height - 16 : vis.minY + 16
        setFrame(f, display: true, animate: true)
    }

    func setOpacity(_ a: CGFloat) {
        let a = min(1, max(0.2, a))
        alphaValue = a
        bar.setOpacity(a)
        defaults.set(Double(a), forKey: "opacity") // default for new windows
    }

    private func saveFrame() { defaults.set(NSStringFromRect(frame), forKey: "frame") }
    func windowDidMove(_ n: Notification) { saveFrame() }
    func windowDidEndLiveResize(_ n: Notification) { saveFrame(); reportSize() }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func close() {
        guard !closing else { return }
        closing = true
        saveFrame()
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        peekTimer?.invalidate()
        super.close()
        onClose?()
    }
}

// MARK: - Click = play/pause, drag = move, hover = controls

final class HoverView: NSView {
    var onHover: ((Bool) -> Void)?
    var onClick: (() -> Void)?
    var onMove: (() -> Void)?
    private var start: (mouse: NSPoint, origin: NSPoint)?
    private var dragged = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with e: NSEvent) { onHover?(true) }
    override func mouseExited(with e: NSEvent) { onHover?(false) }
    override func mouseMoved(with e: NSEvent) { onMove?() }
    override func mouseDown(with e: NSEvent) {
        start = (NSEvent.mouseLocation, window?.frame.origin ?? .zero)
        dragged = false
    }
    override func mouseDragged(with e: NSEvent) {
        guard let s = start, let w = window else { return }
        let m = NSEvent.mouseLocation
        if !dragged, hypot(m.x - s.mouse.x, m.y - s.mouse.y) < 3 { return }
        dragged = true
        w.setFrameOrigin(NSPoint(x: s.origin.x + m.x - s.mouse.x, y: s.origin.y + m.y - s.mouse.y))
    }
    override func mouseUp(with e: NSEvent) {
        if !dragged { onClick?() }
        start = nil
    }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
}

/// Hover overlay, laid out like the browsers' own PiP:
///   top:    title …………………………………… ✕
///   center:        ⟲10   ▶︎   ⟳10
///   bottom: 0:08 ━━━━━━●────── 3:45   🔈  ◐ ━━
/// Clicks on empty areas fall through to the window (drag to move, click to play/pause).
final class Controls: NSView {
    var onCommand: ((String) -> Void)?
    var onSeek: ((Double) -> Void)?
    var onOpacity: ((Double) -> Void)?
    var isInteracting: Bool { timeline.isDragging || opacity.isDragging }

    private let titleLabel = NSTextField(labelWithString: "")
    private let elapsed = NSTextField(labelWithString: "0:00")
    private let total = NSTextField(labelWithString: "0:00")
    private let timeline = ThinSlider()
    private let opacity = ThinSlider()
    private let top = CAGradientLayer()
    private let bottom = CAGradientLayer()
    private var play: NSButton!
    private var mute: NSButton!
    private var ghost: NSButton!

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for (g, flip) in [(top, true), (bottom, false)] {
            let dark = NSColor.black.withAlphaComponent(0.6).cgColor, clear = NSColor.black.withAlphaComponent(0).cgColor
            g.colors = flip ? [clear, dark] : [dark, clear] // layer y grows upward
            layer?.addSublayer(g)
        }

        play = icon("pause.fill", 26, "Play/Pause (Space)", "toggle")
        mute = icon("speaker.wave.2.fill", 13, "Mute (M)", "mute")
        let center = NSStackView(views: [icon("gobackward.10", 18, "Back 10 s (←)", "back"), play,
                                         icon("goforward.10", 18, "Forward 10 s (→)", "fwd")])
        center.spacing = 26
        let close = icon("xmark", 12, "Close (Esc)", "close")
        ghost = icon("hand.raised.slash", 12, "Click-through: clicks go to the app underneath (hold ⌥ to interact)", "ghost")
        let dim = NSImageView(image: symbol("circle.lefthalf.filled", 12))
        dim.contentTintColor = NSColor.white.withAlphaComponent(0.85)
        dim.toolTip = "Opacity"

        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        for l in [titleLabel, elapsed, total] {
            l.textColor = .white
            l.lineBreakMode = .byTruncatingTail
            l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        for l in [elapsed, total] {
            l.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
            l.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        timeline.onChange = { [weak self] v in self?.elapsed.stringValue = Self.format(v) }
        timeline.onCommit = { [weak self] v in self?.onSeek?(v) }
        opacity.minValue = 0.2
        opacity.value = 1
        opacity.onChange = { [weak self] v in self?.onOpacity?(v) }
        opacity.toolTip = "Opacity"

        for v in [titleLabel, ghost, close, center, elapsed, timeline, total, mute, dim, opacity] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        let row = bottomAnchor
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: ghost.leadingAnchor, constant: -10),
            ghost.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -14),
            ghost.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: topAnchor, constant: 16),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            close.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),

            center.centerXAnchor.constraint(equalTo: centerXAnchor),
            center.centerYAnchor.constraint(equalTo: centerYAnchor),

            elapsed.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            elapsed.centerYAnchor.constraint(equalTo: row, constant: -16),
            timeline.leadingAnchor.constraint(equalTo: elapsed.trailingAnchor, constant: 8),
            timeline.centerYAnchor.constraint(equalTo: elapsed.centerYAnchor),
            timeline.heightAnchor.constraint(equalToConstant: 16),
            total.leadingAnchor.constraint(equalTo: timeline.trailingAnchor, constant: 8),
            total.centerYAnchor.constraint(equalTo: elapsed.centerYAnchor),
            mute.leadingAnchor.constraint(equalTo: total.trailingAnchor, constant: 12),
            mute.centerYAnchor.constraint(equalTo: elapsed.centerYAnchor),
            dim.leadingAnchor.constraint(equalTo: mute.trailingAnchor, constant: 12),
            dim.centerYAnchor.constraint(equalTo: elapsed.centerYAnchor),
            opacity.leadingAnchor.constraint(equalTo: dim.trailingAnchor, constant: 6),
            opacity.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            opacity.centerYAnchor.constraint(equalTo: elapsed.centerYAnchor),
            opacity.widthAnchor.constraint(equalToConstant: 48),
            opacity.heightAnchor.constraint(equalToConstant: 16),
        ])
        setTime(0, duration: 0)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        top.frame = NSRect(x: 0, y: bounds.height - 44, width: bounds.width, height: 44)
        bottom.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 52)
        CATransaction.commit()
    }

    /// Only buttons and sliders take clicks; everything else falls through to the window.
    override func hitTest(_ p: NSPoint) -> NSView? {
        let v = super.hitTest(p)
        return v is NSButton || v is ThinSlider ? v : nil
    }

    func setTitle(_ t: String) { titleLabel.stringValue = t }
    func setOpacity(_ a: CGFloat) { opacity.value = Double(a) }
    func setClickThrough(_ on: Bool) {
        ghost.image = symbol(on ? "hand.raised.slash.fill" : "hand.raised.slash", 12)
        ghost.contentTintColor = on ? .controlAccentColor : .white
    }
    func setState(paused: Bool, muted: Bool) {
        play.image = symbol(paused ? "play.fill" : "pause.fill", 26)
        mute.image = symbol(muted ? "speaker.slash.fill" : "speaker.wave.2.fill", 13)
    }

    /// duration 0 = live stream: no timeline.
    func setTime(_ t: Double, duration d: Double) {
        let live = !(d > 0)
        for v in [elapsed, timeline, total] as [NSView] { v.isHidden = live }
        guard !live, !timeline.isDragging else { return }
        timeline.maxValue = d
        timeline.value = min(max(t, 0), d)
        elapsed.stringValue = Self.format(t)
        total.stringValue = Self.format(d)
    }

    static func format(_ s: Double) -> String {
        let s = Int(max(0, s.isFinite ? s : 0))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    private func symbol(_ name: String, _ size: CGFloat) -> NSImage {
        let img = NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage()
        return img.withSymbolConfiguration(.init(pointSize: size, weight: .semibold)) ?? img
    }

    private func icon(_ name: String, _ size: CGFloat, _ tip: String, _ cmd: String) -> NSButton {
        let b = NSButton(image: symbol(name, size), target: self, action: #selector(tapped(_:)))
        b.identifier = NSUserInterfaceItemIdentifier(cmd)
        b.isBordered = false
        b.contentTintColor = .white
        b.toolTip = tip
        let sh = NSShadow()
        sh.shadowColor = NSColor.black.withAlphaComponent(0.5)
        sh.shadowBlurRadius = 4
        b.shadow = sh
        return b
    }
    @objc private func tapped(_ b: NSButton) { onCommand?(b.identifier?.rawValue ?? "") }
}

/// Minimal slider: 3 pt track that thickens with a knob on hover. onChange while dragging, onCommit on release.
final class ThinSlider: NSView {
    var minValue = 0.0, maxValue = 1.0
    var value = 0.0 { didSet { needsDisplay = true } }
    var onChange: ((Double) -> Void)?
    var onCommit: ((Double) -> Void)?
    private(set) var isDragging = false
    private var hovering = false { didSet { needsDisplay = true } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with e: NSEvent) { hovering = true }
    override func mouseExited(with e: NSEvent) { hovering = false }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    private var fraction: CGFloat {
        maxValue > minValue ? CGFloat(min(max((value - minValue) / (maxValue - minValue), 0), 1)) : 0
    }

    override func draw(_ dirty: NSRect) {
        let active = hovering || isDragging
        let h: CGFloat = active ? 5 : 3, r: CGFloat = 6
        let track = NSRect(x: r, y: bounds.midY - h / 2, width: max(0, bounds.width - 2 * r), height: h)
        NSColor.white.withAlphaComponent(0.3).setFill()
        NSBezierPath(roundedRect: track, xRadius: h / 2, yRadius: h / 2).fill()
        var fill = track
        fill.size.width = track.width * fraction
        NSColor.white.setFill()
        NSBezierPath(roundedRect: fill, xRadius: h / 2, yRadius: h / 2).fill()
        if active {
            NSBezierPath(ovalIn: NSRect(x: fill.maxX - r, y: bounds.midY - r, width: 2 * r, height: 2 * r)).fill()
        }
    }

    private func set(from e: NSEvent) {
        let x = convert(e.locationInWindow, from: nil).x
        let f = min(max((x - 6) / max(1, bounds.width - 12), 0), 1)
        value = minValue + Double(f) * (maxValue - minValue)
        onChange?(value)
    }
    override func mouseDown(with e: NSEvent) { isDragging = true; set(from: e) }
    override func mouseDragged(with e: NSEvent) { set(from: e) }
    override func mouseUp(with e: NSEvent) { isDragging = false; needsDisplay = true; onCommit?(value) }
}
