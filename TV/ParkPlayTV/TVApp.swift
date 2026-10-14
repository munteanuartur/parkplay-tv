import SwiftUI

/// ParkPlay TV — YouTube fără reclame pe Apple TV, în stilul ParkPlay: Acasă, Caută,
/// Bibliotecă (favorite, istoric, playlisturi), Setări. Redarea: pagina m.youtube într-un
/// WKWebView (API privat, instalat din Xcode), cu aceleași scripturi ca versiunea de Mac.
/// Autor: arturm
@main
struct ParkPlayTVApp: App {
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
        }
        .onChange(of: phase) { _, p in
            switch p {
            case .active:
                TVEngine.shared.wake()
            case .background:
                // Ieșit din aplicație: oprim tot, ca Apple TV-ul să poată dormi.
                TVEngine.shared.suspend()
                TVSync.shared.stop()
                TVAppState.shared.playerOpen = false
            default:
                TVEngine.shared.saveAll()
            }
        }
    }
}

/// Starea interfeței: player-ul deschis, dialogul „Playlist nou”, mesaje scurte.
@MainActor
final class TVAppState: ObservableObject {
    static let shared = TVAppState()

    @Published var playerOpen = false
    @Published var toastText: String?
    /// Piesa pentru care se creează un playlist nou (dialog cu text).
    @Published var newPlaylistFor: Track?
    @Published var newPlaylistName = ""

    private var toastTask: Task<Void, Never>?

    func play(_ tracks: [Track], _ i: Int) {
        guard !tracks.isEmpty else { return }
        TVEngine.shared.playList(tracks, start: i)
        playerOpen = true
    }

    func toast(_ t: String) {
        toastTask?.cancel()
        withAnimation { toastText = t }
        toastTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if !Task.isCancelled { withAnimation { toastText = nil } }
        }
    }

    func toggleFavorite(_ t: Track) {
        toast(Library.toggleFavorite(t) ? "❤ Adăugat la favorite" : "Scos din favorite")
    }

    func add(_ t: Track, to p: PlaylistStore.Playlist) {
        toast(PlaylistStore.addTrack(p.id, t) ? "Adăugat în „\(p.name)”" : "Deja în „\(p.name)”")
    }

    func createPlaylist() {
        let name = newPlaylistName.trimmingCharacters(in: .whitespaces)
        guard let t = newPlaylistFor, !name.isEmpty else { return }
        let p = PlaylistStore.create(name)
        PlaylistStore.addTrack(p.id, t)
        toast("Adăugat în „\(p.name)”")
        newPlaylistFor = nil
        newPlaylistName = ""
    }

    nonisolated static func videoId(in text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil { return t }
        let regex = try? NSRegularExpression(pattern: "(?:v=|youtu\\.be/|shorts/|embed/|live/)([A-Za-z0-9_-]{11})")
        guard let m = regex?.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
              let g = Range(m.range(at: 1), in: t) else { return nil }
        return String(t[g])
    }
}

struct RootView: View {
    @ObservedObject private var app = TVAppState.shared

    var body: some View {
        TabView {
            TVHomeView().tabItem { Label("Acasă", systemImage: "house.fill") }
            TVSearchView().tabItem { Label("Caută", systemImage: "magnifyingglass") }
            TVLibraryView().tabItem { Label("Bibliotecă", systemImage: "books.vertical.fill") }
            TVSettingsView().tabItem { Label("Setări", systemImage: "gearshape.fill") }
        }
        .fullScreenCover(isPresented: $app.playerOpen) { TVPlayerView() }
        .alert("Playlist nou", isPresented: Binding(get: { app.newPlaylistFor != nil }, set: { if !$0 { app.newPlaylistFor = nil } })) {
            TextField("Numele playlistului", text: $app.newPlaylistName)
            Button("Creează") { app.createPlaylist() }
            Button("Anulează", role: .cancel) { app.newPlaylistFor = nil }
        }
        .overlay(alignment: .bottom) {
            if let t = app.toastText {
                Text(t).font(.callout.bold())
                    .padding(.horizontal, 30).padding(.vertical, 16)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 50)
                    .transition(.opacity)
            }
        }
    }
}

// MARK: - Bucăți comune

/// Meniul unei piese (ține apăsat pe card).
struct TVTrackMenu: View {
    let track: Track
    var removeTitle: String? = nil
    var onRemove: (() -> Void)? = nil

    var body: some View {
        let app = TVAppState.shared
        let e = TVEngine.shared
        Button { app.play([track], 0) } label: { Label("Redă acum", systemImage: "play.fill") }
        Button { e.playNext(track); app.toast("Urmează: \(track.title)") } label: { Label("Redă după acesta", systemImage: "text.insert") }
        Button { e.enqueue(track); app.toast("Adăugat la coadă") } label: { Label("Adaugă la coadă", systemImage: "text.append") }
        Button { app.toggleFavorite(track) } label: {
            Label(Library.isFavorite(track.id) ? "Scoate din favorite" : "Adaugă la favorite",
                  systemImage: Library.isFavorite(track.id) ? "heart.slash" : "heart")
        }
        Menu {
            Button("＋ Playlist nou…") { app.newPlaylistName = ""; app.newPlaylistFor = track }
            ForEach(PlaylistStore.all) { p in Button(p.name) { app.add(track, to: p) } }
        } label: { Label("Adaugă în playlist", systemImage: "music.note.list") }
        if let removeTitle, let onRemove {
            Button(role: .destructive, action: onRemove) { Label(removeTitle, systemImage: "trash") }
        }
    }
}

/// Raft orizontal cu carduri (focus cu telecomanda).
struct TVShelf: View {
    let title: String
    let tracks: [Track]
    var onPlay: ((Int) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title3.bold())
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 40) {
                    ForEach(Array(tracks.enumerated()), id: \.offset) { i, t in
                        TVCard(track: t) { (onPlay ?? { TVAppState.shared.play(tracks, $0) })(i) }
                    }
                }
                .padding(.vertical, 30)
            }
            .scrollClipDisabled()
        }
        .focusSection()
    }
}

struct TVCard: View {
    let track: Track
    var width: CGFloat = 400
    var removeTitle: String? = nil
    var onRemove: (() -> Void)? = nil
    let action: () -> Void
    @ObservedObject private var engine = TVEngine.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: action) {
                ZStack(alignment: .bottomTrailing) {
                    AsyncImage(url: track.bigThumbnailURL) { phase in
                        if let img = phase.image { img.resizable().scaledToFill() } else { Color(white: 0.15) }
                    }
                    .frame(width: width, height: width * 9 / 16)
                    .clipped()
                    if !track.duration.isEmpty {
                        Text(track.duration).font(.caption2.bold())
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 6))
                            .padding(10)
                    }
                    if let f = WatchPositions.fraction(track.id) {
                        // Cât ai văzut (ca pe YouTube)
                        GeometryReader { g in
                            VStack(spacing: 0) {
                                Spacer()
                                ZStack(alignment: .leading) {
                                    Rectangle().fill(.white.opacity(0.35))
                                    Rectangle().fill(Color(red: 1, green: 0, blue: 0.2)).frame(width: g.size.width * f)
                                }
                                .frame(height: 6)
                            }
                        }
                    }
                    if engine.current?.id == track.id {
                        Image(systemName: "waveform").font(.title3).padding(10)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                }
            }
            .buttonStyle(.card)
            .contextMenu { TVTrackMenu(track: track, removeTitle: removeTitle, onRemove: onRemove) }
            Text(track.title).font(.callout).lineLimit(2).frame(width: width, alignment: .leading)
            Text([track.channel, track.published].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                .frame(width: width, alignment: .leading)
        }
    }
}

/// Grilă de carduri (Favorite, Istoric, playlist, rezultate).
struct TVGrid: View {
    let tracks: [Track]
    var removeTitle: String? = nil
    var onRemove: ((Int) -> Void)? = nil

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 380), spacing: 50)], spacing: 60) {
            ForEach(Array(tracks.enumerated()), id: \.offset) { i, t in
                TVCard(track: t, width: 380, removeTitle: removeTitle,
                       onRemove: onRemove.map { f in { f(i) } }) {
                    TVAppState.shared.play(tracks, i)
                }
            }
        }
    }
}

// MARK: - Acasă

@MainActor
final class TVHomeModel: ObservableObject {
    static let shared = TVHomeModel()
    @Published var online: [String: [Track]] = [:]
    @Published var mixes: [DailyMix.Mix] = DailyMix.cached() ?? DailyMix.lastKnown()
    private var loadedAt: [String: Date] = [:]
    private var mixesTried = false

    func load(_ key: String, _ fetch: @escaping () async -> [Track]) {
        if let t = loadedAt[key], Date().timeIntervalSince(t) < 1800 { return }
        loadedAt[key] = Date()
        Task { @MainActor in online[key] = await fetch() }
    }

    func ensureMixes() {
        guard !mixesTried else { return }
        mixesTried = true
        if let c = DailyMix.cached() { mixes = c; return }
        Task { @MainActor in
            let m = await DailyMix.generate()
            if !m.isEmpty { mixes = m }
        }
    }
}

struct TVHomeView: View {
    @ObservedObject private var prefs = Prefs.shared
    @ObservedObject private var model = TVHomeModel.shared
    @ObservedObject private var engine = TVEngine.shared

    var body: some View {
        let favs = Library.favorites
        let hist = Library.history
        let seed = hist.first ?? favs.first
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 40) {
                    Text(greeting).font(.title.bold())
                    if !PPWebView.isAvailable() {
                        Text("⚠️ WebKit nu e disponibil pe acest Apple TV: \(PPWebView.availabilityInfo())").foregroundStyle(.orange)
                    }
                    if let cur = engine.current {
                        Button {
                            engine.resume()
                            TVAppState.shared.playerOpen = true
                        } label: {
                            Label("Continuă „\(cur.title)”" + (engine.clock.position > 15 ? " de la \(TVTime.fmt(engine.clock.position))" : ""),
                                  systemImage: "play.circle.fill").lineLimit(1)
                        }
                    }
                    if !hist.isEmpty { TVShelf(title: "Continuă să vizionezi", tracks: Array(hist.prefix(15))) }
                    if !model.mixes.isEmpty && favs.count + hist.count >= 3 {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Mixurile tale").font(.title3.bold())
                            ScrollView(.horizontal) {
                                LazyHStack(spacing: 40) {
                                    ForEach(model.mixes) { m in
                                        Button { TVAppState.shared.play(m.tracks, 0) } label: {
                                            ZStack(alignment: .bottomLeading) {
                                                AsyncImage(url: m.tracks.first?.bigThumbnailURL) { p in
                                                    if let i = p.image { i.resizable().scaledToFill().opacity(0.6) } else { Color.pink.opacity(0.4) }
                                                }
                                                .frame(width: 320, height: 320).clipped()
                                                VStack(alignment: .leading) {
                                                    Text(m.name).font(.title3.bold())
                                                    Text(m.subtitle).font(.caption).lineLimit(2)
                                                }
                                                .padding(20)
                                            }
                                        }
                                        .buttonStyle(.card)
                                    }
                                }
                                .padding(.vertical, 30)
                            }
                            .scrollClipDisabled()
                        }
                        .focusSection()
                    }
                    if let seed { onlineShelf("Pentru tine", "mix:" + seed.id) { await YouTubeSearch.mix(seed.id, limit: 20) } }
                    if favs.count > 2 { TVShelf(title: "Din favoritele tale", tracks: Array(favs.prefix(20))) }
                    onlineShelf("Hituri acum", "hits") { await YouTubeSearch.search("Top hits", limit: 20) }
                    onlineShelf("Noutăți", "new") { await YouTubeSearch.search("New hits", limit: 20) }
                    onlineShelf("Muzică românească", "ro") { await YouTubeSearch.search("muzica romaneasca hituri 2026", limit: 20) }
                    TVCategories()
                }
                .padding(.horizontal, 60)
            }
            .onAppear { if favs.count + hist.count >= 3 { model.ensureMixes() } }
        }
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5...11: return "Bună dimineața"
        case 12...17: return "Bună ziua"
        default: return "Bună seara"
        }
    }

    @ViewBuilder
    private func onlineShelf(_ title: String, _ key: String, _ fetch: @escaping () async -> [Track]) -> some View {
        if let t = model.online[key] {
            if !t.isEmpty { TVShelf(title: title, tracks: t) }
        } else {
            Text("\(title) — se încarcă…").foregroundStyle(.secondary)
                .onAppear { model.load(key, fetch) }
        }
    }
}

/// Categoriile (aceleași ca pe Mac și Android) → rezultate.
struct TVCategories: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Categorii").font(.title3.bold())
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 40)], spacing: 40) {
                ForEach(Categories.list) { c in
                    NavigationLink {
                        TVResultsView(title: c.label, query: c.query)
                    } label: {
                        Text(c.label).font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 120, alignment: .bottomLeading)
                            .padding(20)
                            .background(LinearGradient(colors: [c.color, c.color.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    }
                    .buttonStyle(.card)
                }
            }
            .padding(.vertical, 20)
        }
        .focusSection()
    }
}

/// Rezultatele unei căutări (categorie).
struct TVResultsView: View {
    let title: String
    let query: String
    @State private var tracks: [Track] = []
    @State private var loading = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                HStack(spacing: 30) {
                    Text(title).font(.title.bold())
                    if !tracks.isEmpty {
                        Button { TVAppState.shared.play(tracks, 0) } label: { Label("Redă", systemImage: "play.fill") }
                        Button { TVAppState.shared.play(tracks.shuffled(), 0) } label: { Label("Amestecă", systemImage: "shuffle") }
                    }
                }
                if loading { ProgressView() }
                TVGrid(tracks: tracks)
            }
            .padding(60)
        }
        .task {
            guard tracks.isEmpty else { return }
            tracks = await YouTubeSearch.search(query, limit: 40)
            loading = false
        }
    }
}

// MARK: - Caută

struct TVSearchView: View {
    @State private var query = ""
    @State private var results: [Track] = []
    @State private var status = ""
    @State private var task: Task<Void, Never>?
    @State private var filters = YouTubeSearch.Filters()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    ScrollView(.horizontal) {
                        HStack(spacing: 20) {
                            filterButton("Oricând", .init(upload: 0, sort: filters.sort))
                            filterButton("Azi", .init(upload: YouTubeSearch.uploadToday, sort: filters.sort))
                            filterButton("Săptămâna asta", .init(upload: YouTubeSearch.uploadWeek, sort: filters.sort))
                            filterButton("Luna asta", .init(upload: YouTubeSearch.uploadMonth, sort: filters.sort))
                            filterButton("Ultimul an", .init(upload: YouTubeSearch.uploadYear, sort: filters.sort))
                            filterButton("🕘 Cele mai noi", .init(upload: filters.upload, sort: filters.sort == YouTubeSearch.sortDate ? 0 : YouTubeSearch.sortDate, maxAgeDays: filters.maxAgeDays))
                            filterButton("🔥 Cele mai vizionate", .init(upload: filters.upload, sort: filters.sort == YouTubeSearch.sortViews ? 0 : YouTubeSearch.sortViews, maxAgeDays: filters.maxAgeDays))
                        }
                        .padding(.vertical, 20)
                    }
                    .scrollClipDisabled()
                    .focusSection()

                    if !status.isEmpty { Text(status).foregroundStyle(.secondary) }
                    if query.trimmingCharacters(in: .whitespaces).count < 2 {
                        let recents = Library.recentSearches
                        if !recents.isEmpty {
                            Text("Căutări recente").font(.title3.bold())
                            ScrollView(.horizontal) {
                                HStack(spacing: 20) {
                                    ForEach(recents.prefix(10), id: \.self) { q in Button(q) { query = q } }
                                }
                                .padding(.vertical, 20)
                            }
                            .scrollClipDisabled()
                            .focusSection()
                        }
                        TVCategories()
                    } else {
                        if !results.isEmpty {
                            HStack(spacing: 30) {
                                Button { Library.addRecentSearch(query); TVAppState.shared.play(results, 0) } label: { Label("Redă tot", systemImage: "play.fill") }
                                Button { TVAppState.shared.play(results.shuffled(), 0) } label: { Label("Amestecă", systemImage: "shuffle") }
                            }
                            .focusSection()
                        }
                        TVGrid(tracks: results)
                    }
                }
                .padding(.horizontal, 60)
            }
            .searchable(text: $query, prompt: "Artist, piesă, playlist…")
            .onChange(of: query) { _, q in search(q) }
        }
    }

    private func filterButton(_ title: String, _ f: YouTubeSearch.Filters) -> some View {
        let on = (f.sort == filters.sort && f.upload == filters.upload && f.maxAgeDays == filters.maxAgeDays)
        return Button {
            filters = f
            search(query)
        } label: {
            Text(title).fontWeight(on ? .bold : .regular).foregroundStyle(on ? Color.pink : Color.primary)
        }
    }

    private func search(_ q: String) {
        task?.cancel()
        let text = q.trimmingCharacters(in: .whitespaces)
        guard text.count >= 2 else { results = []; status = ""; return }
        let f = filters
        task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            status = "Caut „\(text)”…"
            let out = await YouTubeSearch.searchDetailed(text, limit: 40, filters: f)
            guard !Task.isCancelled else { return }
            results = out.tracks
            if !out.tracks.isEmpty { Library.addRecentSearch(text) }
            switch out.problem {
            case .none: status = ""
            case .network: status = "Fără internet sau YouTube nu răspunde"
            case .changed: status = "YouTube și-a schimbat pagina — căutarea trebuie actualizată"
            case .noResults: status = "Nu am găsit nimic pentru „\(text)”"
            }
        }
    }
}
