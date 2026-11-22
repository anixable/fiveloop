import Foundation

/// Drum instruments used by the rhythm engine. Every sound is synthesised at start-up
/// (no sampled/proprietary audio is used).
public enum DrumVoice: Int, CaseIterable {
    case kick, snare, closedHat, openHat, clap, rim, lowTom, midTom, highTom, crash, ride, shaker, cowbell
    public static let letters: [Character: DrumVoice] = [
        "K": .kick, "S": .snare, "H": .closedHat, "O": .openHat, "C": .clap, "R": .rim,
        "L": .lowTom, "M": .midTom, "T": .highTom, "X": .crash, "Y": .ride, "Z": .shaker, "B": .cowbell
    ]
    var pan: Float {
        switch self {
        case .closedHat, .openHat: return 0.25
        case .lowTom: return -0.3; case .midTom: return 0; case .highTom: return 0.3
        case .ride: return -0.25; case .crash: return 0.2; case .shaker: return 0.35; case .cowbell: return -0.2
        default: return 0
        }
    }
}

/// Synthesis parameters that give each kit its character.
public struct KitRecipe {
    public var name: String
    var kickPitch: Float = 55, kickSweep: Float = 120, kickDecay: Float = 0.38, kickClick: Float = 0.4
    var snareTone: Float = 190, snareNoise: Float = 0.7, snareDecay: Float = 0.18, snareBrush = false
    var hatDecay: Float = 0.05, hatOpenDecay: Float = 0.35, hatBright: Float = 7500
    var tomScale: Float = 1, tomDecay: Float = 0.35
    var drive: Float = 1, tone: Float = 16000, room: Float = 0.0
    var clapSpread: Float = 0.012, cajon = false, analog = false
}

public let kitRecipes: [KitRecipe] = {
    var k: [KitRecipe] = []
    func add(_ name: String, _ f: (inout KitRecipe) -> Void) { var r = KitRecipe(name: name); f(&r); k.append(r) }
    add("STUDIO") { _ in }
    add("LIVE") { $0.room = 0.25; $0.snareDecay = 0.22; $0.kickDecay = 0.42 }
    add("LIGHT") { $0.kickDecay = 0.25; $0.snareNoise = 0.5; $0.drive = 0.8; $0.tone = 12000 }
    add("HEAVY") { $0.kickPitch = 50; $0.kickClick = 0.7; $0.drive = 1.8; $0.snareDecay = 0.25; $0.room = 0.2 }
    add("ROCK") { $0.kickClick = 0.6; $0.snareTone = 210; $0.drive = 1.4; $0.room = 0.18 }
    add("METAL") { $0.kickClick = 0.9; $0.kickDecay = 0.25; $0.snareTone = 230; $0.drive = 2.0; $0.hatBright = 9000 }
    add("JAZZ") { $0.kickPitch = 65; $0.kickDecay = 0.3; $0.snareNoise = 0.55; $0.tomScale = 1.2; $0.tone = 11000; $0.room = 0.15 }
    add("BRUSH") { $0.snareBrush = true; $0.snareDecay = 0.3; $0.kickDecay = 0.28; $0.tone = 9000; $0.hatDecay = 0.07 }
    add("CAJON") { $0.cajon = true; $0.kickPitch = 80; $0.kickSweep = 40; $0.kickDecay = 0.22; $0.kickClick = 0.2; $0.tone = 8000 }
    add("DRUM&BASS") { $0.kickPitch = 52; $0.kickDecay = 0.3; $0.snareTone = 240; $0.snareDecay = 0.14; $0.drive = 1.3 }
    add("R&B") { $0.kickPitch = 48; $0.kickDecay = 0.55; $0.snareDecay = 0.15; $0.clapSpread = 0.015 }
    add("DANCE") { $0.kickPitch = 50; $0.kickSweep = 160; $0.kickDecay = 0.45; $0.drive = 1.3; $0.analog = true }
    add("TECHNO") { $0.kickPitch = 46; $0.kickDecay = 0.5; $0.drive = 1.6; $0.analog = true; $0.hatDecay = 0.035 }
    add("DANCE BEATS") { $0.kickPitch = 54; $0.kickDecay = 0.35; $0.analog = true; $0.hatBright = 8500 }
    add("HIPHOP") { $0.kickPitch = 45; $0.kickDecay = 0.6; $0.snareTone = 180; $0.tone = 10000; $0.drive = 1.2 }
    add("ANALOG") { $0.analog = true; $0.kickPitch = 49; $0.kickDecay = 0.7; $0.kickClick = 0.1; $0.hatBright = 8000 }
    return k
}()

/// A rendered drum kit (one sample buffer per voice).
public final class DrumKit {
    public let name: String
    let samples: [UnsafeMutablePointer<Float>]
    let lengths: [Int]

    public init(recipe: KitRecipe, sampleRate: Double) {
        name = recipe.name
        var s: [UnsafeMutablePointer<Float>] = [], lens: [Int] = []
        for v in DrumVoice.allCases {
            let data = DrumKit.render(v, recipe, Float(sampleRate))
            let p = UnsafeMutablePointer<Float>.allocate(capacity: max(1, data.count))
            data.withUnsafeBufferPointer { p.initialize(from: $0.baseAddress!, count: data.count) }
            s.append(p); lens.append(data.count)
        }
        samples = s; lengths = lens
    }
    deinit { samples.forEach { $0.deallocate() } }

    static func render(_ v: DrumVoice, _ k: KitRecipe, _ sr: Float) -> [Float] {
        var noise = Noise(seed: UInt32(v.rawValue * 7919 + 13))
        func env(_ t: Float, _ decay: Float) -> Float { expf(-t / max(decay, 0.001) * 4.6) } // −40 dB at `decay`
        func buffer(_ seconds: Float, _ f: (Float, Int) -> Float) -> [Float] {
            let n = Int(seconds * sr); var out = [Float](repeating: 0, count: n)
            for i in 0..<n { out[i] = f(Float(i) / sr, i) }
            return out
        }
        var bp = Biquad(), hp = Biquad(), lp = Biquad()
        var out: [Float]
        switch v {
        case .kick:
            var phase: Float = 0
            out = buffer(k.kickDecay + 0.05) { t, _ in
                let f = k.kickPitch + k.kickSweep * expf(-t * 35)
                phase += 2 * Float.pi * f / sr
                let body = sinf(phase) * env(t, k.kickDecay)
                let click = k.kickClick * expf(-t * 900) * noise.next() * 0.6
                return body + click
            }
            if k.cajon {
                bp.set(.bandpass, freq: 2200, q: 1.2, sampleRate: sr)
                for i in 0..<out.count { out[i] += bp.tick(noise.next()) * env(Float(i) / sr, 0.05) * 0.3 }
            }
        case .snare:
            bp.set(.bandpass, freq: k.snareBrush ? 4000 : 3500, q: k.snareBrush ? 0.5 : 0.8, sampleRate: sr)
            var ph: Float = 0
            out = buffer(k.snareDecay + 0.1) { t, _ in
                if k.snareBrush {
                    let swish = min(1, t * 30) * env(t, k.snareDecay)
                    return bp.tick(noise.next()) * swish * 1.2
                }
                if k.cajon { return bp.tick(noise.next()) * env(t, 0.12) * 0.9 + sinf(2 * .pi * 320 * t) * env(t, 0.04) * 0.5 }
                ph += 2 * Float.pi * k.snareTone * (1 + 0.5 * expf(-t * 60)) / sr
                let tone = sinf(ph) * env(t, 0.08) * (1 - k.snareNoise * 0.5)
                return tone + bp.tick(noise.next()) * env(t, k.snareDecay) * k.snareNoise * 1.4
            }
        case .closedHat, .openHat, .ride:
            let decay = v == .closedHat ? k.hatDecay : (v == .openHat ? k.hatOpenDecay : 1.1)
            hp.set(.highpass, freq: v == .ride ? 5000 : k.hatBright, q: 0.7, sampleRate: sr)
            let ratios: [Float] = [2.0, 3.0, 4.16, 5.43, 6.79, 8.21]
            var phases = [Float](repeating: 0, count: 6)
            let base: Float = v == .ride ? 330 : 400
            out = buffer(decay + 0.05) { t, _ in
                var metal: Float = 0
                for j in 0..<6 {
                    phases[j] += base * ratios[j] / sr; if phases[j] >= 1 { phases[j] -= 1 }
                    metal += phases[j] < 0.5 ? 1 : -1
                }
                let mix = k.analog ? metal * 0.12 + noise.next() * 0.3 : metal * 0.06 + noise.next() * 0.6
                let bell: Float = v == .ride ? sinf(2 * .pi * 2650 * t) * env(t, 0.5) * 0.25 : 0
                return hp.tick(mix) * env(t, decay) * (v == .ride ? 0.5 : 0.8) + bell
            }
        case .clap:
            bp.set(.bandpass, freq: 1200, q: 0.9, sampleRate: sr)
            out = buffer(0.35) { t, _ in
                var e = env(t - 3 * k.clapSpread, 0.25)
                for j in 0..<3 where t >= Float(j) * k.clapSpread && t < Float(j + 1) * k.clapSpread {
                    e = env(t - Float(j) * k.clapSpread, 0.012) }
                return bp.tick(noise.next()) * e * 1.6
            }
        case .rim:
            bp.set(.bandpass, freq: 1700, q: 3, sampleRate: sr)
            out = buffer(0.08) { t, _ in bp.tick(noise.next() * 0.3 + sinf(2 * .pi * 1700 * t)) * env(t, 0.03) * 1.2 }
        case .lowTom, .midTom, .highTom:
            let f0: Float = (v == .lowTom ? 95 : v == .midTom ? 140 : 200) * k.tomScale
            var ph: Float = 0
            out = buffer(k.tomDecay + 0.05) { t, _ in
                ph += 2 * Float.pi * f0 * (1 + 0.4 * expf(-t * 25)) / sr
                return sinf(ph) * env(t, k.tomDecay) + noise.next() * env(t, 0.02) * 0.15
            }
        case .crash:
            hp.set(.highpass, freq: 4000, q: 0.7, sampleRate: sr)
            out = buffer(1.8) { t, _ in hp.tick(noise.next()) * env(t, 1.7) * 0.7 }
        case .shaker:
            bp.set(.bandpass, freq: 6500, q: 1.5, sampleRate: sr)
            out = buffer(0.12) { t, _ in bp.tick(noise.next()) * min(1, t * 200) * env(t, 0.08) * 1.4 }
        case .cowbell:
            bp.set(.bandpass, freq: 700, q: 2, sampleRate: sr)
            out = buffer(0.35) { t, _ in
                let a: Float = sinf(2 * .pi * 540 * t) > 0 ? 1 : -1
                let b: Float = sinf(2 * .pi * 800 * t) > 0 ? 1 : -1
                return bp.tick((a + b) * 0.5) * env(t, 0.3) * 1.5
            }
        }
        // Kit colouring: drive, tone, tiny room
        lp.set(.lowpass, freq: k.tone, q: 0.7, sampleRate: sr)
        for i in 0..<out.count { out[i] = lp.tick(tanhf(out[i] * k.drive) / max(0.7, tanhf(k.drive))) }
        if k.room > 0 {
            let d = Int(0.023 * sr), d2 = Int(0.041 * sr)
            out += [Float](repeating: 0, count: d2 * 3)
            for i in stride(from: out.count - 1, through: d2, by: -1) {
                out[i] += out[i - d] * k.room * 0.6 + out[i - d2] * k.room * 0.4
            }
        }
        // normalise peak to 0.9
        let pk = out.reduce(0) { max($0, abs($1)) }
        if pk > 0 { let g = 0.9 / pk; for i in 0..<out.count { out[i] *= g } }
        // short fade-out to avoid clicks at the end of the sample
        let f = min(64, out.count)
        for j in 0..<f { out[out.count - 1 - j] *= Float(j) / Float(f) }
        return out
    }
}
