import Foundation

/// Timing information handed to every effect for each audio block.
public struct FXContext {
    public var sampleRate: Double = 44100
    public var tempo: Double = 120
    public var beatsPerMeasure: Int = 4
    public var beatUnit: Int = 4
    /// Length of one measure in *real* frames at the current tempo.
    public var measureFrames: Double = 88200
    /// Musical position (in measures) at the first frame of the block.
    public var measurePos: Double = 0
    /// Measures advanced per frame.
    public var measuresPerFrame: Double = 1.0 / 88200
    public var running = false
    public init() {}

    /// Musical position (in measures) of frame `i` inside the current block.
    @inline(__always) public func measure(at i: Int) -> Double { measurePos + Double(i) * measuresPerFrame }
}

public enum FXParamKind: Equatable {
    case range(Float, Float)
    case choice([String])
}

public struct FXParamSpec: Equatable {
    public let name: String
    public let kind: FXParamKind
    public let defaultValue: Float
    public init(_ name: String, _ kind: FXParamKind, _ def: Float) { self.name = name; self.kind = kind; defaultValue = def }

    public static func pct(_ name: String, _ def: Float) -> FXParamSpec { .init(name, .range(0, 100), def) }

    public func display(_ v: Float) -> String {
        switch kind {
        case .range(let lo, let hi):
            _ = hi
            return lo < 0 ? String(format: "%+.0f", v) : String(format: "%.0f", v)
        case .choice(let opts):
            let i = clamp(Int(v.rounded()), 0, opts.count - 1)
            return opts[i]
        }
    }
    public var minValue: Float { if case .range(let lo, _) = kind { return lo }; return 0 }
    public var maxValue: Float {
        switch kind { case .range(_, let hi): return hi; case .choice(let o): return Float(o.count - 1) }
    }
}

/// Synchronised rate choices (shared by modulation effects).
public let syncChoices = ["OFF", "4MEAS", "2MEAS", "1MEAS", "1/2", "1/4", "1/8", "1/16", "1/32"]

/// Length in measures of a sync choice for the given time signature (nil = not synced).
public func syncLengthMeasures(_ choice: Int, beatsPerMeasure: Int, beatUnit: Int) -> Double? {
    let quarterPerMeasure = Double(beatsPerMeasure) * 4.0 / Double(beatUnit)
    switch choice {
    case 1: return 4
    case 2: return 2
    case 3: return 1
    case 4: return 2 / quarterPerMeasure
    case 5: return 1 / quarterPerMeasure
    case 6: return 0.5 / quarterPerMeasure
    case 7: return 0.25 / quarterPerMeasure
    case 8: return 0.125 / quarterPerMeasure
    default: return nil
    }
}

/// Base class for all effects. Subclasses override `render` and optionally `update`.
/// Instances are created on the main thread (all allocation happens in `init`),
/// then handed to the audio thread through the engine's command queue.
open class FXProcessor {
    public static let maxParams = 12
    public let type: FXType
    /// Fixed storage so the audio thread never triggers copy-on-write.
    private let params: UnsafeMutablePointer<Float>
    public let sampleRate: Float

    public init(type: FXType, sampleRate: Double) {
        self.type = type
        self.sampleRate = Float(sampleRate)
        params = .allocate(capacity: FXProcessor.maxParams)
        params.initialize(repeating: 0, count: FXProcessor.maxParams)
        for (i, s) in type.params.enumerated() { params[i] = s.defaultValue }
    }
    deinit { params.deallocate() }

    /// Snapshot of current values (main thread use, e.g. tests).
    public var paramValues: [Float] { (0..<type.params.count).map { params[$0] } }

    /// Called on the audio thread. Never allocates.
    public final func setParam(_ index: Int, _ value: Float) {
        guard index >= 0 && index < type.params.count else { return }
        let s = type.params[index]
        params[index] = clamp(value, s.minValue, s.maxValue)
        update()
    }

    /// Recompute cached coefficients after a parameter change.
    open func update() {}
    open func reset() {}
    /// In-place stereo processing.
    open func render(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ n: Int, _ ctx: FXContext) {}

    @inline(__always) public func p(_ i: Int) -> Float { params[i] }
    @inline(__always) public func choice(_ i: Int) -> Int { Int(p(i).rounded()) }

    /// LFO phase 0…1 at frame i: locked to the musical grid when synced, free running otherwise.
    public var freePhase: Double = 0
    @inline(__always) public func lfoPhase(syncIndex: Int, rateParam: Int, at i: Int, _ ctx: FXContext, slowHz: Double = 0.05, fastHz: Double = 10) -> Double {
        if let len = syncLengthMeasures(choice(syncIndex), beatsPerMeasure: ctx.beatsPerMeasure, beatUnit: ctx.beatUnit), ctx.running {
            let m = ctx.measure(at: i) / len
            return m - floor(m)
        }
        return freePhase
    }
    /// Advance the free-running LFO by one frame.
    @inline(__always) public func advanceFree(rateParam: Int, slowHz: Double = 0.05, fastHz: Double = 10) {
        let hz = slowHz * pow(fastHz / slowHz, Double(p(rateParam)) / 100)
        freePhase += hz / Double(sampleRate)
        if freePhase >= 1 { freePhase -= 1 }
    }
}

@inline(__always) func sine01(_ ph: Double) -> Float { Float(sin(2 * Double.pi * ph)) }
@inline(__always) func tri01(_ ph: Double) -> Float { Float(ph < 0.5 ? 4 * ph - 1 : 3 - 4 * ph) }
