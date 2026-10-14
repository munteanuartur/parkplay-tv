import Foundation
import Network
import SwiftUI

/// Sincronizare prin rețeaua de acasă: Apple TV-ul pornește o pagină web mică
/// (http://IP-ul-Apple-TV:8080). O deschizi pe telefon sau pe Mac și poți:
///  - importa backup-ul ParkPlay (de pe Android sau Mac) — favorite, playlisturi, istoric;
///  - descărca backup-ul de pe Apple TV;
///  - trimite un link YouTube care pornește imediat pe televizor.
/// Autor: arturm
@MainActor
final class TVSync: ObservableObject {

    static let shared = TVSync()
    static let port: UInt16 = 8080

    @Published private(set) var running = false
    @Published private(set) var address = ""
    @Published private(set) var lastAction = ""

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "ParkPlayTV.sync")

    func start() {
        guard listener == nil else { return }
        do {
            let l = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: Self.port)!)
            l.newConnectionHandler = { conn in
                conn.start(queue: DispatchQueue(label: "ParkPlayTV.sync.conn"))
                Self.receive(conn, buffer: Data())
            }
            l.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready: self?.running = true
                    case .failed(let e): self?.running = false; self?.lastAction = "Serverul nu pornește: \(e)"
                    case .cancelled: self?.running = false
                    default: break
                    }
                }
            }
            l.start(queue: queue)
            listener = l
            address = Self.localIP().map { "http://\($0):\(Self.port)" } ?? "(nu găsesc adresa IP)"
        } catch {
            lastAction = "Serverul nu pornește: \(error.localizedDescription)"
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        running = false
    }

    // MARK: - HTTP minimal

    private nonisolated static func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, done, error in
            var buf = buffer
            if let data { buf.append(data) }
            if let req = Request(buf) {
                handle(req, conn)
            } else if done || error != nil || buf.count > 20 << 20 {
                conn.cancel()
            } else {
                receive(conn, buffer: buf)
            }
        }
    }

    private struct Request {
        let method: String
        let path: String
        let query: [String: String]
        let body: Data

        /// nil = cererea nu e încă completă.
        init?(_ data: Data) {
            guard let sep = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
            let head = String(decoding: data[..<sep.lowerBound], as: UTF8.self)
            let lines = head.components(separatedBy: "\r\n")
            let first = lines.first?.components(separatedBy: " ") ?? []
            guard first.count >= 2 else { return nil }
            var length = 0
            for l in lines.dropFirst() {
                let p = l.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if p.count == 2, p[0].lowercased() == "content-length" { length = Int(p[1]) ?? 0 }
            }
            let bodyStart = sep.upperBound
            guard data.count - bodyStart >= length else { return nil }
            method = first[0]
            let comps = URLComponents(string: first[1])
            path = comps?.path ?? first[1]
            var q: [String: String] = [:]
            comps?.queryItems?.forEach { q[$0.name] = $0.value ?? "" }
            query = q
            body = data.subdata(in: bodyStart..<(bodyStart + length))
        }
    }

    private nonisolated static func respond(_ conn: NWConnection, _ status: String = "200 OK", type: String, _ body: Data, extra: String = "") {
        var head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        head += extra
        head += "\r\n"
        conn.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in conn.cancel() })
    }

    private nonisolated static func handle(_ r: Request, _ conn: NWConnection) {
        switch (r.method, r.path) {
        case ("GET", "/"):
            respond(conn, type: "text/html; charset=utf-8", Data(page.utf8))
        case ("GET", "/export"):
            Task { @MainActor in
                let d = BackupManager.export()
                TVSync.shared.lastAction = "Backup descărcat de pe Apple TV"
                respond(conn, type: "application/json", d,
                        extra: "Content-Disposition: attachment; filename=\"\(BackupManager.fileName())\"\r\n")
            }
        case ("POST", "/import"):
            let replace = r.query["mode"] == "replace"
            let body = r.body
            Task { @MainActor in
                guard let s = BackupManager.inspect(body) else {
                    respond(conn, "400 Bad Request", type: "text/plain; charset=utf-8", Data("Fișierul nu e un backup ParkPlay".utf8))
                    return
                }
                do {
                    try BackupManager.importBackup(body, replace: replace)
                    let msg = "Importat: \(s.favorites) favorite, \(s.playlists) playlisturi, \(s.history) în istoric (\(replace ? "înlocuit" : "combinat"))"
                    TVSync.shared.lastAction = msg
                    respond(conn, type: "text/plain; charset=utf-8", Data(msg.utf8))
                } catch {
                    respond(conn, "400 Bad Request", type: "text/plain; charset=utf-8", Data("Import eșuat".utf8))
                }
            }
        case ("POST", "/play"):
            let text = String(decoding: r.body, as: UTF8.self)
            Task { @MainActor in
                guard let id = TVAppState.videoId(in: text) else {
                    respond(conn, "400 Bad Request", type: "text/plain; charset=utf-8", Data("Nu e un link YouTube".utf8))
                    return
                }
                let t = await YouTubeSearch.oembed(id)
                TVAppState.shared.play([t], 0)
                TVSync.shared.lastAction = "Pornit de pe telefon: \(t.title)"
                respond(conn, type: "text/plain; charset=utf-8", Data("Pornit pe Apple TV: \(t.title)".utf8))
            }
        default:
            respond(conn, "404 Not Found", type: "text/plain", Data("404".utf8))
        }
    }

    // MARK: - Adresa IP a Apple TV-ului

    nonisolated static func localIP() -> String? {
        var addr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addr) == 0, let first = addr else { return nil }
        defer { freeifaddrs(addr) }
        var best: String?
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let i = p.pointee
            guard let sa = i.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: i.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: host)
                if name == "en0" { return ip }
                best = best ?? ip
            }
        }
        return best
    }

    // MARK: - Pagina web

    nonisolated private static let page = """
    <!doctype html><html lang="ro"><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1">
    <title>ParkPlay TV</title>
    <style>
    body{font-family:-apple-system,system-ui,sans-serif;background:#121216;color:#eee;margin:0;padding:24px;max-width:640px}
    h1{font-size:22px}h2{font-size:17px;margin-top:28px}
    button,input{font-size:16px;border-radius:10px;border:0;padding:10px 16px}
    button{background:#f472b6;color:#000;font-weight:700;margin:6px 6px 0 0}
    button.alt{background:#333;color:#fff}
    input[type=text]{width:100%;box-sizing:border-box;background:#222;color:#fff;margin-top:6px}
    #msg{margin-top:16px;color:#f9a8d4;min-height:1.2em}
    a{color:#f472b6}
    </style></head><body>
    <h1>📺 ParkPlay TV</h1>
    <h2>Trimite un video pe televizor</h2>
    <input type="text" id="link" placeholder="https://youtu.be/…">
    <button onclick="send()">▶ Pornește pe Apple TV</button>
    <h2>Importă backup-ul (Android / Mac)</h2>
    <input type="file" id="file" accept=".json,application/json">
    <div><button onclick="imp('merge')">Combină</button><button class="alt" onclick="imp('replace')">Înlocuiește</button></div>
    <h2>Backup de pe Apple TV</h2>
    <a href="/export">⬇ Descarcă backup-ul</a>
    <div id="msg"></div>
    <script>
    function show(t){document.getElementById('msg').textContent=t}
    function send(){var l=document.getElementById('link').value;
      fetch('/play',{method:'POST',body:l}).then(function(r){return r.text()}).then(show).catch(function(){show('Eroare')})}
    function imp(mode){var f=document.getElementById('file').files[0];if(!f){show('Alege fișierul de backup');return}
      f.text().then(function(t){return fetch('/import?mode='+mode,{method:'POST',body:t})})
       .then(function(r){return r.text()}).then(show).catch(function(){show('Eroare')})}
    </script></body></html>
    """
}
