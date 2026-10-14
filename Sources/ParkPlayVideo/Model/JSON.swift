import Foundation

/// JSON care păstrează ordinea cheilor (ca `org.json` pe Android): rezultatele căutării
/// YouTube trebuie citite în ordinea din pagină, iar `JSONSerialization` nu o păstrează.
/// Autor: arturm
indirect enum JSON {
    case object([(String, JSON)])
    case array([JSON])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    subscript(key: String) -> JSON? {
        guard case .object(let kv) = self else { return nil }
        for (k, v) in kv where k == key { return v }
        return nil
    }

    func has(_ key: String) -> Bool { self[key] != nil }

    var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var double: Double? {
        switch self {
        case .number(let d): return d
        case .string(let s): return Double(s)
        default: return nil
        }
    }

    var array: [JSON]? {
        if case .array(let a) = self { return a }
        return nil
    }

    var isObject: Bool {
        if case .object = self { return true }
        return false
    }

    /// Obiectul de la cheia dată (null dacă nu e obiect).
    func obj(_ key: String) -> JSON? {
        guard let v = self[key], v.isObject else { return nil }
        return v
    }

    /// Text de la cheia dată ("" dacă lipsește), ca `optString`.
    func str(_ key: String) -> String { self[key]?.string ?? "" }

    // MARK: - Parsare

    static func parse(_ text: String) -> JSON? {
        var p = Parser(bytes: Array(text.utf8))
        p.skipWS()
        guard let v = p.value() else { return nil }
        return v
    }

    private struct Parser {
        let bytes: [UInt8]
        var i = 0

        init(bytes: [UInt8]) { self.bytes = bytes }

        mutating func skipWS() {
            while i < bytes.count, bytes[i] == 0x20 || bytes[i] == 0x0A || bytes[i] == 0x0D || bytes[i] == 0x09 { i += 1 }
        }

        mutating func value() -> JSON? {
            skipWS()
            guard i < bytes.count else { return nil }
            switch bytes[i] {
            case UInt8(ascii: "{"): return object()
            case UInt8(ascii: "["): return arrayValue()
            case UInt8(ascii: "\""): return stringValue().map { .string($0) }
            case UInt8(ascii: "t"): return literal("true", .bool(true))
            case UInt8(ascii: "f"): return literal("false", .bool(false))
            case UInt8(ascii: "n"): return literal("null", .null)
            default: return number()
            }
        }

        mutating func literal(_ word: String, _ v: JSON) -> JSON? {
            let w = Array(word.utf8)
            guard i + w.count <= bytes.count, Array(bytes[i..<i + w.count]) == w else { return nil }
            i += w.count
            return v
        }

        mutating func number() -> JSON? {
            let start = i
            while i < bytes.count {
                let c = bytes[i]
                if (c >= 0x30 && c <= 0x39) || c == UInt8(ascii: "-") || c == UInt8(ascii: "+") ||
                    c == UInt8(ascii: ".") || c == UInt8(ascii: "e") || c == UInt8(ascii: "E") {
                    i += 1
                } else { break }
            }
            guard i > start, let s = String(bytes: bytes[start..<i], encoding: .ascii), let d = Double(s) else { return nil }
            return .number(d)
        }

        mutating func object() -> JSON? {
            i += 1 // {
            var kv: [(String, JSON)] = []
            skipWS()
            if i < bytes.count, bytes[i] == UInt8(ascii: "}") { i += 1; return .object(kv) }
            while true {
                skipWS()
                guard i < bytes.count, bytes[i] == UInt8(ascii: "\""), let k = stringValue() else { return nil }
                skipWS()
                guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { return nil }
                i += 1
                guard let v = value() else { return nil }
                kv.append((k, v))
                skipWS()
                guard i < bytes.count else { return nil }
                if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                if bytes[i] == UInt8(ascii: "}") { i += 1; return .object(kv) }
                return nil
            }
        }

        mutating func arrayValue() -> JSON? {
            i += 1 // [
            var out: [JSON] = []
            skipWS()
            if i < bytes.count, bytes[i] == UInt8(ascii: "]") { i += 1; return .array(out) }
            while true {
                guard let v = value() else { return nil }
                out.append(v)
                skipWS()
                guard i < bytes.count else { return nil }
                if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                if bytes[i] == UInt8(ascii: "]") { i += 1; return .array(out) }
                return nil
            }
        }

        mutating func hex4() -> UInt32? {
            guard i + 4 <= bytes.count, let s = String(bytes: bytes[i..<i + 4], encoding: .ascii),
                  let v = UInt32(s, radix: 16) else { return nil }
            i += 4
            return v
        }

        mutating func stringValue() -> String? {
            i += 1 // "
            var buf: [UInt8] = []
            while i < bytes.count {
                let c = bytes[i]
                if c == UInt8(ascii: "\"") {
                    i += 1
                    return String(decoding: buf, as: UTF8.self)
                }
                if c == UInt8(ascii: "\\") {
                    i += 1
                    guard i < bytes.count else { return nil }
                    let e = bytes[i]
                    i += 1
                    switch e {
                    case UInt8(ascii: "n"): buf.append(0x0A)
                    case UInt8(ascii: "t"): buf.append(0x09)
                    case UInt8(ascii: "r"): buf.append(0x0D)
                    case UInt8(ascii: "b"): buf.append(0x08)
                    case UInt8(ascii: "f"): buf.append(0x0C)
                    case UInt8(ascii: "u"):
                        guard var code = hex4() else { return nil }
                        // Perechi surogat (emoji etc.)
                        if code >= 0xD800 && code < 0xDC00, i + 6 <= bytes.count,
                           bytes[i] == UInt8(ascii: "\\"), bytes[i + 1] == UInt8(ascii: "u") {
                            i += 2
                            if let low = hex4(), low >= 0xDC00 && low < 0xE000 {
                                code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                            }
                        }
                        let scalar = Unicode.Scalar(code) ?? "\u{FFFD}"
                        buf.append(contentsOf: Array(String(Character(scalar)).utf8))
                    default: buf.append(e) // \" \\ \/
                    }
                    continue
                }
                buf.append(c)
                i += 1
            }
            return nil
        }
    }
}
