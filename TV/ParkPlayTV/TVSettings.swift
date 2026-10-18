import SwiftUI

/// SETĂRI: redare, sincronizare cu telefonul / Mac-ul, diagnostic, testul 4K. Autor: arturm
struct TVSettingsView: View {
    @ObservedObject private var engine = TVEngine.shared
    @ObservedObject private var sync = TVSync.shared

    var body: some View {
        NavigationStack {
            List {
                Section("Redare") {
                    Picker("Calitate la pornire", selection: $engine.quality) {
                        ForEach(TVEngine.startQualities.filter { engine.playerMode == .native || !$0.0.hasPrefix("vlc") }, id: \.0) { q in Text(q.1).tag(q.0) }
                    }
                    Picker("Viteză", selection: $engine.rate) {
                        ForEach([0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { r in
                            Text((r == r.rounded() ? String(Int(r)) : String(r)) + "×").tag(r)
                        }
                    }
                    Toggle("Autoplay: continuă cu video-uri asemănătoare", isOn: $engine.autoplay)
                    Toggle("SponsorBlock: sari peste intro, reclame citite", isOn: $engine.sponsorBlock)
                    Text("Video-ul îl ia player-ul YouTube din pagină (cu contul tău), iar aplicația îl redă cu player-ul Apple: până la 1080p, decodare hardware, fără reclame. Dacă un video nu pornește așa, aplicația trece singură pe varianta simplă (360p).")
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
