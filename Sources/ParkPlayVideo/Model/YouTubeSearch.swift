import Foundation

/// Căutare YouTube fără API key, cu metode de rezervă:
///  1. pagina de rezultate (desktop)  → JSON-ul `ytInitialData`;
///  2. API-ul intern al site-ului (InnerTube, `youtubei/v1/search`);
///  3. pagina mobilă m.youtube.com    → `ytInitialData` codat ca text.
/// Dacă formatul cunoscut (`videoRenderer`) nu mai există, se caută generic orice obiect
/// cu `videoId` + titlu. La eșec se spune clar de ce. Autor: arturm
enum YouTubeSearch {

    private static let uaDesktop =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
    private static let uaMobile =
        "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Mobile Safari/537.36"

    /// De ce nu sunt rezultate.
    enum Problem { case none, noResults, network, changed }

    struct Outcome {
        let tracks: [Track]
        let problem: Problem
        var method: String = ""
    }

    private struct Attempt {
        let tracks: [Track]
        let looksValid: Bool
    }

    private struct NetworkError: Error {}

    /// Formatele cunoscute ale unui rezultat video (desktop, mobil, liste).
    private static let renderers = ["videoRenderer", "videoWithContextRenderer", "compactVideoRenderer"]

    // MARK: - Filtre (ca pe YouTube: data încărcării, ordinea)

    static let uploadAny = 0, uploadToday = 2, uploadWeek = 3, uploadMonth = 4, uploadYear = 5
    /// Ordinea: 0 = relevanță, 2 = cele mai noi, 3 = cele mai vizionate.
    static let sortRelevance = 0, sortDate = 2, sortViews = 3

    /// `maxAgeDays` > 0: filtrare în aplicație după „acum X luni” (ex. ultimele 6 luni).
    struct Filters: Equatable {
        var upload = 0
        var sort = 0
        var maxAgeDays = 0
        var isDefault: Bool { upload == 0 && sort == 0 && maxAgeDays == 0 }
    }

    /// Parametrul `sp` al YouTube: un mesaj protobuf mic, în base64. nil = fără filtre.
    private static func sp(_ f: Filters) -> String? {
        if f.isDefault { return nil }
        var bytes: [UInt8] = []
        if f.sort != sortRelevance { bytes += [0x08, UInt8(f.sort)] }
        var inner: [UInt8] = []
        if f.upload != uploadAny { inner += [0x08, UInt8(f.upload)] }
        inner += [0x10, 0x01] // doar video-uri
        bytes += [0x12, UInt8(inner.count)] + inner
        return Data(bytes).base64EncodedString()
    }

    private static func enc(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    private static func spQuery(_ f: Filters) -> String { sp(f).map { "&sp=" + enc($0) } ?? "" }

    private static func matches(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    /// „acum 3 luni” / „3 months ago” → zile (aproximativ); -1 dacă nu se înțelege.
    static func ageDays(_ published: String) -> Int {
        let t = published.lowercased()
        if t.trimmingCharacters(in: .whitespaces).isEmpty { return -1 }
        var n = 1
        if let r = t.range(of: "\\d+", options: .regularExpression) { n = Int(t[r]) ?? 1 }
        if matches("sec|min|\\bh\\b|oră|\\bore\\b|hour", t) { return 0 }
        if matches("săpt|sapt|week|\\bw\\b", t) { return 7 * n }
        if matches("\\bzi\\b|zile|day|\\bd\\b", t) { return n }
        if matches("\\blun|month|\\blu\\b", t) { return 30 * n }
        if matches("\\ban\\b|\\bani\\b|year|\\by\\b", t) { return 365 * n }
        return -1
    }

    static func search(_ query: String, limit: Int = 30) async -> [Track] {
        await searchDetailed(query, limit: limit).tracks
    }

    private static func maxDays(_ f: Filters) -> Int {
        if f.maxAgeDays > 0 { return f.maxAgeDays }
        switch f.upload {
        case uploadToday: return 1
        case uploadWeek: return 7
        case uploadMonth: return 31
        case uploadYear: return 366
        default: return 0
        }
    }

    private static func ageOk(_ t: Track, _ max: Int, keepUnknown: Bool) -> Bool {
        if max <= 0 { return true }
        let d = ageDays(t.published)
        return d < 0 ? keepUnknown : d <= max
    }

    private static func sorted(_ list: [Track], _ sort: Int) -> [Track] {
        switch sort {
        case sortDate:
            return list.sorted { a, b in
                let da = ageDays(a.published), db = ageDays(b.published)
                return (da < 0 ? Int.max : da) < (db < 0 ? Int.max : db)
            }
        case sortViews: return list.sorted { $0.views > $1.views }
        default: return list
        }
    }

    /// Căutare cu filtre. Întâi cu filtrul YouTube (`sp`); dacă dă prea puține rezultate,
    /// căutare normală + filtrare și ordonare în aplicație.
    static func searchDetailed(_ query: String, limit: Int = 30, filters: Filters = Filters()) async -> Outcome {
        if filters.isDefault { return await runMethods(query, limit, Filters()) }
        let max = maxDays(filters)
        let first = await runMethods(query, limit * 2, filters)
        var list = first.tracks.filter { ageOk($0, max, keepUnknown: true) }
        if list.count < 5 {
            let plain = await runMethods(query, 100, Filters())
            let extra = plain.tracks.filter { ageOk($0, max, keepUnknown: false) }
            list = (list + extra).uniqued()
            if list.isEmpty {
                return Outcome(tracks: [], problem: plain.problem == .network ? .network : .noResults)
            }
        }
        return Outcome(tracks: Array(sorted(list, filters.sort).prefix(limit)), problem: .none, method: first.method)
    }

    private static func runMethods(_ query: String, _ limit: Int, _ f: Filters) async -> Outcome {
        let methods: [(String, () async throws -> Attempt)] = [
            ("pagină", { try await searchPage(query, limit, f) }),
            ("innertube", { try await searchInnerTube(query, limit, f) }),
            ("mobil", { try await searchMobile(query, limit, f) }),
        ]
        var networkErrors = 0
        var sawValid = false
        for (name, method) in methods {
            do {
                let a = try await method()
                if !a.tracks.isEmpty { return Outcome(tracks: a.tracks, problem: .none, method: name) }
                if a.looksValid { sawValid = true }
            } catch is NetworkError {
                networkErrors += 1
            } catch is URLError {
                networkErrors += 1
            } catch {
                // format necunoscut
            }
        }
        let problem: Problem = networkErrors == methods.count ? .network : (sawValid ? .noResults : .changed)
        return Outcome(tracks: [], problem: problem)
    }

    // MARK: - Metoda 1: pagina de rezultate desktop

    private static func searchPage(_ q: String, _ limit: Int, _ f: Filters) async throws -> Attempt {
        let html = try await download("https://www.youtube.com/results?search_query=" + enc(q) + "&hl=ro" + spQuery(f), uaDesktop)
        guard let data = extractInitialData(html) else { return Attempt(tracks: [], looksValid: false) }
        return Attempt(tracks: tracksFrom(data, limit), looksValid: true)
    }

    // MARK: - Metoda 2: InnerTube

    private static func searchInnerTube(_ q: String, _ limit: Int, _ f: Filters) async throws -> Attempt {
        var body: [String: Any] = [
            "context": ["client": ["clientName": "WEB", "clientVersion": "2.20240101.00.00", "hl": "ro"]],
            "query": q,
        ]
        if let p = sp(f) { body["params"] = p }
        var req = URLRequest(url: URL(string: "https://www.youtube.com/youtubei/v1/search?prettyPrint=false")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(uaDesktop, forHTTPHeaderField: "User-Agent")
        req.setValue("SOCS=CAI; CONSENT=YES+1", forHTTPHeaderField: "Cookie")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (d, resp) = try await fetch(req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return Attempt(tracks: [], looksValid: false) }
        guard let data = JSON.parse(String(decoding: d, as: UTF8.self)) else { return Attempt(tracks: [], looksValid: false) }
        return Attempt(tracks: tracksFrom(data, limit), looksValid: data.has("contents") || data.has("estimatedResults"))
    }

    // MARK: - Metoda 3: pagina mobilă

    private static func searchMobile(_ q: String, _ limit: Int, _ f: Filters) async throws -> Attempt {
        let html = try await download("https://m.youtube.com/results?search_query=" + enc(q) + "&hl=ro" + spQuery(f), uaMobile)
        guard let data = extractInitialData(html) ?? extractEscapedInitialData(html) else {
            return Attempt(tracks: [], looksValid: false)
        }
        return Attempt(tracks: tracksFrom(data, limit), looksValid: true)
    }

    private static func tracksFrom(_ data: JSON, _ limit: Int) -> [Track] {
        var out = OrderedTracks(limit: limit)
        collect(data, &out, renderers)
        if out.isEmpty { collectGeneric(data, &out) }
        return out.list
    }

    /// „Radio”: mixul YouTube pornind de la o piesă (playlistul RD<id>, piese asemănătoare).
    static func mix(_ videoId: String, limit: Int = 50) async -> [Track] {
        do {
            let html = try await download("https://www.youtube.com/watch?v=\(videoId)&list=RD\(videoId)&hl=ro", uaDesktop)
            guard let data = extractInitialData(html) else { return [] }
            var out = OrderedTracks(limit: limit)
            collect(data, &out, ["playlistPanelVideoRenderer"])
            if out.isEmpty { collectGeneric(data, &out) }
            return out.list
        } catch {
            return []
        }
    }

    /// Titlul și canalul unui video (pentru linkuri deschise în aplicație).
    static func oembed(_ id: String) async -> Track {
        let url = "https://www.youtube.com/oembed?format=json&url=" + enc("https://www.youtube.com/watch?v=\(id)")
        if let u = URL(string: url), let res = try? await fetch(URLRequest(url: u)),
           let o = JSON.parse(String(decoding: res.0, as: UTF8.self)), !o.str("title").isEmpty {
            return Track(id: id, title: o.str("title"), channel: o.str("author_name"), duration: "")
        }
        return Track(id: id, title: "Video YouTube", channel: "", duration: "")
    }

    // MARK: - Descărcare și extragere

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 15
        c.httpShouldSetCookies = false
        return URLSession(configuration: c)
    }()

    static func fetch(_ req: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: req)
        } catch {
            throw NetworkError()
        }
    }

    private static func download(_ url: String, _ ua: String) async throws -> String {
        guard let u = URL(string: url) else { throw NetworkError() }
        var req = URLRequest(url: u)
        req.timeoutInterval = 15
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue("ro,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        // Evită pagina de consimțământ pentru cookie-uri.
        req.setValue("SOCS=CAI; CONSENT=YES+1", forHTTPHeaderField: "Cookie")
        let (d, _) = try await fetch(req)
        return String(decoding: d, as: UTF8.self)
    }

    private static func extractInitialData(_ html: String) -> JSON? {
        for m in ["var ytInitialData = ", "window[\"ytInitialData\"] = ", "ytInitialData = "] {
            guard let start = html.range(of: m) else { continue }
            let from = start.upperBound
            guard from < html.endIndex, html[from] == "{" else { continue }
            guard let end = html.range(of: ";</script>", range: from..<html.endIndex) else { continue }
            return JSON.parse(String(html[from..<end.lowerBound]))
        }
        return nil
    }

    /// Pagina mobilă: `var ytInitialData = '\x7b\x22...';` — text JS care trebuie decodat.
    private static func extractEscapedInitialData(_ html: String) -> JSON? {
        let m = "var ytInitialData = '"
        guard let start = html.range(of: m),
              let end = html.range(of: "';", range: start.upperBound..<html.endIndex) else { return nil }
        return JSON.parse(unescapeJs(String(html[start.upperBound..<end.lowerBound])))
    }

    private static func unescapeJs(_ s: String) -> String {
        let c = Array(s.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        func hex(_ from: Int, _ len: Int) -> UInt32? {
            guard from + len <= c.count else { return nil }
            return UInt32(String(String.UnicodeScalarView(c[from..<from + len])), radix: 16)
        }
        while i < c.count {
            let ch = c[i]
            if ch == "\\" && i + 1 < c.count {
                let n = c[i + 1]
                switch n {
                case "x":
                    if let v = hex(i + 2, 2), let sc = Unicode.Scalar(v) { out.append(sc); i += 4; continue }
                case "u":
                    if let v = hex(i + 2, 4), let sc = Unicode.Scalar(v) { out.append(sc); i += 6; continue }
                case "n": out.append("\n"); i += 2; continue
                case "t": out.append("\t"); i += 2; continue
                default: out.append(n); i += 2; continue
                }
            }
            out.append(ch)
            i += 1
        }
        return String(out)
    }

    // MARK: - Parcurgerea JSON-ului

    private struct OrderedTracks {
        let limit: Int
        var list: [Track] = []
        var ids = Set<String>()
        var isEmpty: Bool { list.isEmpty }
        var full: Bool { list.count >= limit }
        mutating func add(_ t: Track) {
            if !full && ids.insert(t.id).inserted { list.append(t) }
        }
    }

    private static func collect(_ node: JSON, _ out: inout OrderedTracks, _ keys: [String]) {
        if out.full { return }
        switch node {
        case .object(let kv):
            for k in keys {
                if let r = node.obj(k), let t = toTrack(r) { out.add(t) }
            }
            for (_, v) in kv { collect(v, &out, keys) }
        case .array(let a):
            for v in a { collect(v, &out, keys) }
        default: break
        }
    }

    /// Rezervă: orice obiect cu `videoId` de 11 caractere și un titlu.
    private static func collectGeneric(_ node: JSON, _ out: inout OrderedTracks) {
        if out.full { return }
        switch node {
        case .object(let kv):
            if node.str("videoId").count == 11, node.has("title") || node.has("headline"), let t = toTrack(node) {
                out.add(t)
            }
            for (_, v) in kv { collectGeneric(v, &out) }
        case .array(let a):
            for v in a { collectGeneric(v, &out) }
        default: break
        }
    }

    private static func toTrack(_ r: JSON) -> Track? {
        let id = r.str("videoId")
        guard id.count == 11 else { return nil }
        let rawTitle = r.str("title")
        guard let title = text(r.obj("title")) ?? text(r.obj("headline")) ?? (rawTitle.isEmpty ? nil : rawTitle) else { return nil }
        let channel = text(r.obj("ownerText")) ?? text(r.obj("shortBylineText")) ?? text(r.obj("longBylineText")) ?? ""
        let duration = text(r.obj("lengthText")) ?? ""
        let published = text(r.obj("publishedTimeText")) ?? ""
        let views = parseViews(text(r.obj("viewCountText")) ?? text(r.obj("shortViewCountText")))
        return Track(id: id, title: title, channel: channel, duration: duration, published: published, views: views)
    }

    /// „1.234.567 de vizionări”, „1,2 mil. de vizionări”, „3.4M views” → număr; -1 dacă nu se poate.
    private static func parseViews(_ raw: String?) -> Int64 {
        guard let t = raw?.lowercased() else { return -1 }
        let mult: Double
        if matches("mld|\\bb\\b|billion", t) { mult = 1_000_000_000 }
        else if matches("mil|\\bm\\b|million", t) { mult = 1_000_000 }
        else if matches("\\bmii\\b|\\bk\\b|thousand", t) { mult = 1_000 }
        else { mult = 0 }
        if mult > 0 {
            guard let r = t.range(of: "\\d+(?:[.,]\\d+)?", options: .regularExpression),
                  let n = Double(t[r].replacingOccurrences(of: ",", with: ".")) else { return -1 }
            return Int64(n * mult)
        }
        let digits = String(t.filter { $0.isASCII && $0.isNumber }.prefix(18))
        return Int64(digits) ?? -1
    }

    private static func text(_ o: JSON?) -> String? {
        guard let o else { return nil }
        let simple = o.str("simpleText")
        if !simple.isEmpty { return simple }
        guard let runs = o["runs"]?.array else { return nil }
        let s = runs.map { $0.str("text") }.joined()
        return s.isEmpty ? nil : s
    }
}
