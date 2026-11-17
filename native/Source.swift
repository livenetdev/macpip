import Foundation

/// A validated float request. Only http(s) URLs are ever accepted.
struct Request {
    let url: URL       // page URL (or an embed iframe's URL)
    let src: URL?      // direct media URL, when the page exposed one
    let time: Double   // start position, seconds
    let size: CGSize?  // natural video size hint
    let title: String

    init?(message m: [String: Any]) {
        guard let u = (m["url"] as? String).flatMap(Request.web) else { return nil }
        url = u
        src = (m["src"] as? String).flatMap(Request.web)
        time = Request.clean((m["t"] as? NSNumber)?.doubleValue)
        let w = (m["w"] as? NSNumber)?.doubleValue ?? 0, h = (m["h"] as? NSNumber)?.doubleValue ?? 0
        size = w > 0 && h > 0 ? CGSize(width: w, height: h) : nil
        title = String((m["title"] as? String ?? "").prefix(200))
    }

    init?(url s: String, time t: Double?) {
        guard let u = Request.web(s) else { return nil }
        let isMedia = ["mp4", "m4v", "mov", "webm", "m3u8", "mp3", "m4a"].contains(u.pathExtension.lowercased())
        url = u
        src = isMedia ? u : nil
        time = Request.clean(t)
        size = nil
        title = u.host ?? ""
    }

    static func web(_ s: String) -> URL? {
        guard s.count < 8192, let u = URL(string: s), let scheme = u.scheme?.lowercased(),
              scheme == "https" || scheme == "http", u.host != nil else { return nil }
        return u
    }

    private static func clean(_ t: Double?) -> Double {
        guard let t, t.isFinite, t > 0 else { return 0 }
        return t
    }
}

enum Mode: String { case embed, direct, page }

/// How to load a request. `fallback` is used if the first attempt reports an error.
struct Plan {
    let mode: Mode
    let url: URL
    let fallback: URL?
}

extension Request {
    var plan: Plan {
        let t = time > 0 ? time : Self.urlTime(url)
        if let id = Self.youTubeID(url) {
            // youtube-nocookie: no cookies until playback, no personalised tracking.
            return Plan(mode: .embed,
                        url: URL(string: "https://www.youtube-nocookie.com/embed/\(id)?autoplay=1&playsinline=1&rel=0&iv_load_policy=3&start=\(Int(t))")!,
                        fallback: URL(string: "https://www.youtube.com/watch?v=\(id)&t=\(Int(t))s"))
        }
        if let vimeo = Self.vimeoID(url) {
            let (id, hash) = vimeo
            let h = hash.map { "&h=\($0)" } ?? ""
            return Plan(mode: .embed,
                        url: URL(string: "https://player.vimeo.com/video/\(id)?autoplay=1&dnt=1\(h)#t=\(Int(t))s")!,
                        fallback: url)
        }
        if let src { return Plan(mode: .direct, url: src, fallback: src == url ? nil : url) }
        return Plan(mode: .page, url: url, fallback: nil)
    }

    private static func host(_ u: URL, is domain: String) -> Bool {
        guard let h = u.host?.lowercased() else { return false }
        return h == domain || h.hasSuffix("." + domain)
    }

    private static func query(_ u: URL, _ name: String) -> String? {
        URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }

    private static func parts(_ u: URL) -> [String] { u.pathComponents.filter { $0 != "/" } }

    static func youTubeID(_ u: URL) -> String? {
        let p = parts(u)
        var id: String?
        if host(u, is: "youtu.be") {
            id = p.first
        } else if host(u, is: "youtube.com") || host(u, is: "youtube-nocookie.com") {
            if p.first == "watch" { id = query(u, "v") }
            else if p.count >= 2, ["shorts", "live", "embed", "v"].contains(p[0]) { id = p[1] }
        }
        guard let id, id.count == 11,
              id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        return id
    }

    static func vimeoID(_ u: URL) -> (String, String?)? {
        guard host(u, is: "vimeo.com") else { return nil }
        let p = parts(u)
        guard let i = p.firstIndex(where: { !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
        let next = i + 1 < p.count ? p[i + 1] : nil
        let hash = query(u, "h") ?? next.flatMap { $0.allSatisfy { $0.isHexDigit } ? $0 : nil }
        return (p[i], hash)
    }

    /// Parses `t=90`, `t=90s`, `t=1h2m3s`, `start=90`.
    static func urlTime(_ u: URL) -> Double {
        guard let s = query(u, "t") ?? query(u, "start") else { return 0 }
        if let d = Double(s) { return max(d, 0) }
        var total = 0.0, num = ""
        for c in s {
            if c.isNumber { num.append(c); continue }
            let n = Double(num) ?? 0
            num = ""
            switch c { case "h": total += n * 3600; case "m": total += n * 60; case "s": total += n; default: break }
        }
        return total + (Double(num) ?? 0)
    }
}
