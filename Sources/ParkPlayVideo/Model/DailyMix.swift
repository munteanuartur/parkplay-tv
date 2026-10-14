import Foundation

/// „Daily Mix” (zilnic) și „Descoperă săptămânal” — playlisturi generate din ce vizionezi:
///  - Daily Mix 1–3: câte unul pentru artiștii ascultați cel mai mult (statistici + favorite + istoric),
///    cu piesele lor cunoscute + mixul YouTube asemănător;
///  - Descoperă: piese asemănătoare cu favoritele tale, dar pe care NU le-ai mai ascultat.
/// Se generează o dată pe zi / săptămână și se păstrează local. Autor: arturm
enum DailyMix {

    struct Mix: Identifiable, Codable {
        let id: String
        let name: String
        let subtitle: String
        let tracks: [Track]
    }

    private struct Saved: Codable {
        let day: String
        let week: String
        let mixes: [Mix]
    }

    private static let key = "daily_mixes"

    private static func today() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    private static func thisWeek() -> String {
        let c = Calendar.current
        let d = Date()
        return "\(c.component(.year, from: d))-W\(c.component(.weekOfYear, from: d))"
    }

    private static func read() -> Saved? {
        guard let raw = Prefs.shared.string(key), let d = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Saved.self, from: d)
    }

    /// Mixurile salvate, dacă sunt de azi / din săptămâna asta; altfel nil.
    static func cached() -> [Mix]? {
        guard let s = read(), s.day == today(), s.week == thisWeek() else { return nil }
        return s.mixes
    }

    /// Ultimele mixuri salvate, chiar dacă sunt vechi.
    static func lastKnown() -> [Mix] { read()?.mixes ?? [] }

    /// Generează (rețea).
    static func generate() async -> [Mix] {
        let favs = Library.favorites
        let hist = Library.history
        let top = StatsStore.topTracks(60)

        // Scor pe artist: ascultări (din statistici) + favorite + istoric
        var score: [String: Double] = [:]
        var order: [String] = []
        var tracksOf: [String: [Track]] = [:]
        func add(_ t: Track, _ w: Double) {
            let a = StatsStore.cleanArtist(t.channel)
            if a.isEmpty { return }
            if score[a] == nil { order.append(a) }
            score[a, default: 0] += w
            var l = tracksOf[a] ?? []
            if !l.contains(where: { $0.id == t.id }) { l.append(t) }
            tracksOf[a] = l
        }
        for (i, t) in top.enumerated() { add(t, 60.0 - Double(i)) }
        favs.forEach { add($0, 20) }
        hist.prefix(80).forEach { add($0, 5) }

        let known = Set((favs + hist + top).map(\.id))
        var result: [Mix] = []
        let artists = order.sorted { (score[$0] ?? 0) > (score[$1] ?? 0) }.prefix(3)
        for (i, artist) in artists.enumerated() {
            let own = tracksOf[artist] ?? []
            guard let seed = own.first else { continue }
            let similar = await YouTubeSearch.mix(seed.id, limit: 30)
            let tracks = (Array(own.prefix(6)) + similar).uniqued()
            guard let first = tracks.first else { continue }
            // Amestecăm, dar păstrăm o piesă cunoscută la început
            let mixed = [first] + tracks.dropFirst().shuffled()
            if mixed.count >= 5 {
                result.append(Mix(id: "daily\(i + 1)", name: "Daily Mix \(i + 1)",
                                  subtitle: "\(artist) și alții", tracks: Array(mixed.prefix(35))))
            }
        }

        // Descoperă săptămânal
        let seeds = (Array(favs.shuffled().prefix(2)) + Array(top.prefix(2))).uniqued()
        if !seeds.isEmpty {
            var pool: [Track] = []
            for s in seeds { pool += await YouTubeSearch.mix(s.id, limit: 30) }
            let fresh = Array(pool.filter { !known.contains($0.id) }.uniqued().shuffled().prefix(30))
            if fresh.count >= 5 {
                result.append(Mix(id: "discover", name: "Descoperă săptămânal",
                                  subtitle: "Piese noi pentru tine, după ce-ți place", tracks: fresh))
            }
        }

        if let d = try? JSONEncoder().encode(Saved(day: today(), week: thisWeek(), mixes: result)) {
            Prefs.shared.set(key, string: String(decoding: d, as: UTF8.self))
        }
        return result
    }
}
