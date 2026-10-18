import Foundation
import AVFoundation
import CoreMedia
import AudioToolbox
import UIKit
import SwiftUI

/// Redarea bucăților fMP4 pe care player-ul YouTube din pagină le dă MediaSource-ului fals
/// (vezi TVFakeMSE): le despachetăm (moov → format, moof/mdat → cadre) și le dăm renderer-elor
/// native Apple (decodare hardware H.264 + AAC). Ceasul (sincronizatorul) e cel care contează:
/// timpul lui ajunge înapoi în pagină ca `video.currentTime`, iar player-ul YouTube cere date după el.
/// Autor: arturm
@MainActor
final class MSERenderer {

    static let shared = MSERenderer()

    let displayLayer = AVSampleBufferDisplayLayer()
    let audioRenderer = AVSampleBufferAudioRenderer()
    let sync = AVSampleBufferRenderSynchronizer()

    /// Starea afișată în Diagnostic.
    private(set) var info = ""
    private(set) var wantPlay = false
    /// Pentru statistici: octeți primiți, cadre video, secunde în buffer.
    private(set) var bytesIn = 0
    var framesIn: Int { video.frames }
    private(set) var ahead: Double = 0
    private(set) var waiting = true

    private final class Track {
        var format: CMFormatDescription?
        var timescale: Int32 = 0
        var defaultDuration: UInt32 = 0
        var defaultSize: UInt32 = 0
        var defaultFlags: UInt32 = 0
        var pending: [UInt8] = []
        var queue: [CMSampleBuffer] = []
        var lastEnd: Double = 0
        var frames = 0
        var width = 0
        var height = 0
    }

    private var video = Track()
    private var audio = Track()

    private init() {
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor
        sync.addRenderer(displayLayer)
        sync.addRenderer(audioRenderer)
        displayLayer.requestMediaDataWhenReady(on: .main) { [weak self] in
            MainActor.assumeIsolated { self?.pump() }
        }
        audioRenderer.requestMediaDataWhenReady(on: .main) { [weak self] in
            MainActor.assumeIsolated { self?.pump() }
        }
    }

    var currentTime: Double {
        let t = sync.currentTime().seconds
        return t.isFinite ? max(t, 0) : 0
    }
    var isPlaying: Bool { sync.rate > 0 }
    var videoSize: CGSize { CGSize(width: video.width, height: video.height) }

    // MARK: - Comenzi (din pagină: play / pause / seek / reset)

    func reset() {
        sync.rate = 0
        displayLayer.flushAndRemoveImage()
        audioRenderer.flush()
        video = Track()
        audio = Track()
        bytesIn = 0
        ahead = 0
        sync.setRate(0, time: .zero)
        waiting = true
        wantPlay = false
    }

    func play() {
        wantPlay = true
        update()
    }

    func pause() {
        wantPlay = false
        sync.rate = 0
    }

    func seek(_ t: Double) {
        displayLayer.flush()
        audioRenderer.flush()
        for tr in [video, audio] {
            tr.queue.removeAll()
            tr.lastEnd = t
        }
        sync.setRate(0, time: CMTime(seconds: max(t, 0), preferredTimescale: 90_000))
        waiting = true
    }

    /// Bucată nouă de la pagină. `kind` = "v" / "a"; `offset` = timestampOffset al SourceBuffer-ului.
    func append(kind: String, data: Data, offset: Double) {
        let tr = kind == "v" ? video : audio
        bytesIn += data.count
        tr.pending.append(contentsOf: data)
        parse(tr, isVideo: kind == "v", offset: offset)
        pump()
        update()
    }

    /// Apelat periodic: pornește / oprește ceasul după cât e în buffer.
    func update() {
        let t = currentTime
        let active = [video, audio].filter { $0.format != nil }
        guard !active.isEmpty else { waiting = true; return }
        let ahead = (active.map { $0.lastEnd }.min() ?? 0) - t
        self.ahead = max(ahead, 0)
        if sync.rate > 0 && ahead < 0.15 {
            sync.rate = 0
            waiting = true
        } else if sync.rate == 0 && wantPlay && ahead > 1.0 {
            sync.rate = 1
            waiting = false
        }
        info = String(format: "%@ · %.1f s · buffer %.1f s · cadre %d · %dx%d",
                      sync.rate > 0 ? "rulează" : (wantPlay ? "așteaptă date" : "pauză"),
                      t, max(ahead, 0), video.frames, video.width, video.height)
    }

    // MARK: - Trimiterea cadrelor la renderer-e

    private func pump() {
        while displayLayer.isReadyForMoreMediaData, !video.queue.isEmpty {
            displayLayer.enqueue(video.queue.removeFirst())
        }
        while audioRenderer.isReadyForMoreMediaData, !audio.queue.isEmpty {
            audioRenderer.enqueue(audio.queue.removeFirst())
        }
        if displayLayer.status == .failed, let e = displayLayer.error {
            info = "video: " + e.localizedDescription
            displayLayer.flush()
        }
        if audioRenderer.status == .failed, let e = audioRenderer.error {
            info = "sunet: " + e.localizedDescription
            audioRenderer.flush()
        }
    }

    // MARK: - fMP4

    private static func u32(_ b: [UInt8], _ p: Int) -> UInt32 {
        UInt32(b[p]) << 24 | UInt32(b[p + 1]) << 16 | UInt32(b[p + 2]) << 8 | UInt32(b[p + 3])
    }
    private static func u16(_ b: [UInt8], _ p: Int) -> UInt16 { UInt16(b[p]) << 8 | UInt16(b[p + 1]) }

    /// Cutiile dintre s și e: (tip, început conținut, sfârșit, început cutie).
    private static func boxes(_ b: [UInt8], _ s: Int, _ e: Int) -> [(String, Int, Int, Int)] {
        var out: [(String, Int, Int, Int)] = []
        var p = s
        while p + 8 <= e {
            var size = Int(u32(b, p))
            var h = 8
            if size == 1, p + 16 <= e { size = Int(u32(b, p + 8)) << 32 | Int(u32(b, p + 12)); h = 16 } else if size == 0 { size = e - p }
            guard size >= h, p + size <= e else { break }
            let type = String(bytes: b[(p + 4)..<(p + 8)], encoding: .ascii) ?? "????"
            out.append((type, p + h, p + size, p))
            p += size
        }
        return out
    }

    /// Cutiile complete de la începutul `pending`; restul (incomplet) rămâne pentru bucata următoare.
    private func parse(_ tr: Track, isVideo: Bool, offset: Double) {
        let b = tr.pending
        var p = 0
        var consumed = 0
        while p + 8 <= b.count {
            var size = Int(Self.u32(b, p))
            if size == 1, p + 16 <= b.count { size = Int(Self.u32(b, p + 8)) << 32 | Int(Self.u32(b, p + 12)) }
            guard size >= 8, p + size <= b.count else { break }
            let type = String(bytes: b[(p + 4)..<(p + 8)], encoding: .ascii) ?? ""
            if type == "moov" {
                parseInit(b, p, p + size, tr, isVideo: isVideo)
            } else if type == "moof" {
                // Cadrele sunt în „mdat”-ul care urmează: așteptăm să fie complet.
                let q = p + size
                guard q + 8 <= b.count else { break }
                let msize = Int(Self.u32(b, q))
                guard msize >= 8, q + msize <= b.count else { break }
                parseFragment(b, moofStart: p, moofEnd: p + size, tr, isVideo: isVideo, offset: offset)
                p = q + msize
                consumed = p
                continue
            }
            p += size
            consumed = p
        }
        if consumed > 0 { tr.pending.removeFirst(consumed) }
        if tr.pending.count > 64 << 20 { tr.pending.removeAll() } // ceva nu se potrivește: nu ținem la nesfârșit
    }

    private func parseInit(_ b: [UInt8], _ s: Int, _ e: Int, _ tr: Track, isVideo: Bool) {
        for (t, cs, ce, _) in Self.boxes(b, s + 8, e) {
            if t == "mvex" {
                for (t2, c2, _, _) in Self.boxes(b, cs, ce) where t2 == "trex" {
                    tr.defaultDuration = Self.u32(b, c2 + 12)
                    tr.defaultSize = Self.u32(b, c2 + 16)
                    tr.defaultFlags = Self.u32(b, c2 + 20)
                }
            }
            guard t == "trak" else { continue }
            for (t2, c2, e2, _) in Self.boxes(b, cs, ce) where t2 == "mdia" {
                for (t3, c3, e3, _) in Self.boxes(b, c2, e2) {
                    if t3 == "mdhd" {
                        tr.timescale = Int32(b[c3] == 1 ? Self.u32(b, c3 + 20) : Self.u32(b, c3 + 12))
                    }
                    guard t3 == "minf" else { continue }
                    for (t4, c4, e4, _) in Self.boxes(b, c3, e3) where t4 == "stbl" {
                        for (t5, c5, e5, _) in Self.boxes(b, c4, e4) where t5 == "stsd" {
                            // fullbox (4) + entry_count (4), apoi prima intrare
                            for (t6, c6, e6, _) in Self.boxes(b, c5 + 8, e5) {
                                if isVideo && (t6 == "avc1" || t6 == "avc3") {
                                    makeVideoFormat(b, c6, e6, tr)
                                } else if !isVideo && t6 == "mp4a" {
                                    makeAudioFormat(b, c6, e6, tr)
                                }
                                break
                            }
                        }
                    }
                }
            }
        }
    }

    private func makeVideoFormat(_ b: [UInt8], _ s: Int, _ e: Int, _ tr: Track) {
        let w = Int(Self.u16(b, s + 24)), h = Int(Self.u16(b, s + 26))
        guard let avcC = Self.boxes(b, s + 78, e).first(where: { $0.0 == "avcC" }) else { info = "video: lipsește avcC"; return }
        let atom = Data(b[avcC.1..<avcC.2])
        let ext: [String: Any] = [kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String: ["avcC": atom]]
        var fd: CMFormatDescription?
        let st = CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCMVideoCodecType_H264,
                                                width: Int32(w), height: Int32(h),
                                                extensions: ext as CFDictionary, formatDescriptionOut: &fd)
        if st == noErr, let fd { tr.format = fd; tr.width = w; tr.height = h } else { info = "video: format \(st)" }
    }

    private func makeAudioFormat(_ b: [UInt8], _ s: Int, _ e: Int, _ tr: Track) {
        let channels = Int(Self.u16(b, s + 16))
        let rate = Double(Self.u32(b, s + 24) >> 16)
        guard let esds = Self.boxes(b, s + 28, e).first(where: { $0.0 == "esds" }) else { info = "sunet: lipsește esds"; return }
        // „Magic cookie” pentru AAC = descriptorul ES din esds (fără versiune / flags).
        let cookie = Array(b[(esds.1 + 4)..<esds.2])
        var asbd = AudioStreamBasicDescription(mSampleRate: rate > 0 ? rate : 44_100, mFormatID: kAudioFormatMPEG4AAC,
                                               mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 1024,
                                               mBytesPerFrame: 0, mChannelsPerFrame: UInt32(max(channels, 1)),
                                               mBitsPerChannel: 0, mReserved: 0)
        var fd: CMAudioFormatDescription?
        let st = cookie.withUnsafeBytes { p in
            CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
                                           magicCookieSize: cookie.count, magicCookie: p.baseAddress,
                                           extensions: nil, formatDescriptionOut: &fd)
        }
        if st == noErr, let fd { tr.format = fd } else { info = "sunet: format \(st)" }
    }

    private func parseFragment(_ b: [UInt8], moofStart: Int, moofEnd: Int, _ tr: Track, isVideo: Bool, offset: Double) {
        guard let fmt = tr.format, tr.timescale > 0 else { return }
        let ts = Int64(tr.timescale)
        let off = Int64((offset * Double(ts)).rounded())
        for (t, cs, ce, _) in Self.boxes(b, moofStart + 8, moofEnd) where t == "traf" {
            var base: Int64 = 0
            var baseOffset = moofStart
            var defDur = tr.defaultDuration, defSize = tr.defaultSize, defFlags = tr.defaultFlags
            let parts = Self.boxes(b, cs, ce)
            for (t2, c2, _, _) in parts {
                if t2 == "tfhd" {
                    let fl = Self.u32(b, c2) & 0xFFFFFF
                    var q = c2 + 8
                    if fl & 0x1 != 0 { baseOffset = Int(Self.u32(b, q)) << 32 | Int(Self.u32(b, q + 4)); q += 8 }
                    if fl & 0x2 != 0 { q += 4 }
                    if fl & 0x8 != 0 { defDur = Self.u32(b, q); q += 4 }
                    if fl & 0x10 != 0 { defSize = Self.u32(b, q); q += 4 }
                    if fl & 0x20 != 0 { defFlags = Self.u32(b, q); q += 4 }
                }
                if t2 == "tfdt" {
                    base = b[c2] == 1 ? Int64(Self.u32(b, c2 + 4)) << 32 | Int64(Self.u32(b, c2 + 8)) : Int64(Self.u32(b, c2 + 4))
                }
            }
            for (t2, c2, _, _) in parts where t2 == "trun" {
                let version = b[c2]
                let fl = Self.u32(b, c2) & 0xFFFFFF
                let n = Int(Self.u32(b, c2 + 4))
                var q = c2 + 8
                var dataPos = baseOffset
                if fl & 0x1 != 0 { dataPos = baseOffset + Int(Int32(bitPattern: Self.u32(b, q))); q += 4 }
                var firstFlags: UInt32?
                if fl & 0x4 != 0 { firstFlags = Self.u32(b, q); q += 4 }
                var dts = base
                for i in 0..<n {
                    var dur = defDur, size = defSize, flags = defFlags
                    var cto: Int64 = 0
                    if fl & 0x100 != 0 { dur = Self.u32(b, q); q += 4 }
                    if fl & 0x200 != 0 { size = Self.u32(b, q); q += 4 }
                    if fl & 0x400 != 0 { flags = Self.u32(b, q); q += 4 }
                    if fl & 0x800 != 0 {
                        let raw = Self.u32(b, q); q += 4
                        cto = version == 0 ? Int64(raw) : Int64(Int32(bitPattern: raw))
                    }
                    if i == 0, let f = firstFlags { flags = f }
                    let sz = Int(size)
                    guard sz > 0, dataPos >= 0, dataPos + sz <= b.count else { dts += Int64(dur); dataPos += sz; continue }
                    let nonSync = isVideo && (flags & 0x0001_0000) != 0
                    if let sbuf = makeSample(b, dataPos, sz, fmt: fmt,
                                             pts: dts + cto + off, dts: dts + off, dur: Int64(dur), ts: ts, nonSync: nonSync) {
                        tr.queue.append(sbuf)
                        if isVideo { tr.frames += 1 }
                    }
                    dts += Int64(dur)
                    dataPos += sz
                }
                tr.lastEnd = max(tr.lastEnd, Double(dts + off) / Double(ts))
            }
        }
    }

    private func makeSample(_ b: [UInt8], _ p: Int, _ size: Int, fmt: CMFormatDescription,
                            pts: Int64, dts: Int64, dur: Int64, ts: Int64, nonSync: Bool) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: size,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                                                 offsetToData: 0, dataLength: size, flags: 0, blockBufferOut: &block) == noErr,
              let block else { return nil }
        let ok = b.withUnsafeBufferPointer { buf -> Bool in
            guard let base = buf.baseAddress else { return false }
            return CMBlockBufferReplaceDataBytes(with: base + p, blockBuffer: block, offsetIntoDestination: 0, dataLength: size) == noErr
        }
        guard ok else { return nil }
        var timing = CMSampleTimingInfo(duration: CMTime(value: dur, timescale: Int32(ts)),
                                        presentationTimeStamp: CMTime(value: pts, timescale: Int32(ts)),
                                        decodeTimeStamp: CMTime(value: dts, timescale: Int32(ts)))
        var sizeEntry = size
        var sbuf: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: fmt,
                                        sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &sizeEntry, sampleBufferOut: &sbuf) == noErr,
              let sbuf else { return nil }
        if nonSync, let atts = CMSampleBufferGetSampleAttachmentsArray(sbuf, createIfNecessary: true), CFArrayGetCount(atts) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(atts, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sbuf
    }
}

/// Imaginea renderer-ului MSE în player.
struct MSEHost: UIViewRepresentable {
    final class LayerView: UIView {
        override func layoutSubviews() {
            super.layoutSubviews()
            MSERenderer.shared.displayLayer.frame = bounds
        }
    }
    func makeUIView(context: Context) -> LayerView {
        let v = LayerView()
        v.backgroundColor = .black
        v.isUserInteractionEnabled = false
        let layer = MSERenderer.shared.displayLayer
        layer.removeFromSuperlayer()
        v.layer.addSublayer(layer)
        return v
    }
    func updateUIView(_ v: LayerView, context: Context) {
        let layer = MSERenderer.shared.displayLayer
        if layer.superlayer !== v.layer { layer.removeFromSuperlayer(); v.layer.addSublayer(layer) }
        layer.frame = v.bounds
    }
}
