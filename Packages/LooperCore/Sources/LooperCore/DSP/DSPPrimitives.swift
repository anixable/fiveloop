import Foundation

// Small, allocation-free DSP building blocks. All original implementations of
// textbook algorithms (state-variable filter, biquad, delay line, LFO, etc.).

@inline(__always) public func clamp<T: Comparable>(_ v: T, _ lo: T, _ hi: T) -> T { min(max(v, lo), hi) }
@inline(__always) public func dbToGain(_ db: Float) -> Float { powf(10, db / 20) }
@inline(__always) public func gainToDb(_ g: Float) -> Float { 20 * log10f(max(g, 1e-9)) }

/// Maps 0…100 onto an exponential frequency range.
@inline(__always) public func expMap(_ x: Float, _ lo: Float, _ hi: Float) -> Float {
    lo * powf(hi / lo, clamp(x, 0, 100) / 100)
}

/// Equal-power pan. pan in -1…+1.
@inline(__always) public func panGains(_ pan: Float) -> (Float, Float) {
    let a = (clamp(pan, -1, 1) + 1) * 0.25 * Float.pi
    return (cosf(a) * 1.41421356, sinf(a) * 1.41421356)
}

/// Linear parameter smoother (avoids zipper noise / clicks).
public struct Smoother {
    public var value: Float
    public var target: Float
    private var step: Float = 0
    private var remaining = 0
    public init(_ v: Float) { value = v; target = v }
    public mutating func set(_ t: Float, frames: Int) {
        target = t
        if frames <= 0 { value = t; remaining = 0; return }
        step = (t - value) / Float(frames); remaining = frames
    }
    @inline(__always) public mutating func next() -> Float {
        if remaining > 0 { value += step; remaining -= 1; if remaining == 0 { value = target } }
        return value
    }
    public var isRamping: Bool { remaining > 0 }
}

/// Topology-preserving state-variable filter (Simper/Zavalishin form).
public struct SVF {
    private var ic1 = 0.0 as Float, ic2 = 0.0 as Float
    private var g: Float = 0, k: Float = 1, a1: Float = 0, a2: Float = 0, a3: Float = 0
    public init() {}
    public mutating func set(cutoff: Float, q: Float, sampleRate: Float) {
        let fc = clamp(cutoff, 10, sampleRate * 0.45)
        g = tanf(Float.pi * fc / sampleRate)
        k = 1 / max(q, 0.05)
        a1 = 1 / (1 + g * (g + k)); a2 = g * a1; a3 = g * a2
    }
    public mutating func reset() { ic1 = 0; ic2 = 0 }
    /// returns (low, band, high)
    @inline(__always) public mutating func tick(_ v0: Float) -> (Float, Float, Float) {
        let v3 = v0 - ic2
        let v1 = a1 * ic1 + a2 * v3
        let v2 = ic2 + a2 * ic1 + a3 * v3
        ic1 = 2 * v1 - ic1
        ic2 = 2 * v2 - ic2
        return (v2, v1, v0 - k * v1 - v2)
    }
}

/// RBJ cookbook biquad.
public struct Biquad {
    public enum Kind { case lowpass, highpass, bandpass, peak, lowShelf, highShelf, allpass }
    var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0
    var z1: Float = 0, z2: Float = 0
    public init() {}
    public mutating func set(_ kind: Kind, freq: Float, q: Float, gainDb: Float = 0, sampleRate: Float) {
        let w0 = 2 * Float.pi * clamp(freq, 10, sampleRate * 0.45) / sampleRate
        let cw = cosf(w0), sw = sinf(w0)
        let alpha = sw / (2 * max(q, 0.05))
        let A = powf(10, gainDb / 40)
        var nb0: Float, nb1: Float, nb2: Float, na0: Float, na1: Float, na2: Float
        switch kind {
        case .lowpass: nb0 = (1 - cw) / 2; nb1 = 1 - cw; nb2 = nb0; na0 = 1 + alpha; na1 = -2 * cw; na2 = 1 - alpha
        case .highpass: nb0 = (1 + cw) / 2; nb1 = -(1 + cw); nb2 = nb0; na0 = 1 + alpha; na1 = -2 * cw; na2 = 1 - alpha
        case .bandpass: nb0 = alpha; nb1 = 0; nb2 = -alpha; na0 = 1 + alpha; na1 = -2 * cw; na2 = 1 - alpha
        case .allpass: nb0 = 1 - alpha; nb1 = -2 * cw; nb2 = 1 + alpha; na0 = 1 + alpha; na1 = -2 * cw; na2 = 1 - alpha
        case .peak:
            nb0 = 1 + alpha * A; nb1 = -2 * cw; nb2 = 1 - alpha * A
            na0 = 1 + alpha / A; na1 = -2 * cw; na2 = 1 - alpha / A
        case .lowShelf:
            let s = 2 * sqrtf(A) * alpha
            nb0 = A * ((A + 1) - (A - 1) * cw + s); nb1 = 2 * A * ((A - 1) - (A + 1) * cw); nb2 = A * ((A + 1) - (A - 1) * cw - s)
            na0 = (A + 1) + (A - 1) * cw + s; na1 = -2 * ((A - 1) + (A + 1) * cw); na2 = (A + 1) + (A - 1) * cw - s
        case .highShelf:
            let s = 2 * sqrtf(A) * alpha
            nb0 = A * ((A + 1) + (A - 1) * cw + s); nb1 = -2 * A * ((A - 1) + (A + 1) * cw); nb2 = A * ((A + 1) + (A - 1) * cw - s)
            na0 = (A + 1) - (A - 1) * cw + s; na1 = 2 * ((A - 1) - (A + 1) * cw); na2 = (A + 1) - (A - 1) * cw - s
        }
        b0 = nb0 / na0; b1 = nb1 / na0; b2 = nb2 / na0; a1 = na1 / na0; a2 = na2 / na0
    }
    public mutating func reset() { z1 = 0; z2 = 0 }
    @inline(__always) public mutating func tick(_ x: Float) -> Float {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }
}

/// Fixed-capacity fractional delay line (allocated once).
public final class DelayLine {
    private let buf: UnsafeMutablePointer<Float>
    private let size: Int
    private var w = 0
    public init(maxFrames: Int) {
        size = max(4, maxFrames + 2)
        buf = .allocate(capacity: size); buf.initialize(repeating: 0, count: size)
    }
    deinit { buf.deallocate() }
    public func reset() { buf.update(repeating: 0, count: size); w = 0 }
    @inline(__always) public func write(_ x: Float) { buf[w] = x; w += 1; if w == size { w = 0 } }
    /// Read `delay` samples behind the most recent write (linear interpolation).
    @inline(__always) public func read(_ delay: Float) -> Float {
        let d = clamp(delay, 1, Float(size - 2))
        var rp = Float(w) - d
        if rp < 0 { rp += Float(size) }
        let i0 = Int(rp); let f = rp - Float(i0)
        let i1 = i0 + 1 == size ? 0 : i0 + 1
        return buf[i0] + (buf[i1] - buf[i0]) * f
    }
    public var capacity: Int { size - 2 }
}

public struct LFO {
    public enum Shape { case sine, triangle, square, saw }
    public var phase: Double = 0
    public init() {}
    @inline(__always) public mutating func tick(freq: Double, sampleRate: Double, shape: Shape = .sine) -> Float {
        let v: Float
        switch shape {
        case .sine: v = Float(sin(2 * .pi * phase))
        case .triangle: v = Float(phase < 0.5 ? 4 * phase - 1 : 3 - 4 * phase)
        case .square: v = phase < 0.5 ? 1 : -1
        case .saw: v = Float(2 * phase - 1)
        }
        phase += freq / sampleRate
        if phase >= 1 { phase -= floor(phase) }
        return v
    }
}

/// Cheap deterministic noise (xorshift) for real-time use.
public struct Noise {
    private var s: UInt32
    public init(seed: UInt32 = 0x9E3779B9) { s = seed == 0 ? 1 : seed }
    @inline(__always) public mutating func next() -> Float {
        s ^= s << 13; s ^= s >> 17; s ^= s << 5
        return Float(Int32(bitPattern: s)) / Float(Int32.max)
    }
}

/// One-pole envelope follower.
public struct EnvelopeFollower {
    var env: Float = 0
    var att: Float = 0, rel: Float = 0
    public init() {}
    public mutating func set(attackMs: Float, releaseMs: Float, sampleRate: Float) {
        att = expf(-1 / (max(attackMs, 0.01) * 0.001 * sampleRate))
        rel = expf(-1 / (max(releaseMs, 0.01) * 0.001 * sampleRate))
    }
    @inline(__always) public mutating func tick(_ x: Float) -> Float {
        let a = abs(x)
        env = a > env ? att * env + (1 - att) * a : rel * env + (1 - rel) * a
        return env
    }
    public mutating func reset() { env = 0 }
}

@inline(__always) public func softClip(_ x: Float) -> Float {
    if x > 1.5 { return 1 } else if x < -1.5 { return -1 }
    return x - (4.0 / 27.0) * x * x * x
}
