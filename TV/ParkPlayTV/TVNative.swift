import SwiftUI
import UIKit
#if canImport(TVVLCKit)
import TVVLCKit
#endif

/// Fluxurile „native” ale unui video, cerute direct de la YouTube (API-ul intern InnerTube) ca
/// aplicația YouTube VR (client ANDROID_VR): fără PO token și cu adrese directe, inclusiv
/// VP9 / AV1 până la 4K. Folosit de testul 4K cu VLC. Poate să se strice când YouTube schimbă ceva.
/// Autor: arturm
enum NativeStreams {

    /// Un client YouTube (InnerTube) prin care cerem fluxurile.
    struct Client {
        let name: String
        let id: String
        let version: String
        let ua: String
        let extra: [String: Any]
    }

    /// Încercați pe rând. Testat (oct. 2026): iOS 20.10.4 dă adrese directe până la 4K fără login;
    /// iOS-ul actual din App Store nu mai dă adrese directe; ANDROID_VR cere login.
    static let clients: [Client] = [
        Client(name: "IOS", id: "5", version: "20.10.4",
               ua: "com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)",
               extra: ["deviceMake": "Apple", "deviceModel": "iPhone16,2", "osName": "iPhone", "osVersion": "18.3.2.22D82"]),
        Client(name: "ANDROID_VR", id: "28", version: "1.65.10",
               ua: "com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip",
               extra: ["deviceMake": "Oculus", "deviceModel": "Quest 3", "androidSdkVersion": 32, "osName": "Android", "osVersion": "12L"]),
    ]

    /// User-Agent-ul clientului care a dat fluxurile (adresele merg doar cu el).
    static var userAgent = clients[0].ua

    struct Format: Identifiable, Hashable {
        let itag: Int
        let mime: String
        let codecs: String
        let label: String
        let width: Int
        let height: Int
        let fps: Int
        let bitrate: Int
        let url: URL
        /// Unde sunt în fișier antetul (init) și indexul segmentelor (sidx) — pentru HLS-ul local.
        var initRange: ClosedRange<Int>? = nil
        var indexRange: ClosedRange<Int>? = nil
        var id: Int { itag }
        var isVideo: Bool { mime.hasPrefix("video/") }
        var isAudio: Bool { mime.hasPrefix("audio/") }
        var codecName: String {
            let c = codecs.lowercased()
            if c.hasPrefix("vp09") || c.hasPrefix("vp9") { return "VP9" }
            if c.hasPrefix("av01") { return "AV1" }
            if c.hasPrefix("avc1") { return "H.264" }
            if c.hasPrefix("opus") { return "Opus" }
            if c.hasPrefix("mp4a") { return "AAC" }
            return codecs
        }
        var summary: String {
            if isVideo {
                return "\(label.isEmpty ? "\(height)p" : label) · \(codecName) · \(fps) fps · \(bitrate / 1000) kbit/s"
            }
            return "Audio · \(codecName) · \(bitrate / 1000) kbit/s"
        }
    }

    struct Result {
        var title = ""
        var formats: [Format] = []
        /// Miniaturile pentru bara de derulare (același format ca în pagina YouTube).
        var storyboardSpec: String?
        var error: String?
        var videos: [Format] { formats.filter(\.isVideo).sorted { ($0.height, $0.fps, $0.bitrate) > ($1.height, $1.fps, $1.bitrate) } }
        var bestAudio: Format? {
            let a = formats.filter(\.isAudio)
            return a.filter { $0.codecName == "Opus" }.max { $0.bitrate < $1.bitrate } ?? a.max { $0.bitrate < $1.bitrate }
        }
    }

    /// „Visitor data”: identificatorul de vizitator YouTube. Fără el, YouTube cere des
    /// „Sign in to confirm you're not a bot” (LOGIN_REQUIRED). Îl luăm din pagina deja deschisă
    /// în WebKit sau, la nevoie, din sw.js_data (ca NewPipe).
    @MainActor
    static func visitorData() async -> String {
        if let web = TVEngine.shared.web {
            let v: String = await withCheckedContinuation { c in
                web.evaluate("(function(){try{return (window.ytcfg&&ytcfg.get&&ytcfg.get('VISITOR_DATA'))||''}catch(e){return ''}})()") { r, _ in
                    c.resume(returning: r as? String ?? "")
                }
            }
            if !v.isEmpty { return v }
        }
        var req = URLRequest(url: URL(string: "https://www.youtube.com/sw.js_data")!)
        req.setValue(TVEngine.SiteMode.mobile.userAgent, forHTTPHeaderField: "User-Agent")
        guard let res = try? await URLSession.shared.data(for: req) else { return "" }
        var text = String(decoding: res.0, as: UTF8.self)
        if text.hasPrefix(")]}'") { text = String(text.dropFirst(4)) }
        guard let a = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [Any],
              let a0 = a.first as? [Any], a0.count > 2, let a2 = a0[2] as? [Any],
              let b = a2.first as? [Any], let c = b.first as? [Any], c.count > 13 else { return "" }
        return c[13] as? String ?? ""
    }

    /// Verifică dacă YouTube chiar dă datele fluxului (primii 1024 de octeți), ca VLC să nu aștepte degeaba.
    static func probe(_ url: URL) async -> String {
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
        do {
            let (d, r) = try await URLSession.shared.data(for: req)
            let code = (r as? HTTPURLResponse)?.statusCode ?? 0
            let ok = code == 200 || code == 206
            return (ok ? "✓ " : "✗ ") + "HTTP \(code), \(d.count) octeți"
        } catch {
            return "✗ " + error.localizedDescription
        }
    }

    static func fetch(_ videoId: String) async -> Result {
        let visitor = await visitorData()
        var errors: [String] = []
        var last = Result(error: "Fără răspuns")
        for c in clients {
            var r = await fetchOnce(videoId, client: c, visitor: visitor)
            if !r.formats.isEmpty { userAgent = c.ua; return r }
            if let e = r.error { errors.append("\(c.name) \(c.version): \(e)") }
            r.error = errors.joined(separator: "\n")
            last = r
        }
        return last
    }

    /// {"start":"0","end":"740"} → 0...740
    private static func range(_ v: Any?) -> ClosedRange<Int>? {
        guard let d = v as? [String: Any],
              let a = Int(d["start"] as? String ?? ""), let b = Int(d["end"] as? String ?? ""), b >= a else { return nil }
        return a...b
    }

    private static func fetchOnce(_ videoId: String, client c: Client, visitor: String) async -> Result {
        var client: [String: Any] = ["clientName": c.name, "clientVersion": c.version, "hl": "ro", "gl": "RO"]
        client.merge(c.extra) { a, _ in a }
        if !visitor.isEmpty { client["visitorData"] = visitor }
        let body: [String: Any] = [
            "context": ["client": client],
            "videoId": videoId,
            "contentCheckOk": true,
            "racyCheckOk": true,
        ]
        var req = URLRequest(url: URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(c.ua, forHTTPHeaderField: "User-Agent")
        if !visitor.isEmpty { req.setValue(visitor, forHTTPHeaderField: "X-Goog-Visitor-Id") }
        req.setValue(c.id, forHTTPHeaderField: "X-YouTube-Client-Name")
        req.setValue(c.version, forHTTPHeaderField: "X-YouTube-Client-Version")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let res = try? await URLSession.shared.data(for: req) else {
            return Result(error: "Fără răspuns de la YouTube (rețea)")
        }
        guard let o = try? JSONSerialization.jsonObject(with: res.0) as? [String: Any] else {
            return Result(error: "Răspuns necunoscut (HTTP \((res.1 as? HTTPURLResponse)?.statusCode ?? 0))")
        }
        var r = Result()
        r.title = ((o["videoDetails"] as? [String: Any])?["title"] as? String) ?? ""
        let play = o["playabilityStatus"] as? [String: Any]
        if let status = play?["status"] as? String, status != "OK" {
            r.error = "YouTube: \(status) — \(play?["reason"] as? String ?? "")"
        }
        if let sb = o["storyboards"] as? [String: Any],
           let spec = (sb["playerStoryboardSpecRenderer"] as? [String: Any])?["spec"] as? String {
            r.storyboardSpec = spec
        }
        let sd = o["streamingData"] as? [String: Any]
        let all = ((sd?["adaptiveFormats"] as? [[String: Any]]) ?? []) + ((sd?["formats"] as? [[String: Any]]) ?? [])
        for f in all {
            guard let u = (f["url"] as? String).flatMap(URL.init(string:)) else { continue } // cele cu „signatureCipher” nu se pot folosi direct
            let mimeFull = f["mimeType"] as? String ?? ""
            let mime = mimeFull.components(separatedBy: ";").first ?? mimeFull
            var codecs = ""
            if let r1 = mimeFull.range(of: "codecs=\"") {
                codecs = String(mimeFull[r1.upperBound...]).components(separatedBy: "\"").first ?? ""
            }
            r.formats.append(Format(
                itag: f["itag"] as? Int ?? 0, mime: mime, codecs: codecs,
                label: f["qualityLabel"] as? String ?? "",
                width: f["width"] as? Int ?? 0, height: f["height"] as? Int ?? 0,
                fps: f["fps"] as? Int ?? 0, bitrate: f["bitrate"] as? Int ?? 0, url: u,
                initRange: range(f["initRange"]), indexRange: range(f["indexRange"])))
        }
        if r.formats.isEmpty && r.error == nil { r.error = "YouTube n-a dat adrese directe (poate cere acum token)" }
        return r
    }
}

// MARK: - Testul 4K (ecran în Setări)

/// Arată ce fluxuri dă YouTube pe calea nativă și le redă cu VLC (VP9 / AV1, până la 4K).
struct Native4KTestView: View {
    @ObservedObject private var engine = TVEngine.shared
    @State private var result: NativeStreams.Result?
    @State private var loading = false
    @State private var playing: NativeStreams.Format?
    @State private var withAudio = true

    private let testId = "LXb3EKWsInQ" // video natural 4K 60 fps

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Test 4K — redare nativă cu VLC").font(.title2.bold())
                Text(vlcAvailable
                     ? "VLC (TVVLCKit) e instalat. Alege un flux video: se redă cu cel mai bun sunet, direct, fără pagina YouTube."
                     : "VLC (TVVLCKit) nu e încă în proiect: poți vedea ce fluxuri dă YouTube, dar nu le poți reda. Vezi TV/README.md → „Test 4K”.")
                    .foregroundStyle(.secondary)
                HStack(spacing: 30) {
                    Button("Video de test 4K") { load(testId) }
                    if let cur = engine.current { Button("Video-ul curent: \(cur.title.prefix(30))") { load(cur.id) } }
                }
                Toggle("Cu sunet (fluxul audio separat)", isOn: $withAudio)
                if loading { ProgressView("Cer fluxurile de la YouTube…") }
                if let r = result {
                    if !r.title.isEmpty { Text(r.title).font(.headline) }
                    if let e = r.error { Text(e).foregroundStyle(.orange) }
                    if let a = r.bestAudio { Text("Sunet: " + a.summary).font(.callout).foregroundStyle(.secondary) }
                    ForEach(r.videos) { f in
                        Button {
                            if vlcAvailable { playing = f }
                        } label: {
                            HStack {
                                Text(f.summary)
                                Spacer()
                                Text("itag \(f.itag)").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .padding(60)
        }
        .fullScreenCover(item: $playing) { f in
            VLCTestPlayerView(video: f, audio: withAudio ? result?.bestAudio : nil)
        }
    }

    private var vlcAvailable: Bool {
        #if canImport(TVVLCKit)
        return true
        #else
        return false
        #endif
    }

    private func load(_ id: String) {
        loading = true
        result = nil
        Task { @MainActor in
            result = await NativeStreams.fetch(id)
            loading = false
        }
    }
}

// MARK: - Player-ul VLC

#if canImport(TVVLCKit)

@MainActor
final class VLCTester: NSObject, ObservableObject, VLCMediaPlayerDelegate {
    let player = VLCMediaPlayer()
    @Published var time = "0:00"
    @Published var length = ""
    @Published var stateText = "pornesc…"
    @Published var fps: Double = 0
    @Published var lost = 0
    @Published var size = "—"
    private var lastPictures = -1
    private var timer: Timer?

    func start(video: URL, audio: URL?, view: UIView) {
        // Jurnalul VLC în consola Xcode (de ce rămâne „se încarcă”: 403, codec, rețea…).
        let logger = VLCConsoleLogger()
        logger.level = VLCLogLevel(rawValue: 2) ?? logger.level // info
        VLCLibrary.shared().loggers = [logger]
        let media = VLCMedia(url: video)
        media.addOption(":http-user-agent=\(NativeStreams.userAgent)")
        media.addOption(":network-caching=3000")
        player.media = media
        player.drawable = view
        player.delegate = self
        if let audio { player.addPlaybackSlave(audio, type: .audio, enforce: true) }
        player.play()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        player.stop()
    }

    private func tick() {
        time = player.time.stringValue
        length = player.media?.length.stringValue ?? ""
        let s = player.videoSize
        size = s.width > 0 ? "\(Int(s.width))×\(Int(s.height))" : "—"
        if let m = player.media {
            let shown = Int(m.numberOfDisplayedPictures)
            if lastPictures >= 0 && shown >= lastPictures { fps = Double(shown - lastPictures) }
            lastPictures = shown
            lost = Int(m.numberOfLostPictures)
        }
    }

    nonisolated func mediaPlayerStateChanged(_ aNotification: Notification) {
        Task { @MainActor in
            switch self.player.state {
            case .opening: self.stateText = "se deschide"
            case .buffering: self.stateText = "se încarcă"
            case .playing: self.stateText = "rulează"
            case .paused: self.stateText = "pauză"
            case .error: self.stateText = "eroare (VLC nu poate reda fluxul)"
            case .ended: self.stateText = "s-a terminat"
            case .stopped: self.stateText = "oprit"
            default: break
            }
        }
    }
}

private struct VLCDrawable: UIViewRepresentable {
    let tester: VLCTester
    let video: URL
    let audio: URL?
    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .black
        DispatchQueue.main.async { tester.start(video: video, audio: audio, view: v) }
        return v
    }
    func updateUIView(_ v: UIView, context: Context) {}
}

struct VLCTestPlayerView: View {
    let video: NativeStreams.Format
    let audio: NativeStreams.Format?
    @StateObject private var t = VLCTester()
    @State private var probeVideo = "verific…"
    @State private var probeAudio = "verific…"
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topLeading) {
            VLCDrawable(tester: t, video: video.url, audio: audio?.url).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 6) {
                Text("VLC · " + video.summary)
                Text("Stare: \(t.stateText)")
                Text("Timp: \(t.time) / \(t.length)")
                Text("Rezoluție: \(t.size)")
                Text(String(format: "FPS afișat: %.0f · cadre pierdute: %d", t.fps, t.lost))
                Text("Flux video: \(probeVideo)")
                Text("Flux audio: " + (audio == nil ? "oprit" : probeAudio))
            }
            .font(.system(size: 24, design: .monospaced))
            .padding(24)
            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 16))
            .padding(60)
            // Primește telecomanda
            Button {} label: { Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity) }
                .buttonStyle(InvisibleButtonStyle())
                .onMoveCommand { dir in
                    if dir == .left { t.player.jumpBackward(10) }
                    if dir == .right { t.player.jumpForward(10) }
                }
        }
        .onPlayPauseCommand { t.player.isPlaying ? t.player.pause() : t.player.play() }
        .onExitCommand { t.stop(); dismiss() }
        .onDisappear { t.stop() }
        .task {
            probeVideo = await NativeStreams.probe(video.url)
            if let a = audio { probeAudio = await NativeStreams.probe(a.url) }
        }
    }
}

#else

struct VLCTestPlayerView: View {
    let video: NativeStreams.Format
    let audio: NativeStreams.Format?
    var body: some View { Text("TVVLCKit nu e instalat") }
}

#endif
