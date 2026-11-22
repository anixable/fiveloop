import Foundation

/// Effect types implemented in this build. Names follow the RC-505mkII Parameter Guide
/// ("Input FX/Track FX List"); the DSP is an original implementation with comparable
/// musical behaviour, NOT a reproduction of the BOSS algorithms.
public enum FXType: String, Codable, CaseIterable, Identifiable {
    case lpf, hpf, bpf, phaser, flanger, chorus, tremolo, vibrato, autoPan, manualPan
    case patternSlicer, delay, panningDelay, tapeEcho, reverb, dist, lofi, ringMod, radio
    case isolator, eq, dynamics, freeze, roll
    // Track FX only
    case beatRepeat, vinylFlick

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .lpf: return "LPF"; case .hpf: return "HPF"; case .bpf: return "BPF"
        case .phaser: return "PHASER"; case .flanger: return "FLANGER"; case .chorus: return "CHORUS"
        case .tremolo: return "TREMOLO"; case .vibrato: return "VIBRATO"; case .autoPan: return "AUTO PAN"
        case .manualPan: return "MANUAL PAN"; case .patternSlicer: return "PATTERN SLICER"
        case .delay: return "DELAY"; case .panningDelay: return "PANNING DELAY"; case .tapeEcho: return "TAPE ECHO"
        case .reverb: return "REVERB"; case .dist: return "DIST"; case .lofi: return "LO-FI"
        case .ringMod: return "RING MOD"; case .radio: return "RADIO"; case .isolator: return "ISOLATOR"
        case .eq: return "EQ"; case .dynamics: return "DYNAMICS"; case .freeze: return "FREEZE"
        case .roll: return "ROLL"; case .beatRepeat: return "BEAT REPEAT"; case .vinylFlick: return "VINYL FLICK"
        }
    }

    public var trackOnly: Bool { self == .beatRepeat || self == .vinylFlick }

    public static func available(forTrackFX: Bool) -> [FXType] {
        allCases.filter { forTrackFX || !$0.trackOnly }
    }

    public var params: [FXParamSpec] {
        let sync = FXParamSpec("SYNC", .choice(syncChoices), 0)
        switch self {
        case .lpf, .hpf, .bpf:
            return [sync, .pct("RATE", 50), .pct("DEPTH", 50), .pct("RESONANCE", 50), .pct("CUTOFF", 50)]
        case .phaser:
            return [sync, .pct("RATE", 50), .pct("DEPTH", 50), .pct("RESONANCE", 50), .pct("MANUAL", 50),
                    FXParamSpec("STAGE", .choice(["4", "8", "12"]), 1), .pct("D.LEVEL", 100), .pct("E.LEVEL", 50)]
        case .flanger:
            return [sync, .pct("RATE", 50), .pct("DEPTH", 50), .pct("RESONANCE", 50), .pct("MANUAL", 50),
                    .pct("SEPARATION", 0), .pct("D.LEVEL", 100), .pct("E.LEVEL", 50)]
        case .chorus:
            return [sync, .pct("RATE", 50), .pct("DEPTH", 50), .pct("D.LEVEL", 100), .pct("E.LEVEL", 50)]
        case .tremolo:
            return [sync, .pct("RATE", 70), .pct("DEPTH", 50), FXParamSpec("WAVE", .choice(["TRI", "SINE", "SQUARE"]), 0)]
        case .vibrato:
            return [sync, .pct("RATE", 70), .pct("DEPTH", 50)]
        case .autoPan:
            return [sync, .pct("RATE", 50), .pct("DEPTH", 50), FXParamSpec("WAVE", .choice(["TRI", "SINE", "SQUARE"]), 1)]
        case .manualPan:
            return [FXParamSpec("POSITION", .range(-50, 50), 0)]
        case .patternSlicer:
            return [FXParamSpec("RATE", .choice(["1/8", "1/16", "1/32"]), 1),
                    FXParamSpec("PATTERN", .range(1, 16), 1), .pct("DEPTH", 100), .pct("ATTACK", 30)]
        case .delay, .panningDelay:
            return [sync, FXParamSpec("TIME", .range(1, 2000), 400), .pct("FEEDBACK", 40), .pct("HIGH CUT", 80),
                    .pct("D.LEVEL", 100), .pct("E.LEVEL", 50)]
        case .tapeEcho:
            return [sync, FXParamSpec("TIME", .range(20, 2000), 350), .pct("FEEDBACK", 45), .pct("WOW", 30),
                    .pct("SATURATION", 40), .pct("E.LEVEL", 50)]
        case .reverb:
            return [FXParamSpec("TIME", .range(1, 100), 30), FXParamSpec("PRE DELAY", .range(0, 500), 20),
                    .pct("LOW CUT", 10), .pct("HIGH CUT", 70), .pct("D.LEVEL", 100), .pct("E.LEVEL", 40)]
        case .dist:
            return [.pct("DRIVE", 50), .pct("TONE", 50), .pct("D.LEVEL", 0), .pct("E.LEVEL", 50)]
        case .lofi:
            return [FXParamSpec("BIT DEPTH", .range(1, 31), 8), .pct("SAMPLE RATE", 50), .pct("BALANCE", 100)]
        case .ringMod:
            return [.pct("FREQUENCY", 50), .pct("D.LEVEL", 0), .pct("E.LEVEL", 80)]
        case .radio:
            return [.pct("LO-FI", 50), .pct("NOISE", 20), .pct("LEVEL", 80)]
        case .isolator:
            return [.pct("LOW", 50), .pct("MID", 50), .pct("HIGH", 50)]
        case .eq:
            return [FXParamSpec("LOW", .range(-20, 20), 0), FXParamSpec("LO-MID", .range(-20, 20), 0),
                    FXParamSpec("HI-MID", .range(-20, 20), 0), FXParamSpec("HIGH", .range(-20, 20), 0),
                    FXParamSpec("LEVEL", .range(-20, 20), 0)]
        case .dynamics:
            return [.pct("DEPTH", 50), .pct("ATTACK", 30), .pct("RELEASE", 40), FXParamSpec("LEVEL", .range(-20, 20), 0)]
        case .freeze:
            return [.pct("ATTACK", 20), .pct("RELEASE", 30), .pct("LEVEL", 80)]
        case .roll:
            return [FXParamSpec("LENGTH", .choice(["1/4", "1/8", "1/16", "1/32"]), 1), .pct("FEEDBACK", 100), .pct("BALANCE", 100)]
        case .beatRepeat:
            return [FXParamSpec("LENGTH", .choice(["1/2", "1/4", "1/8", "1/16"]), 1), FXParamSpec("MODE", .choice(["FORWARD", "REVERSE"]), 0)]
        case .vinylFlick:
            return [.pct("FLICK", 50), .pct("D.LEVEL", 80), .pct("E.LEVEL", 60)]
        }
    }

    /// Creates a processor. Must be called off the audio thread (allocates).
    public func make(sampleRate: Double) -> FXProcessor {
        switch self {
        case .lpf, .hpf, .bpf: return FilterFX(type: self, sampleRate: sampleRate)
        case .phaser: return PhaserFX(type: self, sampleRate: sampleRate)
        case .flanger: return FlangerFX(type: self, sampleRate: sampleRate)
        case .chorus: return ChorusFX(type: self, sampleRate: sampleRate)
        case .tremolo: return TremoloFX(type: self, sampleRate: sampleRate)
        case .vibrato: return VibratoFX(type: self, sampleRate: sampleRate)
        case .autoPan: return AutoPanFX(type: self, sampleRate: sampleRate)
        case .manualPan: return ManualPanFX(type: self, sampleRate: sampleRate)
        case .patternSlicer: return SlicerFX(type: self, sampleRate: sampleRate)
        case .delay, .panningDelay: return DelayFX(type: self, sampleRate: sampleRate)
        case .tapeEcho: return TapeEchoFX(type: self, sampleRate: sampleRate)
        case .reverb: return ReverbFX(type: self, sampleRate: sampleRate)
        case .dist: return DistFX(type: self, sampleRate: sampleRate)
        case .lofi: return LoFiFX(type: self, sampleRate: sampleRate)
        case .ringMod: return RingModFX(type: self, sampleRate: sampleRate)
        case .radio: return RadioFX(type: self, sampleRate: sampleRate)
        case .isolator: return IsolatorFX(type: self, sampleRate: sampleRate)
        case .eq: return EQFX(type: self, sampleRate: sampleRate)
        case .dynamics: return DynamicsFX(type: self, sampleRate: sampleRate)
        case .freeze: return FreezeFX(type: self, sampleRate: sampleRate)
        case .roll: return RollFX(type: self, sampleRate: sampleRate)
        case .beatRepeat: return BeatRepeatFX(type: self, sampleRate: sampleRate)
        case .vinylFlick: return VinylFlickFX(type: self, sampleRate: sampleRate)
        }
    }
}

/// Full list of type names in the RC-505mkII Parameter Guide, used for the
/// implementation-status table in the documentation and UI.
public let referenceFXNames: [String] = [
    "LPF", "HPF", "BPF", "PHASER", "FLANGER", "SYNTH", "LO-FI", "RADIO", "RING MOD", "G2B", "SUSTAINER",
    "AUTO RIFF", "SLOW GEAR", "TRANSPOSE", "PITCH BEND", "ROBOT", "ELECTRIC", "HRM MANUAL", "HRM AUTO(M)",
    "VOCODER", "OSC VOC", "OSC BOT", "PREAMP", "DIST", "DYNAMICS", "EQ", "ISOLATOR", "OCTAVE", "AUTO PAN",
    "MANUAL PAN", "STEREO ENHANCE", "TREMOLO", "VIBRATO", "PATTERN SLICER", "STEP SLICER", "DELAY",
    "PANNING DELAY", "REVERSE DELAY", "MOD DELAY", "TAPE ECHO1", "TAPE ECHO2", "GRANULAR DELAY", "WARP",
    "TWIST", "ROLL1", "ROLL2", "FREEZE", "CHORUS", "REVERB", "GATE REVERB", "REVERSE REVERB",
    "BEAT SCATTER", "BEAT REPEAT", "BEAT SHIFT", "VINYL FLICK"
]
