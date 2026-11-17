import AppKit

/// One entry from the window server's list. No permission needed except for `title`
/// (Screen Recording), which MacPiP has anyway.
struct Win {
    let id: CGWindowID
    let pid: pid_t
    let owner: String
    let title: String
    let bounds: CGRect   // global, top-left origin
    let layer: Int
    let onScreen: Bool   // visible on the current Space
}

enum Windows {
    static func all() -> [Win] {
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        let me = getpid()
        return list.compactMap { d in
            guard let id = d[kCGWindowNumber as String] as? CGWindowID,
                  let pid = d[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  let b = d[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: b as CFDictionary) else { return nil }
            return Win(id: id, pid: pid,
                       owner: d[kCGWindowOwnerName as String] as? String ?? "",
                       title: d[kCGWindowName as String] as? String ?? "",
                       bounds: r,
                       layer: d[kCGWindowLayer as String] as? Int ?? 0,
                       onScreen: d[kCGWindowIsOnscreen as String] as? Bool ?? false)
        }
    }

    private static let browsers: Set<String> = [
        "Google Chrome", "Google Chrome Beta", "Google Chrome Dev", "Google Chrome Canary", "Chromium",
        "Brave Browser", "Microsoft Edge", "Arc", "Vivaldi", "Opera", "Thorium", "Dia", "Comet",
        "Firefox", "Firefox Developer Edition", "Firefox Nightly", "Zen", "Zen Browser", "LibreWolf", "Waterfox", "Floorp",
    ]
    private static let floating = Int(CGWindowLevelForKey(.floatingWindow))

    /// A browser's native picture-in-picture window.
    static func isPiP(_ w: Win) -> Bool {
        guard w.bounds.width >= 100, w.bounds.height >= 60 else { return false }
        if w.title.range(of: "picture.?in.?picture", options: [.regularExpression, .caseInsensitive]) != nil { return true }
        return w.layer == floating && browsers.contains(w.owner)
    }

    /// Ordinary app windows a user might want to pin.
    static func pinnable(_ wins: [Win]) -> [Win] {
        wins.filter { $0.layer == 0 && $0.bounds.width >= 160 && $0.bounds.height >= 90 && !$0.owner.isEmpty }
    }

    /// Converts window-server coordinates (top-left of main display) to AppKit (bottom-left).
    static func appKitRect(_ r: CGRect) -> NSRect {
        let h = NSScreen.screens.first?.frame.height ?? r.maxY
        return NSRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
    }
}
