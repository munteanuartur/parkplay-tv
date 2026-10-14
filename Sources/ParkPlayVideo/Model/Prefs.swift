import Foundation
import Combine

/// Echivalentul SharedPreferences „parkplay” de pe Android: valori pe tipuri
/// (bool, întreg, real, text), salvate într-un fișier JSON în
/// ~/Library/Application Support/ParkPlayVideo/prefs.json. Autor: arturm
final class Prefs: ObservableObject, @unchecked Sendable {

    static let shared = Prefs()

    /// Crește la orice schimbare: ecranele se redesenează.
    @Published private(set) var revision = 0

    private struct Stored: Codable {
        var bools: [String: Bool] = [:]
        var ints: [String: Int64] = [:]
        var floats: [String: Double] = [:]
        var strings: [String: String] = [:]
    }

    private var data = Stored()
    private let lock = NSLock()
    private let ioQueue = DispatchQueue(label: "ParkPlayVideo.prefs")
    private var saveScheduled = false

    let fileURL: URL = {
        #if os(tvOS)
        // Pe Apple TV se poate scrie doar în Caches (poate fi golit) — avem și o copie în UserDefaults.
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        #else
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        #endif
        let dir = base.appendingPathComponent("ParkPlayVideo", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("prefs.json")
    }()

    private init() {
        if let d = try? Data(contentsOf: fileURL), let s = try? JSONDecoder().decode(Stored.self, from: d) {
            data = s
            return
        }
        #if os(tvOS)
        if let d = UserDefaults.standard.data(forKey: Self.mirrorKey),
           let s = try? JSONDecoder().decode(Stored.self, from: d) {
            data = s
        }
        #endif
    }

    #if os(tvOS)
    private static let mirrorKey = "prefs_mirror"
    /// Ce nu intră în copia din UserDefaults (limitată la ~500 KB pe tvOS): date mari, refăcute oricum.
    private static let mirrorSkip: Set<String> = ["listening_stats", "daily_mixes", "video_resume"]
    #endif

    // MARK: - Citire

    func bool(_ key: String, default def: Bool = true) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return data.bools[key] ?? def
    }

    func string(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return data.strings[key]
    }

    func double(_ key: String, default def: Double) -> Double {
        lock.lock(); defer { lock.unlock() }
        return data.floats[key] ?? data.ints[key].map(Double.init) ?? def
    }

    func int(_ key: String, default def: Int64) -> Int64 {
        lock.lock(); defer { lock.unlock() }
        return data.ints[key] ?? def
    }

    /// Toate setările simple (pentru backup): bool, întregi, reale.
    func simpleValues() -> (bools: [String: Bool], ints: [String: Int64], floats: [String: Double]) {
        lock.lock(); defer { lock.unlock() }
        return (data.bools, data.ints, data.floats)
    }

    // MARK: - Scriere

    func set(_ key: String, bool v: Bool) { edit { $0.bools[key] = v } }
    func set(_ key: String, string v: String?) { edit { $0.strings[key] = v } }
    func set(_ key: String, double v: Double) { edit { $0.floats[key] = v } }
    func set(_ key: String, int v: Int64) { edit { $0.ints[key] = v } }

    /// Mai multe schimbări odată (o singură salvare / notificare).
    func batch(_ change: (inout BatchEditor) -> Void) {
        var e = BatchEditor()
        change(&e)
        edit { d in
            for (k, v) in e.bools { d.bools[k] = v }
            for (k, v) in e.ints { d.ints[k] = v }
            for (k, v) in e.floats { d.floats[k] = v }
            for (k, v) in e.strings { d.strings[k] = v }
        }
    }

    struct BatchEditor {
        var bools: [String: Bool] = [:]
        var ints: [String: Int64] = [:]
        var floats: [String: Double] = [:]
        var strings: [String: String] = [:]
    }

    private func edit(_ change: (inout Stored) -> Void) {
        lock.lock()
        change(&data)
        let needSave = !saveScheduled
        saveScheduled = true
        lock.unlock()
        if needSave {
            ioQueue.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.writeNow() }
        }
        if Thread.isMainThread { revision += 1 } else { DispatchQueue.main.async { self.revision += 1 } }
    }

    /// Scrie imediat pe disc (și la ieșirea din aplicație).
    func writeNow() {
        lock.lock()
        saveScheduled = false
        let snapshot = data
        lock.unlock()
        guard let d = try? JSONEncoder().encode(snapshot) else { return }
        try? d.write(to: fileURL, options: .atomic)
        #if os(tvOS)
        var small = snapshot
        for k in Self.mirrorSkip { small.strings[k] = nil }
        if let m = try? JSONEncoder().encode(small), m.count < 400_000 {
            UserDefaults.standard.set(m, forKey: Self.mirrorKey)
        }
        #endif
    }
}
