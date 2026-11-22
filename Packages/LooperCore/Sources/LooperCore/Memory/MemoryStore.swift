import Foundation

public struct MemorySummary: Equatable, Identifiable {
    public let index: Int          // 1…99
    public let name: String
    public let hasAudio: Bool
    public let modified: Date?
    public var id: Int { index }
}

public enum MemoryStoreError: Error, Equatable { case badIndex, notFound, badBundle(String) }

/// On-disk layout (inside the app's Documents folder, visible in the Files app):
///   Memories/M001/memory.json, Memories/M001/T1.wav … T5.wav (32-bit float stereo)
///   Memories/Recovery/…            (autosave used for crash recovery)
/// Single-file exchange format (.floop): "FLOOP1" | u32 jsonLen | json | 5 × (u32 frames | L floats | R floats)
public final class MemoryStore {
    public static let memoryCount = 99
    public let root: URL
    public let sampleRate: Int
    private let fm = FileManager.default

    public init(root: URL, sampleRate: Int = 44100) throws {
        self.root = root
        self.sampleRate = sampleRate
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    public func folder(_ index: Int) -> URL {
        index == 0 ? root.appendingPathComponent("Recovery", isDirectory: true)
                   : root.appendingPathComponent(String(format: "M%03d", index), isDirectory: true)
    }

    public func exists(_ index: Int) -> Bool { fm.fileExists(atPath: folder(index).appendingPathComponent("memory.json").path) }

    public func list() -> [MemorySummary] {
        (1...MemoryStore.memoryCount).map { i in
            let url = folder(i).appendingPathComponent("memory.json")
            guard let d = try? Data(contentsOf: url), let m = try? JSONDecoder().decode(MemoryData.self, from: d) else {
                return MemorySummary(index: i, name: "INIT MEMORY", hasAudio: false, modified: nil)
            }
            let date = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
            return MemorySummary(index: i, name: m.name, hasAudio: m.hasAudio, modified: date)
        }
    }

    // MARK: save / load

    public func save(_ index: Int, data: MemoryData, audio: [TrackAudio?]) throws {
        guard index >= 0 && index <= MemoryStore.memoryCount else { throw MemoryStoreError.badIndex }
        let dir = folder(index)
        let tmp = root.appendingPathComponent(".tmp-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        var m = data
        for i in 0..<5 {
            if let a = audio[i], !a.left.isEmpty {
                let wav = WAV.encode(left: a.left, right: a.right, sampleRate: sampleRate, format: .float32)
                try wav.write(to: tmp.appendingPathComponent("T\(i + 1).wav"))
                m.trackMeta[i].hasAudio = true; m.trackMeta[i].length = a.left.count
            } else {
                m.trackMeta[i].hasAudio = false; m.trackMeta[i].length = 0
            }
        }
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(m).write(to: tmp.appendingPathComponent("memory.json"))
        // atomic-ish swap: replace the folder only after everything was written
        if fm.fileExists(atPath: dir.path) { try fm.removeItem(at: dir) }
        try fm.moveItem(at: tmp, to: dir)
    }

    public func load(_ index: Int) throws -> (MemoryData, [TrackAudio?]) {
        let dir = folder(index)
        guard let d = try? Data(contentsOf: dir.appendingPathComponent("memory.json")) else { throw MemoryStoreError.notFound }
        let m = try JSONDecoder().decode(MemoryData.self, from: d)
        var audio: [TrackAudio?] = []
        for i in 0..<5 {
            let url = dir.appendingPathComponent("T\(i + 1).wav")
            if m.trackMeta[i].hasAudio, let wd = try? Data(contentsOf: url), let w = try? WAV.decode(wd) {
                audio.append(stereo(w))
            } else { audio.append(nil) }
        }
        return (m, audio)
    }

    func stereo(_ w: WAV.Decoded) -> TrackAudio {
        var l = w.channels[0]
        var r = w.channels.count > 1 ? w.channels[1] : l
        if w.sampleRate != sampleRate {
            l = WAV.resample(l, from: w.sampleRate, to: sampleRate); r = WAV.resample(r, from: w.sampleRate, to: sampleRate)
        }
        return (l, r)
    }

    public func rename(_ index: Int, to name: String) throws {
        let url = folder(index).appendingPathComponent("memory.json")
        guard let d = try? Data(contentsOf: url) else { throw MemoryStoreError.notFound }
        var m = try JSONDecoder().decode(MemoryData.self, from: d)
        m.name = String(name.prefix(12)).uppercased()
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(m).write(to: url, options: .atomic)
    }

    public func duplicate(_ from: Int, to: Int) throws {
        guard exists(from) else { throw MemoryStoreError.notFound }
        guard to >= 1 && to <= MemoryStore.memoryCount else { throw MemoryStoreError.badIndex }
        if fm.fileExists(atPath: folder(to).path) { try fm.removeItem(at: folder(to)) }
        try fm.copyItem(at: folder(from), to: folder(to))
    }

    public func delete(_ index: Int) throws {
        if fm.fileExists(atPath: folder(index).path) { try fm.removeItem(at: folder(index)) }
    }

    // MARK: single-file bundles

    public static func bundle(_ m: MemoryData, audio: [TrackAudio?]) throws -> Data {
        var d = Data("FLOOP1".utf8)
        let json = try JSONEncoder().encode(m)
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        u32(json.count); d.append(json)
        for i in 0..<5 {
            let a = audio.indices.contains(i) ? audio[i] : nil
            let l = a?.left ?? [], r = a?.right ?? []
            u32(l.count)
            l.withUnsafeBytes { d.append(contentsOf: $0) }
            let rr = r.count == l.count ? r : l
            rr.withUnsafeBytes { d.append(contentsOf: $0) }
        }
        return d
    }

    public static func unbundle(_ d: Data) throws -> (MemoryData, [TrackAudio?]) {
        let b = [UInt8](d)
        guard b.count >= 10, String(bytes: b[0..<6], encoding: .ascii) == "FLOOP1" else { throw MemoryStoreError.badBundle("magic") }
        var o = 6
        func u32() throws -> Int {
            guard o + 4 <= b.count else { throw MemoryStoreError.badBundle("truncated") }
            defer { o += 4 }
            return Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24
        }
        let jl = try u32()
        guard o + jl <= b.count else { throw MemoryStoreError.badBundle("json") }
        let m = try JSONDecoder().decode(MemoryData.self, from: Data(b[o..<o + jl])); o += jl
        var audio: [TrackAudio?] = []
        for _ in 0..<5 {
            let n = try u32()
            guard o + n * 8 <= b.count else { throw MemoryStoreError.badBundle("audio") }
            if n == 0 { audio.append(nil); continue }
            func floats(_ count: Int) -> [Float] {
                var out = [Float](repeating: 0, count: count)
                out.withUnsafeMutableBytes { dst in b.withUnsafeBytes { src in
                    dst.copyMemory(from: UnsafeRawBufferPointer(rebasing: src[o..<o + count * 4])) } }
                o += count * 4
                return out
            }
            let l = floats(n), r = floats(n)
            audio.append((l, r))
        }
        return (m, audio)
    }

    public func exportBundle(_ index: Int, to url: URL) throws {
        let (m, a) = try load(index)
        try MemoryStore.bundle(m, audio: a).write(to: url, options: .atomic)
    }

    public func importBundle(from url: URL, to index: Int) throws {
        let (m, a) = try MemoryStore.unbundle(try Data(contentsOf: url))
        try save(index, data: m, audio: a)
    }

    // MARK: backup / restore of all memories ("FLBAK1" | u32 count | (u32 index | u64 len | bundle)*)

    public func backupAll(to url: URL) throws {
        var d = Data("FLBAK1".utf8)
        let items = (1...MemoryStore.memoryCount).filter { exists($0) }
        var c = UInt32(items.count).littleEndian; withUnsafeBytes(of: &c) { d.append(contentsOf: $0) }
        for i in items {
            let (m, a) = try load(i)
            let bdl = try MemoryStore.bundle(m, audio: a)
            var idx = UInt32(i).littleEndian; withUnsafeBytes(of: &idx) { d.append(contentsOf: $0) }
            var len = UInt64(bdl.count).littleEndian; withUnsafeBytes(of: &len) { d.append(contentsOf: $0) }
            d.append(bdl)
        }
        try d.write(to: url, options: .atomic)
    }

    @discardableResult
    public func restoreAll(from url: URL) throws -> Int {
        let d = try Data(contentsOf: url)
        guard d.count >= 10, String(data: d.prefix(6), encoding: .ascii) == "FLBAK1" else { throw MemoryStoreError.badBundle("backup magic") }
        func readInt(_ o: Int, _ n: Int) -> Int { var v = 0; for k in 0..<n { v |= Int(d[d.startIndex + o + k]) << (8 * k) }; return v }
        let count = readInt(6, 4)
        var o = 10, restored = 0
        for _ in 0..<count {
            guard o + 12 <= d.count else { throw MemoryStoreError.badBundle("backup truncated") }
            let idx = readInt(o, 4), len = readInt(o + 4, 8); o += 12
            guard o + len <= d.count else { throw MemoryStoreError.badBundle("backup truncated") }
            let (m, a) = try MemoryStore.unbundle(d.subdata(in: (d.startIndex + o)..<(d.startIndex + o + len)))
            try save(idx, data: m, audio: a); restored += 1
            o += len
        }
        return restored
    }

    // MARK: crash recovery marker

    private var lockURL: URL { root.appendingPathComponent("session.lock") }
    /// Returns true if the previous session did not end cleanly and a recovery memory exists.
    public func beginSession() -> Bool {
        let crashed = fm.fileExists(atPath: lockURL.path) && exists(0)
        try? Data().write(to: lockURL)
        return crashed
    }
    public func endSession() { try? fm.removeItem(at: lockURL) }
}
