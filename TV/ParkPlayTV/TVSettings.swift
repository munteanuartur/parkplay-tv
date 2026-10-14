import SwiftUI

/// SETĂRI: redare, sincronizare cu telefonul / Mac-ul, diagnostic, testul 4K. Autor: arturm
struct TVSettingsView: View {
    @ObservedObject private var engine = TVEngine.shared
    @ObservedObject private var sync = TVSync.shared

    var body: some View {
        NavigationStack {
            List {
                Section("Redare") {
                    Picker("Viteză", selection: $engine.rate) {
                        ForEach([0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { r in
                            Text((r == r.rounded() ? String(Int(r)) : String(r)) + "×").tag(r)
                        }
                    }
                    Toggle("Autoplay: continuă cu video-uri asemănătoare", isOn: $engine.autoplay)
                    Toggle("SponsorBlock: sari peste intro, reclame citite", isOn: $engine.sponsorBlock)
                    Text("Calitatea e automată: YouTube trimite video-ul ca HLS, iar Apple TV alege singur calitatea (până la 1080p) după viteza rețelei.")
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

                Section("Avansat") {
                    NavigationLink("Diagnostic (WebKit, codecuri, site)") { DiagnosticsView() }
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
