import AppKit

/// One-time setup: register this app as the extension's native-messaging host in every
/// installed Chromium browser, and put the extension in a stable folder for "Load unpacked".
enum Setup {
    static let hostName = "io.github.macpip"
    static let extensionID = "jopkiidhnpobkkoidfmmeeegeagionim" // fixed by the "key" in extension/manifest.json

    private static let support = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support")
    static let extensionDir = support.appendingPathComponent("MacPiP/extension")

    private static let browsers: [(String, String)] = [
        ("Google/Chrome", "Chrome"), ("Google/Chrome Beta", "Chrome Beta"), ("Google/Chrome Dev", "Chrome Dev"),
        ("Google/Chrome Canary", "Chrome Canary"), ("Google/Chrome for Testing", "Chrome for Testing"),
        ("Chromium", "Chromium"), ("BraveSoftware/Brave-Browser", "Brave"), ("Microsoft Edge", "Edge"),
        ("Vivaldi", "Vivaldi"), ("Arc/User Data", "Arc"), ("Thorium", "Thorium"),
    ]

    static var translocated: Bool { Bundle.main.bundlePath.contains("/AppTranslocation/") }

    /// Returns the names of browsers linked.
    @discardableResult
    static func install(extraHostDirs: [String] = []) -> [String] {
        let fm = FileManager.default
        guard let exe = Bundle.main.executablePath else { return [] }
        let manifest: [String: Any] = [
            "name": hostName, "description": "MacPiP", "path": exe, "type": "stdio",
            "allowed_origins": ["chrome-extension://\(extensionID)/"],
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .withoutEscapingSlashes])
        else { return [] }

        var linked: [String] = []
        var dirs = browsers.compactMap { (rel, name) -> (URL, String)? in
            let base = support.appendingPathComponent(rel)
            return fm.fileExists(atPath: base.path) ? (base.appendingPathComponent("NativeMessagingHosts"), name) : nil
        }
        dirs += extraHostDirs.map { (URL(fileURLWithPath: $0).appendingPathComponent("NativeMessagingHosts"), $0) }
        for (dir, name) in dirs {
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                try json.write(to: dir.appendingPathComponent("\(hostName).json"))
                linked.append(name)
            } catch { log("link \(name): \(error.localizedDescription)") }
        }

        if let src = Bundle.main.resourceURL?.appendingPathComponent("extension") {
            try? fm.removeItem(at: extensionDir)
            try? fm.createDirectory(at: extensionDir.deletingLastPathComponent(), withIntermediateDirectories: true)
            do { try fm.copyItem(at: src, to: extensionDir) } catch { log("copy extension: \(error.localizedDescription)") }
        }
        return linked
    }

    static func interactive() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        if translocated {
            alert.messageText = "Move MacPiP to Applications first"
            alert.informativeText = "Drag MacPiP.app into your Applications folder, then open it from there."
            alert.runModal()
            exit(0)
        }
        let linked = install()
        alert.messageText = linked.isEmpty ? "No Chromium browser found" : "MacPiP is set up"
        alert.informativeText = """
        Linked with: \(linked.isEmpty ? "none (install Chrome, Brave, Edge, Arc or Vivaldi, then open MacPiP again)" : linked.joined(separator: ", ")).

        One-time step in your browser:
        1. Open chrome://extensions (address copied to clipboard)
        2. Turn on Developer mode
        3. Load unpacked → choose the "extension" folder shown in Finder

        Then on any video: click the MacPiP toolbar button or press ⌥⇧P. Press it again to stop.
        """
        alert.addButton(withTitle: "Show Extension Folder")
        alert.addButton(withTitle: "Done")
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("chrome://extensions", forType: .string)
            NSWorkspace.shared.activateFileViewerSelecting([extensionDir])
        }
        exit(0)
    }
}
