import Foundation
import Network

/// Proxy local pentru fluxurile YouTube: VLC cere fișierul „de la X până la final” (bytes=X-),
/// iar YouTube refuză asemenea cereri (HTTP 403) pentru clientul iOS. Proxy-ul primește cererea
/// de la VLC pe 127.0.0.1 și o împarte în bucăți mici cu capăt precis (bytes=X-Y), pe care YouTube
/// le acceptă. Merge pentru orice container (webm VP9, mp4 AV1 / H.264, sunet). Autor: arturm
final class ChunkProxy: @unchecked Sendable {

    static let shared = ChunkProxy()
    static let port: UInt16 = 8091
    /// Mărimea unei bucăți cerute de la YouTube (bucata următoare se cere cât se trimite cea curentă).
    private let chunk = 4 << 20

    private struct Source {
        let url: URL
        let ua: String
        let length: Int?
    }

    private let lock = NSLock()
    private var sources: [String: Source] = [:]
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "ParkPlayTV.proxy")
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20
        c.httpShouldSetCookies = false
        return URLSession(configuration: c)
    }()

    /// Adresa locală pentru un flux (pornește proxy-ul la prima folosire).
    func localURL(for url: URL, ua: String, length: Int?) -> URL {
        startIfNeeded()
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        lock.lock()
        sources[token] = Source(url: url, ua: ua, length: length)
        lock.unlock()
        return URL(string: "http://127.0.0.1:\(Self.port)/\(token)")!
    }

    /// Uită fluxurile vechi (adresele YouTube expiră oricum în câteva ore).
    func clear() {
        lock.lock()
        sources.removeAll()
        lock.unlock()
    }

    private func startIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback   // doar aplicația, nu toată rețeaua
        params.allowLocalEndpointReuse = true
        guard let port = NWEndpoint.Port(rawValue: Self.port), let l = try? NWListener(using: params, on: port) else {
            NSLog("ParkPlayTV: proxy-ul nu pornește pe portul \(Self.port)")
            return
        }
        l.newConnectionHandler = { [weak self] conn in
            guard let self else { conn.cancel(); return }
            conn.start(queue: self.queue)
            self.readRequest(conn, buffer: Data())
        }
        l.start(queue: queue)
        listener = l
    }

    // MARK: - HTTP minimal

    private func readRequest(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 << 10) { [weak self] data, _, done, error in
            guard let self else { conn.cancel(); return }
            var buf = buffer
            if let data { buf.append(data) }
            if let end = buf.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buf[..<end.lowerBound], as: UTF8.self)
                Task { await self.serve(head, conn) }
            } else if done || error != nil || buf.count > 64 << 10 {
                conn.cancel()
            } else {
                self.readRequest(conn, buffer: buf)
            }
        }
    }

    private func serve(_ head: String, _ conn: NWConnection) async {
        let lines = head.components(separatedBy: "\r\n")
        let first = lines.first?.components(separatedBy: " ") ?? []
        guard first.count >= 2 else { conn.cancel(); return }
        let method = first[0]
        let token = first[1].trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        lock.lock()
        let src = sources[token]
        lock.unlock()
        guard let src else {
            await send(conn, Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
            conn.cancel()
            return
        }
        var length = src.length
        if length == nil { length = await probeLength(src) }

        // Range: bytes=X- sau bytes=X-Y
        var start = 0
        var end: Int? = nil
        var ranged = false
        for l in lines.dropFirst() where l.lowercased().hasPrefix("range:") {
            let v = l.split(separator: "=", maxSplits: 1).last.map(String.init) ?? ""
            let parts = v.split(separator: "-", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 {
                start = Int(parts[0]) ?? 0
                end = Int(parts[1])
                ranged = true
            }
        }
        guard let total = length else {
            await send(conn, Data("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
            conn.cancel()
            return
        }
        let last = min(end ?? total - 1, total - 1)
        guard start <= last else {
            await send(conn, Data("HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */\(total)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
            conn.cancel()
            return
        }
        var h = ranged ? "HTTP/1.1 206 Partial Content\r\n" : "HTTP/1.1 200 OK\r\n"
        h += "Content-Type: application/octet-stream\r\nAccept-Ranges: bytes\r\n"
        h += "Content-Length: \(last - start + 1)\r\n"
        if ranged { h += "Content-Range: bytes \(start)-\(last)/\(total)\r\n" }
        h += "Connection: close\r\n\r\n"
        guard await send(conn, Data(h.utf8)) else { conn.cancel(); return }
        if method == "HEAD" { conn.cancel(); return }

        // Bucăți cu capăt precis; următoarea se cere cât se trimite cea curentă.
        var pos = start
        var next: Task<Data?, Never>? = fetchTask(src, pos, min(pos + chunk - 1, last))
        while let t = next {
            let data = await t.value
            guard let data, !data.isEmpty else { break }
            pos += data.count
            next = pos <= last ? fetchTask(src, pos, min(pos + chunk - 1, last)) : nil
            guard await send(conn, data) else { next?.cancel(); break }
        }
        conn.cancel()
    }

    private func fetchTask(_ s: Source, _ a: Int, _ b: Int) -> Task<Data?, Never> {
        Task {
            for attempt in 0..<3 {
                var req = URLRequest(url: s.url)
                req.setValue(s.ua, forHTTPHeaderField: "User-Agent")
                req.setValue("bytes=\(a)-\(b)", forHTTPHeaderField: "Range")
                if let (d, r) = try? await session.data(for: req),
                   let code = (r as? HTTPURLResponse)?.statusCode, code == 206 || code == 200 {
                    return d
                }
                if Task.isCancelled { return nil }
                try? await Task.sleep(nanoseconds: UInt64(300_000_000 * (attempt + 1)))
            }
            return nil
        }
    }

    /// Mărimea fișierului, dacă YouTube n-a dat-o în listă: din Content-Range-ul unei cereri mici.
    private func probeLength(_ s: Source) async -> Int? {
        var req = URLRequest(url: s.url)
        req.setValue(s.ua, forHTTPHeaderField: "User-Agent")
        req.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        guard let (_, r) = try? await session.data(for: req),
              let cr = (r as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range"),
              let total = cr.split(separator: "/").last.flatMap({ Int($0) }) else { return nil }
        return total
    }

    @discardableResult
    private func send(_ conn: NWConnection, _ data: Data) async -> Bool {
        await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            conn.send(content: data, completion: .contentProcessed { error in c.resume(returning: error == nil) })
        }
    }
}
