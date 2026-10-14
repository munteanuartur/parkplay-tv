import Foundation

/// Statistici de vizionare (doar pe acest Mac): cât ai ascultat din fiecare piesă, pe zile și pe ore.
/// Folosite de „ParkPlay Wrapped” și de Daily Mix. Reclamele nu se numără.
/// Structura (ca pe Android): { "AAAA-LL": { "tracks": {id: {t,c,d,s,n}}, "hours": [24], "days": {"AAAA-LL-ZZ": sec} } }
/// Autor: arturm
enum StatsStore {

    private static let key = "listening_stats"

    struct TrackStat: Codable {
        var t: String
        var c: String
        var d: String
        var s: Double
        var n: Int
    }

    struct MonthStats: Codable {
        var tracks: [String: TrackStat] = [:]
        var hours: [Double] = Array(repeating: 0, count: 24)
        var days: [String: Double] = [:]
    }

    private static var data: [String: MonthStats]?
    private static var dirty = false
    private static let lock = NSLock()

    private static let monthFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM"; return f
    }()
    private static let dayFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f
    }()

    private static func load() -> [String: MonthStats] {
        if let data { return data }
        var loaded: [String: MonthStats] = [:]
        if let raw = Prefs.shared.string(key), let d = raw.data(using: .utf8),
           let v = try? JSONDecoder().decode([String: MonthStats].self, from: d) {
            loaded = v
        }
        data = loaded
        return loaded
    }

    private static func mutate(_ date: Date = Date(), _ change: (inout MonthStats) -> Void) {
        var all = load()
        let k = monthFmt.string(from: date)
        var m = all[k] ?? MonthStats()
        if m.hours.count != 24 { m.hours = Array(repeating: 0, count: 24) }
        change(&m)
        all[k] = m
        data = all
        dirty = true
    }

    private static func ensure(_ m: inout MonthStats, _ t: Track) {
        if m.tracks[t.id] == nil {
            m.tracks[t.id] = TrackStat(t: t.title, c: t.channel, d: t.duration, s: 0, n: 0)
        }
    }

    /// O piesă a pornit.
    static func countPlay(_ t: Track) {
        lock.lock(); defer { lock.unlock() }
        mutate { m in
            ensure(&m, t)
            m.tracks[t.id]?.n += 1
        }
    }

    /// Câteva secunde vizionate din piesa `t`.
    static func addListening(_ t: Track, seconds: Double) {
        guard seconds.isFinite, seconds > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        mutate(now) { m in
            ensure(&m, t)
            m.tracks[t.id]?.s += seconds
            let h = Calendar.current.component(.hour, from: now)
            m.hours[h] += seconds
            m.days[dayFmt.string(from: now), default: 0] += seconds
        }
    }

    /// Scrie în preferințe (apelat periodic).
    static func flush() {
        lock.lock(); defer { lock.unlock() }
        flushLocked()
    }

    private static func flushLocked() {
        guard dirty, let data else { return }
        dirty = false
        if let d = try? JSONEncoder().encode(data) {
            Prefs.shared.set(key, string: String(decoding: d, as: UTF8.self))
        }
    }

    // MARK: - Rezumate (Wrapped, Daily Mix)

    struct Summary {
        let seconds: Double
        let weekSeconds: Double
        let plays: Int
        let distinctTracks: Int
        let topArtists: [(String, Double)]
        let topTracks: [(Track, Double)]
        let topHour: Int
        let daysActive: Int
    }

    /// monthOnly = luna curentă; altfel tot timpul.
    static func summary(monthOnly: Bool) -> Summary {
        lock.lock(); defer { lock.unlock() }
        let all = load()
        let months: [MonthStats] = monthOnly ? [all[monthFmt.string(from: Date())]].compactMap { $0 } : Array(all.values)

        var perTrack: [String: (Track, Double)] = [:]
        var perArtist: [String: Double] = [:]
        var hours = Array(repeating: 0.0, count: 24)
        var plays = 0
        var days = 0
        for m in months {
            for (id, e) in m.tracks {
                plays += e.n
                let t = Track(id: id, title: e.t, channel: e.c, duration: e.d)
                perTrack[id] = (t, (perTrack[id]?.1 ?? 0) + e.s)
                let artist = cleanArtist(t.channel)
                if !artist.isEmpty { perArtist[artist, default: 0] += e.s }
            }
            for h in 0..<min(24, m.hours.count) { hours[h] += m.hours[h] }
            days += m.days.count
        }
        // Ultimele 7 zile (pot fi în luna trecută)
        var week = 0.0
        var d = Date()
        for _ in 0..<7 {
            week += all[monthFmt.string(from: d)]?.days[dayFmt.string(from: d)] ?? 0
            d = Calendar.current.date(byAdding: .day, value: -1, to: d) ?? d
        }
        let topHour = hours.indices.max(by: { hours[$0] < hours[$1] }) ?? 20
        return Summary(
            seconds: perTrack.values.reduce(0) { $0 + $1.1 },
            weekSeconds: week,
            plays: plays,
            distinctTracks: perTrack.values.filter { $0.1 > 30 }.count,
            topArtists: Array(perArtist.sorted { $0.value > $1.value }.prefix(5).map { ($0.key, $0.value) }),
            topTracks: Array(perTrack.values.sorted { $0.1 > $1.1 }.prefix(5)),
            topHour: hours.allSatisfy({ $0 == 0 }) ? 20 : topHour,
            daysActive: days
        )
    }

    /// Piesele vizionate cel mai mult (pentru Daily Mix), din tot istoricul.
    static func topTracks(_ n: Int) -> [Track] {
        lock.lock(); defer { lock.unlock() }
        var per: [String: (Track, Double)] = [:]
        for m in load().values {
            for (id, e) in m.tracks {
                per[id] = (Track(id: id, title: e.t, channel: e.c, duration: e.d), (per[id]?.1 ?? 0) + e.s)
            }
        }
        return Array(per.values.sorted { $0.1 > $1.1 }.prefix(n).map { $0.0 })
    }

    /// „Artist - Topic”, „ArtistVEVO” → „Artist”.
    static func cleanArtist(_ channel: String) -> String {
        var s = channel
        s = s.replacingOccurrences(of: "\\s*-\\s*Topic$", with: "", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "VEVO$", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\s*\\(?Official\\)?$", with: "", options: [.regularExpression, .caseInsensitive])
        return s.trimmingCharacters(in: .whitespaces)
    }
}
