import SwiftUI
import UIKit
import AVFoundation

/// Locul paginii YouTube (WKWebView-ul) în interfață.
struct WebHost: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let box = UIView()
        box.backgroundColor = .black
        box.isUserInteractionEnabled = false
        if let wv = TVEngine.shared.web?.view {
            wv.removeFromSuperview()
            wv.frame = box.bounds
            box.addSubview(wv)
        }
        return box
    }
    func updateUIView(_ v: UIView, context: Context) {
        if let wv = TVEngine.shared.web?.view, wv.superview !== v {
            wv.removeFromSuperview()
            wv.frame = v.bounds
            v.addSubview(wv)
        }
    }
}

/// Imaginea player-ului nativ (AVPlayer) — în locul paginii YouTube.
struct NativeHost: UIViewRepresentable {
    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
    func makeUIView(context: Context) -> PlayerView {
        let v = PlayerView()
        v.backgroundColor = .black
        v.isUserInteractionEnabled = false
        v.playerLayer.videoGravity = .resizeAspect
        v.playerLayer.player = TVEngine.shared.avPlayer
        return v
    }
    func updateUIView(_ v: PlayerView, context: Context) {}
}

/// Suprafața VLC (peste 1080p) — aceeași de fiecare dată, mutată aici când se deschide player-ul.
struct VLCHost: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let box = UIView()
        box.backgroundColor = .black
        box.isUserInteractionEnabled = false
        #if canImport(TVVLCKit)
        let v = TVEngine.shared.vlcView
        v.removeFromSuperview()
        v.frame = box.bounds
        box.addSubview(v)
        #endif
        return box
    }
    func updateUIView(_ box: UIView, context: Context) {
        #if canImport(TVVLCKit)
        let v = TVEngine.shared.vlcView
        if v.superview !== box { v.removeFromSuperview(); v.frame = box.bounds; box.addSubview(v) }
        #endif
    }
}

/// Player-ul pe tot ecranul, comandat cu telecomanda Siri:
///  ⏯ = redă / pauză · stânga / dreapta (cu controalele ascunse) = ∓10 s ·
///  click / sus / jos = arată controalele · Menu / Înapoi = ascunde controalele, apoi închide.
/// Autor: arturm
struct TVPlayerView: View {
    @ObservedObject private var engine = TVEngine.shared
    @ObservedObject private var diag = TVEngine.shared.diag
    @Environment(\.dismiss) private var dismiss

    @State private var osd = true
    @State private var showDiag = false
    @State private var showQueue = false
    @ObservedObject private var prefs = Prefs.shared
    @ObservedObject private var app = TVAppState.shared
    @State private var hideTask: Task<Void, Never>?
    @State private var flash: String?
    @FocusState private var focus: Field?

    enum Field: Hashable { case surface, play, scrub }

    // Derularea pe bara de timp (ca pe YouTube)
    @State private var scrubPreview: Double?
    @State private var scrubSpeed = 0
    @State private var lastScrubAt = Date.distantPast
    @State private var scrubTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if engine.useVLC { VLCHost().ignoresSafeArea() }
            else if engine.nativeActive { NativeHost().ignoresSafeArea() }
            else {
                WebHost().ignoresSafeArea()
                // Experimentul MediaSource fals: imaginea vine din redarea nativă, peste pagină.
                if FakeMSE.enabled && !engine.mseFallback { MSEHost().ignoresSafeArea() }
            }

            if engine.wantPlay && (engine.buffering || engine.extending) && !engine.playing {
                ProgressView().scaleEffect(1.6)
            }
            if engine.inAd {
                Text("Reclamă blocată — se sare…")
                    .padding(.horizontal, 20).padding(.vertical, 10)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(60)
            }
            if let flash {
                Text(flash).font(.title.bold())
                    .padding(.horizontal, 30).padding(.vertical, 16)
                    .background(.black.opacity(0.5), in: Capsule())
            }
            if showDiag {
                LiveStats()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(60)
                    .allowsHitTesting(false)
            }

            if showQueue && osd {
                QueuePanel { showQueue = false }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .transition(.move(edge: .trailing))
            }
            if osd {
                controls.transition(.opacity)
            } else {
                // Suprafață invizibilă care primește telecomanda cât controalele sunt ascunse.
                Button { showOSD() } label: { Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity) }
                    .buttonStyle(InvisibleButtonStyle())
                    .focused($focus, equals: .surface)
                    .onMoveCommand { dir in
                        switch dir {
                        case .left: engine.seek(by: -10); showFlash("⏪  10 s")
                        case .right: engine.seek(by: 10); showFlash("10 s  ⏩")
                        default: showOSD()
                        }
                    }
            }
        }
        .onPlayPauseCommand { engine.toggle(); showOSD() }
        .onExitCommand {
            if scrubPreview != nil {
                cancelScrub()
            } else if showQueue {
                showQueue = false
            } else if osd && engine.playing {
                hideOSD()
            } else {
                engine.pause()
                dismiss()
            }
        }
        .onAppear { showOSD() }
        .onChange(of: engine.playing) { _, p in if p { scheduleHide() } else { showOSD() } }
        .onChange(of: focus) { _, _ in if osd { scheduleHide() } }
        .alert("Playlist nou", isPresented: Binding(get: { app.newPlaylistFor != nil }, set: { if !$0 { app.newPlaylistFor = nil } })) {
            TextField("Numele playlistului", text: $app.newPlaylistName)
            Button("Creează") { app.createPlaylist() }
            Button("Anulează", role: .cancel) { app.newPlaylistFor = nil }
        }
        .overlay(alignment: .top) {
            if let t = app.toastText {
                Text(t).font(.callout.bold())
                    .padding(.horizontal, 30).padding(.vertical, 16)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 50)
            }
        }
    }

    // MARK: Controale

    private var controls: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer()
            Text(engine.current?.title ?? "").font(.title2.bold()).lineLimit(2)
            Text(engine.current?.channel ?? "").font(.callout).foregroundStyle(.secondary)
            // Bara de timp: focus pe ea + stânga / dreapta = derulare cu previzualizare
            Button { commitScrub() } label: {
                ScrubBar(clock: engine.clock, storyboard: engine.storyboard, preview: scrubPreview, focused: focus == .scrub)
            }
            .buttonStyle(InvisibleButtonStyle())
            .focused($focus, equals: .scrub)
            .onMoveCommand { dir in
                if dir == .left { scrub(-1) }
                if dir == .right { scrub(1) }
            }
            HStack {
                TVTimeText(clock: engine.clock)
                Spacer()
                Text(qualityText).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 28) {
                Button { engine.previous() } label: { Image(systemName: "backward.end.fill") }
                Button { engine.toggle() } label: {
                    Image(systemName: engine.wantPlay ? "pause.fill" : "play.fill").frame(width: 40)
                }
                .focused($focus, equals: .play)
                Button { engine.next() } label: { Image(systemName: "forward.end.fill") }

                Button { if let t = engine.current { TVAppState.shared.toggleFavorite(t) } } label: {
                    Image(systemName: Library.isFavorite(engine.current?.id) ? "heart.fill" : "heart")
                }
                Menu {
                    Button("＋ Playlist nou…") {
                        if let t = engine.current { TVAppState.shared.newPlaylistName = ""; TVAppState.shared.newPlaylistFor = t }
                    }
                    ForEach(PlaylistStore.all) { p in
                        Button(p.name) { if let t = engine.current { TVAppState.shared.add(t, to: p) } }
                    }
                } label: { Image(systemName: "text.badge.plus") }

                // Subtitrări (le desenează playerul YouTube; traducere automată inclusă)
                Menu {
                    Button { engine.captionChoice = "off" } label: {
                        CheckLabel(title: "Fără subtitrări", on: engine.captionChoice == "off")
                    }
                    if engine.captionTracks.isEmpty {
                        Text("Video-ul n-are subtitrări")
                    }
                    ForEach(engine.captionTracks) { t in
                        Button { engine.captionChoice = t.code } label: {
                            CheckLabel(title: t.name + (t.auto ? " (automate)" : ""), on: engine.captionChoice == t.code)
                        }
                    }
                    if !engine.captionTracks.isEmpty {
                        Section("Traducere automată") {
                            ForEach([("ro", "Română"), ("en", "English"), ("ru", "Русский")], id: \.0) { l in
                                Button { engine.captionChoice = "tr:" + l.0 } label: {
                                    CheckLabel(title: "→ " + l.1, on: engine.captionChoice == "tr:" + l.0)
                                }
                            }
                        }
                    }
                    Section("Mărime") {
                        ForEach([(0.8, "Mică"), (1.0, "Normală"), (1.3, "Mare"), (1.7, "Foarte mare")], id: \.0) { z in
                            Button { engine.captionSize = z.0 } label: {
                                CheckLabel(title: z.1, on: engine.captionSize == z.0)
                            }
                        }
                    }
                } label: {
                    Image(systemName: engine.captionChoice == "off" ? "captions.bubble" : "captions.bubble.fill")
                }
                Menu {
                    ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { r in
                        Button((r == r.rounded() ? String(Int(r)) : String(r)) + "×") { engine.rate = r }
                    }
                } label: {
                    Text("Viteză: " + (engine.rate == engine.rate.rounded() ? String(Int(engine.rate)) : String(engine.rate)) + "×")
                }
                // Calitatea pentru video-ul curent (H.264 cu AVPlayer; peste 1080p VP9 cu VLC).
                Menu {
                    if engine.choices.isEmpty {
                        Text(engine.nativeActive ? "Se încarcă…" : "Pe pagina YouTube calitatea o alege YouTube")
                    }
                    ForEach(engine.choices) { c in
                        Button { engine.selectChoice(c.id) } label: {
                            CheckLabel(title: c.label, on: engine.currentChoice == c.id)
                        }
                    }
                } label: {
                    Text(engine.choices.first { $0.id == engine.currentChoice }.map { "\($0.height)p" + ($0.vlc ? " VLC" : "") } ?? "Calitate")
                }
                // Radio: după video-ul curent urmează la nesfârșit video-uri asemănătoare.
                Button { engine.startRadio(); scheduleHide() } label: {
                    if engine.radioLoading { ProgressView() } else { Image(systemName: "dot.radiowaves.left.and.right") }
                }
                Button { showQueue.toggle(); hideTask?.cancel() } label: { Image(systemName: "list.bullet") }
                Button { showDiag.toggle() } label: {
                    Image(systemName: showDiag ? "stethoscope.circle.fill" : "stethoscope")
                }
            }
            .font(.body)
        }
        .padding(60)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom)
                .ignoresSafeArea()
        )
    }

    private var qualityText: String {
        // Rezoluția reală a video-ului (din panoul de statistici), ex. „1920×1080” → „1080p”.
        let parts = diag.videoSize.split(separator: "×")
        let player = engine.useVLC ? "VLC" : (engine.nativeActive ? "AVPlayer" : "YouTube")
        if parts.count == 2, let h = Int(parts[1]), h > 0 { return "\(player) · \(h)p" }
        return player
    }

    private func showOSD() {
        withAnimation(.easeOut(duration: 0.2)) { osd = true }
        DispatchQueue.main.async { if focus == nil || focus == .surface { focus = .scrub } }
        scheduleHide()
    }

    private func hideOSD() {
        hideTask?.cancel()
        withAnimation(.easeIn(duration: 0.25)) { osd = false }
        DispatchQueue.main.async { focus = .surface }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        if showQueue || scrubPreview != nil { return }
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if !Task.isCancelled && engine.playing && scrubPreview == nil { hideOSD() }
        }
    }

    // MARK: Derulare

    /// Stânga / dreapta pe bară: mută previzualizarea; apăsări rapide = salturi tot mai mari.
    private func scrub(_ dir: Double) {
        let now = Date()
        scrubSpeed = now.timeIntervalSince(lastScrubAt) < 0.45 ? min(scrubSpeed + 1, 5) : 0
        lastScrubAt = now
        let steps: [Double] = [10, 10, 20, 30, 60, 120]
        let dur = engine.clock.duration
        let base = scrubPreview ?? engine.clock.position
        var v = base + dir * steps[scrubSpeed]
        v = max(0, dur > 0 ? min(v, dur - 1) : v)
        scrubPreview = v
        hideTask?.cancel()
        // Confirmă singur după o clipă fără apăsări (ca pe Apple TV / YouTube).
        scrubTask?.cancel()
        scrubTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            if !Task.isCancelled { commitScrub() }
        }
    }

    private func commitScrub() {
        scrubTask?.cancel()
        if let p = scrubPreview {
            engine.seek(to: p)
            scrubPreview = nil
            scheduleHide()
        } else {
            engine.toggle()
        }
    }

    private func cancelScrub() {
        scrubTask?.cancel()
        scrubPreview = nil
        scheduleHide()
    }

    private func showFlash(_ text: String) {
        withAnimation { flash = text }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            if flash == text { withAnimation { flash = nil } }
        }
    }
}

/// Buton fără niciun efect vizual (pentru suprafața care primește telecomanda).
struct InvisibleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}

struct TVProgress: View {
    @ObservedObject var clock: TVClock

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { g in
                let f = clock.duration > 0 ? min(max(clock.position / clock.duration, 0), 1) : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.25))
                    Capsule().fill(Color(red: 244 / 255, green: 114 / 255, blue: 182 / 255)).frame(width: g.size.width * f)
                }
            }
            .frame(height: 8)
            Text(fmt(clock.position) + (clock.duration > 0 ? " / " + fmt(clock.duration) : ""))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private func fmt(_ s: Double) -> String {
        let t = Int(max(0, s.isFinite ? s : 0))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, (t / 60) % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }
}

/// Panoul peste video: FPS, trafic, cadre pierdute, buffer, rezoluție, codec, reclame sărite.
struct LiveStats: View {
    @ObservedObject private var d = TVEngine.shared.diag
    @ObservedObject private var e = TVEngine.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            row("FPS", String(format: "%.1f", d.fps))
            row("Trafic", d.kbps >= 1000 ? String(format: "%.1f Mbit/s", d.kbps / 1000) : String(format: "%.0f kbit/s", d.kbps))
            if !d.connection.isEmpty { row("Conexiune", d.connection) }
            row("Cadre pierdute", "\(d.dropped) / \(d.frames)")
            row("Buffer", String(format: "%.1f s", d.buffer))
            row("Video", d.videoSize)
            row("Calitate", TVEngine.label(e.currentQuality.isEmpty ? "—" : e.currentQuality))
            if e.nativeActive {
                if !e.netError.isEmpty { row("Eroare rețea", e.netError) }
            } else {
                row("Reclame sărite", "\(d.adsSkipped)")
            }
            if !d.lastEvent.isEmpty { Text(d.lastEvent).foregroundStyle(.secondary).lineLimit(3) }
            if !d.codecs.isEmpty { Text(d.codecs).foregroundStyle(.secondary).lineLimit(2) }
        }
        .font(.system(size: 24, design: .monospaced))
        .padding(24)
        .frame(width: 620, alignment: .leading)
        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 16))
    }

    private func row(_ l: String, _ v: String) -> some View {
        HStack { Text(l).foregroundStyle(.secondary); Spacer(); Text(v) }
    }
}

// MARK: - Diagnostic (tab)

/// Ce poate WebKit-ul de pe acest Apple TV + setări de test (site, calitate, SponsorBlock, Autoplay).
struct DiagnosticsView: View {
    @ObservedObject private var engine = TVEngine.shared
    @ObservedObject private var d = TVEngine.shared.diag

    /// Video de test 4K (natură, fără muzică).
    private let testVideo = Track(id: "LXb3EKWsInQ", title: "Test 4K — COSTA RICA IN 4K 60fps HDR", channel: "Jacob + Katie Schwarz", duration: "")

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                Text("Diagnostic").font(.title.bold())
                group("WebKit") {
                    line("Stare", d.webKit)
                    line("Filtru de reclame", d.adRules)
                    line("Ultimul eveniment", d.lastEvent.isEmpty ? "—" : d.lastEvent)
                }
                // Experimentul MediaSource fals: sus, ca să se vadă fără derulare.
                let mse = d.page.keys.filter { $0.hasPrefix("MSE fals") }.sorted()
                if !mse.isEmpty {
                    group("Redare 1080p (MediaSource fals)") {
                        ForEach(mse, id: \.self) { k in line(String(k.dropFirst("MSE fals: ".count)), d.page[k] ?? "") }
                    }
                }
                group("Pagina YouTube (după ce pornești un video)") {
                    if d.page.isEmpty {
                        Text("Pornește un video, apoi apasă „Verifică din nou”.").foregroundStyle(.secondary)
                    }
                    ForEach(d.page.keys.filter { !$0.hasPrefix("MSE fals") }.sorted(), id: \.self) { k in line(k, d.page[k] ?? "") }
                }
                HStack(spacing: 30) {
                    Button("▶  Video de test 4K") { TVAppState.shared.play([testVideo], 0) }
                    Button("Verifică din nou") { engine.runDiagnostics() }
                }
                group("Setări de test") {
                    Picker("Site", selection: $engine.siteMode) {
                        ForEach(TVEngine.SiteMode.allCases) { m in Text(m.title).tag(m) }
                    }
                    Picker("Player", selection: $engine.playerMode) {
                        ForEach(TVEngine.PlayerMode.allCases) { m in Text(m.title).tag(m) }
                    }
                    Toggle("SponsorBlock (sare peste intro, reclame citite)", isOn: $engine.sponsorBlock)
                    Toggle("Autoplay (continuă cu video-uri asemănătoare)", isOn: $engine.autoplay)
                }
                group("Teste vechi (clientul iOS al YouTube — limitat / blocat)") {
                    NavigationLink("Test AVPlayer — redare nativă 1080p (H.264)") { HLSTestView() }
                    NavigationLink("Test 4K — redare nativă cu VLC") { Native4KTestView() }
                }
                Text("ParkPlay TV · autor: arturm").font(.caption).foregroundStyle(.secondary)
            }
            .padding(60)
        }
    }

    private func group<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            content()
        }
        .padding(30)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 20))
        .focusSection()
    }

    private func line(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k).foregroundStyle(.secondary).frame(width: 420, alignment: .leading)
            Text(v).lineLimit(8)
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusable()   // ca telecomanda să poată derula și peste rândurile de text
    }
}

/// „Urmează”: lista curentă în dreapta ecranului (alegi alt video cu telecomanda).
struct QueuePanel: View {
    let close: () -> Void
    @ObservedObject private var engine = TVEngine.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Urmează").font(.title3.bold())
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(engine.queue.enumerated()), id: \.offset) { i, t in
                            Button {
                                engine.playIndex(i)
                                close()
                            } label: {
                                HStack(spacing: 16) {
                                    AsyncImage(url: t.thumbnailURL) { p in
                                        if let img = p.image { img.resizable().scaledToFill() } else { Color(white: 0.2) }
                                    }
                                    .frame(width: 160, height: 90).clipped()
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text((i == engine.index ? "▶ " : "") + t.title).font(.callout).lineLimit(2)
                                        Text(t.channel).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                }
                            }
                            .id(i)
                        }
                        if engine.extending { Text("Caut video-uri asemănătoare…").foregroundStyle(.secondary) }
                        else if engine.autoplay && engine.index == engine.queue.count - 1 {
                            Text("Autoplay: la final urmează video-uri asemănătoare").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 20)
                }
                .onAppear { proxy.scrollTo(max(engine.index, 0), anchor: .top) }
            }
        }
        .padding(40)
        .frame(width: 700)
        .frame(maxHeight: .infinity)
        .background(.ultraThinMaterial)
        .focusSection()
    }
}

/// „1:23 / 4:56”
struct TVTimeText: View {
    @ObservedObject var clock: TVClock
    var body: some View {
        Text(TVTime.fmt(clock.position) + (clock.duration > 0 ? " / " + TVTime.fmt(clock.duration) : ""))
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
    }
}

/// Rând de meniu cu bifă când e ales.
struct CheckLabel: View {
    let title: String
    let on: Bool
    var body: some View {
        if on { Label(title, systemImage: "checkmark") } else { Text(title) }
    }
}
