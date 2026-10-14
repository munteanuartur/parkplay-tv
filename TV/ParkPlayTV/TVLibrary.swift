import SwiftUI

/// BIBLIOTECĂ: Favorite, Istoric, În redare, Playlisturi, Wrapped — aceleași date ca pe Mac și
/// pe Android (le aduci prin Setări → Sincronizare). Autor: arturm
struct TVLibraryView: View {
    @ObservedObject private var prefs = Prefs.shared
    @ObservedObject private var engine = TVEngine.shared

    var body: some View {
        let favs = Library.favorites
        let hist = Library.history
        let lists = PlaylistStore.all
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 40) {
                    Text("Bibliotecă").font(.title.bold())
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 380), spacing: 40)], spacing: 40) {
                        entry("❤", "Favorite", nTracks(favs.count), favs.first) { TVTrackListView(kind: .favorites) }
                        entry("🕘", "Istoric", nTracks(hist.count), hist.first) { TVTrackListView(kind: .history) }
                        entry("▶", "În redare", nTracks(engine.queue.count), engine.current) { TVTrackListView(kind: .queue) }
                        entry("🎉", "ParkPlay Wrapped", "Statisticile tale", nil) { TVWrappedView() }
                    }
                    .focusSection()

                    HStack(spacing: 30) {
                        Text("Playlisturi").font(.title3.bold())
                        Button { TVPlaylistsModel.shared.askNew = true } label: { Label("Playlist nou", systemImage: "plus") }
                    }
                    if lists.isEmpty {
                        Text("Încă nu ai playlisturi. Ține apăsat pe orice video → Adaugă în playlist, sau importă backup-ul de pe telefon / Mac din Setări → Sincronizare.")
                            .foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 380), spacing: 40)], spacing: 40) {
                        ForEach(lists) { p in
                            entry("🎵", p.name, nTracks(p.tracks.count), p.tracks.first) { TVPlaylistView(playlistId: p.id) }
                        }
                    }
                    .focusSection()
                }
                .padding(60)
            }
            .alert("Playlist nou", isPresented: $playlists.askNew) {
                TextField("Numele playlistului", text: $playlists.name)
                Button("Creează") {
                    let n = playlists.name.trimmingCharacters(in: .whitespaces)
                    if !n.isEmpty { PlaylistStore.create(n) }
                    playlists.name = ""
                }
                Button("Anulează", role: .cancel) { playlists.name = "" }
            }
        }
    }

    @ObservedObject private var playlists = TVPlaylistsModel.shared

    private func entry<D: View>(_ icon: String, _ title: String, _ sub: String, _ thumb: Track?,
                                @ViewBuilder destination: @escaping () -> D) -> some View {
        NavigationLink(destination: destination) {
            ZStack(alignment: .bottomLeading) {
                if let thumb {
                    AsyncImage(url: thumb.bigThumbnailURL) { p in
                        if let i = p.image { i.resizable().scaledToFill().opacity(0.45) } else { Color(white: 0.15) }
                    }
                } else {
                    Color(white: 0.15)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(icon + "  " + title).font(.headline).lineLimit(1)
                    Text(sub).font(.caption).foregroundStyle(.secondary)
                }
                .padding(20)
            }
            .frame(width: 380, height: 214)
            .clipped()
        }
        .buttonStyle(.card)
    }
}

/// Dialogul „Playlist nou” din Bibliotecă.
@MainActor
final class TVPlaylistsModel: ObservableObject {
    static let shared = TVPlaylistsModel()
    @Published var askNew = false
    @Published var name = ""
}

func nTracks(_ n: Int) -> String {
    if n == 1 { return "1 video" }
    let r = n % 100
    if n == 0 || (r >= 1 && r <= 19) { return "\(n) video-uri" }
    return "\(n) de video-uri"
}

/// Favorite / Istoric / În redare.
struct TVTrackListView: View {
    enum Kind { case favorites, history, queue }
    let kind: Kind
    @ObservedObject private var prefs = Prefs.shared
    @ObservedObject private var engine = TVEngine.shared

    var body: some View {
        let tracks: [Track] = {
            switch kind {
            case .favorites: return Library.favorites
            case .history: return Library.history
            case .queue: return engine.queue
            }
        }()
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                HStack(spacing: 30) {
                    Text(kind == .favorites ? "Favorite" : kind == .history ? "Istoric" : "În redare").font(.title.bold())
                    if !tracks.isEmpty && kind != .queue {
                        Button { TVAppState.shared.play(tracks, 0) } label: { Label("Redă", systemImage: "play.fill") }
                        Button { TVAppState.shared.play(tracks.shuffled(), 0) } label: { Label("Amestecă", systemImage: "shuffle") }
                    }
                    if kind == .history && !tracks.isEmpty {
                        Button(role: .destructive) { Library.clearHistory() } label: { Label("Golește", systemImage: "trash") }
                    }
                }
                .focusSection()
                if tracks.isEmpty {
                    Text(kind == .favorites ? "Încă nu ai favorite. Ține apăsat pe un video → Adaugă la favorite."
                         : kind == .history ? "Încă n-ai vizionat nimic." : "Nu rulează nimic.")
                        .foregroundStyle(.secondary)
                }
                if kind == .queue {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 380), spacing: 50)], spacing: 60) {
                        ForEach(Array(tracks.enumerated()), id: \.offset) { i, t in
                            TVCard(track: t, width: 380) {
                                engine.playIndex(i)
                                TVAppState.shared.playerOpen = true
                            }
                        }
                    }
                } else if kind == .favorites {
                    TVGrid(tracks: tracks, removeTitle: "Scoate din favorite") { i in Library.removeFavorite(tracks[i].id) }
                } else {
                    TVGrid(tracks: tracks)
                }
            }
            .padding(60)
        }
    }
}

/// Un playlist: Redă, Amestecă, Redenumește, Șterge; video-urile se scot ținând apăsat.
struct TVPlaylistView: View {
    let playlistId: String
    @ObservedObject private var prefs = Prefs.shared
    @Environment(\.dismiss) private var dismiss
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmDelete = false

    var body: some View {
        if let p = PlaylistStore.get(playlistId) {
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    Text(p.name).font(.title.bold())
                    Text(nTracks(p.tracks.count)).foregroundStyle(.secondary)
                    HStack(spacing: 30) {
                        if !p.tracks.isEmpty {
                            Button { TVAppState.shared.play(p.tracks, 0) } label: { Label("Redă", systemImage: "play.fill") }
                            Button { TVAppState.shared.play(p.tracks.shuffled(), 0) } label: { Label("Amestecă", systemImage: "shuffle") }
                        }
                        Button { newName = p.name; renaming = true } label: { Label("Redenumește", systemImage: "pencil") }
                        Button(role: .destructive) { confirmDelete = true } label: { Label("Șterge", systemImage: "trash") }
                    }
                    .focusSection()
                    if p.tracks.isEmpty {
                        Text("Playlistul e gol. Ține apăsat pe orice video → Adaugă în playlist.").foregroundStyle(.secondary)
                    }
                    TVGrid(tracks: p.tracks, removeTitle: "Scoate din playlist") { i in
                        PlaylistStore.remove(p.id, at: IndexSet(integer: i))
                    }
                }
                .padding(60)
            }
            .alert("Redenumește", isPresented: $renaming) {
                TextField("Numele playlistului", text: $newName)
                Button("OK") { PlaylistStore.rename(p.id, newName) }
                Button("Anulează", role: .cancel) {}
            }
            .confirmationDialog("Ștergi playlistul „\(p.name)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Șterge", role: .destructive) { PlaylistStore.delete(p.id); dismiss() }
            }
        } else {
            Text("Playlistul nu mai există.").foregroundStyle(.secondary)
        }
    }
}

/// ParkPlay Wrapped (simplu): cât ai vizionat, artiștii și video-urile de top, ora preferată.
struct TVWrappedView: View {
    @State private var monthOnly = true

    var body: some View {
        let s = StatsStore.summary(monthOnly: monthOnly)
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                HStack(spacing: 30) {
                    Text("🎉 ParkPlay Wrapped").font(.title.bold())
                    Button(monthOnly ? "• Luna aceasta" : "Luna aceasta") { monthOnly = true }
                    Button(!monthOnly ? "• Tot timpul" : "Tot timpul") { monthOnly = false }
                }
                .focusSection()
                if s.seconds < 60 {
                    Text("Încă nu ai vizionat destul. Revino după câteva video-uri.").foregroundStyle(.secondary)
                } else {
                    let m = Int(s.seconds / 60)
                    card(.pink) {
                        Text(monthOnly ? "Luna aceasta ai vizionat" : "Până acum ai vizionat")
                        Text("\(m) minute").font(.system(size: 80, weight: .bold))
                        Text("adică \(m / 60) h \(m % 60) min · ultimele 7 zile: \(Int(s.weekSeconds / 60)) min")
                    }
                    if !s.topArtists.isEmpty {
                        card(.teal) {
                            Text("Artiștii tăi de top").font(.headline)
                            ForEach(Array(s.topArtists.enumerated()), id: \.offset) { i, a in
                                Text("\(i + 1).  \(a.0) — \(Int(a.1 / 60)) min")
                            }
                        }
                    }
                    if !s.topTracks.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 30) {
                                Text("Video-urile tale de top").font(.title3.bold())
                                Button { TVAppState.shared.play(s.topTracks.map(\.0), 0) } label: { Label("Redă topul", systemImage: "play.fill") }
                            }
                            TVShelf(title: "", tracks: s.topTracks.map(\.0))
                        }
                    }
                    card(.indigo) {
                        Text("Ora ta preferată")
                        Text(String(format: "%02d:00", s.topHour)).font(.system(size: 70, weight: .bold))
                        Text("\(s.distinctTracks) video-uri diferite · \(s.plays) porniri · \(s.daysActive) zile")
                    }
                }
            }
            .padding(60)
        }
    }

    private func card<C: View>(_ color: Color, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) { c() }
            .padding(40)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LinearGradient(colors: [color, color.opacity(0.4)], startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 30))
    }
}
