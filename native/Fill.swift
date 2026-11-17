import AppKit
import ApplicationServices

/// "Fullscreen without a new Space": the front window fills its screen on the
/// *current* Space, so the browser's own PiP window (which floats over every
/// normal window on its Space) stays visible, live and clickable.
final class Filler {
    private struct Filled { let pid: pid_t; let window: AXUIElement; let frame: CGRect }
    private var filled: Filled?
    private let defaults = UserDefaults.standard

    var isFilled: Bool { filled != nil }
    var hidesChrome: Bool {
        get { defaults.object(forKey: "hideChrome") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "hideChrome") }
    }

    init() {
        // Crash recovery: put the user's menu bar / Dock settings back.
        if let saved = defaults.array(forKey: "restoreChrome") as? [Bool], saved.count == 2 {
            SystemUI.set(dock: saved[0], menuBar: saved[1])
            defaults.removeObject(forKey: "restoreChrome")
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] n in
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if let self, app?.processIdentifier == self.filled?.pid { self.filled = nil; self.restoreChrome() }
        }
    }

    func toggle() {
        guard AX.trusted(prompt: true) else { return }
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid(),
              let win = AX.focusedWindow(app.processIdentifier) else { log("no front window"); return }
        if let f = filled, CFEqual(f.window, win) { return restore() }
        restore()

        if AX.bool(win, "AXFullScreen") == true {
            // Leave the separate fullscreen Space first; that's the thing that hides PiP.
            AX.set(win, "AXFullScreen", kCFBooleanFalse)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.fill(win, app.processIdentifier) }
        } else {
            fill(win, app.processIdentifier)
        }
    }

    private func fill(_ win: AXUIElement, _ pid: pid_t) {
        guard let original = AX.frame(win) else { log("window has no frame"); return }
        filled = Filled(pid: pid, window: win, frame: original)
        let screen = Self.screen(containing: original)
        if hidesChrome, let current = SystemUI.get() {
            defaults.set([current.dock, current.menuBar], forKey: "restoreChrome")
            SystemUI.set(dock: true, menuBar: true)
            // Give the menu bar / Dock a moment to retract so the window may cover their area.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { AX.setFrame(win, Self.axRect(screen.frame)) }
        } else {
            AX.setFrame(win, Self.axRect(screen.visibleFrame))
        }
        log("filled pid \(pid)")
    }

    func restore() {
        if let f = filled { AX.setFrame(f.window, f.frame) }
        filled = nil
        restoreChrome()
    }

    private func restoreChrome() {
        guard let saved = defaults.array(forKey: "restoreChrome") as? [Bool], saved.count == 2 else { return }
        SystemUI.set(dock: saved[0], menuBar: saved[1])
        defaults.removeObject(forKey: "restoreChrome")
    }

    // MARK: Coordinates: AX uses top-left origin of the main display, AppKit bottom-left.

    private static var mainHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    private static func axRect(_ r: NSRect) -> CGRect {
        CGRect(x: r.minX, y: mainHeight - r.maxY, width: r.width, height: r.height)
    }

    private static func screen(containing ax: CGRect) -> NSScreen {
        let center = NSPoint(x: ax.midX, y: mainHeight - ax.midY)
        return NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main ?? NSScreen.screens[0]
    }
}

// MARK: - Accessibility helpers

enum AX {
    static func trusted(prompt: Bool) -> Bool {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary)
    }

    static func get(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success ? v : nil
    }

    static func set(_ el: AXUIElement, _ attr: String, _ value: CFTypeRef) {
        let r = AXUIElementSetAttributeValue(el, attr as CFString, value)
        if r != .success { log("AX set \(attr) failed: \(r.rawValue)") }
    }

    static func bool(_ el: AXUIElement, _ attr: String) -> Bool? { get(el, attr) as? Bool }

    static func focusedWindow(_ pid: pid_t) -> AXUIElement? {
        guard let w = get(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute),
              CFGetTypeID(w) == AXUIElementGetTypeID() else { return nil }
        return (w as! AXUIElement)
    }

    static func frame(_ w: AXUIElement) -> CGRect? {
        guard let p = get(w, kAXPositionAttribute), let s = get(w, kAXSizeAttribute) else { return nil }
        var pt = CGPoint.zero, sz = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &pt), AXValueGetValue(s as! AXValue, .cgSize, &sz) else { return nil }
        return CGRect(origin: pt, size: sz)
    }

    static func setFrame(_ w: AXUIElement, _ r: CGRect) {
        var o = r.origin, s = r.size
        guard let pos = AXValueCreate(.cgPoint, &o), let size = AXValueCreate(.cgSize, &s) else { return }
        // position → size → position: apps clamp size to the space left below the current origin.
        set(w, kAXPositionAttribute, pos)
        set(w, kAXSizeAttribute, size)
        set(w, kAXPositionAttribute, pos)
    }
}

// MARK: - Menu bar / Dock auto-hide (System Events, the same switches as System Settings)

enum SystemUI {
    static func get() -> (dock: Bool, menuBar: Bool)? {
        guard let d = run("tell application \"System Events\" to tell dock preferences to get {autohide, autohide menu bar}"),
              d.numberOfItems == 2, let a = d.atIndex(1), let b = d.atIndex(2) else { return nil }
        return (a.booleanValue, b.booleanValue)
    }

    static func set(dock: Bool, menuBar: Bool) {
        run("""
        tell application "System Events" to tell dock preferences
          set autohide to \(dock)
          set autohide menu bar to \(menuBar)
        end tell
        """)
    }

    @discardableResult
    private static func run(_ source: String) -> NSAppleEventDescriptor? {
        var err: NSDictionary?
        let r = NSAppleScript(source: source)?.executeAndReturnError(&err)
        if let err { log("AppleScript: \(err[NSAppleScript.errorMessage] ?? err)") }
        return err == nil ? r : nil
    }
}
