import SwiftUI

/// SETĂRI: redare, sincronizare cu telefonul / Mac-ul, diagnostic, testul 4K. Autor: arturm
struct TVSettingsView: View {
    @ObservedObject private var engine = TVEngine.shared
    @ObservedObject private var sync = TVSync.shared

    var body: some View {
        NavigationStack {
            List {
                Section("Redare") {
                    Picker("Player", selection: $engine.playerMode) {
                        ForEach(TVEngine.PlayerMode.allCases) { m in Text(m.title).tag(m) }
                    }
                    Picker("Calitate la pornire", selection: $engine.quality) {
                        ForEach(TVEngine.startQualities, id: \.0) { q in Text(q.1).tag(q.0) }
                    }
                    Picker("Viteză", selection: $engine.rate) {
                        ForEach([0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { r in
                            Text((r == r.rounded() ? String(Int(r)) : String(r)) + "×").tag(r)
                        }
                    }
                    Toggle("Autoplay: continuă cu video-uri asemănătoare", isOn: $engine.autoplay)
                    Toggle("SponsorBlock: sari peste intro, reclame citite", isOn: $engine.sponsorBlock)
                    Text("Nativ: video-ul vine direct de la YouTube, fără reclame. Până la 1080p îl redă player-ul Apple (fluid, decodare hardware); peste 1080p doar VLC, care pe Apple TV ține fluid 4K la 30 fps, dar nu și la 60 fps. În player poți schimba calitatea pentru fiecare video. Dacă un video nu merge nativ, aplicația trece singură pe pagina YouTube. Subtitrările merg deocamdată doar pe pagina YouTube.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Sincronizare cu telefonul / Mac-ul") {
                    Toggle("Pagina de sincronizare (în rețeaua de acasă)", isOn: Binding(
                        get: { sync.running },
                        set: { $0 ? sync.start() : sync.stop() }))
                    if sync.running {
                        Text("Deschide pe telefon sau pe Mac:").foregroundStyle(.secondary)
                        Text(sync.address).font(.title3.monospaced().bold())
                        Text("De acolo: importi backup-ul ParkPlay (favorite, playlisturi, istoric), descarci backup-ul de pe Apple TV sau trimiți un link YouTube care pornește pe televizor.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if !sync.lastAction.isEmpty { Text(sync.lastAction).foregroundStyle(.pink) }
                }

                Section("Cont YouTube") {
                    HStack {
                        Text("Stare")
                        Spacer()
                        Text(engine.signedIn ? "conectat" : "neconectat").foregroundStyle(engine.signedIn ? Color.green : Color.secondary)
                    }
                    Text("Dacă YouTube cere „Sign in to confirm you're not a bot”, pornește pagina de sincronizare și lipește acolo cookie-urile YouTube din browserul în care ești logat.")
                        .font(.caption).foregroundStyle(.secondary)
                    if engine.signedIn {
                        Button("Deconectează contul de pe Apple TV", role: .destructive) { engine.signOut() }
                    }
                    Button("Browser curat: șterge toate datele paginii YouTube", role: .destructive) { engine.clearBrowserData() }
                }

                Section("Avansat") {
                    NavigationLink("Diagnostic (WebKit, codecuri, site)") { DiagnosticsView() }
                    NavigationLink("Test AVPlayer — redare nativă 1080p (H.264)") { HLSTestView() }
                    NavigationLink("Test 4K — redare nativă cu VLC") { Native4KTestView() }
                }

                Section {
                    Text("ParkPlay TV · versiunea \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") · autor: arturm")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Setări")
        }
    }
}
