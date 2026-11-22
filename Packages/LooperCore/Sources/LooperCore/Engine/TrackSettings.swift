import Foundation

// Parameter names and value ranges follow the RC-505mkII Parameter Guide
// ("Memory Settings (LOOP)" → TRACK 1–5, REC, PLAY). Behaviour is an original
// re-implementation; no proprietary code is used.

public enum StartMode: String, Codable, CaseIterable { case immediate, fade }
public enum StopMode: String, Codable, CaseIterable { case immediate, fade, loop }
public enum DubMode: String, Codable, CaseIterable { case overdub, replace1, replace2 }
public enum TempoSyncMode: String, Codable, CaseIterable { case pitch /* XFADE: see LIMITATIONS */ }
public enum PlaySpeed: String, Codable, CaseIterable {
    case half, normal, double
    public var factor: Double {
        switch self { case .half: return 0.5; case .normal: return 1; case .double: return 2 }
    }
}
public enum RecAction: String, Codable, CaseIterable { case recDub, recPlay }
public enum Quantize: String, Codable, CaseIterable { case off, measure }
public enum PlayMode: String, Codable, CaseIterable { case multi, single }
public enum SingleTrackChange: String, Codable, CaseIterable { case immediate, loopEnd }

/// MEASURE parameter: AUTO, FREE or a manual number of measures (fractions allowed in the
/// hardware for note values – here we support 1/4, 1/2 and whole measures).
public enum MeasureSetting: Codable, Equatable, Hashable {
    case auto
    case free
    case measures(Double) // e.g. 0.25, 0.5, 1, 2, 4 ...

    public var label: String {
        switch self {
        case .auto: return "AUTO"
        case .free: return "FREE"
        case .measures(let m):
            if m < 1 { return m == 0.5 ? "1/2" : "1/4" }
            return "\(Int(m))MEAS"
        }
    }
}

public struct TrackSettings: Codable, Equatable {
    public var reverse = false
    public var oneShot = false
    public var pan: Float = 0            // -50 ... +50 (L50–CENTER–R50)
    public var playLevel: Float = 100    // 0 ... 200
    public var startMode: StartMode = .immediate
    public var stopMode: StopMode = .immediate
    public var dubMode: DubMode = .overdub
    public var fxOn = true
    public var measure: MeasureSetting = .auto
    public var loopSync = true
    public var tempoSync = true
    public var tempoSyncMode: TempoSyncMode = .pitch
    public var speed: PlaySpeed = .normal
    public var bounceIn = false
    public var inputOn = true            // INPUT (mic/inst) → track
    public var rhythmToTrack = false     // INPUT RHYTHM → track
    public var fadeInMeasures: Double = 2
    public var fadeOutMeasures: Double = 2
    public var allStartTarget = true
    public var allStopTarget = true
    public var midiStartTarget = true
    public var midiStopTarget = true

    public init() {}
}

public struct GlobalLoopSettings: Codable, Equatable {
    public var recAction: RecAction = .recDub
    public var quantize: Quantize = .measure
    public var autoRec = false
    public var autoRecSensitivity: Float = 50 // 1...100
    public var playMode: PlayMode = .multi
    public var singleTrackChange: SingleTrackChange = .immediate
    public var loopLengthMeasures: Int = 0     // 0 = AUTO
    public init() {}
}
