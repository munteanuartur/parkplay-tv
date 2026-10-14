import Foundation

/// Backup pentru favorite, playlisturi, istoric, căutări recente și setări.
/// Un singur fișier JSON mic, compatibil cu ParkPlay Audio / Video de pe Android
/// (îl poți muta între telefon și Mac). La import: „Combină” sau „Înlocuiește”. Autor: arturm
enum BackupManager {

    private static let format = "parkplay-audio-backup"
    private static let version = 1
    private static let historyMax = 200
    /// Ce NU intră în backup (stare temporară, specifică acestui dispozitiv).
    private static let skipSettings: Set<String> = ["resume_state", "podcast_positions", "last_backup"]
    private static let keyLastBackup = "last_backup"

    struct Summary {
        let favorites: Int
        let playlists: Int
        let history: Int
    }

    static func fileName() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return "ParkPlay-backup-\(f.string(from: Date())).json"
    }

    private static func rawArray(_ key: String) -> [Any] {
        guard let s = Prefs.shared.string(key), let d = s.data(using: .utf8),
              let a = try? JSONSerialization.jsonObject(with: d) as? [Any] else { return [] }
        return a
    }

    private static func isBool(_ n: NSNumber) -> Bool { CFGetTypeID(n) == CFBooleanGetTypeID() }

    // MARK: - Export

    static func export() -> Data {
        let p = Prefs.shared.simpleValues()
        var settings: [String: Any] = [:]
        for (k, v) in p.bools where !skipSettings.contains(k) { settings[k] = v }
        for (k, v) in p.ints where !skipSettings.contains(k) { settings[k] = v }
        for (k, v) in p.floats where !skipSettings.contains(k) {
            settings[k] = v
            settings["\(k)#float"] = true
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        let json: [String: Any] = [
            "format": format,
            "version": version,
            "created": f.string(from: Date()),
            "app": "ParkPlay Video (Mac)",
            "author": "arturm",
            Library.keyFavorites: rawArray(Library.keyFavorites),
            Library.keyHistory: rawArray(Library.keyHistory),
            Library.keyRecent: rawArray(Library.keyRecent),
            "playlists": rawArray(PlaylistStore.key),
            "settings": settings,
        ]
        Prefs.shared.set(keyLastBackup, int: Int64(Date().timeIntervalSince1970 * 1000))
        return (try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    static var lastBackup: Date? {
        let ms = Prefs.shared.int(keyLastBackup, default: 0)
        return ms > 0 ? Date(timeIntervalSince1970: Double(ms) / 1000) : nil
    }

    // MARK: - Import

    private static func parse(_ data: Data) -> [String: Any]? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              o["format"] as? String == format else { return nil }
        return o
    }

    /// Verifică fișierul și spune ce conține (nil = nu e un backup ParkPlay valid).
    static func inspect(_ data: Data) -> Summary? {
        guard let o = parse(data) else { return nil }
        return Summary(
            favorites: (o[Library.keyFavorites] as? [Any])?.count ?? 0,
            playlists: (o["playlists"] as? [Any])?.count ?? 0,
            history: (o[Library.keyHistory] as? [Any])?.count ?? 0
        )
    }

    private static func jsonString(_ v: Any) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: v) else { return "[]" }
        return String(decoding: d, as: UTF8.self)
    }

    /// replace = true: exact ce e în backup; false: combină cu ce există, fără dubluri.
    static func importBackup(_ data: Data, replace: Bool) throws {
        guard let o = parse(data) else { throw CocoaError(.fileReadCorruptFile) }

        func objects(_ v: Any?) -> [[String: Any]] { (v as? [Any])?.compactMap { $0 as? [String: Any] } ?? [] }
        func id(_ o: [String: Any]) -> String { o["id"] as? String ?? "" }

        var e = Prefs.BatchEditor()

        // Favorite și istoric: liste de piese, unice după id
        for (key, cap) in [(Library.keyFavorites, Int.max), (Library.keyHistory, historyMax)] {
            let incoming = objects(o[key])
            let result: [[String: Any]]
            if replace {
                result = incoming
            } else {
                let current = objects(rawArray(key))
                let ids = Set(current.map(id))
                result = current + incoming.filter { !ids.contains(id($0)) }
            }
            e.strings[key] = jsonString(Array(result.prefix(cap)))
        }

        // Căutări recente (text)
        let inRecent = (o[Library.keyRecent] as? [Any])?.compactMap { $0 as? String } ?? []
        let recent: [String]
        if replace {
            recent = inRecent
        } else {
            let cur = rawArray(Library.keyRecent).compactMap { $0 as? String }
            recent = cur + inRecent.filter { r in !cur.contains { $0.caseInsensitiveCompare(r) == .orderedSame } }
        }
        e.strings[Library.keyRecent] = jsonString(Array(recent.prefix(12)))

        // Playlisturi: același id → se completează cu piesele lipsă; altfel se adaugă
        let inPl = objects(o["playlists"])
        var pls: [[String: Any]]
        if replace {
            pls = inPl
        } else {
            pls = objects(rawArray(PlaylistStore.key))
            for p in inPl {
                guard let i = pls.firstIndex(where: { id($0) == id(p) }) else { pls.append(p); continue }
                var have = objects(pls[i]["tracks"])
                let ids = Set(have.map(id))
                have += objects(p["tracks"]).filter { !ids.contains(id($0)) }
                pls[i]["tracks"] = have
            }
        }
        e.strings[PlaylistStore.key] = jsonString(pls)

        // Setări (doar dacă înlocuim)
        if replace, let s = o["settings"] as? [String: Any] {
            for (k, v) in s where !k.hasSuffix("#float") {
                guard let n = v as? NSNumber else { continue }
                if isBool(n) { e.bools[k] = n.boolValue }
                else if (s["\(k)#float"] as? NSNumber)?.boolValue == true { e.floats[k] = n.doubleValue }
                else { e.ints[k] = n.int64Value }
            }
        }
        let edits = e
        Prefs.shared.batch { $0 = edits }
    }
}
