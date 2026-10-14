import Foundation

/// Un rezultat YouTube (video). Se salvează doar id, titlu, canal, durată
/// (același format ca în ParkPlay Audio / Video pe Android). Autor: arturm
struct Track: Identifiable, Hashable, Codable {
    let id: String
    var title: String
    var channel: String
    var duration: String
    /// Când a fost publicat, ca text YouTube („acum 3 luni”); gol dacă nu se știe.
    var published: String = ""
    /// Numărul de vizionări (-1 = necunoscut).
    var views: Int64 = -1

    init(id: String, title: String, channel: String, duration: String, published: String = "", views: Int64 = -1) {
        self.id = id
        self.title = title
        self.channel = channel
        self.duration = duration
        self.published = published
        self.views = views
    }

    var thumbnailURL: URL? { URL(string: "https://i.ytimg.com/vi/\(id)/mqdefault.jpg") }
    var bigThumbnailURL: URL? { URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg") }
    var watchURL: String { "https://www.youtube.com/watch?v=\(id)" }
    var shareURL: URL { URL(string: "https://youtu.be/\(id)")! }

    /// Durata din rezultatul căutării („3:45”), în secunde; 0 dacă nu se știe.
    var expectedDuration: Double {
        let parts = duration.trimmingCharacters(in: .whitespaces).split(separator: ":").map { Int64($0) }
        guard !parts.isEmpty, parts.count <= 3, !parts.contains(where: { $0 == nil }) else { return 0 }
        return Double(parts.reduce(Int64(0)) { $0 * 60 + ($1 ?? 0) })
    }

    // Doar cele 4 câmpuri, ca pe Android.
    enum CodingKeys: String, CodingKey { case id, title, channel, duration }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
        channel = (try? c.decodeIfPresent(String.self, forKey: .channel)) ?? ""
        duration = (try? c.decodeIfPresent(String.self, forKey: .duration)) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(channel, forKey: .channel)
        try c.encode(duration, forKey: .duration)
    }

    // Identitatea = id-ul video-ului.
    static func == (a: Track, b: Track) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

extension Array where Element == Track {
    /// Fără dubluri (după id), păstrând ordinea.
    func uniqued() -> [Track] {
        var seen = Set<String>()
        return filter { seen.insert($0.id).inserted }
    }
}

/// Liste de piese ⇄ text JSON (cum sunt salvate în preferințe).
enum TrackCodec {
    static func decode(_ raw: String?) -> [Track] {
        guard let raw, let d = raw.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([Track].self, from: d)) ?? []
    }

    static func encode(_ list: [Track]) -> String {
        guard let d = try? JSONEncoder().encode(list) else { return "[]" }
        return String(decoding: d, as: UTF8.self)
    }
}
