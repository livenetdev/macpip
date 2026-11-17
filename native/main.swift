import AppKit
import ServiceManagement

// MacPiP: when a browser's own picture-in-picture window is hidden by a fullscreen
// app, show a live mirror of it that floats above. Nothing is re-loaded, so anything
// that plays in your browser works. No network, no extension, no data stored.

func log(_ s: String) {
    if ProcessInfo.processInfo.environment["MACPIP_DEBUG"] != nil {
        FileHandle.standardError.write(Data("macpip: \(s)\n".utf8))
    }
}

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let defaults = UserDefaults.standard
    private var status: NSStatusItem!
    private var mirror: Mirror?
    private var pinned: CGWindowID?
    private var dismissed = Set<CGWindowID>()
    private var lastFrame: NSRect?
    private var clickThrough = false
    private var auto: Bool { defaults.object(forKey: "auto") as? Bool ?? true }

    private let menu = NSMenu()
    private let pinMenu = NSMenu()

    func applicationDidFinishLaunching(_ n: Notification) {
        let args = CommandLine.arguments
        if args.contains("--list") {
            for w in Windows.all() where w.bounds.width > 50 {
                print("\(w.id)\tlayer=\(w.layer)\tonscreen=\(w.onScreen)\tpip=\(Windows.isPiP(w))\t\(w.owner) — \(w.title)")
            }
            exit(0)
        }
        if let i = args.firstIndex(of: "--window"), i + 1 < args.count, let id = CGWindowID(args[i + 1]) { pinned = id }

        log("screen recording permission: \(CGPreflightScreenCaptureAccess())")
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
        buildStatusItem()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(tick),
                                                          name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        let t = Timer(timeInterval: 1, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        t.tolerance = 0.25
        RunLoop.main.add(t, forMode: .common)
        tick()
    }

    // MARK: Watcher — one CGWindowList call per second; capture runs only while a mirror is shown.

    @objc private func tick() {
        let wins = Windows.all()
        let ids = Set(wins.map(\.id))
        dismissed.formIntersection(ids)
        if let p = pinned, !ids.contains(p) { pinned = nil }

        let target = pinned.flatMap { p in wins.first { $0.id == p } }
            ?? (auto ? wins.filter { Windows.isPiP($0) && !dismissed.contains($0.id) }.max { $0.id < $1.id } : nil)

        // Mirror only while the original can't be seen (e.g. you're in a fullscreen app).
        guard let t = target, !t.onScreen, CGPreflightScreenCaptureAccess() else { return hideMirror() }
        if let m = mirror, m.source == t.id { return m.sourceChanged(t) }

        hideMirror()
        log("mirroring \(t.id) \(t.owner) — \(t.title)")
        let m = Mirror(source: t, frame: lastFrame, opacity: CGFloat(defaults.object(forKey: "opacity") as? Double ?? 1),
                       clickThrough: clickThrough)
        m.onFrameChange = { [weak self] f in self?.lastFrame = f }
        m.onDismiss = { [weak self] in
            self?.dismissed.insert(t.id)
            if self?.pinned == t.id { self?.pinned = nil }
            self?.hideMirror()
        }
        mirror = m
        m.start()
    }

    private func hideMirror() {
        mirror?.stop()
        mirror = nil
    }

    // MARK: Menu bar

    private func buildStatusItem() {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "pip", accessibilityDescription: "MacPiP")
        menu.delegate = self
        status.menu = menu
    }

    func menuNeedsUpdate(_ m: NSMenu) {
        guard m === menu else { return }
        m.removeAllItems()
        if !CGPreflightScreenCaptureAccess() {
            m.addItem(item("Grant Screen Recording…", #selector(openPrivacy)))
            m.addItem(.separator())
        }
        m.addItem(item("Float browser PiP over fullscreen apps", #selector(toggleAuto), on: auto))

        let pin = NSMenuItem(title: "Float a window", action: nil, keyEquivalent: "")
        pinMenu.removeAllItems()
        for w in Windows.pinnable(Windows.all()).prefix(30) {
            let title = w.title.isEmpty ? w.owner : "\(w.owner) — \(w.title.prefix(50))"
            let i = item(title, #selector(pinWindow(_:)), on: pinned == w.id)
            i.tag = Int(w.id)
            pinMenu.addItem(i)
        }
        if pinMenu.items.isEmpty { pinMenu.addItem(NSMenuItem(title: "No windows", action: nil, keyEquivalent: "")) }
        pin.submenu = pinMenu
        m.addItem(pin)
        m.addItem(.separator())

        let op = NSMenuItem(title: "Opacity", action: nil, keyEquivalent: "")
        let opMenu = NSMenu()
        for pct in [100, 80, 60, 40, 20] {
            let i = item("\(pct)%", #selector(setOpacity(_:)))
            i.tag = pct
            opMenu.addItem(i)
        }
        op.submenu = opMenu
        m.addItem(op)
        m.addItem(item("Click-through", #selector(toggleGhost), on: clickThrough))
        let mv = NSMenuItem(title: "Move to", action: nil, keyEquivalent: "")
        let mvMenu = NSMenu()
        for (i, name) in ["Top Left", "Top Right", "Bottom Left", "Bottom Right"].enumerated() {
            let c = item(name, #selector(snap(_:)))
            c.tag = i
            mvMenu.addItem(c)
        }
        mv.submenu = mvMenu
        m.addItem(mv)
        m.addItem(item("Stop floating", #selector(stopFloating)))
        m.addItem(.separator())
        if #available(macOS 13.0, *) {
            m.addItem(item("Launch at login", #selector(toggleLogin), on: SMAppService.mainApp.status == .enabled))
        }
        m.addItem(item("Quit MacPiP", #selector(quit)))
    }

    private func item(_ title: String, _ action: Selector, on: Bool = false) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        i.state = on ? .on : .off
        return i
    }

    @objc private func openPrivacy() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
    @objc private func toggleAuto() { defaults.set(!auto, forKey: "auto"); tick() }
    @objc private func pinWindow(_ s: NSMenuItem) {
        let id = CGWindowID(s.tag)
        pinned = pinned == id ? nil : id
        dismissed.remove(id)
        tick()
    }
    @objc private func setOpacity(_ s: NSMenuItem) {
        defaults.set(Double(s.tag) / 100, forKey: "opacity")
        mirror?.alphaValue = CGFloat(s.tag) / 100
    }
    @objc private func toggleGhost() { clickThrough.toggle(); mirror?.clickThrough = clickThrough }
    @objc private func snap(_ s: NSMenuItem) { mirror?.snap(s.tag) }
    @objc private func stopFloating() { mirror?.onDismiss?() }
    @available(macOS 13.0, *)
    @objc private func toggleLogin() {
        let s = SMAppService.mainApp
        do { if s.status == .enabled { try s.unregister() } else { try s.register() } }
        catch { log("login item: \(error.localizedDescription)") }
    }
    @objc private func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
