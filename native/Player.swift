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
    private let bar = Bar()
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
            NSAnimationContext.runAnimationGroup { $0.duration = 0.15; self.bar.animator().alphaValue = inside ? 1 : 0 }
        }
        root.onClick = { [weak self] in self?.onCommand?(["cmd": "toggle"]) }
        contentView = root

        bar.frame = NSRect(x: 0, y: 0, width: root.bounds.width, height: Bar.height)
        bar.autoresizingMask = [.width, .maxYMargin]
        bar.alphaValue = 0
        bar.setOpacity(alphaValue)
        bar.onOpacity = { [weak self] a in self?.setOpacity(CGFloat(a)) }
        bar.onSeek = { [weak self] t in self?.onCommand?(["cmd": "seekTo", "t": t]) }
        bar.onCommand = { [weak self] c in
            guard let self else { return }
            switch c {
            case "close": self.close()
            default: self.onCommand?(c == "back" ? ["cmd": "seek", "d": -10] : c == "fwd" ? ["cmd": "seek", "d": 10] : ["cmd": c])
            }
        }
        root.addSubview(bar)
        if ProcessInfo.processInfo.environment["MACPIP_SHOW_CONTROLS"] != nil { bar.alphaValue = 1 } // CI screenshots

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
            stats.topAnchor.constraint(equalTo: root.topAnchor, constant: 6),
            stats.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -6),
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
        super.close()
        onClose?()
    }
}

// MARK: - Click = play/pause, drag = move, hover = controls

final class HoverView: NSView {
    var onHover: ((Bool) -> Void)?
    var onClick: (() -> Void)?
    private var start: (mouse: NSPoint, origin: NSPoint)?
    private var dragged = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with e: NSEvent) { onHover?(true) }
    override func mouseExited(with e: NSEvent) { onHover?(false) }
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

/// Hover controls: timeline row above a button row.
final class Bar: NSView {
    static let height: CGFloat = 60
    var onCommand: ((String) -> Void)?
    var onSeek: ((Double) -> Void)?
    var onOpacity: ((Double) -> Void)?
    private let label = NSTextField(labelWithString: "")
    private let elapsed = NSTextField(labelWithString: "0:00")
    private let total = NSTextField(labelWithString: "0:00")
    private let timeline = ScrubSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let opacity = NSSlider(value: 1, minValue: 0.2, maxValue: 1, target: nil, action: nil)
    private var playButton: NSButton!
    private var muteButton: NSButton!
    private var duration = 0.0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        appearance = NSAppearance(named: .darkAqua)
        playButton = button("pause.fill", "Play/Pause (Space)", "toggle")
        muteButton = button("speaker.wave.2.fill", "Mute (M)", "mute")
        let left = NSStackView(views: [button("gobackward.10", "Back 10 s (←)", "back"), playButton,
                                       button("goforward.10", "Forward 10 s (→)", "fwd"), muteButton])
        let dim = NSImageView(image: NSImage(systemSymbolName: "circle.lefthalf.filled", accessibilityDescription: "Opacity") ?? NSImage())
        dim.contentTintColor = .white
        let right = NSStackView(views: [dim, opacity, button("xmark", "Close (Esc)", "close")])
        left.spacing = 10; right.spacing = 6

        for l in [label, elapsed, total] {
            l.textColor = .white
            l.lineBreakMode = .byTruncatingTail
        }
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for l in [elapsed, total] { l.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium) }

        timeline.controlSize = .small
        timeline.isContinuous = true
        timeline.target = self
        timeline.action = #selector(scrubbing)
        timeline.toolTip = "Seek"
        timeline.onRelease = { [weak self] v in self?.onSeek?(v) }
        timeline.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        opacity.controlSize = .mini
        opacity.isContinuous = true
        opacity.target = self
        opacity.action = #selector(opacityChanged)
        opacity.toolTip = "Opacity"

        for v in [left, label, right, elapsed, timeline, total] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            // Row 1: 0:12 ━━━━━●──── 3:45
            elapsed.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            elapsed.centerYAnchor.constraint(equalTo: bottomAnchor, constant: -42),
            timeline.leadingAnchor.constraint(equalTo: elapsed.trailingAnchor, constant: 6),
            timeline.trailingAnchor.constraint(equalTo: total.leadingAnchor, constant: -6),
            timeline.centerYAnchor.constraint(equalTo: elapsed.centerYAnchor),
            total.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            total.centerYAnchor.constraint(equalTo: elapsed.centerYAnchor),
            // Row 2: ⟲ ▶ ⟳ 🔈  title …  ◐ ━━ ✕
            left.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            left.centerYAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            label.leadingAnchor.constraint(equalTo: left.trailingAnchor, constant: 10),
            label.trailingAnchor.constraint(lessThanOrEqualTo: right.leadingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: left.centerYAnchor),
            right.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            right.centerYAnchor.constraint(equalTo: left.centerYAnchor),
            opacity.widthAnchor.constraint(equalToConstant: 64),
        ])
        setTime(0, duration: 0)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func makeBackingLayer() -> CALayer {
        let g = CAGradientLayer()
        g.colors = [NSColor.black.withAlphaComponent(0.75).cgColor, NSColor.black.withAlphaComponent(0).cgColor]
        return g
    }

    func setTitle(_ t: String) { label.stringValue = t }
    func setOpacity(_ a: CGFloat) { opacity.doubleValue = Double(a) }
    func setState(paused: Bool, muted: Bool) {
        playButton.image = NSImage(systemSymbolName: paused ? "play.fill" : "pause.fill", accessibilityDescription: nil)
        muteButton.image = NSImage(systemSymbolName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill", accessibilityDescription: nil)
    }

    /// duration 0 = live stream: no timeline.
    func setTime(_ t: Double, duration d: Double) {
        let live = !(d > 0)
        for v in [elapsed, timeline, total] as [NSView] { v.isHidden = live }
        guard !live, !timeline.isScrubbing else { return }
        duration = d
        timeline.maxValue = d
        timeline.doubleValue = min(max(t, 0), d)
        elapsed.stringValue = Self.format(t)
        total.stringValue = Self.format(d)
    }

    static func format(_ s: Double) -> String {
        let s = Int(max(0, s.isFinite ? s : 0))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    @objc private func scrubbing() { elapsed.stringValue = Self.format(timeline.doubleValue) }
    @objc private func opacityChanged() { onOpacity?(opacity.doubleValue) }

    private func button(_ symbol: String, _ tip: String, _ cmd: String) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage(),
                         target: self, action: #selector(tapped(_:)))
        b.identifier = NSUserInterfaceItemIdentifier(cmd)
        b.isBordered = false
        b.contentTintColor = .white
        b.toolTip = tip
        return b
    }
    @objc private func tapped(_ b: NSButton) { onCommand?(b.identifier?.rawValue ?? "") }

    override func mouseDown(with e: NSEvent) { window?.performDrag(with: e) }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
}

/// Timeline slider that seeks once, on release, and ignores position updates while dragged.
final class ScrubSlider: NSSlider {
    var onRelease: ((Double) -> Void)?
    private(set) var isScrubbing = false
    override func mouseDown(with e: NSEvent) {
        isScrubbing = true
        super.mouseDown(with: e) // runs the drag loop until mouse-up
        isScrubbing = false
        onRelease?(doubleValue)
    }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
}
