import Foundation

/// Functions that can be assigned to MIDI CC / notes or on-screen controls (ASSIGN 1–16 style).
public enum AssignTarget: Codable, Hashable {
    case recPlay(Int), stop(Int), clear(Int), undo(Int), redo(Int), mute(Int)
    case trackLevel(Int)
    case currentRecPlay, currentStop, undoRedoCurrent
    case inputFX(Int), trackFX(Int)              // slot A–D (0…3) of the active bank
    case rhythmStartStop, rhythmLevel, tempo, tapTempo
    case allStartStop, memoryNext, memoryPrev
    case masterLevel

    public var label: String {
        switch self {
        case .recPlay(let t): return "TRACK\(t + 1) REC/PLAY"
        case .stop(let t): return "TRACK\(t + 1) STOP"
        case .clear(let t): return "TRACK\(t + 1) CLEAR"
        case .undo(let t): return "TRACK\(t + 1) UNDO"
        case .redo(let t): return "TRACK\(t + 1) REDO"
        case .mute(let t): return "TRACK\(t + 1) MUTE"
        case .trackLevel(let t): return "TRACK\(t + 1) LEVEL"
        case .currentRecPlay: return "CUR TRACK REC/PLAY"
        case .currentStop: return "CUR TRACK STOP"
        case .undoRedoCurrent: return "UNDO/REDO"
        case .inputFX(let s): return "INPUT FX \(["A", "B", "C", "D"][s])"
        case .trackFX(let s): return "TRACK FX \(["A", "B", "C", "D"][s])"
        case .rhythmStartStop: return "RHYTHM ST/STP"
        case .rhythmLevel: return "RHYTHM LEVEL"
        case .tempo: return "TEMPO"
        case .tapTempo: return "TAP TEMPO"
        case .allStartStop: return "ALL START/STOP"
        case .memoryNext: return "MEMORY INC"
        case .memoryPrev: return "MEMORY DEC"
        case .masterLevel: return "MASTER LEVEL"
        }
    }

    /// Continuous targets use the controller value; the rest trigger on press.
    public var isContinuous: Bool {
        switch self { case .trackLevel, .rhythmLevel, .tempo, .masterLevel: return true; default: return false }
    }

    public static var all: [AssignTarget] {
        var a: [AssignTarget] = []
        for t in 0..<5 { a += [.recPlay(t), .stop(t), .clear(t), .undo(t), .redo(t), .mute(t), .trackLevel(t)] }
        a += [.currentRecPlay, .currentStop, .undoRedoCurrent]
        for s in 0..<4 { a.append(.inputFX(s)) }
        for s in 0..<4 { a.append(.trackFX(s)) }
        a += [.rhythmStartStop, .rhythmLevel, .tempo, .tapTempo, .allStartStop, .memoryNext, .memoryPrev, .masterLevel]
        return a
    }
}

public enum AssignSource: Codable, Hashable {
    case cc(channel: Int, number: Int)       // channel 0 = any
    case note(channel: Int, number: Int)

    public var label: String {
        switch self {
        case .cc(let c, let n): return "CC#\(n)" + (c == 0 ? "" : " ch\(c)")
        case .note(let c, let n): return "NOTE \(n)" + (c == 0 ? "" : " ch\(c)")
        }
    }
}

public enum SwitchMode: String, Codable { case toggle, momentary }

public struct Assignment: Codable, Hashable, Identifiable {
    public var id = UUID()
    public var source: AssignSource
    public var target: AssignTarget
    public var mode: SwitchMode = .toggle
    public var enabled = true
    public init(source: AssignSource, target: AssignTarget, mode: SwitchMode = .toggle) {
        self.source = source; self.target = target; self.mode = mode
    }
}

public struct AssignmentAction: Equatable {
    public let target: AssignTarget
    public let value: Float      // 0…1
    public let pressed: Bool     // value crossed above the threshold (CC ≥ 64 or note on)
    public let released: Bool
}

public struct AssignmentMap: Codable, Equatable {
    public var items: [Assignment] = []
    public init() {}

    public static var defaults: AssignmentMap {
        // Simple default layout for a generic 8-pad / footswitch controller (editable via MIDI learn).
        var m = AssignmentMap()
        for t in 0..<5 { m.items.append(Assignment(source: .cc(channel: 0, number: 80 + t), target: .recPlay(t))) }
        m.items.append(Assignment(source: .cc(channel: 0, number: 85), target: .allStartStop))
        m.items.append(Assignment(source: .cc(channel: 0, number: 86), target: .undoRedoCurrent))
        m.items.append(Assignment(source: .cc(channel: 0, number: 87), target: .rhythmStartStop))
        return m
    }

    public func actions(for msg: MIDIMessage) -> [AssignmentAction] {
        var out: [AssignmentAction] = []
        for a in items where a.enabled {
            switch (a.source, msg) {
            case (.cc(let c, let n), .controlChange(let ch, let cc, let v)) where (c == 0 || c == ch) && n == cc:
                out.append(AssignmentAction(target: a.target, value: Float(v) / 127, pressed: v >= 64, released: v < 64))
            case (.note(let c, let n), .noteOn(let ch, let note, let v)) where (c == 0 || c == ch) && n == note:
                out.append(AssignmentAction(target: a.target, value: Float(v) / 127, pressed: true, released: false))
            case (.note(let c, let n), .noteOff(let ch, let note, _)) where (c == 0 || c == ch) && n == note:
                out.append(AssignmentAction(target: a.target, value: 0, pressed: false, released: true))
            default: break
            }
        }
        return out
    }

    /// Source for MIDI learn from an incoming message.
    public static func learnSource(from msg: MIDIMessage) -> AssignSource? {
        switch msg {
        case .controlChange(let ch, let cc, _): return .cc(channel: ch, number: cc)
        case .noteOn(let ch, let n, _): return .note(channel: ch, number: n)
        default: return nil
        }
    }
}

/// Tap-tempo helper (main thread).
public struct TapTempo {
    private var taps: [Double] = []
    public init() {}
    public mutating func tap(at t: Double) -> Double? {
        if let last = taps.last, t - last > 2.0 { taps.removeAll() }
        taps.append(t)
        if taps.count > 6 { taps.removeFirst() }
        guard taps.count >= 2 else { return nil }
        let span = (taps.last! - taps.first!) / Double(taps.count - 1)
        return clamp((60 / span * 10).rounded() / 10, 40, 250)
    }
}
