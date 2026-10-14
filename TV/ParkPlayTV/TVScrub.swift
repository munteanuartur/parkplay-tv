import SwiftUI

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

    static func all() -> [String: Entry] {
        guard let raw = Prefs.shared.string(key), let d = raw.data(using: .utf8),
              let v = try? JSONDecoder().decode([String: Entry].self, from: d) else { return [:] }
        return v
    }

    private static func save(_ v: [String: Entry]) {
        if let d = try? JSONEncoder().encode(v) { Prefs.shared.set(key, string: String(decoding: d, as: UTF8.self)) }
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

// MARK: - Storyboard: miniaturile de pe bara de derulare

/// Miniaturile YouTube de pe bara de derulare („storyboard”): imagini mari cu multe cadre
/// mici, din care afișăm cadrul pentru momentul ales. Formatul (din răspunsul playerului):
/// `URL_baza|w#h#count#cols#rows#interval_ms#nume#sigh|...` — folosim nivelul cel mai detaliat.
struct Storyboard: Equatable {
    let base: String
    let level: Int
    let w: Int, h: Int, count: Int, cols: Int, rows: Int
    let interval: Int
    let name: String
    let sigh: String

    init?(spec: String) {
        let parts = spec.components(separatedBy: "|")
        guard parts.count >= 2, let last = parts.last else { return nil }
        let f = last.components(separatedBy: "#")
        guard f.count >= 8, let w = Int(f[0]), let h = Int(f[1]), let count = Int(f[2]),
              let cols = Int(f[3]), let rows = Int(f[4]), w > 0, h > 0, count > 0, cols > 0, rows > 0 else { return nil }
        base = parts[0]
        level = parts.count - 2
        self.w = w; self.h = h; self.count = count; self.cols = cols; self.rows = rows
        interval = Int(f[5]) ?? 0
        name = f[6]
        sigh = f[7]
    }

    func frame(at time: Double, duration: Double) -> (url: URL, col: Int, row: Int)? {
        var i: Int
        if interval > 0 { i = Int(time * 1000 / Double(interval)) }
        else if duration > 0 { i = Int(time / duration * Double(count)) }
        else { return nil }
        i = min(max(i, 0), count - 1)
        let perSheet = cols * rows
        let sheet = i / perSheet
        let within = i % perSheet
        let n = name.replacingOccurrences(of: "$M", with: String(sheet))
        var s = base.replacingOccurrences(of: "$L", with: String(level)).replacingOccurrences(of: "$N", with: n)
        if !sigh.isEmpty { s += (s.contains("?") ? "&" : "?") + "sigh=" + sigh }
        guard let u = URL(string: s) else { return nil }
        return (u, within % cols, within / cols)
    }
}

/// Un cadru din storyboard (decupat din imaginea mare).
struct StoryboardThumb: View {
    let sb: Storyboard
    let time: Double
    let duration: Double
    let width: CGFloat

    var body: some View {
        let scale = width / CGFloat(sb.w)
        let height = CGFloat(sb.h) * scale
        if let f = sb.frame(at: time, duration: duration) {
            AsyncImage(url: f.url) { phase in
                if let img = phase.image {
                    img.scaleEffect(scale, anchor: .topLeading)
                        .offset(x: -CGFloat(f.col * sb.w) * scale, y: -CGFloat(f.row * sb.h) * scale)
                } else {
                    Color.black
                }
            }
            .frame(width: width, height: height, alignment: .topLeading)
            .clipped()
        } else {
            Color.black.frame(width: width, height: height)
        }
    }
}

// MARK: - Bara de derulare (ca pe YouTube)

/// Bara de timp din player. Cu focus pe ea: stânga / dreapta (click sau glisare) mută un
/// marcaj de previzualizare — cu cât apeși mai repede, cu atât sare mai mult — și arată
/// miniatura momentului; click confirmă (sau singur după o clipă), Menu anulează.
struct ScrubBar: View {
    @ObservedObject var clock: TVClock
    let storyboard: Storyboard?
    let preview: Double?
    let focused: Bool

    private let accent = Color(red: 1, green: 0, blue: 0.2)

    var body: some View {
        GeometryReader { g in
            let dur = max(clock.duration, 1)
            let cur = min(max(clock.position / dur, 0), 1)
            let mark = preview.map { min(max($0 / dur, 0), 1) }
            let barH: CGFloat = focused ? 12 : 7
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25)).frame(height: barH)
                Capsule().fill(accent).frame(width: g.size.width * cur, height: barH)
                if focused {
                    Circle().fill(accent)
                        .frame(width: 28, height: 28)
                        .shadow(radius: 4)
                        .offset(x: g.size.width * (mark ?? cur) - 14)
                }
                if let m = mark, let p = preview {
                    VStack(spacing: 8) {
                        if let sb = storyboard {
                            StoryboardThumb(sb: sb, time: p, duration: clock.duration, width: 360)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white, lineWidth: 3))
                        }
                        Text(TVTime.fmt(p) + "  (" + (p >= clock.position ? "+" : "−") + TVTime.fmt(abs(p - clock.position)) + ")")
                            .font(.headline.monospacedDigit())
                            .padding(.horizontal, 14).padding(.vertical, 6)
                            .background(.black.opacity(0.75), in: Capsule())
                    }
                    .position(x: min(max(g.size.width * m, 190), g.size.width - 190),
                              y: storyboard == nil ? -36 : -150)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: 40)
        .animation(.easeOut(duration: 0.12), value: focused)
    }
}

enum TVTime {
    static func fmt(_ s: Double) -> String {
        let t = Int(max(0, s.isFinite ? s : 0))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, (t / 60) % 60, t % 60)
            : String(format: "%d:%02d", t / 60, t % 60)
    }
}
