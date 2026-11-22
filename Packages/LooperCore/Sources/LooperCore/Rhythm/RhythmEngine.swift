import Foundation

public enum RhythmStartTrigger: String, Codable, CaseIterable { case loopStart, beforeLoop }

public struct RhythmSettings: Codable, Equatable {
    public var startTrigger: RhythmStartTrigger = .loopStart
    public var patternIndex = 30          // "Rock 8"
    public var variation = 0              // 0…3 = A…D
    public var kitIndex = 0
    public var level: Float = 100         // RHYTHM OUT 0…200
    public var fill = true
    public var countInMeasures = 0        // 0 = off, 1–2 = count-in before recording (INTRO REC style)
    public var stopWithLoops = true       // STOP TRIG = LOOP STOP
    public init() {}
}

/// Step-sequenced drum machine locked to the engine's song position.
public final class RhythmEngine {
    public let kits: [DrumKit]
    public let compiled: [[CompiledPattern]]   // [pattern][variation]
    let fills3: [[(DrumVoice, Float)]], fills4: [[(DrumVoice, Float)]]
    let guideClick: CompiledPattern

    var patternIndex = 0
    var variation = 0
    var pendingVariation: Int? = nil
    var kitIndex = 0
    var fillOn = true
    var lastMeasure = Int.min

    struct Voice { var sample: UnsafeMutablePointer<Float>? = nil; var length = 0; var pos = 0; var delay = 0
                   var gain: Float = 0; var gl: Float = 1; var gr: Float = 1; var voice = DrumVoice.kick }
    private var voices = [Voice](repeating: Voice(), count: 32)
    private var nextVoice = 0

    public init(sampleRate: Double) {
        kits = kitRecipes.map { DrumKit(recipe: $0, sampleRate: sampleRate) }
        compiled = patternDefs.map { def in (0..<4).map { PatternCompiler.compile(def, variation: $0) } }
        fills3 = PatternCompiler.fill(stepsPerQuarter: 3)
        fills4 = PatternCompiler.fill(stepsPerQuarter: 4)
        guideClick = PatternCompiler.compile(PatternDef(genre: "GUIDE", name: "count", stepsPerQuarter: 4, swing: 0,
                                                        lines: ["B:X...x...x...x..."]), variation: 0)
    }

    public static var patternCount: Int { patternDefs.count }

    func apply(_ s: RhythmSettings) {
        patternIndex = clamp(s.patternIndex, 0, compiled.count - 1)
        kitIndex = clamp(s.kitIndex, 0, kits.count - 1)
        fillOn = s.fill
        let v = clamp(s.variation, 0, 3)
        if v != variation { pendingVariation = v }
    }

    func reset() {
        for i in 0..<voices.count { voices[i].sample = nil }
        lastMeasure = Int.min
        if let p = pendingVariation { variation = p; pendingVariation = nil }
    }

    private func trigger(_ v: DrumVoice, _ vel: Float, delay: Int) {
        let kit = kits[kitIndex]
        if v == .closedHat { // choke open hat
            for i in 0..<voices.count where voices[i].voice == .openHat && voices[i].sample != nil { voices[i].gain *= 0.0; voices[i].sample = nil }
        }
        let (gl, gr) = panGains(v.pan)
        voices[nextVoice] = Voice(sample: kit.samples[v.rawValue], length: kit.lengths[v.rawValue], pos: 0, delay: delay,
                                  gain: vel * vel, gl: gl, gr: gr, voice: v)
        nextVoice = (nextVoice + 1) % voices.count
    }

    /// Live pad / MIDI note trigger (audio thread).
    func hit(_ v: DrumVoice, _ vel: Float) { trigger(v, clamp(vel, 0, 1), delay: 0) }

    /// Adds the rhythm for one block into outL/outR (caller zeroes them).
    func render(_ n: Int, songStart: Double, ratio: Double, refMeasure: Double, beats: Int, unit: Int,
                playing: Bool, countIn: Bool, outL: UnsafeMutablePointer<Float>, outR: UnsafeMutablePointer<Float>) {
        if playing || countIn {
            let pat = compiled[patternIndex][variation]
            let spq = pat.stepsPerQuarter
            let stepsPerMeasure = max(1, Int((Double(beats) * 4 / Double(unit) * Double(spq)).rounded()))
            let stepLen = refMeasure / Double(stepsPerMeasure)
            let songEnd = songStart + Double(n) * ratio
            let maxSwing = pat.swing * stepLen * 0.66
            var k = Int(floor((songStart - maxSwing) / stepLen))
            let kEnd = Int(floor(songEnd / stepLen))
            while k <= kEnd {
                let m = Int(floor(Double(k) / Double(stepsPerMeasure)))
                let s = k - m * stepsPerMeasure
                var pos = Double(k) * stepLen
                if spq == 4 && s % 2 == 1 { pos += pat.swing * stepLen * 0.66 }
                if pos >= songStart && pos < songEnd {
                    if m != lastMeasure {
                        lastMeasure = m
                        if let p = pendingVariation { variation = p; pendingVariation = nil }
                    }
                    let delay = Int((pos - songStart) / ratio)
                    let cur = compiled[patternIndex][variation]
                    if k < 0 || !playing {
                        // count-in: guide click on each beat
                        let beatSteps = max(1, stepsPerMeasure / beats)
                        if s % beatSteps == 0 { trigger(.cowbell, s == 0 ? 1.0 : 0.7, delay: delay) }
                    } else if fillOn && pendingVariation != nil && s >= stepsPerMeasure - spq {
                        let f = spq == 3 ? fills3 : fills4
                        for h in f[(s - (stepsPerMeasure - spq)) % f.count] { trigger(h.0, h.1, delay: delay) }
                    } else {
                        for h in cur.hits[s % cur.steps] { trigger(h.0, h.1, delay: delay) }
                    }
                }
                k += 1
            }
        }
        voices.withUnsafeMutableBufferPointer { vs in
            for vi in 0..<vs.count where vs[vi].sample != nil {
                var v = vs[vi]
                let smp = v.sample!
                var i = 0
                if v.delay > 0 { i = min(v.delay, n); v.delay -= i }
                while i < n && v.pos < v.length {
                    let x = smp[v.pos] * v.gain
                    outL[i] += x * v.gl; outR[i] += x * v.gr
                    v.pos += 1; i += 1
                }
                if v.pos >= v.length { v.sample = nil }
                vs[vi] = v
            }
        }
    }
}
