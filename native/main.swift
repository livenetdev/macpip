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

final class App: NSObject, NSApplicationDelegate {
    private var host: NativeHost?
    private var player: Player?
    private var status: NSStatusItem?

    func applicationDidFinishLaunching(_ n: Notification) {
        let args = CommandLine.arguments
        if args.count > 1, args[1].hasPrefix("chrome-extension://") {
            host = NativeHost(onMessage: { [weak self] in self?.handle($0) }, onEOF: { exit(0) })
            host?.start()
        } else if let i = args.firstIndex(of: "--setup-quiet") {
            let linked = Setup.install(extraHostDirs: Array(args.dropFirst(i + 1)))
            print("linked: \(linked.joined(separator: ", "))\nextension: \(Setup.extensionDir.path)")
            exit(0)
        } else {
            Setup.interactive()
        }
    }

    private func handle(_ m: [String: Any]) {
        switch m["k"] as? String {
        case "hello":
            ensurePlayer().setTitle(m["title"] as? String ?? "")
        case "cfg":
            guard let w = m["w"] as? Int, let h = m["h"] as? Int,
                  let s = m["avcc"] as? String, let avcc = Data(base64Encoded: s) else { return }
            ensurePlayer().configure(width: w, height: h, avcc: avcc)
        case "f":
            guard let s = m["d"] as? String, let d = Data(base64Encoded: s) else { return }
            player?.enqueue(d, key: m["key"] as? Bool ?? false)
        case "state":
            player?.setState(paused: m["paused"] as? Bool ?? false, muted: m["muted"] as? Bool ?? false)
        case "bye":
            exit(0)
        default:
            break
        }
    }

    private func ensurePlayer() -> Player {
        if let p = player { return p }
        let p = Player()
        p.onCommand = { [weak self] in self?.host?.send($0) }
        p.onClose = { [weak self] in
            self?.host?.send(["cmd": "stop"])
            exit(0)
        }
        player = p
        buildStatusItem()
        return p
    }

    // MARK: Menu bar item: opacity, corners, click-through (only reachable from here once enabled)

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "pip", accessibilityDescription: "MacPiP")
        let menu = NSMenu()
        let ghost = NSMenuItem(title: "Click-through", action: #selector(toggleGhost(_:)), keyEquivalent: "")
        ghost.target = self
        menu.addItem(ghost)
        let op = NSMenuItem(title: "Opacity", action: nil, keyEquivalent: "")
        let opMenu = NSMenu()
        for pct in [100, 80, 60, 40, 20] {
            let i = NSMenuItem(title: "\(pct)%", action: #selector(setOpacity(_:)), keyEquivalent: "")
            i.target = self; i.tag = pct
            opMenu.addItem(i)
        }
        op.submenu = opMenu
        menu.addItem(op)
        let mv = NSMenuItem(title: "Move to", action: nil, keyEquivalent: "")
        let mvMenu = NSMenu()
        for (i, name) in ["Top Left", "Top Right", "Bottom Left", "Bottom Right"].enumerated() {
            let c = NSMenuItem(title: name, action: #selector(snap(_:)), keyEquivalent: "")
            c.target = self; c.tag = i
            mvMenu.addItem(c)
        }
        mv.submenu = mvMenu
        menu.addItem(mv)
        menu.addItem(.separator())
        let close = NSMenuItem(title: "Close", action: #selector(closePlayer), keyEquivalent: "")
        close.target = self
        menu.addItem(close)
        item.menu = menu
        status = item
    }

    @objc private func toggleGhost(_ s: NSMenuItem) {
        guard let p = player else { return }
        p.ignoresMouseEvents.toggle()
        s.state = p.ignoresMouseEvents ? .on : .off
    }
    @objc private func setOpacity(_ s: NSMenuItem) { player?.setOpacity(CGFloat(s.tag) / 100) }
    @objc private func snap(_ s: NSMenuItem) { player?.snap(s.tag) }
    @objc private func closePlayer() { player?.close() }
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
