import Foundation
import CryptoKit
import SwiftUI

/// SponsorBlock (sponsor.ajay.app): bază de date publică, făcută de comunitate, cu părțile
/// dintr-un video care nu sunt conținutul principal — intro, outro, părți vorbite din
/// clipurile muzicale, reclame citite de autor etc. Le sărim automat.
/// Pentru confidențialitate trimitem doar primele 4 caractere din hash-ul ID-ului video. Autor: arturm
enum SponsorBlock {

    struct Segment {
        let start: Double
        let end: Double
        let category: String
    }

    private static let categories = [
        "music_offtopic", "sponsor", "selfpromo", "interaction", "intro", "outro", "preview",
    ]

    static func segments(_ videoId: String) async -> [Segment] {
        let hash = SHA256.hash(data: Data(videoId.utf8)).map { String(format: "%02x", $0) }.joined()
        let prefix = String(hash.prefix(4))
        guard let cats = try? JSONSerialization.data(withJSONObject: categories),
              var comps = URLComponents(string: "https://sponsor.ajay.app/api/skipSegments/\(prefix)") else { return [] }
        comps.queryItems = [
            URLQueryItem(name: "categories", value: String(decoding: cats, as: UTF8.self)),
            URLQueryItem(name: "actionType", value: "skip"),
        ]
        guard let url = comps.url else { return [] }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        req.setValue("ParkPlayVideo-Mac (arturm)", forHTTPHeaderField: "User-Agent")
        guard let res = try? await URLSession.shared.data(for: req),
              (res.1 as? HTTPURLResponse)?.statusCode == 200, // 404 = niciun segment
              let arr = JSON.parse(String(decoding: res.0, as: UTF8.self))?.array else { return [] }
        var out: [Segment] = []
        for video in arr where video.str("videoID") == videoId {
            for s in video["segments"]?.array ?? [] {
                guard let range = s["segment"]?.array, range.count >= 2,
                      let start = range[0].double, let end = range[1].double else { continue }
                if start >= 0 && end > start + 0.5 { out.append(Segment(start: start, end: end, category: s.str("category"))) }
            }
        }
        return out.sorted { $0.start < $1.start }
    }
}

/// Categoriile de muzică (tab-ul Caută). Autor: arturm
enum Categories {
    struct Category: Identifiable {
        let label: String
        let query: String
        let color: Color
        var id: String { query }
    }

    private static func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color { Color(red: r / 255, green: g / 255, blue: b / 255) }

    static let list: [Category] = [
        Category(label: "Pop", query: "pop hits 2026", color: rgb(233, 30, 99)),
        Category(label: "Rock", query: "rock classics best songs", color: rgb(183, 28, 28)),
        Category(label: "Hip-Hop", query: "hip hop hits 2026", color: rgb(230, 81, 0)),
        Category(label: "Dance / Electronic", query: "dance electronic hits 2026", color: rgb(106, 27, 154)),
        Category(label: "Chill / Lo-fi", query: "chill lofi music", color: rgb(0, 121, 107)),
        Category(label: "Jazz", query: "jazz classics", color: rgb(93, 64, 55)),
        Category(label: "Clasică", query: "classical music best pieces", color: rgb(69, 90, 100)),
        Category(label: "Românească", query: "muzica romaneasca hituri 2026", color: rgb(21, 101, 192)),
        Category(label: "Retro anii 80–90", query: "80s 90s hits", color: rgb(173, 20, 87)),
        Category(label: "Party", query: "party mix hits", color: rgb(255, 111, 0)),
        Category(label: "Sport", query: "workout music mix", color: rgb(46, 125, 50)),
        Category(label: "Podcasturi", query: "podcast popular episode", color: rgb(48, 63, 159)),
    ]
}
