import Foundation

public enum WAVFormat: String, Codable, CaseIterable { case int16, int24, float32 }

public enum WAVError: Error, Equatable { case notWAV, unsupported(String), truncated }

/// Minimal RIFF/WAVE reader & writer (PCM 16/24/32-bit int, 32-bit float; mono/stereo/multi).
public enum WAV {
    public static func encode(left: [Float], right: [Float]?, sampleRate: Int, format: WAVFormat = .float32) -> Data {
        let channels = right == nil ? 1 : 2
        let frames = left.count
        let bps: Int = format == .int16 ? 2 : (format == .int24 ? 3 : 4)
        var d = Data(capacity: 44 + frames * channels * bps)
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        let dataBytes = frames * channels * bps
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + dataBytes)); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16)
        u16(format == .float32 ? 3 : 1); u16(UInt16(channels)); u32(UInt32(sampleRate))
        u32(UInt32(sampleRate * channels * bps)); u16(UInt16(channels * bps)); u16(UInt16(bps * 8))
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(dataBytes))
        var bytes = [UInt8](repeating: 0, count: dataBytes)
        var o = 0
        for i in 0..<frames {
            for c in 0..<channels {
                let s = c == 0 ? left[i] : right![min(i, right!.count - 1)]
                switch format {
                case .float32:
                    var b = s.bitPattern.littleEndian
                    withUnsafeBytes(of: &b) { for k in 0..<4 { bytes[o + k] = $0[k] } }
                case .int16:
                    let v = Int16(clamp(s, -1, 1) * 32767)
                    bytes[o] = UInt8(truncatingIfNeeded: v); bytes[o + 1] = UInt8(truncatingIfNeeded: v >> 8)
                case .int24:
                    let v = Int32(clamp(s, -1, 1) * 8_388_607)
                    bytes[o] = UInt8(truncatingIfNeeded: v); bytes[o + 1] = UInt8(truncatingIfNeeded: v >> 8)
                    bytes[o + 2] = UInt8(truncatingIfNeeded: v >> 16)
                }
                o += bps
            }
        }
        d.append(contentsOf: bytes)
        return d
    }

    public struct Decoded { public let sampleRate: Int; public let channels: [[Float]] }

    public static func decode(_ data: Data) throws -> Decoded {
        let b = [UInt8](data)
        guard b.count >= 12, String(bytes: b[0..<4], encoding: .ascii) == "RIFF",
              String(bytes: b[8..<12], encoding: .ascii) == "WAVE" else { throw WAVError.notWAV }
        func u16(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24 }
        var o = 12
        var fmt = 0, channels = 0, rate = 0, bits = 0
        var dataStart = -1, dataLen = 0
        while o + 8 <= b.count {
            let id = String(bytes: b[o..<o + 4], encoding: .ascii) ?? ""
            let len = u32(o + 4)
            if id == "fmt " {
                guard o + 8 + 16 <= b.count else { throw WAVError.truncated }
                fmt = u16(o + 8); channels = u16(o + 10); rate = u32(o + 12); bits = u16(o + 22)
                if fmt == 0xFFFE && len >= 40 { fmt = u16(o + 8 + 24) } // WAVE_FORMAT_EXTENSIBLE sub-format
            } else if id == "data" {
                dataStart = o + 8; dataLen = min(len, b.count - dataStart); break
            }
            o += 8 + len + (len & 1)
        }
        guard dataStart >= 0, channels > 0 else { throw WAVError.truncated }
        guard (fmt == 1 && [16, 24, 32].contains(bits)) || (fmt == 3 && bits == 32) else {
            throw WAVError.unsupported("format \(fmt), \(bits) bit")
        }
        let bps = bits / 8
        let frames = dataLen / (bps * channels)
        var out = [[Float]](repeating: [Float](repeating: 0, count: frames), count: channels)
        var p = dataStart
        for i in 0..<frames {
            for c in 0..<channels {
                let v: Float
                switch (fmt, bits) {
                case (3, 32): v = Float(bitPattern: UInt32(u32(p)))
                case (1, 16): v = Float(Int16(bitPattern: UInt16(u16(p)))) / 32768
                case (1, 24):
                    var x = Int32(b[p]) | Int32(b[p + 1]) << 8 | Int32(b[p + 2]) << 16
                    if x & 0x800000 != 0 { x |= ~0xFFFFFF }
                    v = Float(x) / 8_388_608
                default: v = Float(Int32(bitPattern: UInt32(u32(p)))) / 2_147_483_648
                }
                out[c][i] = v
                p += bps
            }
        }
        return Decoded(sampleRate: rate, channels: out)
    }

    /// Linear-interpolation resampler for imported files (offline, main thread).
    public static func resample(_ x: [Float], from: Int, to: Int) -> [Float] {
        guard from != to, from > 0, !x.isEmpty else { return x }
        let ratio = Double(from) / Double(to)
        let n = Int(Double(x.count) / ratio)
        var y = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let p = Double(i) * ratio
            let i0 = Int(p), f = Float(p - Double(i0))
            let a = x[min(i0, x.count - 1)], b = x[min(i0 + 1, x.count - 1)]
            y[i] = a + (b - a) * f
        }
        return y
    }
}
