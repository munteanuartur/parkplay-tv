import SwiftUI
import AVKit

/// Test: redare nativă cu AVPlayer (player-ul Apple, decodare hardware), fără pagina web.
/// Fluxurile vin de la clientul iOS al YouTube (NativeStreams): video H.264 (mp4) + sunet AAC (m4a),
/// unite într-o compoziție AVFoundation. H.264 merge până la 1080p; peste, YouTube dă doar VP9 / AV1
/// (pentru acelea: testul cu VLC). Dacă merge bine, devine player-ul principal. Autor: arturm

// MARK: - Ecranul de test (Setări → Avansat)

struct HLSTestView: View {
    @ObservedObject private var engine = TVEngine.shared
    @State private var result: NativeStreams.Result?
    @State private var loading = false
    @State private var playing: PlayRequest?

    struct PlayRequest: Identifiable {
        let id = UUID()
        let video: NativeStreams.Format
        let audio: NativeStreams.Format
        let ua: String
    }

    private let testId = "LXb3EKWsInQ" // video natural 4K 60 fps

    /// Ce poate reda AVPlayer direct: H.264 în mp4.
    private var h264: [NativeStreams.Format] {
        (result?.videos ?? []).filter { $0.codecName == "H.264" && $0.mime == "video/mp4" }
    }
    private var aac: NativeStreams.Format? {
        (result?.formats ?? []).filter { $0.isAudio && $0.codecName == "AAC" }.max { $0.bitrate < $1.bitrate }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Test AVPlayer — redare nativă (H.264)").font(.title2.bold())
                Text("Cere fluxurile ca aplicația YouTube de iPhone și le redă cu player-ul Apple (decodare hardware), fără pagina web. Peste 1080p YouTube nu dă H.264 — pentru 1440p / 4K e testul cu VLC.")
                    .foregroundStyle(.secondary)
                HStack(spacing: 30) {
                    Button("Video de test 4K") { load(testId) }
                    if let cur = engine.current { Button("Video-ul curent: \(cur.title.prefix(30))") { load(cur.id) } }
                }
                if loading { ProgressView("Cer fluxurile de la YouTube…") }
                if let r = result {
                    if !r.title.isEmpty { Text(r.title).font(.headline) }
                    if let e = r.error, r.formats.isEmpty { Text(e).foregroundStyle(.orange) }
                    if let a = aac {
                        Text("Sunet: " + a.summary).font(.callout).foregroundStyle(.secondary)
                        if h264.isEmpty { Text("YouTube n-a dat H.264 pentru acest video.").foregroundStyle(.orange) }
                        ForEach(h264) { v in
                            Button {
                                playing = PlayRequest(video: v, audio: a, ua: NativeStreams.userAgent)
                            } label: {
                                HStack { Text("▶  " + v.summary); Spacer(); Text("itag \(v.itag)").foregroundStyle(.secondary) }
                            }
                        }
                    } else if !r.formats.isEmpty {
                        Text("Lipsește sunetul AAC (m4a) în răspuns.").foregroundStyle(.orange)
                    }
                }
            }
            .padding(60)
        }
        .fullScreenCover(item: $playing) { p in HLSTestPlayerView(request: p) }
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

// MARK: - AVPlayer: video + sunet separate, unite într-o compoziție

@MainActor
final class HLSTester: ObservableObject {
    let player = AVPlayer()
    @Published var info = "pregătesc fluxurile…"
    private var timer: Timer?
    private var label = ""
    private var setupError: String?

    func start(_ r: HLSTestView.PlayRequest) {
        label = r.video.summary
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        Task { @MainActor in
            do {
                let item = try await makeItem(video: r.video, audio: r.audio, ua: r.ua)
                player.replaceCurrentItem(with: item)
                player.play()
            } catch {
                setupError = error.localizedDescription
                tick()
            }
        }
    }

    /// Ține „serverul” de playlisturi cât timp rulează (delegatul AVFoundation e referință slabă).
    private var hls: LocalHLS?

    func makeItem(video: NativeStreams.Format, audio: NativeStreams.Format, ua: String) async throws -> AVPlayerItem {
        let (item, loader) = try await LocalHLS.item(video: video, audio: audio, ua: ua)
        hls = loader
        return item
    }

    struct TestError: LocalizedError {
        let message: String
        init(_ m: String) { message = m }
        var errorDescription: String? { message }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        hls = nil
    }

    private func tick() {
        var lines = ["AVPlayer · \(label)"]
        if let e = setupError {
            lines.append("Eroare la pregătire: \(e)")
            info = lines.joined(separator: "\n")
            return
        }
        guard let it = player.currentItem else {
            info = (lines + ["pregătesc fluxurile…"]).joined(separator: "\n")
            return
        }
        let state: String
        switch (it.status, player.timeControlStatus) {
        case (.failed, _): state = "eroare"
        case (_, .playing): state = "rulează"
        case (_, .waitingToPlayAtSpecifiedRate): state = "se încarcă"
        case (_, .paused): state = "pauză"
        default: state = "…"
        }
        lines.append("Stare: \(state)")
        let s = it.presentationSize
        lines.append("Rezoluție: " + (s.width > 0 ? "\(Int(s.width))×\(Int(s.height))" : "—"))
        let t = player.currentTime().seconds
        lines.append("Timp: \(Int(t.isFinite ? t : 0)) s")
        if let e = it.accessLog()?.events.last {
            lines.append(String(format: "Rețea: %.1f Mbit/s · cadre pierdute: %d · blocaje: %d",
                                max(e.observedBitrate, 0) / 1e6, max(e.numberOfDroppedVideoFrames, 0), max(e.numberOfStalls, 0)))
        }
        if let err = it.error { lines.append("Eroare: \(err.localizedDescription)") }
        info = lines.joined(separator: "\n")
    }
}

struct HLSTestPlayerView: View {
    let request: HLSTestView.PlayRequest
    @StateObject private var t = HLSTester()

    var body: some View {
        VideoPlayer(player: t.player) {
            VStack {
                HStack {
                    Text(t.info)
                        .font(.system(size: 24, design: .monospaced))
                        .padding(24)
                        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 16))
                    Spacer()
                }
                Spacer()
            }
            .padding(60)
            .allowsHitTesting(false)
        }
        .ignoresSafeArea()
        .onAppear { t.start(request) }
        .onDisappear { t.stop() }
    }
}

// MARK: - HLS local din fluxurile DASH ale YouTube

/// Dă lui AVPlayer playlisturile (schema „pphls://”); segmentele rămân adrese https YouTube.
final class LocalHLS: NSObject, AVAssetResourceLoaderDelegate {
    static let scheme = "pphls"
    let queue = DispatchQueue(label: "ParkPlayTV.localhls")
    private let files: [String: Data]

    init(_ files: [String: Data]) { self.files = files }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource req: AVAssetResourceLoadingRequest) -> Bool {
        guard let url = req.request.url, url.scheme == Self.scheme, let d = files[url.lastPathComponent] else { return false }
        if let info = req.contentInformationRequest {
            info.contentType = "public.m3u-playlist"
            info.contentLength = Int64(d.count)
            info.isByteRangeAccessSupported = false
        }
        req.dataRequest?.respond(with: d)
        req.finishLoading()
        return true
    }

    /// Fluxurile YouTube (fMP4 cu index „sidx”) prezentate lui AVPlayer ca HLS: playlisturile
    /// le facem noi din index, segmentele le ia AVPlayer direct de la YouTube, pe bucăți (byte range).
    /// Loader-ul întors trebuie ținut în viață cât rulează item-ul (AVFoundation îl ține slab).
    static func item(video: NativeStreams.Format, audio: NativeStreams.Format, ua: String) async throws -> (AVPlayerItem, LocalHLS) {
        async let vp = mediaPlaylist(video, ua: ua)
        async let ap = mediaPlaylist(audio, ua: ua)
        let v = try await vp, a = try await ap
        let codecs = [video.codecs, audio.codecs].filter { !$0.isEmpty }.joined(separator: ",")
        let master = """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-INDEPENDENT-SEGMENTS
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="Audio",DEFAULT=YES,AUTOSELECT=YES,URI="\(scheme)://pp/audio.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=\(max(video.bitrate + audio.bitrate, 1)),CODECS="\(codecs)",RESOLUTION=\(video.width)x\(video.height),FRAME-RATE=\(max(video.fps, 1)),AUDIO="a"
        \(scheme)://pp/video.m3u8

        """
        let loader = LocalHLS(["master.m3u8": Data(master.utf8), "video.m3u8": Data(v.utf8), "audio.m3u8": Data(a.utf8)])
        let opts: [String: Any] = ["AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": ua]]
        let asset = AVURLAsset(url: URL(string: "\(scheme)://pp/master.m3u8")!, options: opts)
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        return (AVPlayerItem(asset: asset), loader)
    }

    struct HLSError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Playlistul unui flux: antetul (EXT-X-MAP) + câte o bucată pentru fiecare intrare din „sidx”.
    static func mediaPlaylist(_ f: NativeStreams.Format, ua: String) async throws -> String {
        guard let initR = f.initRange, let idx = f.indexRange else {
            throw HLSError(message: "itag \(f.itag): YouTube n-a dat initRange / indexRange")
        }
        var req = URLRequest(url: f.url)
        req.timeoutInterval = 15
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue("bytes=\(idx.lowerBound)-\(idx.upperBound)", forHTTPHeaderField: "Range")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 206 || code == 200 else { throw HLSError(message: "itag \(f.itag): indexul a răspuns HTTP \(code)") }
        let segs = try sidx(Array(data), base: idx.lowerBound)
        guard !segs.isEmpty else { throw HLSError(message: "itag \(f.itag): index gol") }
        let target = Int((segs.map(\.duration).max() ?? 1).rounded(.up))
        let uri = f.url.absoluteString
        var out = """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-TARGETDURATION:\(target)
        #EXT-X-MEDIA-SEQUENCE:0
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXT-X-INDEPENDENT-SEGMENTS
        #EXT-X-MAP:URI="\(uri)",BYTERANGE="\(initR.count)@\(initR.lowerBound)"

        """
        for s in segs {
            out += "#EXTINF:\(String(format: "%.3f", s.duration)),\n#EXT-X-BYTERANGE:\(s.size)@\(s.offset)\n\(uri)\n"
        }
        out += "#EXT-X-ENDLIST\n"
        return out
    }

    struct Segment { let offset: Int; let size: Int; let duration: Double }

    /// Citește cutia „sidx” (ISO BMFF): mărimea și durata fiecărui fragment.
    static func sidx(_ b: [UInt8], base: Int) throws -> [Segment] {
        func u32(_ i: Int) -> Int { Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3]) }
        func u64(_ i: Int) -> Int { u32(i) << 32 | u32(i + 4) }
        func u16(_ i: Int) -> Int { Int(b[i]) << 8 | Int(b[i + 1]) }
        // Căutăm „sidx” (indexul poate începe cu alte cutii).
        var start = -1
        var i = 0
        while i + 8 <= b.count {
            let size = u32(i)
            if b[i + 4] == 0x73, b[i + 5] == 0x69, b[i + 6] == 0x64, b[i + 7] == 0x78 { start = i; break }
            guard size >= 8 else { break }
            i += size
        }
        guard start >= 0 else { throw HLSError(message: "nu găsesc „sidx” în index") }
        // Deplasările din sidx se numără de la primul octet de după cutie.
        let anchor = base + start + u32(start)
        var p = start + 8
        guard p + 12 <= b.count else { throw HLSError(message: "index scurt") }
        let version = b[p]
        p += 4                       // versiune + flags
        p += 4                       // reference_ID
        let timescale = max(u32(p), 1); p += 4
        let firstOffset: Int
        if version == 0 { firstOffset = u32(p + 4); p += 8 } else { firstOffset = u64(p + 8); p += 16 }
        p += 2                       // rezervat
        let count = u16(p); p += 2
        var offset = anchor + firstOffset
        var out: [Segment] = []
        for _ in 0..<count {
            guard p + 12 <= b.count else { break }
            let size = u32(p) & 0x7FFF_FFFF
            let dur = Double(u32(p + 4)) / Double(timescale)
            out.append(Segment(offset: offset, size: size, duration: dur))
            offset += size
            p += 12
        }
        return out
    }
}
