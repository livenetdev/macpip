import AppKit
import Carbon.HIToolbox
import ServiceManagement

// MacPiP: keeps your browser's own picture-in-picture visible while you work "fullscreen".
//
// macOS hides PiP windows from Chrome, Firefox etc. inside native fullscreen Spaces, and
// stops updating windows on other Spaces, so nothing outside the browser can fix that.
// Instead, ⌃⌥⌘F fills the screen with the front window on the *current* Space (menu bar
// and Dock auto-hidden), where the browser's PiP floats on top as usual: live, clickable,
// with your own login. No capture, no network, no extension.

func log(_ s: String) {
    if ProcessInfo.processInfo.environment["MACPIP_DEBUG"] != nil {
        FileHandle.standardError.write(Data("macpip: \(s)\n".utf8))
    }
}

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let filler = Filler()
    private var status: NSStatusItem!
    private var hotKeyRef: EventHotKeyRef?
    private let menu = NSMenu()

    func applicationDidFinishLaunching(_ n: Notification) {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "pip", accessibilityDescription: "MacPiP")
        menu.delegate = self
        status.menu = menu
        registerHotKey()
        log("accessibility trusted: \(AX.trusted(prompt: false))")
        if !AX.trusted(prompt: false) { _ = AX.trusted(prompt: true) }
        if CommandLine.arguments.contains("--fill") { filler.toggle() }
    }

    func applicationWillTerminate(_ n: Notification) { filler.restore() }

    // ⌃⌥⌘F, global. Carbon hot keys need no permission and don't see other keystrokes.
    private func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
            (NSApp.delegate as? App)?.hotKey()
            return noErr
        }, 1, &spec, nil, nil)
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_F), UInt32(cmdKey | optionKey | controlKey),
                                         EventHotKeyID(signature: 0x4D_50_50_46, id: 1), // 'MPPF'
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        log("hotkey registered: \(status == noErr)")
    }

    func hotKey() {
        log("hotkey")
        filler.toggle()
    }

    // MARK: Menu

    func menuNeedsUpdate(_ m: NSMenu) {
        m.removeAllItems()
        if !AX.trusted(prompt: false) {
            m.addItem(item("Grant Accessibility Access…", #selector(openAccessibility)))
            m.addItem(.separator())
        }
        let fill = item(filler.isFilled ? "Restore Window" : "Fill Screen with Front Window", #selector(toggleFill))
        fill.keyEquivalent = "f"
        fill.keyEquivalentModifierMask = [.control, .option, .command]
        m.addItem(fill)
        m.addItem(item("Hide Menu Bar & Dock While Filled", #selector(toggleChrome), on: filler.hidesChrome))
        m.addItem(.separator())
        if #available(macOS 13.0, *) {
            m.addItem(item("Launch at Login", #selector(toggleLogin), on: SMAppService.mainApp.status == .enabled))
        }
        m.addItem(item("Quit MacPiP", #selector(quit)))
    }

    private func item(_ title: String, _ action: Selector, on: Bool = false) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        i.state = on ? .on : .off
        return i
    }

    @objc private func toggleFill() {
        // The menu made MacPiP frontmost for a moment; act on the app that was in front before.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [filler] in filler.toggle() }
    }
    @objc private func toggleChrome() { filler.hidesChrome.toggle() }
    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
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
