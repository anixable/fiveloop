import Foundation

public enum MIDIMessage: Equatable {
    case noteOn(channel: Int, note: Int, velocity: Int)
    case noteOff(channel: Int, note: Int, velocity: Int)
    case controlChange(channel: Int, controller: Int, value: Int)
    case programChange(channel: Int, program: Int)
    case pitchBend(channel: Int, value: Int)
    case clock, start, stop, `continue`
    case songPosition(Int)
    case other
}

/// Byte-stream parser with running status; realtime bytes may be interleaved anywhere.
public struct MIDIParser {
    private var status: UInt8 = 0
    private var data: [UInt8] = []
    private var inSysEx = false
    public init() {}

    public mutating func feed(_ bytes: [UInt8]) -> [MIDIMessage] {
        var out: [MIDIMessage] = []
        for b in bytes { if let m = feed(b) { out.append(m) } }
        return out
    }

    public mutating func feed(_ b: UInt8) -> MIDIMessage? {
        if b >= 0xF8 { // realtime
            switch b { case 0xF8: return .clock; case 0xFA: return .start; case 0xFB: return .continue; case 0xFC: return .stop; default: return nil }
        }
        if b == 0xF0 { inSysEx = true; return nil }
        if b == 0xF7 { inSysEx = false; return nil }
        if inSysEx { return nil }
        if b & 0x80 != 0 {
            status = b; data.removeAll(keepingCapacity: true)
            if b >= 0xF0 && b != 0xF2 { status = 0; return nil }
            return nil
        }
        guard status != 0 else { return nil }
        data.append(b)
        let kind = status & 0xF0, ch = Int(status & 0x0F) + 1
        let needed = (kind == 0xC0 || kind == 0xD0) ? 1 : 2
        guard data.count >= needed else { return nil }
        defer { data.removeAll(keepingCapacity: true) }
        if status == 0xF2 { status = 0; return .songPosition(Int(data[0]) | Int(data[1]) << 7) }
        switch kind {
        case 0x90: return data[1] == 0 ? .noteOff(channel: ch, note: Int(data[0]), velocity: 0)
                                       : .noteOn(channel: ch, note: Int(data[0]), velocity: Int(data[1]))
        case 0x80: return .noteOff(channel: ch, note: Int(data[0]), velocity: Int(data[1]))
        case 0xB0: return .controlChange(channel: ch, controller: Int(data[0]), value: Int(data[1]))
        case 0xC0: return .programChange(channel: ch, program: Int(data[0]))
        case 0xE0: return .pitchBend(channel: ch, value: Int(data[0]) | Int(data[1]) << 7)
        default: return .other
        }
    }

    public static func bytes(_ m: MIDIMessage) -> [UInt8] {
        switch m {
        case .noteOn(let c, let n, let v): return [0x90 | UInt8((c - 1) & 15), UInt8(n & 127), UInt8(v & 127)]
        case .noteOff(let c, let n, let v): return [0x80 | UInt8((c - 1) & 15), UInt8(n & 127), UInt8(v & 127)]
        case .controlChange(let c, let n, let v): return [0xB0 | UInt8((c - 1) & 15), UInt8(n & 127), UInt8(v & 127)]
        case .programChange(let c, let p): return [0xC0 | UInt8((c - 1) & 15), UInt8(p & 127)]
        case .pitchBend(let c, let v): return [0xE0 | UInt8((c - 1) & 15), UInt8(v & 127), UInt8((v >> 7) & 127)]
        case .clock: return [0xF8]; case .start: return [0xFA]; case .stop: return [0xFC]; case .continue: return [0xFB]
        case .songPosition(let p): return [0xF2, UInt8(p & 127), UInt8((p >> 7) & 127)]
        case .other: return []
        }
    }
}

/// Estimates tempo from incoming MIDI clock (24 PPQN) timestamps.
public struct ClockFollower {
    private var last: Double? = nil
    private var intervals: [Double] = []
    public private(set) var bpm: Double? = nil
    public init() {}
    public mutating func reset() { last = nil; intervals.removeAll(); bpm = nil }

    /// Feed the host time (seconds) of each 0xF8. Returns a new tempo when it changed by ≥ 0.05 BPM.
    public mutating func tick(at t: Double) -> Double? {
        defer { last = t }
        guard let l = last else { return nil }
        let dt = t - l
        guard dt > 0.001 && dt < 0.25 else { intervals.removeAll(); return nil } // 10…2500 BPM sanity
        intervals.append(dt)
        if intervals.count > 48 { intervals.removeFirst() }
        guard intervals.count >= 12 else { return nil }
        // median-filtered average to reject USB/BLE jitter
        let sorted = intervals.sorted()
        let core = sorted[sorted.count / 4 ..< sorted.count * 3 / 4]
        let avg = core.reduce(0, +) / Double(core.count)
        let new = (60 / (avg * 24) * 10).rounded() / 10
        if let b = bpm, abs(b - new) < 0.05 { return nil }
        bpm = new
        return new
    }
}

public enum ClockSyncMode: String, Codable, CaseIterable { case auto, `internal` }
public enum MIDIStartMode: String, Codable, CaseIterable { case off, all, rhythm }

public struct MIDISettings: Codable, Equatable {
    public var rxControlChannel = 1          // RX CH CTL
    public var rxRhythmChannel = 10          // RX CH RHYTHM
    public var txChannel = 1
    public var clockSync: ClockSyncMode = .auto
    public var clockOut = true
    public var startMode: MIDIStartMode = .all
    public var programChangeIn = true
    public var programChangeOut = false
    public init() {}
}

/// GM-style note → drum voice mapping for the rhythm RX channel.
public func drumVoice(forNote n: Int) -> DrumVoice? {
    switch n {
    case 35, 36: return .kick
    case 38, 40: return .snare
    case 37: return .rim
    case 39: return .clap
    case 42, 44: return .closedHat
    case 46: return .openHat
    case 41, 43: return .lowTom
    case 45, 47: return .midTom
    case 48, 50: return .highTom
    case 49, 57: return .crash
    case 51, 53, 59: return .ride
    case 56: return .cowbell
    case 70, 82: return .shaker
    default: return nil
    }
}
