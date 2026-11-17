import AppKit

// Two entry modes:
//   macpip chrome-extension://<id>/   → launched by the browser (native messaging over stdio)
//   macpip <url> [start-seconds]      → manual / Safari / scripts
// Process lifetime == one floating window. Closing it exits, so no WebKit state outlives it.

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var player: PlayerWindow?
    private var host: NativeHost?
    private var status: NSStatusItem?
    private let ghostItem = NSMenuItem(title: "Click-through", action: #selector(toggleGhost), keyEquivalent: "")

    func applicationDidFinishLaunching(_ n: Notification) {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.first?.hasPrefix("chrome-extension://") == true {
            host = NativeHost(onMessage: { [weak self] in self?.handle($0) },
                              onEOF: { [weak self] in if self?.player == nil { exit(0) } })
            host?.start()
        } else if let s = args.first, let req = Request(url: s, time: args.count > 1 ? Double(args[1]) : nil) {
            open(req)
        } else {
            FileHandle.standardError.write(Data("usage: macpip <video-url> [start-seconds]\n".utf8))
            exit(64)
        }
    }

    private func handle(_ m: [String: Any]) {
        guard m["action"] as? String == "open", let req = Request(message: m) else {
            host?.send(["type": "error"]); return
        }
        open(req)
        host?.send(["type": "opened"])
    }

    private func open(_ req: Request) {
        if player == nil {
            let p = PlayerWindow(frame: NSRect(x: 0, y: 0, width: 480, height: 270))
            p.onClose = { [weak self] t in
                self?.host?.send(["type": "closed", "t": t])
                exit(0)
            }
            player = p
            buildStatusItem()
        }
        player?.play(req)
    }

    // MARK: Menu bar item — the only way back from click-through mode.

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "pip", accessibilityDescription: "MacPiP")
        let menu = NSMenu()
        menu.autoenablesItems = false

        menu.delegate = self
        ghostItem.target = self
        menu.addItem(ghostItem)

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

    func menuWillOpen(_ menu: NSMenu) { ghostItem.state = player?.clickThrough == true ? .on : .off }
    @objc private func toggleGhost() { player?.clickThrough.toggle() }
    @objc private func setOpacity(_ sender: NSMenuItem) { player?.setOpacity(CGFloat(sender.tag) / 100) }
    @objc private func snap(_ sender: NSMenuItem) { player?.snap(sender.tag) }
    @objc private func closePlayer() { player?.close() }
}

// MARK: - Chrome native messaging: UInt32 little-endian length + UTF-8 JSON, both directions.

final class NativeHost {
    private let onMessage: ([String: Any]) -> Void
    private let onEOF: () -> Void
    private let out = FileHandle.standardOutput

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
                guard len > 0, len <= 65_536 else { break }
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

    /// Synchronous so a final message is flushed before exit().
    func send(_ obj: [String: Any]) {
        guard let body = try? JSONSerialization.data(withJSONObject: obj) else { return }
        let len = withUnsafeBytes(of: UInt32(body.count).littleEndian) { Data($0) }
        out.write(len + body)
    }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
