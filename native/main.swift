import AppKit

// MacPiP — picture-in-picture that floats over fullscreen macOS apps.
//
// The video keeps playing in your browser tab (your login, your session, your audio). The MacPiP
// extension streams the video's frames (hardware H.264) to this app, whose window may enter
// fullscreen Spaces. A tab capture held by the extension keeps Chrome rendering the tab at full
// rate even while its window is hidden behind a fullscreen app.
//
//   double-click MacPiP.app            → one-time setup (registers with Chromium browsers)
//   launched by the browser extension  → player

func log(_ s: String) {
    if ProcessInfo.processInfo.environment["MACPIP_DEBUG"] != nil {
        FileHandle.standardError.write(Data("macpip: \(s)\n".utf8))
    }
}

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var host: NativeHost?
    private var players: [Int: Player] = [:]   // one window per floated tab (key = tab id)
    private weak var active: Player?           // last hovered/created: target of the menu bar commands
    private var status: NSStatusItem?
    private var usr1: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ n: Notification) {
        let args = CommandLine.arguments
        if args.count > 1, args[1].hasPrefix("chrome-extension://") {
            host = NativeHost(onMessage: { [weak self] in self?.handle($0) }, onEOF: { exit(0) })
            host?.start()
            // `kill -USR1` pins the hover controls visible (used by CI for screenshots).
            signal(SIGUSR1, SIG_IGN)
            let sig = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
            sig.setEventHandler { [weak self] in self?.players.values.forEach { $0.togglePinnedControls() } }
            sig.resume()
            usr1 = sig
        } else if let i = args.firstIndex(of: "--setup-quiet") {
            let linked = Setup.install(extraHostDirs: Array(args.dropFirst(i + 1)))
            print("linked: \(linked.joined(separator: ", "))\nextension: \(Setup.extensionDir.path)")
            exit(0)
        } else {
            Setup.interactive()
        }
    }

    private func handle(_ m: [String: Any]) {
        let k = m["k"] as? String ?? "?"
        let s = (m["s"] as? NSNumber)?.intValue ?? 0
        if k != "f" && k != "stats" && k != "time" { log("recv \(k) s=\(s)") }
        switch k {
        case "hello":
            let p = player(s)
            p.setTitle(m["title"] as? String ?? "")
            p.orderFrontRegardless()
        case "cfg":
            guard let w = m["w"] as? Int, let h = m["h"] as? Int,
                  let b = m["avcc"] as? String, let avcc = Data(base64Encoded: b) else { return }
            player(s).configure(width: w, height: h, avcc: avcc)
        case "f":
            guard let b = m["d"] as? String, let d = Data(base64Encoded: b) else { return }
            players[s]?.enqueue(d, key: m["key"] as? Bool ?? false)
        case "state":
            players[s]?.setState(paused: m["paused"] as? Bool ?? false, muted: m["muted"] as? Bool ?? false)
        case "time":
            players[s]?.setTime((m["t"] as? NSNumber)?.doubleValue ?? 0, duration: (m["dur"] as? NSNumber)?.doubleValue ?? 0)
        case "stats":
            guard let p = players[s] else { return }
            let n = { (key: String) in (m[key] as? NSNumber)?.intValue ?? 0 }
            let line = "tab \(n("src")) → enc \(n("enc")) (drop \(n("drop"))) → out \(n("out")) → shown \(p.takeShown()) fps · \(n("kbps")) kbps · \(n("w"))×\(n("h")) · \(m["vis"] as? String ?? "")"
            log("[\(s)] " + line)
            p.showStats(line)
        case "log":
            log("extension: \(m["msg"] as? String ?? "")")
        case "end":
            players[s]?.close() // stopped from the browser (toolbar click, tab closed)
        default:
            break
        }
    }

    /// The window for tab `s`, created next to the existing ones if needed.
    private func player(_ s: Int) -> Player {
        if let p = players[s] { return p }
        let p = Player(cascadeFrom: (active ?? players.values.first)?.frame)
        p.onCommand = { [weak self] c in
            var c = c
            c["s"] = s
            self?.host?.send(c)
        }
        p.onActivate = { [weak self, weak p] in self?.active = p }
        p.onClose = { [weak self, weak p] in
            guard let self else { return }
            self.players[s] = nil
            self.host?.send(["cmd": "stop", "s": s])
            if self.active === p || self.active == nil { self.active = self.players.values.first }
            if self.players.isEmpty, let st = self.status { NSStatusBar.system.removeStatusItem(st); self.status = nil }
        }
        players[s] = p
        active = p
        if status == nil { buildStatusItem() }
        return p
    }

    // MARK: Menu bar item. Acts on the window you last hovered; click-through can only be undone here.

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "pip", accessibilityDescription: "MacPiP")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        status = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let p = active ?? players.values.first else { return }
        if players.count > 1 {
            let header = NSMenuItem(title: p.title.isEmpty ? "Window" : String(p.title.prefix(40)), action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
        }

        let row = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 28))
        let label = NSTextField(labelWithString: "Opacity")
        label.frame = NSRect(x: 20, y: 6, width: 56, height: 16)
        let slider = NSSlider(value: Double(p.alphaValue), minValue: 0.2, maxValue: 1, target: self, action: #selector(opacitySlid(_:)))
        slider.isContinuous = true
        slider.frame = NSRect(x: 78, y: 4, width: 128, height: 20)
        row.addSubview(label); row.addSubview(slider)
        let opacity = NSMenuItem()
        opacity.view = row
        menu.addItem(opacity)

        menu.addItem(item("Click-through", #selector(toggleGhost), on: p.ignoresMouseEvents))
        let mv = NSMenuItem(title: "Move to", action: nil, keyEquivalent: "")
        let mvMenu = NSMenu()
        for (i, name) in ["Top Left", "Top Right", "Bottom Left", "Bottom Right"].enumerated() {
            let c = item(name, #selector(snap(_:)))
            c.tag = i
            mvMenu.addItem(c)
        }
        mv.submenu = mvMenu
        menu.addItem(mv)
        menu.addItem(item("Show Frame Rate", #selector(toggleStats), on: UserDefaults.standard.bool(forKey: "showStats")))
        menu.addItem(.separator())
        menu.addItem(item("Close", #selector(closeActive)))
        if players.count > 1 { menu.addItem(item("Close All (\(players.count))", #selector(closeAll))) }
    }

    private func item(_ title: String, _ action: Selector, on: Bool = false) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        i.state = on ? .on : .off
        return i
    }

    private var target: Player? { active ?? players.values.first }
    @objc private func opacitySlid(_ s: NSSlider) { target?.setOpacity(CGFloat(s.doubleValue)) }
    @objc private func toggleGhost() { if let t = target { t.ignoresMouseEvents.toggle() } }
    @objc private func snap(_ s: NSMenuItem) { target?.snap(s.tag) }
    @objc private func closeActive() { target?.close() }
    @objc private func closeAll() { Array(players.values).forEach { $0.close() } }
    @objc private func toggleStats() {
        let on = !UserDefaults.standard.bool(forKey: "showStats")
        UserDefaults.standard.set(on, forKey: "showStats")
        players.values.forEach { $0.showStats(nil) }
    }
}

// MARK: - Chrome native messaging: UInt32 little-endian length + UTF-8 JSON.

final class NativeHost {
    private let onMessage: ([String: Any]) -> Void
    private let onEOF: () -> Void
    private let out = FileHandle.standardOutput
    private let lock = NSLock()

    init(onMessage: @escaping ([String: Any]) -> Void, onEOF: @escaping () -> Void) {
        self.onMessage = onMessage
        self.onEOF = onEOF
    }

    func start() {
        Thread.detachNewThread { [self] in
            let input = FileHandle.standardInput
            while true {
                let head = input.readData(ofLength: 4)
                guard head.count == 4 else { break }
                let len = Int(UInt32(head[0]) | UInt32(head[1]) << 8 | UInt32(head[2]) << 16 | UInt32(head[3]) << 24)
                guard len > 0, len <= 64 << 20 else { break }
                var body = Data()
                while body.count < len {
                    let chunk = input.readData(ofLength: len - body.count)
                    if chunk.isEmpty { break }
                    body.append(chunk)
                }
                guard body.count == len else { break }
                if let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] {
                    DispatchQueue.main.async { self.onMessage(obj) }
                }
            }
            DispatchQueue.main.async { self.onEOF() }
        }
    }

    func send(_ obj: [String: Any]) {
        guard let body = try? JSONSerialization.data(withJSONObject: obj) else { return }
        let len = withUnsafeBytes(of: UInt32(body.count).littleEndian) { Data($0) }
        lock.lock(); defer { lock.unlock() }
        out.write(len + body)
    }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
