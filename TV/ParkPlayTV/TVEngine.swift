import SwiftUI
import UIKit
import AVFoundation
#if canImport(TVVLCKit)
import TVVLCKit
#endif

/// Poziția și durata (se schimbă des — separat, ca să nu redesenăm tot).
@MainActor
final class TVClock: ObservableObject {
    @Published var position: Double = 0
    @Published var duration: Double = 0
}

/// Ce aflăm despre WebKit-ul de pe Apple TV și despre redare (ecranul Diagnostic).
@MainActor
final class TVDiagnostics: ObservableObject {
    @Published var webKit = PPWebView.availabilityInfo()
    @Published var adRules = "—"
    @Published var page: [String: String] = [:]
    @Published var fps: Double = 0
    @Published var kbps: Double = 0
    @Published var dropped = 0
    @Published var frames = 0
    @Published var buffer: Double = 0
    @Published var videoSize = "—"
    @Published var codecs = ""
    @Published var connection = ""
    @Published var adsSkipped = 0
    @Published var lastEvent = ""
}

/// Motorul de redare pentru Apple TV: lista, WKWebView-ul cu pagina YouTube și scripturile
/// comune cu versiunea de Mac (PageScripts), calitatea, viteza, SponsorBlock, Autoplay.
/// Autor: arturm
@MainActor
final class TVEngine: NSObject, ObservableObject, PPWebViewDelegate {

    static let shared = TVEngine()

    enum SiteMode: String, CaseIterable, Identifiable {
        case desktop, mobile, mobile18, ipad
        var id: String { rawValue }
        var title: String {
            switch self {
            case .desktop: return "Desktop (www, până la 4K — cere MediaSource)"
            case .mobile: return "Mobil (m.youtube, HLS, iPhone iOS 16)"
            case .mobile18: return "Mobil (m.youtube, HLS, iPhone iOS 18)"
            case .ipad: return "iPad (Safari iPadOS 18)"
            }
        }
        var userAgent: String {
            switch self {
            case .desktop:
                return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
            case .mobile:
                return "Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1"
            case .mobile18:
                return "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1"
            case .ipad:
                return "Mozilla/5.0 (iPad; CPU OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1"
            }
        }
        func url(_ id: String, start: Int) -> String {
            let host = (self == .desktop || self == .ipad) ? "https://www.youtube.com" : "https://m.youtube.com"
            return "\(host)/watch?v=\(id)" + (start > 5 ? "&t=\(start)s" : "")
        }
    }

    static let levels: [(String, String)] = [
        ("hd2160", "2160p (4K)"), ("hd1440", "1440p"), ("hd1080", "1080p"), ("hd720", "720p"),
        ("large", "480p"), ("medium", "360p"), ("small", "240p"), ("tiny", "144p"),
    ]
    static func label(_ q: String) -> String { levels.first { $0.0 == q }?.1 ?? (q == "auto" ? "Auto" : q) }

    let clock = TVClock()
    let diag = TVDiagnostics()
    private(set) var web: PPWebView?

    @Published private(set) var queue: [Track] = []
    @Published private(set) var index = -1
    @Published private(set) var playing = false
    @Published private(set) var wantPlay = false
    @Published private(set) var buffering = false
    @Published private(set) var inAd = false
    @Published private(set) var qualities: [String] = []
    @Published private(set) var currentQuality = ""
    @Published private(set) var extending = false
    @Published var quality: String {
        didSet {
            UserDefaults.standard.set(quality, forKey: "quality")
            applyState()
            if oldValue != quality { choiceOverride = nil }
            if nativeActive && oldValue != quality { reloadNative() }
        }
    }
    @Published var rate: Double {
        didSet {
            UserDefaults.standard.set(rate, forKey: "rate")
            applyState()
            if nativeActive && avPlayer.rate > 0 { avPlayer.rate = Float(rate) }
            #if canImport(TVVLCKit)
            if useVLC { vlc.rate = Float(rate) }
            #endif
        }
    }

    /// Cum se redă: nativ (AVPlayer, până la 1080p, decodare hardware) sau prin pagina YouTube.
    enum PlayerMode: String, CaseIterable, Identifiable {
        case native, web
        var id: String { rawValue }
        var title: String { self == .native ? "Nativ (experimental — YouTube îl poate bloca)" : "Pagina YouTube (recomandat)" }
    }
    @Published var playerMode: PlayerMode {
        didSet {
            UserDefaults.standard.set(playerMode.rawValue, forKey: "player_mode2")
            if index >= 0 && loaded && oldValue != playerMode { playIndex(index, start: clock.position) }
        }
    }

    /// Player-ul nativ și starea lui.
    let avPlayer = AVPlayer()
    @Published private(set) var nativeActive = false
    private var nativeLoader: LocalHLS?
    private var loadToken = 0

    /// Calitățile de pornire (Setări → Redare).
    static let startQualities: [(String, String)] = [
        ("auto", "Auto — după viteza internetului (până la 1080p)"),
        ("hd1080", "1080p"),
        ("hd720", "720p"),
        ("large", "480p"),
        ("vlc30", "4K / 1440p la 30 fps când există (VLC), altfel 1080p"),
        ("vlcmax", "Maximă (VLC — la 60 fps poate sacada)"),
    ]

    /// O variantă pe care o poți alege în player pentru video-ul curent.
    struct StreamChoice: Identifiable, Hashable {
        let id: String
        let label: String
        let height: Int
        let fps: Int
        let vlc: Bool
        let video: NativeStreams.Format
    }
    @Published private(set) var choices: [StreamChoice] = []
    @Published private(set) var currentChoice = ""
    /// Alegerea făcută în player pentru un video anume (are prioritate față de setare).
    private var choiceOverride: (video: String, choice: String)?
    /// Răspunsul YouTube pentru video-ul curent (adresele țin câteva ore) — la schimbarea calității nu-l mai cerem.
    private var lastStreams: (id: String, result: NativeStreams.Result)?

    /// Redă VLC acum (în loc de AVPlayer).
    @Published private(set) var useVLC = false
    #if canImport(TVVLCKit)
    let vlc = VLCMediaPlayer()
    /// Suprafața pe care desenează VLC (se mută în player când se deschide).
    let vlcView: UIView = {
        let v = UIView()
        v.backgroundColor = .black
        v.isUserInteractionEnabled = false
        v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        return v
    }()
    private var vlcTimer: Timer?
    private var vlcEnded = false
    #endif
    private var webHasContent = false
    @Published var siteMode: SiteMode {
        didSet {
            UserDefaults.standard.set(siteMode.rawValue, forKey: "site")
            web?.setUserAgent(siteMode.userAgent)
            if index >= 0 { playIndex(index, start: clock.position) }
        }
    }
    @Published var sponsorBlock: Bool { didSet { UserDefaults.standard.set(sponsorBlock, forKey: "sponsorblock") } }
    @Published var autoplay: Bool { didSet { UserDefaults.standard.set(autoplay, forKey: "autoplay") } }

    /// Video-ul curent e încărcat în pagină (după repornirea aplicației, încă nu).
    @Published private(set) var loaded = false
    /// Miniaturile pentru bara de derulare (din răspunsul playerului YouTube).
    @Published private(set) var storyboard: Storyboard?

    // ---- Subtitrări ----
    struct CaptionTrack: Identifiable, Hashable {
        let code: String
        let name: String
        let auto: Bool
        var id: String { code + (auto ? "#auto" : "") }
    }
    @Published private(set) var captionTracks: [CaptionTrack] = []
    /// "off", un cod de limbă („ro”, „en”…) sau "tr:ro" (traducere automată în limba dată).
    @Published var captionChoice: String { didSet { UserDefaults.standard.set(captionChoice, forKey: "captions"); applyCaptions() } }
    @Published var captionSize: Double { didSet { UserDefaults.standard.set(captionSize, forKey: "cc_size"); applyCaptions() } }

    var current: Track? { queue.indices.contains(index) ? queue[index] : nil }

    private var ready = false
    private var pendingURL: URL?
    private var loadedAt: TimeInterval = 0
    private var segments: [SponsorBlock.Segment] = []
    private var lastAdState = false
    private var lastStatTick: TimeInterval = 0
    private var lastFlush: TimeInterval = 0
    private var lastPositionSave: TimeInterval = 0

    /// Calitățile pe care le oferă YouTube pentru video-ul curent (de la cea mai bună).
    var availableLevels: [(String, String)] {
        qualities.isEmpty ? [] : Self.levels.filter { qualities.contains($0.0) }
    }

    private override init() {
        let d = UserDefaults.standard
        // Fără plafon: cerem cea mai bună calitate oferită (scriptul coboară singur la ce există).
        // Vechea valoare implicită „hd1080” e trecută automat pe 4K.
        // Calitatea la pornire (vezi `startQualities`); valorile vechi peste 1080p devin 1080p.
        let savedQ = d.string(forKey: "quality") ?? "hd1080"
        quality = ["hd2160", "hd1440"].contains(savedQ) ? "hd1080" : savedQ
        rate = d.object(forKey: "rate") as? Double ?? 1.0
        siteMode = SiteMode(rawValue: d.string(forKey: "site") ?? "") ?? .mobile // pe Apple TV doar mobilul merge (fără MSE)
        sponsorBlock = d.object(forKey: "sponsorblock") as? Bool ?? true
        autoplay = d.object(forKey: "autoplay") as? Bool ?? true
        captionChoice = d.string(forKey: "captions") ?? "off"
        captionSize = d.object(forKey: "cc_size") as? Double ?? 1.0
        // Implicit: pagina YouTube (clientul iOS al căii native e limitat / blocat de YouTube).
        // Cheie nouă, ca să pornească toți de pe pagina YouTube; nativul rămâne opțiune în Setări.
        playerMode = PlayerMode(rawValue: d.string(forKey: "player_mode2") ?? "") ?? .web
        super.init()
        restoreSession()
        setupWebView()
        setupNative()
    }

    private func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    // MARK: - WebView

    private func setupWebView() {
        guard let w = PPWebView(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                                userAgent: siteMode.userAgent, delegate: self) else {
            diag.webKit = PPWebView.availabilityInfo() + " — WKWebView nu a putut fi creat"
            return
        }
        web = w
        if FakeMSE.enabled {
            w.addDocumentStartScript(FakeMSE.script, mainFrameOnly: true)
            // Ceasul <video>-ului simulat îl mișcăm din aplicație (temporizatoarele paginii sunt frânate).
            Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, !self.suspended, !self.nativeActive else { return }
                    let r = MSERenderer.shared
                    r.update()
                    if r.needsFreshInit {
                        r.needsFreshInit = false
                        self.bounceQuality()
                    }
                    if r.needsReload {
                        // Imaginea nu s-a putut reface pe loc: reîncărcăm video-ul (pagină nouă) de la aceeași secundă.
                        r.needsReload = false
                        if let t = self.current, let url = URL(string: self.siteMode.url(t.id, start: Int(self.clock.position))) {
                            self.diag.lastEvent = "imagine blocată → reîncarc video-ul de la \(Int(self.clock.position)) s"
                            r.reset()
                            self.loadWeb(url)
                        }
                    }
                    self.mseStats(r)
                    self.checkMSEFallback(r)
                    let clock = String(format: "window.__ppClock&&window.__ppClock(%.3f,%@);", r.currentTime, r.isPlaying ? "true" : "false")
                    // Subtitrările le desenează player-ul YouTube în pagină (sub imaginea nativă): le luăm ca text.
                    let cc = "(function(){var c=document.querySelector('.ytp-caption-window-container .caption-window, .ytp-caption-window-container, .caption-window');return c?(c.innerText||c.textContent||''):''})()"
                    self.web?.evaluate(clock + "window.__ppTick&&window.__ppTick();" + cc) { res, _ in
                        Task { @MainActor in
                            let text = ((res as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                            if self.captionChoice == "off" { if !self.captionText.isEmpty { self.captionText = "" } }
                            else if text != self.captionText { self.captionText = text }
                        }
                    }
                }
            }
        }
        w.addDocumentStartScript(PageScripts.adBlock, mainFrameOnly: false)
        w.addDocumentStartScript(PageScripts.bridge, mainFrameOnly: true)
        let year = Date().addingTimeInterval(3600 * 24 * 365)
        let cookies = [
            HTTPCookie(properties: [.name: "SOCS", .value: "CAI", .domain: ".youtube.com", .path: "/", .secure: "TRUE", .expires: year]),
            HTTPCookie(properties: [.name: "CONSENT", .value: "YES+1", .domain: ".youtube.com", .path: "/", .expires: year]),
        ].compactMap { $0 }
        w.addContentRules(PageScripts.adBlockRules, identifier: "ParkPlayAdBlock-1") { [weak self] ok, err in
            Task { @MainActor in
                guard let self else { return }
                self.diag.adRules = ok ? "active (filtru de rețea)" : "indisponibile: \(err ?? "?") — rămâne json-prune"
                self.rulesDone = true
                self.maybeReady()
            }
        }
        w.setCookies(cookies) { [weak self] in
            Task { @MainActor in
                self?.cookiesDone = true
                self?.maybeReady()
            }
        }
    }

    private var rulesDone = false
    private var cookiesDone = false

    /// Aplicația e în fundal: nimic nu are voie să se încarce sau să cânte.
    private(set) var suspended = false
    @Published private(set) var radioLoading = false

    private func maybeReady() {
        guard rulesDone && cookiesDone, !ready, let w = web else { return }
        ready = true
        if let u = pendingURL { pendingURL = nil; w.load(u) }
    }

    private func js(_ code: String) { web?.evaluate(code, completion: nil) }

    private func stateJs() -> String {
        "window.__ppRate=\(rate);window.__ppQ='\(webQualityOverride ?? quality)';window.__ppWant=\(wantPlay);window.__ppStats=true;"
    }

    /// Textul subtitrării curente (calea 1080p: imaginea e nativă, deci subtitrarea o afișăm noi peste ea).
    @Published private(set) var captionText = ""
    /// Ce site (mobil / desktop…) e încărcat acum în pagină.
    private var pageSiteMode: SiteMode?

    /// Calitatea aleasă din player pentru video-ul curent (pe pagina YouTube); următorul pornește după setare.
    @Published private(set) var webQualityOverride: String?

    /// Calitatea coboară o treaptă pentru 4 s, apoi revine: player-ul YouTube trimite astfel un antet
    /// video nou (exact ce se întâmpla când schimbai tu calitatea și imaginea își revenea).
    private func bounceQuality() {
        let target = webQualityOverride ?? quality
        diag.lastEvent = "imagine înghețată → schimbare scurtă de calitate"
        js("(function(){try{var mp=document.getElementById('movie_player');var lv=(mp.getAvailableQualityLevels()||[]).filter(function(q){return q!=='auto';});" +
           "var cur=mp.getPlaybackQuality();var i=lv.indexOf(cur);var alt=lv[i+1]||lv[i-1];if(alt){window.__ppQ=alt;window.__ppQSet='';}}catch(e){}})()")
        let token = loadToken
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard token == self.loadToken else { return }
            self.js("window.__ppQ='\(target)';window.__ppQSet='';")
        }
    }

    func selectWebQuality(_ q: String) {
        webQualityOverride = q
        // __ppQSet gol = scriptul paginii aplică imediat noua calitate.
        js("window.__ppQ='\(q)';window.__ppQSet='';")
        diag.lastEvent = "calitate aleasă: " + Self.label(q)
    }

    private func applyState() { js(stateJs()) }

    // MARK: - Comenzi

    func playList(_ list: [Track], start: Int) {
        guard !list.isEmpty else { return }
        queue = list
        playIndex(min(max(start, 0), list.count - 1))
    }

    /// `start` nil = de unde ai rămas data trecută (ca pe YouTube) sau de la început.
    func playIndex(_ i: Int, start requested: Double? = nil) {
        guard queue.indices.contains(i) else { return }
        savePosition()
        let t = queue[i]
        let start = requested ?? WatchPositions.resumePoint(t.id) ?? 0
        if requested == nil && start > 0 { TVAppState.shared.toast("Continui de la \(TVTime.fmt(start))") }
        index = i
        loaded = true
        storyboard = nil
        captionTracks = []
        wantPlay = true
        playing = false
        buffering = true
        inAd = false
        qualities = []
        currentQuality = ""
        segments = []
        clock.position = start
        clock.duration = t.expectedDuration
        loadedAt = now()
        diag.lastEvent = "încarc \(t.id) (\(siteMode == .desktop ? "desktop" : "mobil"))"
        Library.addHistory(t)
        StatsStore.countPlay(t)
        lastStatTick = 0
        guard let u = URL(string: siteMode.url(t.id, start: Int(start))) else { return }
        loadToken += 1
        let token = loadToken
        webQualityOverride = nil
        let wasFallback = mseFallback
        captionText = ""
        mseFallback = false
        mseStatAt = 0
        if playerMode == .native {
            stopWebPage()
            // Video-ul vechi se oprește imediat (altfel poziția lui s-ar scrie peste cel nou).
            avPlayer.pause()
            avPlayer.replaceCurrentItem(with: nil)
            nativeLoader = nil
            stopVLC()
            choices = []
            currentChoice = ""
            resetStats()
            stallRecoveries = 0
            nativeActive = true
            diag.lastEvent = "încarc \(t.id) (nativ)"
            Task { @MainActor in
                let ok = await startNative(t.id, start: start, token: token)
                if !ok && token == loadToken { fallbackToWeb(u) }
            }
            // Plasă de siguranță: dacă în 26 s nu s-a redat nimic, trecem pe pagina YouTube.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 26_000_000_000)
                if token == loadToken { checkNativeStartTimeout() }
            }
        } else {
            stopNative()
            // Video următor în aceeași pagină (fără reîncărcare) — mult mai rapid. Altfel: pagină nouă.
            // (După 10 schimbări la rând pagina se reîncarcă oricum: player-ul YouTube „obosește” în timp.)
            if FakeMSE.enabled && !wasFallback && webHasContent && ready && !suspended && pageSiteMode == siteMode && inPageSwitches < 10 {
                inPageSwitches += 1
                switchInPage(t.id, start: start, fallback: u, token: token)
            } else {
                loadWeb(u)
            }
        }
        saveSession()
        if sponsorBlock {
            Task { @MainActor in
                let s = await SponsorBlock.segments(t.id)
                if current?.id == t.id { segments = s }
            }
        }
    }

    func play() {
        guard index >= 0 else { return }
        if !loaded { playIndex(index); return }
        wantPlay = true
        #if canImport(TVVLCKit)
        if useVLC { vlc.play(); return }
        #endif
        if nativeActive { avPlayer.playImmediately(atRate: Float(rate)); return }
        js("window.__ppWant=true;(function(){var v=document.querySelector('video.html5-main-video')||document.querySelector('video');if(v){v.muted=false;var p=v.play();if(p&&p.catch)p.catch(function(){});}})();")
    }

    func pause() {
        savePosition()
        wantPlay = false
        playing = false
        lastStatTick = 0
        StatsStore.flush()
        if nativeActive { avPlayer.pause() }
        #if canImport(TVVLCKit)
        if useVLC { vlc.pause() }
        #endif
        js("window.__ppWant=false;document.querySelectorAll('video').forEach(function(v){v.pause();});")
    }

    func toggle() { wantPlay ? pause() : play() }

    /// Pune un video imediat după cel curent (sau îl pornește dacă nu cântă nimic).
    func playNext(_ t: Track) {
        guard let cur = current else { playList([t], start: 0); return }
        var q = queue
        q.removeAll { $0.id == t.id && $0.id != cur.id }
        let at = min((q.firstIndex { $0.id == cur.id } ?? 0) + 1, q.count)
        q.insert(t, at: at)
        queue = q
        index = queue.firstIndex { $0.id == cur.id } ?? 0
    }

    /// Adaugă la finalul listei.
    func enqueue(_ t: Track) {
        guard current != nil else { playList([t], start: 0); return }
        if !queue.contains(where: { $0.id == t.id }) { queue.append(t) }
    }

    func next() {
        if index + 1 < queue.count { playIndex(index + 1) } else { extend() }
    }

    func previous() {
        if clock.position > 5 || index <= 0 { seek(to: 0) } else { playIndex(index - 1) }
    }

    func seek(to s: Double) {
        let v = max(0, s)
        clock.position = v
        #if canImport(TVVLCKit)
        if useVLC { vlc.time = VLCTime(int: Int32(min(v * 1000, Double(Int32.max)))); return }
        #endif
        if nativeActive {
            let tol = CMTime(seconds: 0.5, preferredTimescale: 600)
            avPlayer.seek(to: CMTime(seconds: v, preferredTimescale: 600), toleranceBefore: tol, toleranceAfter: tol)
            return
        }
        js("(function(){var v=document.querySelector('video.html5-main-video')||document.querySelector('video');if(v)v.currentTime=\(v);})();")
    }

    func seek(by d: Double) {
        let dur = clock.duration > 0 ? clock.duration : .greatestFiniteMagnitude
        seek(to: min(max(clock.position + d, 0), max(dur - 1, 0)))
    }

    func stop() {
        pause()
        stopNative()
        web?.load(URL(string: "about:blank")!)
        webHasContent = false
        index = -1
    }

    // MARK: - Redare nativă (AVPlayer + HLS local din fluxurile clientului iOS)

    private func setupNative() {
        avPlayer.allowsExternalPlayback = true
        avPlayer.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] _ in
            Task { @MainActor in self?.nativeTick() }
        }
        NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] n in
            let item = n.object as AnyObject?
            Task { @MainActor in
                guard let self, self.nativeActive, item === self.avPlayer.currentItem else { return }
                self.onEnded()
            }
        }
    }

    /// Nivelurile YouTube („hd1080”…) ↔ înălțimea în pixeli.
    private static let levelHeights: [(String, Int)] = [
        ("hd2160", 2160), ("hd1440", 1440), ("hd1080", 1080), ("hd720", 720),
        ("large", 480), ("medium", 360), ("small", 240), ("tiny", 144),
    ]
    private static func level(_ h: Int) -> String { levelHeights.first { h >= $0.1 }?.0 ?? "tiny" }
    private static func maxHeight(_ q: String) -> Int { levelHeights.first { $0.0 == q }?.1 ?? 4320 }

    /// Variantele unui video: H.264 până la 1080p (AVPlayer) + VP9 peste 1080p (VLC).
    private static func buildChoices(_ r: NativeStreams.Result) -> [StreamChoice] {
        func fpsText(_ f: Int) -> String { f > 30 ? "\(f)" : "" }
        var out: [StreamChoice] = []
        var seen = Set<String>()
        for v in r.videos where v.codecName == "H.264" && v.mime == "video/mp4" && v.indexRange != nil && v.initRange != nil {
            let key = "av\(v.height)-\(v.fps)"
            if seen.insert(key).inserted {
                out.append(StreamChoice(id: "av:\(v.itag)", label: "\(v.height)p\(fpsText(v.fps))", height: v.height, fps: v.fps, vlc: false, video: v))
            }
        }
        #if canImport(TVVLCKit)
        // Peste 1080p: VP9 prin VLC (decodare în software). SDR înaintea HDR (mai ușor de decodat).
        let maxAV = out.map(\.height).max() ?? 0
        let vp9 = r.videos.filter { $0.codecName == "VP9" && $0.height > max(maxAV, 1080) }
            .sorted { ($0.codecs.hasPrefix("vp09.02") ? 1 : 0) < ($1.codecs.hasPrefix("vp09.02") ? 1 : 0) }
        for v in vp9 {
            let key = "vlc\(v.height)-\(v.fps)"
            if seen.insert(key).inserted {
                let hdr = v.codecs.hasPrefix("vp09.02") ? " HDR" : ""
                let warn = v.fps > 30 ? " — poate sacada" : ""
                out.append(StreamChoice(id: "vlc:\(v.itag)", label: "\(v.height)p\(fpsText(v.fps))\(hdr) · VLC\(warn)",
                                        height: v.height, fps: v.fps, vlc: true, video: v))
            }
        }
        #endif
        return out.sorted { ($0.height, $0.fps) > ($1.height, $1.fps) }
    }

    /// Ce variantă pornește: alegerea din player pentru acest video, altfel setarea „Calitate la pornire”.
    private func pickChoice(_ id: String) -> StreamChoice? {
        if let o = choiceOverride, o.video == id, let c = choices.first(where: { $0.id == o.choice }) { return c }
        let av = choices.filter { !$0.vlc }
        let best1080 = av.first { $0.height <= 1080 } ?? av.last
        switch quality {
        case "vlcmax": return choices.first { $0.vlc } ?? best1080
        case "vlc30": return choices.first { $0.vlc && $0.fps <= 30 } ?? best1080
        default:
            let limit = Self.maxHeight(quality)
            return av.first { $0.height <= limit } ?? av.last
        }
    }

    /// Alegerea calității din player (doar pentru video-ul curent).
    func selectChoice(_ choiceId: String) {
        guard let t = current, choiceId != currentChoice else { return }
        choiceOverride = (t.id, choiceId)
        reloadNative()
    }

    /// true = pornit nativ (sau cererea a fost depășită de alt video); false = trebuie pagina YouTube.
    private func startNative(_ id: String, start: Double, token: Int) async -> Bool {
        // Fără „PO token”, YouTube dă clientului iOS doar ~primul minut: mai departe nu are rost.
        if start > 50 {
            diag.lastEvent = "nativ: YouTube dă doar primul minut → pagina YouTube de la \(Int(start)) s"
            return false
        }
        let r: NativeStreams.Result
        if let c = lastStreams, c.id == id, !c.result.formats.isEmpty {
            r = c.result
        } else {
            r = await NativeStreams.fetch(id)
            guard token == loadToken else { return true }
            lastStreams = (id, r)
        }
        choices = Self.buildChoices(r)
        guard let ch = pickChoice(id) else {
            diag.lastEvent = "nativ indisponibil (" + (r.error ?? "fără H.264") + ") → pagina YouTube"
            return false
        }
        currentChoice = ch.id
        currentQuality = Self.level(ch.height)
        if let spec = r.storyboardSpec { storyboard = Storyboard(spec: spec) }
        #if canImport(TVVLCKit)
        if ch.vlc {
            let audio = r.bestAudio
            startVLC(ch.video, audio: audio, start: start)
            diag.lastEvent = "VLC: " + ch.video.summary
            diag.codecs = ch.video.codecs + (audio.map { ", " + $0.codecs } ?? "")
            return true
        }
        stopVLC()
        #endif
        let v = ch.video
        guard let a = r.formats.filter({ $0.isAudio && $0.codecName == "AAC" && $0.indexRange != nil && $0.initRange != nil })
            .max(by: { $0.bitrate < $1.bitrate }) else {
            diag.lastEvent = "nativ: lipsește sunetul AAC → pagina YouTube"
            return false
        }
        do {
            let (item, loader) = try await LocalHLS.item(video: v, audio: a, ua: NativeStreams.userAgent)
            guard token == loadToken else { return true }
            nativeLoader = loader
            avPlayer.replaceCurrentItem(with: item)
            if start > 1 {
                // Poziția se poate seta doar după ce item-ul e gata.
                for _ in 0..<150 where item.status == .unknown { try? await Task.sleep(nanoseconds: 100_000_000) }
                guard token == loadToken else { return true }
                if item.status == .readyToPlay { _ = await avPlayer.seek(to: CMTime(seconds: start, preferredTimescale: 600)) }
            }
            guard token == loadToken else { return true }
            if wantPlay && !suspended { avPlayer.playImmediately(atRate: Float(rate)) }
            diag.lastEvent = "nativ: " + v.summary
            diag.codecs = v.codecs + ", " + a.codecs
            return true
        } catch {
            diag.lastEvent = "nativ: \(error.localizedDescription) → pagina YouTube"
            return false
        }
    }

    // MARK: - VLC (peste 1080p: VP9 decodat în software, prin proxy-ul local)

    #if canImport(TVVLCKit)
    private func startVLC(_ v: NativeStreams.Format, audio: NativeStreams.Format?, start: Double) {
        avPlayer.pause()
        avPlayer.replaceCurrentItem(with: nil)
        nativeLoader = nil
        vlc.stop()
        let ua = NativeStreams.userAgent
        let media = VLCMedia(url: ChunkProxy.shared.localURL(for: v.url, ua: ua, length: v.contentLength))
        media.addOption(":network-caching=3000")
        if start > 1 { media.addOption(":start-time=\(Int(start))") }
        vlc.drawable = vlcView
        vlc.media = media
        if let a = audio {
            vlc.addPlaybackSlave(ChunkProxy.shared.localURL(for: a.url, ua: ua, length: a.contentLength), type: .audio, enforce: true)
        }
        vlcEnded = false
        useVLC = true
        if wantPlay && !suspended {
            vlc.play()
            if rate != 1 { vlc.rate = Float(rate) }
        }
        vlcTimer?.invalidate()
        vlcTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.vlcTick() }
        }
    }

    private func vlcTick() {
        guard useVLC else { return }
        let st = vlc.state
        if st == .error {
            diag.lastEvent = "VLC: eroare → AVPlayer 1080p"
            if let t = current { choiceOverride = (t.id, choices.first { !$0.vlc && $0.height <= 1080 }?.id ?? "") }
            reloadNative()
            return
        }
        if st == .ended {
            if !vlcEnded { vlcEnded = true; onEnded() }
            return
        }
        let pos = Double(vlc.time.intValue) / 1000
        let dur = Double(vlc.media?.length.intValue ?? 0) / 1000
        let p = vlc.isPlaying
        onState(playing: p, pos: max(pos, 0), dur: max(dur, 0), ad: false, buf: !p && wantPlay, native: true)
        let s = vlc.videoSize
        diag.videoSize = s.width > 0 ? "\(Int(s.width))×\(Int(s.height))" : "—"
        if let m = vlc.media {
            sampleStats(bytes: Int64(m.numberOfReadBytesOnInput), fps: nil, displayed: Int(m.numberOfDisplayedPictures),
                        dropped: Int(m.numberOfLostPictures), estimatedFrames: 0, buffer: 0, stream: nil)
        }
    }
    #endif

    private func stopVLC() {
        #if canImport(TVVLCKit)
        vlcTimer?.invalidate()
        vlcTimer = nil
        if useVLC { vlc.stop() }
        #endif
        useVLC = false
    }

    /// Altă calitate pe același video: reîncarcă fluxul nativ de la poziția curentă.
    private func reloadNative() {
        guard let t = current, loaded else { return }
        loadToken += 1
        let token = loadToken
        let pos = clock.position
        buffering = true
        resetStats()
        Task { @MainActor in
            let ok = await startNative(t.id, start: pos, token: token)
            if !ok && token == loadToken, let u = URL(string: siteMode.url(t.id, start: Int(pos))) { fallbackToWeb(u) }
        }
    }

    private func fallbackToWeb(_ u: URL) {
        stopNative()
        loadWeb(u)
    }

    private func stopNative() {
        stopVLC()
        choices = []
        currentChoice = ""
        nativeActive = false
        avPlayer.pause()
        avPlayer.replaceCurrentItem(with: nil)
        nativeLoader = nil
    }

    /// Schimbă video-ul în pagina deja deschisă (player-ul YouTube: loadVideoById). Dacă nu merge sau
    /// nu pornește în 8 s, reîncarcă pagina ca înainte.
    private func switchInPage(_ id: String, start: Double, fallback u: URL, token: Int) {
        MSERenderer.shared.reset(keepFormats: true)
        let code = "(function(){try{var mp=document.getElementById('movie_player');if(!mp||!mp.loadVideoById)return 'nu';" +
            "window.__ppMSEReset&&window.__ppMSEReset();mp.loadVideoById({videoId:'\(id)',startSeconds:\(Int(start))});return 'ok';}catch(e){return 'eroare: '+e;}})()"
        web?.evaluate(code) { [weak self] r, _ in
            Task { @MainActor in
                guard let self, token == self.loadToken else { return }
                guard (r as? String) == "ok" else {
                    self.diag.lastEvent = "schimbare rapidă indisponibilă → reîncarc pagina"
                    self.loadWeb(u)
                    return
                }
                self.diag.lastEvent = "video schimbat în aceeași pagină"
                self.applyState()
                self.loadPageInfo(attempt: 0)
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard token == self.loadToken else { return }
                let check = "(function(){try{var d=document.getElementById('movie_player').getVideoData();return (d&&d.video_id)||''}catch(e){return ''}})()"
                self.web?.evaluate(check) { r2, _ in
                    Task { @MainActor in
                        guard token == self.loadToken else { return }
                        if (r2 as? String) != id || (MSERenderer.shared.bytesIn == 0 && !self.playing) {
                            self.diag.lastEvent = "schimbarea rapidă n-a pornit → reîncarc pagina"
                            self.loadWeb(u)
                        }
                    }
                }
            }
        }
    }

    private var inPageSwitches = 0

    private func loadWeb(_ u: URL) {
        inPageSwitches = 0
        pageSiteMode = siteMode
        webHasContent = true
        if ready { web?.load(u) } else { pendingURL = u }
    }

    /// Pagina YouTube nu trebuie să cânte în paralel cu player-ul nativ.
    private func stopWebPage() {
        pendingURL = nil
        guard webHasContent else { return }
        js("window.__ppWant=false;document.querySelectorAll('video').forEach(function(v){try{v.pause();}catch(e){}});")
        if ready { web?.load(URL(string: "about:blank")!) }
        webHasContent = false
    }

    private func nativeTick() {
        checkNativeStartTimeout()
        guard nativeActive, let it = avPlayer.currentItem else { return }
        if it.status == .failed {
            let msg = it.error?.localizedDescription ?? "eroare"
            diag.lastEvent = "nativ a eșuat: \(msg) → pagina YouTube"
            if let t = current, let u = URL(string: siteMode.url(t.id, start: Int(clock.position))) { fallbackToWeb(u) }
            return
        }
        guard it.status == .readyToPlay else { return }
        let pos = avPlayer.currentTime().seconds
        let dur = it.duration.seconds
        let p = avPlayer.timeControlStatus == .playing
        let buf = avPlayer.timeControlStatus == .waitingToPlayAtSpecifiedRate
        onState(playing: p, pos: pos.isFinite ? pos : 0, dur: dur.isFinite ? dur : 0, ad: false, buf: buf, native: true)
        let s = it.presentationSize
        diag.videoSize = s.width > 0 ? "\(Int(s.width))×\(Int(s.height))" : "—"
        // Statistici live (o dată pe secundă): traficul din octeții primiți, nu media din jurnal.
        let events = it.accessLog()?.events ?? []
        let bytes = events.reduce(Int64(0)) { $0 + max($1.numberOfBytesTransferred, 0) }
        let watched = events.reduce(0.0) { $0 + max($1.durationWatched, 0) }
        let dropped = events.reduce(0) { $0 + max($1.numberOfDroppedVideoFrames, 0) }
        let fps = Double(it.tracks.first { $0.assetTrack?.mediaType == .video }?.currentVideoFrameRate ?? 0)
        var buffer = 0.0
        let now = avPlayer.currentTime()
        for v in it.loadedTimeRanges {
            let r = v.timeRangeValue
            if r.start <= now && now <= r.end { buffer = (r.end - now).seconds }
        }
        sampleStats(bytes: bytes, fps: fps > 0 ? fps : nil, displayed: nil, dropped: dropped,
                    estimatedFrames: Int(watched * max(fps, 0)), buffer: buffer,
                    stream: (events.last?.indicatedBitrate).map { $0 / 1e6 })

        // Erorile de rețea ale player-ului (ex. YouTube refuză o bucată: HTTP 403).
        if let e = it.errorLog()?.events.last {
            netError = "HTTP \(e.errorStatusCode)" + (e.errorComment.map { " — " + $0 } ?? "")
        }
        // Blocaj: buffer gol și player-ul așteaptă de prea mult → cerem adrese noi și continuăm.
        // Doar un blocaj adevărat: YouTube a refuzat o bucată (403) sau video-ul a mers deja aproape un minut.
        // (La pornire AVPlayer poate încărca și 5–10 s — asta nu e blocaj.)
        let refused = netError.contains("403") || clock.position > 40
        if wantPlay && !p && buf && buffer < 0.5 && refused {
            if stallSince == 0 { stallSince = self.now() }
            // YouTube dă clientului iOS doar ~primul minut din fiecare video (apoi HTTP 403, oricât am aștepta
            // sau oricâte adrese noi am cere — testat cu tools/probe-youtube.py --time). Când se termină,
            // continuăm pe pagina YouTube de la aceeași secundă, ca să nu se oprească video-ul.
            if self.now() - stallSince > 3, let t = current,
               let u = URL(string: siteMode.url(t.id, start: Int(clock.position))) {
                stallSince = 0
                diag.lastEvent = "nativ oprit de YouTube (\(netError.isEmpty ? "fără date" : netError)) → continui pe pagina YouTube"
                fallbackToWeb(u)
            }
        } else {
            stallSince = 0
        }
    }

    /// Pornirea nativă a durat prea mult (nimic redat în 25 s) → pagina YouTube.
    private func checkNativeStartTimeout() {
        guard nativeActive, !useVLC, wantPlay, clock.position < 1, now() - loadedAt > 25,
              let t = current, let u = URL(string: siteMode.url(t.id, start: 0)) else { return }
        diag.lastEvent = "nativ: nu pornește în 25 s (\(netError.isEmpty ? "fără date" : netError)) → pagina YouTube"
        fallbackToWeb(u)
    }

    private var stallSince: TimeInterval = 0
    private var stallRecoveries = 0
    /// Ultima eroare de rețea a player-ului nativ (pentru panoul de statistici).
    @Published private(set) var netError = ""

    private var statAt: TimeInterval = 0
    private var statBytes: Int64 = -1
    private var statShown = -1

    /// Trafic, FPS, cadre și buffer din contoarele player-ului — recalculate o dată pe secundă.
    private func sampleStats(bytes: Int64, fps: Double?, displayed: Int?, dropped: Int, estimatedFrames: Int,
                             buffer: Double, stream: Double?) {
        let t = now()
        let dt = t - statAt
        guard statAt == 0 || dt >= 1 else { return }
        if statAt > 0, statBytes >= 0, bytes >= statBytes { diag.kbps = Double(bytes - statBytes) * 8 / 1000 / dt }
        if let fps { diag.fps = fps }
        if let d = displayed {
            if statShown >= 0, d >= statShown, statAt > 0 { diag.fps = Double(d - statShown) / dt }
            statShown = d
            diag.frames = d + dropped
        } else {
            diag.frames = estimatedFrames + dropped
        }
        diag.dropped = dropped
        diag.buffer = max(buffer, 0)
        if let stream, stream > 0 { diag.connection = String(format: "flux %.1f Mbit/s", stream) }
        statAt = t
        statBytes = bytes
    }

    /// La un video nou statisticile pornesc de la zero.
    private func resetStats() {
        statAt = 0; statBytes = -1; statShown = -1
        diag.kbps = 0; diag.fps = 0; diag.dropped = 0; diag.frames = 0; diag.buffer = 0
        diag.connection = ""; diag.videoSize = "—"
        netError = ""
        stallSince = 0
    }

    // MARK: - Diagnostic

    /// Ce suportă WebKit-ul de pe Apple TV (MSE, codecuri) și ce e în pagină.
    func runDiagnostics() {
        let code = """
        (function(){
          var v = document.createElement('video');
          function c(t){ try { return v.canPlayType(t) || 'nu'; } catch (e) { return 'eroare'; } }
          function m(t){ try { var M = window.MediaSource || window.ManagedMediaSource; return M && M.isTypeSupported(t) ? 'da' : 'nu'; } catch (e) { return 'eroare'; } }
          var mp = document.getElementById('movie_player');
          var lv = '';
          try { lv = (mp && mp.getAvailableQualityLevels) ? mp.getAvailableQualityLevels().join(', ') : ''; } catch (e) {}
          var pr = null;
          try { pr = (mp && mp.getPlayerResponse) ? mp.getPlayerResponse() : null; } catch (e) {}
          if (!pr) pr = window.ytInitialPlayerResponse || null;
          var sd = (pr && pr.streamingData) || {};
          var af = sd.adaptiveFormats || [], pf = sd.formats || [];
          var maxH = 0; af.concat(pf).forEach(function(f){ if (f.height > maxH) maxH = f.height; });
          var vt = document.querySelector('video');
          var src = vt ? (vt.currentSrc || vt.src || '') : '';
          var srcKind = !src ? '—' : (src.indexOf('blob:') === 0 ? 'blob (MSE)' : (src.indexOf('m3u8') >= 0 || src.indexOf('manifest') >= 0 ? 'HLS' : 'fișier direct (progresiv)'));
          return JSON.stringify({
            'User agent': navigator.userAgent,
            'Pagina': location.href,
            'MediaSource (MSE)': window.MediaSource ? 'da' : 'nu',
            'ManagedMediaSource': window.ManagedMediaSource ? 'da' : 'nu',
            'MSE H.264': m('video/mp4; codecs="avc1.4d401f"'),
            'MSE VP9': m('video/webm; codecs="vp09.00.10.08"'),
            'MSE AV1': m('video/mp4; codecs="av01.0.05M.08"'),
            'HLS': c('application/vnd.apple.mpegurl'),
            'Player YouTube': mp ? 'da' : 'nu',
            'Calități oferite': lv || '—',
            'Video în pagină': document.querySelectorAll('video').length + '',
            'WebAssembly': (typeof WebAssembly === 'object') ? 'da' : 'nu',
            'Flux HLS în răspuns': sd.hlsManifestUrl ? 'da' : 'nu',
            'Formate (adaptive / combinate)': af.length + ' / ' + pf.length + (maxH ? ' · max ' + maxH + 'p' : ''),
            'Sursa video-ului': srcKind,
            'Rezoluția redată': vt && vt.videoWidth ? (vt.videoWidth + '×' + vt.videoHeight) : '—',
            'Stare redare': (pr && pr.playabilityStatus && pr.playabilityStatus.status) || '—'
          });
        })()
        """
        web?.evaluate(code) { [weak self] r, err in
            Task { @MainActor in
                guard let self else { return }
                if let s = r as? String, let d = s.data(using: .utf8),
                   let o = try? JSONSerialization.jsonObject(with: d) as? [String: String] {
                    self.diag.page = o
                    if FakeMSE.enabled {
                        self.web?.evaluate(FakeMSE.reportJS) { r2, _ in
                            Task { @MainActor in
                                if let s2 = r2 as? String, let d2 = s2.data(using: .utf8),
                                   let o2 = try? JSONSerialization.jsonObject(with: d2) as? [String: String] {
                                    self.diag.page.merge(o2) { _, b in b }
                                    self.diag.page["MSE fals: redare nativă"] = MSERenderer.shared.info
                                    // Și în consola Xcode (se poate copia de acolo).
                                    for k in o2.keys.sorted() { NSLog("ParkPlayTV %@ = %@", k, o2[k] ?? "") }
                                }
                            }
                        }
                    }
                } else {
                    self.diag.page = ["Eroare": err?.localizedDescription ?? "pagina nu răspunde"]
                }
            }
        }
    }

    // MARK: - „Browserul tău nu poate reda videoclipul”

    /// Pagina desktop cere Media Source Extensions, pe care WebKit-ul de pe Apple TV poate să nu le aibă.
    /// Dacă YouTube afișează o eroare de redare, trecem singuri pe site-ul mobil (HLS, fără MSE).
    private var checkTask: Task<Void, Never>?

    func checkPlayable(after seconds: Double) {
        checkTask?.cancel()
        let id = current?.id
        checkTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, current?.id == id else { return }
            let code = """
            (function(){
              var sel = '.ytp-error-content-wrap-reason, .ytp-error, .player-error, ytm-player-error-message-renderer, .ytm-player-error-message-renderer';
              var e = document.querySelector(sel);
              var t = e ? (e.innerText || e.textContent || '').trim() : '';
              return JSON.stringify({err: t, mse: !!(window.MediaSource || window.ManagedMediaSource)});
            })()
            """
            self.web?.evaluate(code) { r, _ in
                Task { @MainActor in
                    guard let s = r as? String, let d = s.data(using: .utf8),
                          let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
                    let err = o["err"] as? String ?? ""
                    let mse = o["mse"] as? Bool ?? false
                    if !err.isEmpty || (!mse && self.siteMode == .desktop && !self.playing) {
                        if self.siteMode == .desktop {
                            self.diag.lastEvent = "desktop nu merge (" + (err.isEmpty ? "fără MSE" : err) + ") → trec pe mobil"
                            self.siteMode = .mobile   // reîncarcă video-ul curent pe m.youtube
                        } else {
                            self.diag.lastEvent = "YouTube (mobil): " + (err.isEmpty ? "video-ul nu pornește" : err)
                            let e = err.lowercased()
                            if e.contains("bot") || e.contains("sign in") || e.contains("conecteaz") || e.contains("login") {
                                TVAppState.shared.toast(self.signedIn
                                    ? "YouTube cere din nou login: trimite cookie-uri noi din Setări → Sincronizare"
                                    : "YouTube cere login: conectează contul din Setări → Sincronizare")
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Cont YouTube (cookie-uri trimise de pe telefon / Mac prin pagina de sincronizare)

    /// YouTube cere uneori pe Apple TV „Sign in to confirm you're not a bot” (LOGIN_REQUIRED).
    /// Cu cookie-urile unui cont logat, pagina m.youtube redă normal. WebKit le ține singur
    /// (magazinul de date e persistent) și le reînnoiește; nu le mai rescriem la pornire.
    @Published private(set) var signedIn = UserDefaults.standard.bool(forKey: "yt_signed_in")

    private static let authNames: Set<String> = [
        "SID", "HSID", "SSID", "APISID", "SAPISID", "LOGIN_INFO",
        "__Secure-1PSID", "__Secure-3PSID", "__Secure-1PAPISID", "__Secure-3PAPISID",
    ]

    func signIn(with cookies: [HTTPCookie]) async -> String {
        guard let w = web else { return "WebKit nu e disponibil pe acest Apple TV" }
        guard cookies.contains(where: { Self.authNames.contains($0.name) }) else {
            return cookies.isEmpty
                ? "Nu am găsit cookie-uri YouTube în textul lipit"
                : "Lipsesc cookie-urile de login (SID, SAPISID…). Ești logat pe youtube.com în browserul din care le-ai exportat?"
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in w.setCookies(cookies) { c.resume() } }
        signedIn = true
        UserDefaults.standard.set(true, forKey: "yt_signed_in")
        diag.lastEvent = "cont YouTube conectat (\(cookies.count) cookie-uri)"
        if loaded && index >= 0 { playIndex(index, start: clock.position) }
        return "Conectat: am pus \(cookies.count) cookie-uri YouTube pe Apple TV"
    }

    // MARK: - Calea 1080p (MediaSource fals + redare nativă): statistici și rezervă

    private var mseStatAt: TimeInterval = 0
    private var mseStatBytes = 0
    private var mseStatFrames = 0
    /// Video-ul curent merge pe varianta simplă (pagina fără MediaSource fals, 360p).
    @Published private(set) var mseFallback = false

    private func mseStats(_ r: MSERenderer) {
        guard FakeMSE.enabled, !nativeActive, !mseFallback else { return }
        let t = now()
        let dt = t - mseStatAt
        guard dt >= 1 else { return }
        if mseStatAt > 0 {
            if r.bytesIn >= mseStatBytes { diag.kbps = Double(r.bytesIn - mseStatBytes) * 8 / 1000 / dt }
            if r.framesIn >= mseStatFrames { diag.fps = Double(r.framesIn - mseStatFrames) / dt }
        }
        mseStatAt = t; mseStatBytes = r.bytesIn; mseStatFrames = r.framesIn
        diag.frames = r.framesIn
        diag.dropped = 0
        diag.buffer = r.ahead
        let s = r.videoSize
        diag.videoSize = s.width > 0 ? "\(Int(s.width))×\(Int(s.height))" : "—"
        diag.connection = "redare nativă · " + r.info
    }

    /// Dacă MediaSource-ul fals n-a primit nimic la 15 s după încărcare, reîncărcăm pagina fără el (360p).
    private func checkMSEFallback(_ r: MSERenderer) {
        guard FakeMSE.enabled, !nativeActive, !mseFallback, loaded, wantPlay, webHasContent,
              now() - loadedAt > 15, r.bytesIn == 0, !playing, let t = current else { return }
        mseFallback = true
        diag.lastEvent = "1080p (MediaSource) n-a primit date → varianta simplă 360p"
        let u = siteMode.url(t.id, start: Int(clock.position))
        if let url = URL(string: u + (u.contains("?") ? "&" : "?") + "pp_nomse=1") { loadWeb(url) }
    }

    /// Cookie-urile din WebKit (pentru feed-ul „Acasă” al contului).
    func youTubeCookies() async -> [HTTPCookie] {
        guard let w = web else { return [] }
        return await withCheckedContinuation { (c: CheckedContinuation<[HTTPCookie], Never>) in
            w.getCookies { c.resume(returning: $0) }
        }
    }

    /// „Browser curat”: șterge cookie-urile, stocarea și cache-ul paginii YouTube (inclusiv contul),
    /// apoi pune la loc doar consimțământul pentru cookie-uri. Video-ul curent se reîncarcă.
    func clearBrowserData() {
        signedIn = false
        UserDefaults.standard.set(false, forKey: "yt_signed_in")
        guard let w = web else { return }
        w.clearAllData {
            let year = Date().addingTimeInterval(3600 * 24 * 365)
            let consent = [
                HTTPCookie(properties: [.name: "SOCS", .value: "CAI", .domain: ".youtube.com", .path: "/", .secure: "TRUE", .expires: year]),
                HTTPCookie(properties: [.name: "CONSENT", .value: "YES+1", .domain: ".youtube.com", .path: "/", .expires: year]),
            ].compactMap { $0 }
            w.setCookies(consent) {
                Task { @MainActor in
                    self.diag.lastEvent = "datele browserului șterse (browser curat)"
                    if self.loaded && self.index >= 0 { self.playIndex(self.index, start: self.clock.position) }
                }
            }
        }
    }

    func signOut() {
        signedIn = false
        UserDefaults.standard.set(false, forKey: "yt_signed_in")
        web?.getCookies { all in
            let mine = all.filter {
                ($0.domain.hasSuffix("youtube.com") || $0.domain.hasSuffix("google.com")) && $0.name != "SOCS" && $0.name != "CONSENT"
            }
            Task { @MainActor in self.removeCookies(mine) }
        }
    }

    private func removeCookies(_ mine: [HTTPCookie]) {
        web?.deleteCookies(mine) {
            Task { @MainActor in
                self.diag.lastEvent = "cont YouTube deconectat"
                if self.loaded && self.index >= 0 { self.playIndex(self.index, start: self.clock.position) }
            }
        }
    }

    // MARK: - Autoplay

    private func extend() {
        guard let last = current, autoplay, !extending else { return }
        extending = true
        Task { @MainActor in
            let mix = await YouTubeSearch.mix(last.id)
            extending = false
            let known = Set(queue.map(\.id))
            let fresh = Array(mix.filter { !known.contains($0.id) }.prefix(25))
            guard !fresh.isEmpty, current?.id == last.id else { return }
            queue += fresh
            playIndex(index + 1)
        }
    }

    // MARK: - PPWebViewDelegate

    nonisolated func ppWebViewDidFinish() {
        Task { @MainActor in
            guard !self.suspended, !self.nativeActive else { return }
            self.web?.evaluate(PageScripts.bridge, completion: nil)
            self.applyState()
            self.diag.lastEvent = "pagina s-a încărcat"
            self.runDiagnostics()
            self.checkPlayable(after: 4)
            self.loadPageInfo(attempt: 0)
        }
    }

    nonisolated func ppWebViewProcessTerminated() {
        Task { @MainActor in
            // În fundal tvOS oprește singur procesul paginii: NU îl repornim (ar porni video-ul
            // fără ecran și ar ține / trezi Apple TV-ul). Îl reîncărcăm doar dacă ne uităm.
            guard !self.suspended, self.loaded else { self.loaded = false; return }
            guard !self.nativeActive else { return }
            self.diag.lastEvent = "procesul paginii a căzut — reîncarc"
            self.web?.reload()
        }
    }

    // MARK: - Fundal: aplicația ieșită de pe ecran se oprește de tot

    /// Apăsat Home / TV-ul adoarme: salvăm unde ai rămas, oprim video-ul și golim pagina
    /// (altfel WebKit continuă să cânte în procesul lui și Apple TV-ul nu mai doarme).
    func suspend() {
        guard !suspended else { return }
        savePosition()
        saveSession()
        suspended = true
        checkTask?.cancel()
        wantPlay = false
        playing = false
        buffering = false
        lastStatTick = 0
        js("window.__ppWant=false;document.querySelectorAll('video').forEach(function(v){try{v.pause();v.removeAttribute('src');v.load();}catch(e){}});")
        pendingURL = nil
        if ready { web?.load(URL(string: "about:blank")!) }
        webHasContent = false
        stopNative()
        MSERenderer.shared.reset()
        loaded = false
        if queue.indices.contains(index) { clock.position = WatchPositions.resumePoint(queue[index].id) ?? clock.position }
        StatsStore.flush()
        Prefs.shared.writeNow()
    }

    /// Înapoi pe ecran: video-ul rămâne oprit; „Continuă” / ▶ îl pornește de unde ai rămas.
    func wake() {
        suspended = false
    }

    // MARK: - Radio: o listă nesfârșită de video-uri asemănătoare cu cel curent

    func startRadio() {
        guard let cur = current, !radioLoading else { return }
        radioLoading = true
        TVAppState.shared.toast("📻 Pornesc radioul…")
        Task { @MainActor in
            let mix = await YouTubeSearch.mix(cur.id, limit: 50)
            radioLoading = false
            guard current?.id == cur.id else { return }
            let fresh = mix.filter { $0.id != cur.id }
            guard !fresh.isEmpty else { TVAppState.shared.toast("Nu am găsit video-uri asemănătoare"); return }
            queue = [cur] + fresh
            index = 0
            if !autoplay { autoplay = true }
            saveSession()
            TVAppState.shared.toast("📻 Radio: \(fresh.count) video-uri ca „\(cur.title)”")
        }
    }

    nonisolated func ppWebViewMessage(_ body: Any) {
        let dict = body as? [String: Any]
        Task { @MainActor in if let dict { self.receive(dict) } }
    }

    private func receive(_ m: [String: Any]) {
        func d(_ k: String) -> Double { (m[k] as? NSNumber)?.doubleValue ?? 0 }
        func b(_ k: String) -> Bool { (m[k] as? NSNumber)?.boolValue ?? false }
        // Bucățile și comenzile MediaSource-ului fals (redare nativă a paginii YouTube).
        switch m["t"] as? String {
        case "mse":
            if let s = m["d"] as? String, let data = Data(base64Encoded: s) {
                MSERenderer.shared.append(kind: m["k"] as? String ?? "v", data: data, offset: d("o"))
            }
            return
        case "mse-reset": MSERenderer.shared.reset(); return
        case "mse-play": MSERenderer.shared.play(); return
        case "mse-pause": MSERenderer.shared.pause(); return
        case "mse-seek":
            if !MSERenderer.shared.seek(d("time"), keep: b("keep")) {
                js("window.__ppDropRanges&&window.__ppDropRanges()")   // nu era în memorie: pagina retrimite
            }
            return
        case "mse-rm":
            MSERenderer.shared.remove(kind: m["k"] as? String ?? "v", from: d("a"), to: d("b"))
            return
        default: break
        }
        if nativeActive && m["t"] as? String != "stats" { return } // pagina veche nu mai comandă
        switch m["t"] as? String {
        case "state":
            onState(playing: b("p"), pos: d("pos"), dur: d("d"), ad: b("ad"), buf: b("buf"))
        case "ended":
            onEnded()
        case "q":
            qualities = (m["l"] as? [Any])?.compactMap { $0 as? String } ?? []
            currentQuality = m["c"] as? String ?? ""
        case "stats":
            if nativeActive { return }
            if FakeMSE.enabled && !mseFallback { return } // le dă redarea nativă (mseStats)
            diag.fps = max(0, d("fps"))
            diag.kbps = max(0, d("kbps"))
            diag.dropped = Int(d("dropped"))
            diag.frames = Int(d("frames"))
            diag.buffer = d("buf")
            let w = Int(d("vw")), h = Int(d("vh"))
            diag.videoSize = w > 0 ? "\(w)×\(h)" : "—"
            diag.codecs = m["codecs"] as? String ?? ""
            diag.connection = m["conn"] as? String ?? ""
        default:
            break
        }
    }

    private func onState(playing p: Bool, pos: Double, dur: Double, ad: Bool, buf: Bool, native: Bool = false) {
        guard let t = current else { return }
        let expected = t.expectedDuration
        // Pe calea nativă nu există reclame: durata e a video-ului.
        let looksAd = ad || (!native && expected > 0 && dur > 0 && abs(dur - expected) > 5)
        if looksAd && !lastAdState { diag.adsSkipped += 1 }
        lastAdState = looksAd
        if inAd != looksAd { inAd = looksAd }
        if playing != p { playing = p }
        let b = p ? buf : (buf || (wantPlay && now() - loadedAt < 30 && pos < 1))
        if buffering != b { buffering = b }
        let n = now()
        if p && !looksAd && lastStatTick > 0 { StatsStore.addListening(t, seconds: min(n - lastStatTick, 5)) }
        lastStatTick = (p && !looksAd) ? n : 0
        if n - lastFlush > 30 { lastFlush = n; StatsStore.flush() }
        guard !looksAd else { return }
        clock.position = pos
        if dur > 0 { clock.duration = dur }
        if p && n - lastPositionSave > 10 { savePosition() }
        if p, let seg = segments.first(where: { pos >= $0.start - 0.3 && pos < $0.end - 0.7 }) {
            seek(to: seg.end)
        }
    }

    private func onEnded() {
        if inAd || now() - loadedAt < 4 { return }
        let ref = clock.duration > 0 ? clock.duration : (current?.expectedDuration ?? 0)
        if ref > 0 && clock.position < ref - 10 { return }
        if let t = current { WatchPositions.set(t.id, position: ref, duration: ref) } // văzut până la capăt
        next()
    }

    // MARK: - Unde ai rămas + sesiunea (lista) la repornire

    /// Salvează poziția video-ului curent (pentru „continuă de unde ai rămas”).
    func savePosition() {
        lastPositionSave = now()
        guard loaded, let t = current, clock.position > 0 else { return }
        WatchPositions.set(t.id, position: clock.position, duration: clock.duration)
    }

    private struct Session: Codable {
        let queue: [Track]
        let index: Int
    }

    private func saveSession() {
        let s = Session(queue: Array(queue.prefix(200)), index: min(index, 199))
        if let d = try? JSONEncoder().encode(s) { UserDefaults.standard.set(d, forKey: "tv_session") }
    }

    private func restoreSession() {
        guard let d = UserDefaults.standard.data(forKey: "tv_session"),
              let s = try? JSONDecoder().decode(Session.self, from: d), s.queue.indices.contains(s.index) else { return }
        queue = s.queue
        index = s.index
        loaded = false
        clock.position = WatchPositions.resumePoint(s.queue[s.index].id) ?? 0
        clock.duration = s.queue[s.index].expectedDuration
    }

    /// Butonul „Continuă” de pe Acasă: pornește video-ul de unde ai rămas.
    func resume() {
        if !loaded && index >= 0 { playIndex(index) } else if !wantPlay { play() }
    }

    /// Aplicația iese de pe ecran: ține minte tot.
    func saveAll() {
        savePosition()
        saveSession()
        StatsStore.flush()
        Prefs.shared.writeNow()
    }

    // MARK: - Subtitrări și storyboard (din răspunsul playerului)

    /// Citește din pagină lista de subtitrări și storyboard-ul (reîncearcă până e gata playerul).
    private func loadPageInfo(attempt: Int) {
        let id = current?.id
        let code = """
        (function(){
          try {
            var mp = document.getElementById('movie_player');
            var r = null;
            try { r = mp && mp.getPlayerResponse ? mp.getPlayerResponse() : null; } catch (e) {}
            if (!r || !r.videoDetails) r = window.ytInitialPlayerResponse || r;
            if (!r) return '';
            var out = {vid: (r.videoDetails && r.videoDetails.videoId) || '', tracks: [], sb: ''};
            var c = r.captions && r.captions.playerCaptionsTracklistRenderer;
            if (c && c.captionTracks) c.captionTracks.forEach(function(t){
              var n = t.name ? (t.name.simpleText || (t.name.runs || []).map(function(x){ return x.text; }).join('')) : t.languageCode;
              out.tracks.push({code: t.languageCode, name: n || t.languageCode, auto: t.kind === 'asr'});
            });
            var s = r.storyboards && (r.storyboards.playerStoryboardSpecRenderer || r.storyboards.playerLiveStoryboardSpecRenderer);
            if (s && s.spec) out.sb = s.spec;
            return JSON.stringify(out);
          } catch (e) { return ''; }
        })()
        """
        web?.evaluate(code) { r, _ in
            Task { @MainActor in
                guard self.current?.id == id else { return }
                guard let str = r as? String, let d = str.data(using: .utf8),
                      let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                      (o["vid"] as? String ?? "") == (id ?? "") else {
                    if attempt < 6 {
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            self.loadPageInfo(attempt: attempt + 1)
                        }
                    }
                    return
                }
                let tracks = (o["tracks"] as? [[String: Any]] ?? []).compactMap { t -> CaptionTrack? in
                    guard let c = t["code"] as? String else { return nil }
                    return CaptionTrack(code: c, name: t["name"] as? String ?? c, auto: (t["auto"] as? Bool) ?? false)
                }
                self.captionTracks = tracks
                self.storyboard = (o["sb"] as? String).flatMap { Storyboard(spec: $0) }
                self.applyCaptions()
            }
        }
    }

    /// Pornește / oprește subtitrările în playerul YouTube (le desenează chiar YouTube).
    func applyCaptions() {
        var code = ""
        var translate = ""
        if captionChoice != "off" && !captionTracks.isEmpty {
            let manual = captionTracks.first { !$0.auto } ?? captionTracks[0]
            if captionChoice.hasPrefix("tr:") {
                let lang = String(captionChoice.dropFirst(3))
                if let own = captionTracks.first(where: { $0.code == lang && !$0.auto }) ?? captionTracks.first(where: { $0.code == lang }) {
                    code = own.code
                } else {
                    code = manual.code
                    translate = lang
                }
            } else if let t = captionTracks.first(where: { $0.code == captionChoice && !$0.auto })
                        ?? captionTracks.first(where: { $0.code == captionChoice }) {
                code = t.code
            } else {
                // Video-ul n-are limba aleasă: traducere automată din prima pistă.
                code = manual.code
                translate = captionChoice
            }
        }
        let opts: [String: Any] = ["code": code, "tl": translate, "size": captionSize]
        guard let d = try? JSONSerialization.data(withJSONObject: opts) else { return }
        let o = String(decoding: d, as: UTF8.self)
        js("""
        (function(o){
          var mp = document.getElementById('movie_player');
          var root = document.documentElement;
          root.style.setProperty('--pp-cc-size', String(o.size));
          if (!mp || !mp.setOption) return;
          if (!o.code) {
            root.classList.remove('pp-cc');
            try { mp.setOption('captions', 'track', {}); } catch (e) {}
            try { mp.unloadModule('captions'); } catch (e) {}
            return;
          }
          root.classList.add('pp-cc');
          try { mp.loadModule('captions'); } catch (e) {}
          var t = {languageCode: o.code};
          if (o.tl) t.translationLanguage = {languageCode: o.tl};
          var set = function(){ try { mp.setOption('captions', 'track', t); } catch (e) {} };
          set(); setTimeout(set, 800); setTimeout(set, 2500);
        })(\(o));
        """)
    }
}
