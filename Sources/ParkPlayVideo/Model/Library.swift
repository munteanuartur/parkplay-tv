import Foundation
import SwiftUI // remove(atOffsets:), move(fromOffsets:toOffset:)

/// Datele utilizatorului: favorite, istoric, căutări recente, setări.
/// Același format ca în ParkPlay Audio / Video (backup-urile se pot importa între ele). Autor: arturm
enum Library {

    static let keyFavorites = "favorites"
    static let keyHistory = "history"
    static let keyRecent = "recent_searches"
    private static let historyMax = 200
    private static let favoritesMax = 300

    // ---- Setări (bife) ----
    static let keyBackground = "background_audio"
    static let keyPip = "pip"
    static let keyAutoplay = "autoplay"
    static let keySponsorBlock = "sponsorblock"
    /** În fundal (fereastra ascunsă / minimizată): calitate minimă, doar sunetul contează. */
    static let keyBgLowQuality = "bg_low_quality"
    static let keyQuality = "video_quality"
    static let keyRate = "video_rate"

    static let defaultSearches = ["Top hits", "New hits", "Muzică românească 2026", "Hituri internaționale", "Podcast în română"]

    private static var prefs: Prefs { .shared }

    static func setting(_ key: String, default def: Bool = true) -> Bool { prefs.bool(key, default: def) }
    static func setSetting(_ key: String, _ value: Bool) { prefs.set(key, bool: value) }

    /// Calitatea aleasă: "auto" sau un nivel YouTube (hd1080, hd720, large…).
    static var quality: String {
        get { prefs.string(keyQuality) ?? "auto" }
        set { prefs.set(keyQuality, string: newValue) }
    }

    /// Calitatea folosită cât video-ul se redă pe Apple TV (AirPlay). Implicit 1080p:
    /// „Auto” ar alege după mărimea player-ului de pe Mac (poate fi mic), nu după televizor.
    static let keyAirplayQuality = "airplay_quality"
    static var airplayQuality: String {
        get { prefs.string(keyAirplayQuality) ?? "hd1080" }
        set { prefs.set(keyAirplayQuality, string: newValue) }
    }

    static var rate: Double {
        get { prefs.double(keyRate, default: 1.0) }
        set { prefs.set(keyRate, double: newValue) }
    }

    // ---- Liste de piese ----

    static var favorites: [Track] { TrackCodec.decode(prefs.string(keyFavorites)) }
    static var history: [Track] { TrackCodec.decode(prefs.string(keyHistory)) }

    private static func write(_ key: String, _ list: [Track]) { prefs.set(key, string: TrackCodec.encode(list)) }

    static func isFavorite(_ id: String?) -> Bool {
        guard let id else { return false }
        return favorites.contains { $0.id == id }
    }

    /// ❤: adaugă (prima în listă) sau scoate. Întoarce true dacă acum e la favorite.
    @discardableResult
    static func toggleFavorite(_ t: Track) -> Bool {
        let favs = favorites
        if favs.contains(where: { $0.id == t.id }) {
            write(keyFavorites, favs.filter { $0.id != t.id })
            return false
        }
        write(keyFavorites, Array(([t] + favs).prefix(favoritesMax)))
        return true
    }

    static func removeFavorite(_ id: String) { write(keyFavorites, favorites.filter { $0.id != id }) }

    static func addHistory(_ t: Track) {
        write(keyHistory, Array(([t] + history.filter { $0.id != t.id }).prefix(historyMax)))
    }

    static func clearHistory() { write(keyHistory, []) }

    // ---- Căutări recente ----

    static var recentSearches: [String] {
        guard let raw = prefs.string(keyRecent), let d = raw.data(using: .utf8),
              let list = try? JSONDecoder().decode([String].self, from: d), !list.isEmpty else { return defaultSearches }
        return list
    }

    static func addRecentSearch(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        let list = Array(([q] + recentSearches.filter { $0.caseInsensitiveCompare(q) != .orderedSame }).prefix(12))
        if let d = try? JSONEncoder().encode(list) { prefs.set(keyRecent, string: String(decoding: d, as: UTF8.self)) }
    }
}

/// Playlist-urile utilizatorului (salvate local). Autor: arturm
enum PlaylistStore {

    static let key = "playlists"

    struct Playlist: Identifiable, Codable, Hashable {
        let id: String
        var name: String
        var tracks: [Track]
    }

    static var all: [Playlist] {
        guard let raw = Prefs.shared.string(key), let d = raw.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([Playlist].self, from: d)) ?? []
    }

    static func get(_ id: String) -> Playlist? { all.first { $0.id == id } }

    @discardableResult
    static func create(_ name: String) -> Playlist {
        let n = name.trimmingCharacters(in: .whitespaces)
        let p = Playlist(id: String(UUID().uuidString.lowercased().prefix(8)), name: n.isEmpty ? "Playlist" : n, tracks: [])
        save(all + [p])
        return p
    }

    static func rename(_ id: String, _ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        update(id) { if !n.isEmpty { $0.name = n } }
    }

    static func delete(_ id: String) { save(all.filter { $0.id != id }) }

    /// Adaugă la final; false dacă piesa era deja în playlist.
    @discardableResult
    static func addTrack(_ id: String, _ t: Track) -> Bool {
        var added = false
        update(id) { p in
            if !p.tracks.contains(where: { $0.id == t.id }) { p.tracks.append(t); added = true }
        }
        return added
    }

    static func remove(_ id: String, at offsets: IndexSet) {
        update(id) { $0.tracks.remove(atOffsets: offsets) }
    }

    static func move(_ id: String, from: IndexSet, to: Int) {
        update(id) { $0.tracks.move(fromOffsets: from, toOffset: to) }
    }

    private static func update(_ id: String, _ change: (inout Playlist) -> Void) {
        var list = all
        guard let i = list.firstIndex(where: { $0.id == id }) else { return }
        change(&list[i])
        save(list)
    }

    private static func save(_ list: [Playlist]) {
        guard let d = try? JSONEncoder().encode(list) else { return }
        Prefs.shared.set(key, string: String(decoding: d, as: UTF8.self))
    }
}
