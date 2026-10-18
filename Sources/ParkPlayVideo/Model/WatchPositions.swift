import Foundation

// MARK: - Unde ai rămas (ca pe YouTube)

/// Poziția la care ai rămas în fiecare video (ultimele 400), ca să continui de acolo
/// și să apară bara roșie pe carduri. Se șterge când video-ul e văzut aproape până la capăt.
/// Autor: arturm
enum WatchPositions {
    private static let key = "watch_positions"
    private static let maxEntries = 400

    struct Entry: Codable {
        var p: Double   // poziția (s)
        var d: Double   // durata (s; 0 = necunoscută)
        var t: Double   // când a fost salvată (timestamp)
    }

    /// Citit o singură dată (miniaturile întreabă des); se schimbă doar prin `set`.
    private static var cache: (raw: String, value: [String: Entry])?

    static func all() -> [String: Entry] {
        guard let raw = Prefs.shared.string(key) else { return [:] }
        if let c = cache, c.raw == raw { return c.value }
        guard let d = raw.data(using: .utf8),
              let v = try? JSONDecoder().decode([String: Entry].self, from: d) else { return [:] }
        cache = (raw, v)
        return v
    }

    private static func save(_ v: [String: Entry]) {
        guard let d = try? JSONEncoder().encode(v) else { return }
        let raw = String(decoding: d, as: UTF8.self)
        cache = (raw, v)
        Prefs.shared.set(key, string: raw)
    }

    /// De unde pornește video-ul (nil = de la început).
    static func resumePoint(_ id: String) -> Double? {
        guard let e = all()[id], e.p > 15 else { return nil }
        if e.d > 0 && e.p > e.d - 30 { return nil }
        return e.p
    }

    /// Cât ai văzut (0…1), pentru bara de pe carduri.
    static func fraction(_ id: String) -> Double? {
        guard let e = all()[id], e.d > 0, e.p > 15 else { return nil }
        return min(e.p / e.d, 1)
    }

    static func set(_ id: String, position: Double, duration: Double) {
        var v = all()
        if position < 10 || (duration > 0 && position > duration - 30) {
            // Prea la început sau aproape terminat: nu e nimic de continuat.
            guard v.removeValue(forKey: id) != nil else { return }
        } else {
            v[id] = Entry(p: position, d: duration, t: Date().timeIntervalSince1970)
            if v.count > maxEntries {
                for (k, _) in v.sorted(by: { $0.value.t < $1.value.t }).prefix(v.count - maxEntries) { v.removeValue(forKey: k) }
            }
        }
        save(v)
    }
}
