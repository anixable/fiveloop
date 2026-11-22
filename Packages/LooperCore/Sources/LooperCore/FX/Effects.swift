import Foundation

// MARK: - Filters (LPF / HPF / BPF) with LFO modulation

final class FilterFX: FXProcessor {
    private var fl = SVF(), fr = SVF()
    private var counter = 0
    override func reset() { fl.reset(); fr.reset() }
    override func render(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ n: Int, _ ctx: FXContext) {
        let depth = p(2) / 100, res = p(3), cutoff = p(4)
        let q = 0.5 + powf(res / 100, 2) * 12
        for i in 0..<n {
            if counter == 0 {
                let ph = lfoPhase(syncIndex: 0, rateParam: 1, at: i, ctx)
                let mod = tri01(ph) * depth * 40   // ±40 % of the 0…100 cutoff scale
                let c = expMap(clamp(cutoff + mod, 0, 100), 40, 18000)
                fl.set(cutoff: c, q: q, sampleRate: sampleRate); fr.set(cutoff: c, q: q, sampleRate: sampleRate)
            }
            counter = (counter + 1) & 15
            advanceFree(rateParam: 1)
            let a = fl.tick(l[i]), b = fr.tick(r[i])
            switch type {
            case .lpf: l[i] = a.0; r[i] = b.0
            case .hpf: l[i] = a.2; r[i] = b.2
            default: l[i] = a.1 * 1.5; r[i] = b.1 * 1.5
            }
        }
    }
}

// MARK: - Phaser

final class PhaserFX: FXProcessor {
    private var apL = [Float](repeating: 0, count: 12), apR = [Float](repeating: 0, count: 12)
    private var fbL: Float = 0, fbR: Float = 0
    override func reset() { for i in 0..<12 { apL[i] = 0; apR[i] = 0 }; fbL = 0; fbR = 0 }
    override func render(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ n: Int, _ ctx: FXContext) {
        let stages = [4, 8, 12][clamp(choice(5), 0, 2)]
        let depth = p(2) / 100, fb = p(3) / 100 * 0.85, manual = p(4)
        let dry = p(6) / 100, wet = p(7) / 100
        apL.withUnsafeMutableBufferPointer { aL in
            apR.withUnsafeMutableBufferPointer { aR in
                for i in 0..<n {
                    let ph = lfoPhase(syncIndex: 0, rateParam: 1, at: i, ctx)
                    advanceFree(rateParam: 1)
                    let f = expMap(clamp(manual + sine01(ph) * depth * 45, 0, 100), 80, 8000)
                    let t = tanf(Float.pi * f / sampleRate)
                    let a = (t - 1) / (t + 1)
                    var xl = l[i] + fbL * fb, xr = r[i] + fbR * fb
                    for s in 0..<stages {
                        let yl = a * xl + aL[s]; aL[s] = xl - a * yl; xl = yl
                        let yr = a * xr + aR[s]; aR[s] = xr - a * yr; xr = yr
                    }
                    fbL = xl; fbR = xr
                    l[i] = l[i] * dry + xl * wet
                    r[i] = r[i] * dry + xr * wet
                }
            }
        }
    }
}

// MARK: - Flanger / Chorus / Vibrato (modulated delay family)

final class FlangerFX: FXProcessor {
    private let dl: DelayLine, dr: DelayLine
    private var fbL: Float = 0, fbR: Float = 0
    override init(type: FXType, sampleRate: Double) {
        dl = DelayLine(maxFrames: Int(sampleRate * 0.02)); dr = DelayLine(maxFrames: Int(sampleRate * 0.02))
        super.init(type: type, sampleRate: sampleRate)
    }
    override func reset() { dl.reset(); dr.reset(); fbL = 0; fbR = 0 }
    override func render(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ n: Int, _ ctx: FXContext) {
        let depth = p(2) / 100, fb = p(3) / 100 * 0.9, manual = p(4) / 100, sep = Double(p(5) / 100) * 0.5
        let dry = p(6) / 100, wet = p(7) / 100
        let base = (0.0005 + Double(manual) * 0.006) * Double(sampleRate)
        for i in 0..<n {
            let ph = lfoPhase(syncIndex: 0, rateParam: 1, at: i, ctx)
            advanceFree(rateParam: 1)
            var phR = ph + sep; if phR >= 1 { phR -= 1 }
            let mL = Float(base) * (1 + tri01(ph) * depth * 0.9)
            let mR = Float(base) * (1 + tri01(phR) * depth * 0.9)
            dl.write(l[i] + fbL * fb); dr.write(r[i] + fbR * fb)
            let yl = dl.read(mL), yr = dr.read(mR)
            fbL = yl; fbR = yr
            l[i] = l[i] * dry + yl * wet
            r[i] = r[i] * dry + yr * wet
        }
    }
}

final class ChorusFX: FXProcessor {
    private let dl: DelayLine, dr: DelayLine
    override init(type: FXType, sampleRate: Double) {
        dl = DelayLine(maxFrames: Int(sampleRate * 0.05)); dr = DelayLine(maxFrames: Int(sampleRate * 0.05))
        super.init(type: type, sampleRate: sampleRate)
    }
    override func reset() { dl.reset(); dr.reset() }
    override func render(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ n: Int, _ ctx: FXContext) {
        let depth = p(2) / 100, dry = p(3) / 100, wet = p(4) / 100
        let base = 0.012 * sampleRate, sweep = 0.006 * sampleRate * depth
        for i in 0..<n {
            let ph = lfoPhase(syncIndex: 0, rateParam: 1, at: i, ctx)
            advanceFree(rateParam: 1, slowHz: 0.05, fastHz: 5)
            var ph2 = ph + 0.25; if ph2 >= 1 { ph2 -= 1 }
            dl.write(l[i]); dr.write(r[i])
            let yl = dl.read(base + sine01(ph) * sweep)
            let yr = dr.read(base + sine01(ph2) * sweep)
            l[i] = l[i] * dry + yl * wet
            r[i] = r[i] * dry + yr * wet
        }
    }
}

final class VibratoFX: FXProcessor {
    private let dl: DelayLine, dr: DelayLine
    override init(type: FXType, sampleRate: Double) {
        dl = DelayLine(maxFrames: Int(sampleRate * 0.02)); dr = DelayLine(maxFrames: Int(sampleRate * 0.02))
        super.init(type: type, sampleRate: sampleRate)
    }
    override func reset() { dl.reset(); dr.reset() }
    override func render(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ n: Int, _ ctx: FXContext) {
        let depth = p(2) / 100
        let base = 0.006 * sampleRate
        for i in 0..<n {
            let ph = lfoPhase(syncIndex: 0, rateParam: 1, at: i, ctx)
            advanceFree(rateParam: 1, slowHz: 0.5, fastHz: 12)
            let d = base + sine01(ph) * base * 0.8 * depth
            dl.write(l[i]); dr.write(r[i])
            l[i] = dl.read(d); r[i] = dr.read(d)
        }
    }
}

// MARK: - Amplitude / pan modulation

final class TremoloFX: FXProcessor {
    override func render(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ n: Int, _ ctx: FXContext) {
        let depth = p(2) / 100, wave = choice(3)
        for i in 0..<n {
            let ph = lfoPhase(syncIndex: 0, rateParam: 1, at: i, ctx)
            advanceFree(rateParam: 1, slowHz: 0.2, fastHz: 20)
            let m: Float = wave == 0 ? tri01(ph) : (wave == 1 ? sine01(ph) : (ph < 0.5 ? 1 : -1))
            let g = 1 - depth * (0.5 - 0.5 * m)
            l[i] *= g; r[i] *= g
        }
    }
}

final class AutoPanFX: FXProcessor {
    override func render(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ n: Int, _ ctx: FXContext) {
        let depth = p(2) / 100, wave = choice(3)
        for i in 0..<n {
            let ph = lfoPhase(syncIndex: 0, rateParam: 1, at: i, ctx)
            advanceFree(rateParam: 1, slowHz: 0.05, fastHz: 10)
            let m: Float = wave == 0 ? tri01(ph) : (wave == 1 ? sine01(ph) : (ph < 0.5 ? 1 : -1))
            let (gl, gr) = panGains(m * depth)
            let mono = (l[i] + r[i]) * 0.5
            l[i] = l[i] * (1 - depth) + mono * gl * depth
            r[i] = r[i] * (1 - depth) + mono * gr * depth
        }
    }
}

final class ManualPanFX: FXProcessor {
    override func render(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ n: Int, _ ctx: FXContext) {
        let (gl, gr) = panGains(p(0) / 50)
        for i in 0..<n { let m = (l[i] + r[i]) * 0.5; l[i] = m * gl; r[i] = m * gr }
    }
}

/// Rhythmic gate driven by 16-step patterns, locked to the measure grid.
final class SlicerFX: FXProcessor {
    static let patterns: [UInt16] = [
        0b1010_1010_1010_1010, 0b1111_0000_1111_0000, 0b1011_1011_1011_1011, 0b1001_0010_0100_1001,
        0b1110_1110_1110_1010, 0b1100_1100_1010_1010, 0b1011_0110_1101_1011, 0b1000_1000_1010_1110,
        0b1101_1010_1101_1010, 0b1111_1010_1111_1010, 0b1001_1001_1001_1111, 0b1110_0111_0011_1001,
        0b1010_1111_1010_0101, 0b1100_0011_1100_0011, 0b1011_1101_1110_1111, 0b1000_0000_1000_0000
    ]
    private var gain = Smoother(1)
    override func render(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ n: Int, _ ctx: FXContext) {
        let stepsPerQuarter = [2.0, 4.0, 8.0][clamp(choice(0), 0, 2)]
        let quarterPerMeasure = Double(ctx.beatsPerMeasure) * 4 / Double(ctx.beatUnit)
        let pat = SlicerFX.patterns[clamp(Int(p(1)) - 1, 0, 15)]
        let depth = p(2) / 100
        let attack = max(8, Int(p(3) / 100 * 0.01 * sampleRate))
        for i in 0..<n {
            let steps = ctx.measure(at: i) * quarterPerMeasure * stepsPerQuarter
            let step = Int(steps) & 15
            let on = (pat >> (15 - step)) & 1 == 1
            let target: Float = on ? 1 : 1 - depth
            if target != gain.target { gain.set(target, frames: attack) }
            let g = gain.next()
            l[i] *= g; r[i] *= g
        }
    }
}

// MARK: - Delays

final class DelayFX: FXProcessor {
    private let dl: DelayLine, dr: DelayLine
    private var lpL = Biquad(), lpR = Biquad()
    private var time = Smoother(0)
    override init(type: FXType, sampleRate: Double) {
        dl = DelayLine(maxFrames: Int(sampleRate * 4)); dr = DelayLine(maxFrames: Int(sampleRate * 4))
        super.init(type: type, sampleRate: sampleRate)
        update()
    }
    override func update() {
        let hc = expMap(p(3), 800, 20000)
        lpL.set(.lowpass, freq: hc, q: 0.707, sampleRate: sampleRate); lpR = lpL
    }
    override func reset() { dl.reset(); dr.reset(); lpL.reset(); lpR.reset() }
    override func render(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ n: Int, _ ctx: FXContext) {
        var frames = Float(p(1) * 0.001 * sampleRate)
        if let m = syncLengthMeasures(choice(0), beatsPerMeasure: ctx.beatsPerMeasure, beatUnit: ctx.beatUnit) {
            frames = Float(m * ctx.measureFrames)
        }
        frames = clamp(frames, 1, Float(dl.capacity - 1))
        if time.value == 0 { time = Smoother(frames) } else if frames != time.target { time.set(frames, frames: 2048) }
        let fb = p(2) / 100 * 0.95, dry = p(4) / 100, wet = p(5) / 100
        let ping = type == .panningDelay
        for i in 0..<n {
            let t = time.next()
            let yl = lpL.tick(dl.read(t)), yr = lpR.tick(dr.read(t))
            if ping {
                let mono = (l[i] + r[i]) * 0.5
                dl.write(mono + yr * fb); dr.write(yl * fb)
            } else {
                dl.write(l[i] + yl * fb); dr.write(r[i] + yr * fb)
            }
            l[i] = l[i] * dry + yl * wet
            r[i] = r[i] * dry + yr * wet
        }
    }
}

final class TapeEchoFX: FXProcessor {
    private let dl: DelayLine, dr: DelayLine
    private var lp = Biquad(), lp2 = Biquad(), hp = Biquad(), hp2 = Biquad()
    private var wow = LFO(), flutter = LFO()
    private var time = Smoother(0)
    override init(type: FXType, sampleRate: Double) {
        dl = DelayLine(maxFrames: Int(sampleRate * 4)); dr = DelayLine(maxFrames: Int(sampleRate * 4))
        super.init(type: type, sampleRate: sampleRate)
        lp.set(.lowpass, freq: 4500, q: 0.6, sampleRate: self.sampleRate); lp2 = lp
        hp.set(.highpass, freq: 120, q: 0.6, sampleRate: self.sampleRate); hp2 = hp
    }
    override func reset() { dl.reset(); dr.reset(); lp.reset(); lp2.reset(); hp.reset(); hp2.reset() }
    override func render(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ n: Int, _ ctx: FXContext) {
        var frames = Float(p(1) * 0.001 * sampleRate)
        if let m = syncLengthMeasures(choice(0), beatsPerMeasure: ctx.beatsPerMeasure, beatUnit: ctx.beatUnit) {
            frames = Float(m * ctx.measureFrames)
        }
        frames = clamp(frames, 1, Float(dl.capacity) * 0.95)
        if time.value == 0 { time = Smoother(frames) } else if frames != time.target { time.set(frames, frames: 6000) }
        let fb = p(2) / 100 * 0.97, wowAmt = p(3) / 100, drive = 1 + p(4) / 100 * 4, wet = p(5) / 100
        let sr = Double(sampleRate)
        for i in 0..<n {
            let mod = 1 + (wow.tick(freq: 0.7, sampleRate: sr) * 0.004 + flutter.tick(freq: 9, sampleRate: sr) * 0.0008) * wowAmt
            let t = time.next() * mod
            var yl = dl.read(t), yr = dr.read(t)
            yl = hp.tick(lp.tick(softClip(yl * drive) / drive)); yr = hp2.tick(lp2.tick(softClip(yr * drive) / drive))
            dl.write(l[i] + yl * fb); dr.write(r[i] + yr * fb)
            l[i] += yl * wet; r[i] += yr * wet
        }
    }
}

// MARK: - Reverb (original Schroeder/Moorer-style network)

final class ReverbFX: FXProcessor {
    private static let combTimes: [Double] = [0.0297, 0.0371, 0.0411, 0.0437, 0.0253, 0.0269, 0.0290, 0.0307]
    private static let apTimes: [Double] = [0.0050, 0.0017, 0.0063, 0.0021]
    private var combsL: [DelayLine] = [], combsR: [DelayLine] = []
    private var combLenL: [Float] = [], combLenR: [Float] = []
    private var damp = [Float](repeating: 0, count: 16)
    private var apsL: [DelayLine] = [], apsR: [DelayLine] = []
    private var apLenL: [Float] = [], apLenR: [Float] = []
    private let pre: DelayLine
    private var lowCut = Biquad(), lowCutR = Biquad(), highCut = Biquad(), highCutR = Biquad()
    private var feedback: Float = 0.8, damping: Float = 0.3

    override init(type: FXType, sampleRate: Double) {
        for t in ReverbFX.combTimes {
            combsL.append(DelayLine(maxFrames: Int(t * sampleRate) + 4)); combLenL.append(Float(t * sampleRate))
            let tr = t + 0.00052
            combsR.append(DelayLine(maxFrames: Int(tr * sampleRate) + 4)); combLenR.append(Float(tr * sampleRate))
        }
        for t in ReverbFX.apTimes {
            apsL.append(DelayLine(maxFrames: Int(t * sampleRate) + 4)); apLenL.append(Float(t * sampleRate))
            apsR.append(DelayLine(maxFrames: Int((t + 0.0003) * sampleRate) + 4)); apLenR.append(Float((t + 0.0003) * sampleRate))
        }
        pre = DelayLine(maxFrames: Int(sampleRate * 0.55))
        super.init(type: type, sampleRate: sampleRate)
        update()
    }
    override func update() {
        let seconds = Double(p(0)) / 10              // 0.1 … 10 s
        let avg = ReverbFX.combTimes.reduce(0, +) / Double(ReverbFX.combTimes.count)
        feedback = Float(pow(0.001, avg / max(seconds, 0.1)))
        damping = 0.2 + (1 - p(3) / 100) * 0.6
        lowCut.set(.highpass, freq: expMap(p(2), 20, 1200), q: 0.7, sampleRate: sampleRate); lowCutR = lowCut
        highCut.set(.lowpass, freq: expMap(p(3), 1500, 18000), q: 0.7, sampleRate: sampleRate); highCutR = highCut
    }
    override func reset() {
        combsL.forEach { $0.reset() }; combsR.forEach { $0.reset() }
        apsL.forEach { $0.reset() }; apsR.forEach { $0.reset() }; pre.reset()
        for i in 0..<damp.count { damp[i] = 0 }
    }
    override func render(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ n: Int, _ ctx: FXContext) {
        let preFrames = max(1, p(1) * 0.001 * sampleRate)
        let dry = p(4) / 100, wet = p(5) / 100
        let nc = combsL.count
        damp.withUnsafeMutableBufferPointer { d in
            for i in 0..<n {
                pre.write((l[i] + r[i]) * 0.5)
                let x = lowCut.tick(pre.read(preFrames)) * 0.25
                var sl: Float = 0, sr: Float = 0
                for c in 0..<nc {
                    let yl = combsL[c].read(combLenL[c])
                    d[c] = yl * (1 - damping) + d[c] * damping
                    combsL[c].write(x + d[c] * feedback)
                    sl += yl
                    let yr = combsR[c].read(combLenR[c])
                    d[c + 8] = yr * (1 - damping) + d[c + 8] * damping
                    combsR[c].write(x + d[c + 8] * feedback)
                    sr += yr
                }
                for a in 0..<apsL.count {
                    let bl = apsL[a].read(apLenL[a]); let vl = sl + bl * 0.5; apsL[a].write(vl); sl = bl - vl * 0.5
                    let br = apsR[a].read(apLenR[a]); let vr = sr + br * 0.5; apsR[a].write(vr); sr = br - vr * 0.5
                }
                sl = highCut.tick(sl); sr = highCutR.tick(sr)
                l[i] = l[i] * dry + sl * wet
                r[i] = r[i] * dry + sr * wet
            }
        }
    }
}

// MARK: - Distortion / Lo-Fi / Ring mod / Radio

final class DistFX: FXProcessor {
    private var tone = Biquad(), toneR = Biquad(), pre = Biquad(), preR = Biquad()
    override init(type: FXType, sampleRate: Double) { super.init(type: type, sampleRate: sampleRate); update() }
    override func update() {
        tone.set(.lowpass, freq: expMap(p(1), 1000, 12000), q: 0.7, sampleRate: sampleRate); toneR = tone
        pre.set(.highpass, freq: 90, q: 0.7, sampleRate: sampleRate); preR = pre
    }
    override func reset() { tone.reset(); toneR.reset(); pre.reset(); preR.reset() }
    override func render(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ n: Int, _ ctx: FXContext) {
        let drive = 1 + powf(p(0) / 100, 2) * 60, dry = p(2) / 100, wet = p(3) / 100
        let comp = 1 / sqrtf(drive) * 1.6
        for i in 0..<n {
            let yl = tone.tick(tanhf(pre.tick(l[i]) * drive)) * comp
            let yr = toneR.tick(tanhf(preR.tick(r[i]) * drive)) * comp
            l[i] = l[i] * dry + yl * wet; r[i] = r[i] * dry + yr * wet
        }
    }
}

final class LoFiFX: FXProcessor {
    private var holdL: Float = 0, holdR: Float = 0, acc: Float = 0
    override func render(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ n: Int, _ ctx: FXContext) {
        let bits = clamp(p(0), 1, 31)
        let levels = powf(2, bits - 1)
        let ratio = expMap(100 - p(1), 1, 60) // decimation factor
        let bal = p(2) / 100
        for i in 0..<n {
            acc += 1
            if acc >= ratio { acc -= ratio; holdL = (l[i] * levels).rounded() / levels; holdR = (r[i] * levels).rounded() / levels }
            l[i] = l[i] * (1 - bal) + holdL * bal; r[i] = r[i] * (1 - bal) + holdR * bal
        }
    }
}

final class RingModFX: FXProcessor {
    private var osc = LFO()
    override func render(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ n: Int, _ ctx: FXContext) {
        let f = Double(expMap(p(0), 30, 3000)), dry = p(1) / 100, wet = p(2) / 100
        for i in 0..<n {
            let m = osc.tick(freq: f, sampleRate: Double(sampleRate))
            l[i] = l[i] * dry + l[i] * m * wet; r[i] = r[i] * dry + r[i] * m * wet
        }
    }
}

final class RadioFX: FXProcessor {
    private var bp = Biquad(), bp2 = Biquad(), noise = Noise(seed: 77)
    override init(type: FXType, sampleRate: Double) { super.init(type: type, sampleRate: sampleRate); update() }
    override func update() {
        let width = 0.5 + p(0) / 100 * 2.5
        bp.set(.bandpass, freq: 1500, q: width, sampleRate: sampleRate)
        bp2.set(.bandpass, freq: 1500, q: width, sampleRate: sampleRate)
    }
    override func reset() { bp.reset(); bp2.reset() }
    override func render(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ n: Int, _ ctx: FXContext) {
        let nz = p(1) / 100 * 0.03, lvl = p(2) / 100 * 2
        for i in 0..<n {
            let m = (l[i] + r[i]) * 0.5
            let y = bp2.tick(bp.tick(softClip(m * 3))) * lvl + noise.next() * nz
            l[i] = y; r[i] = y
        }
    }
}

// MARK: - Isolator / EQ / Dynamics

final class IsolatorFX: FXProcessor {
    private var lpL = Biquad(), lpR = Biquad(), hpL = Biquad(), hpR = Biquad()
    private var gLow = Smoother(1), gMid = Smoother(1), gHigh = Smoother(1)
    override init(type: FXType, sampleRate: Double) {
        super.init(type: type, sampleRate: sampleRate)
        lpL.set(.lowpass, freq: 250, q: 0.5, sampleRate: self.sampleRate); lpR = lpL
        hpL.set(.highpass, freq: 3000, q: 0.5, sampleRate: self.sampleRate); hpR = hpL
        update()
    }
    private func g(_ v: Float) -> Float { v <= 50 ? powf(v / 50, 2) : 1 + (v - 50) / 50 * 1.5 } // 0 = kill, 50 = unity, 100 = +8 dB
    override func update() {
        gLow.set(g(p(0)), frames: 512); gMid.set(g(p(1)), frames: 512); gHigh.set(g(p(2)), frames: 512)
    }
    override func reset() { lpL.reset(); lpR.reset(); hpL.reset(); hpR.reset() }
    override func render(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ n: Int, _ ctx: FXContext) {
        for i in 0..<n {
            let a = gLow.next(), b = gMid.next(), c = gHigh.next()
            let lowL = lpL.tick(l[i]), highL = hpL.tick(l[i]), midL = l[i] - lowL - highL
            let lowR = lpR.tick(r[i]), highR = hpR.tick(r[i]), midR = r[i] - lowR - highR
            l[i] = lowL * a + midL * b + highL * c
            r[i] = lowR * a + midR * b + highR * c
        }
    }
}

final class EQFX: FXProcessor {
    private var bands = [Biquad](repeating: Biquad(), count: 8)
    private var out: Float = 1
    override init(type: FXType, sampleRate: Double) { super.init(type: type, sampleRate: sampleRate); update() }
    override func update() {
        var b = Biquad()
        b.set(.lowShelf, freq: 120, q: 0.7, gainDb: p(0), sampleRate: sampleRate); bands[0] = b; bands[4] = b
        b.set(.peak, freq: 500, q: 0.9, gainDb: p(1), sampleRate: sampleRate); bands[1] = b; bands[5] = b
        b.set(.peak, freq: 2500, q: 0.9, gainDb: p(2), sampleRate: sampleRate); bands[2] = b; bands[6] = b
        b.set(.highShelf, freq: 8000, q: 0.7, gainDb: p(3), sampleRate: sampleRate); bands[3] = b; bands[7] = b
        out = dbToGain(p(4))
    }
    override func render(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ n: Int, _ ctx: FXContext) {
        bands.withUnsafeMutableBufferPointer { bq in
            for i in 0..<n {
                var x = l[i], y = r[i]
                for k in 0..<4 { x = bq[k].tick(x); y = bq[k + 4].tick(y) }
                l[i] = x * out; r[i] = y * out
            }
        }
    }
}

/// Feed-forward RMS-ish compressor. Also used by the Master FX COMP.
final class DynamicsFX: FXProcessor {
    private var env = EnvelopeFollower()
    private var threshold: Float = 0.3, ratio: Float = 4, makeup: Float = 1
    override init(type: FXType, sampleRate: Double) { super.init(type: type, sampleRate: sampleRate); update() }
    override func update() {
        let depth = p(0) / 100
        threshold = dbToGain(-6 - depth * 30)
        ratio = 1.5 + depth * 8
        makeup = dbToGain(depth * 12 + p(3))
        env.set(attackMs: 0.5 + p(1) / 100 * 50, releaseMs: 20 + p(2) / 100 * 600, sampleRate: sampleRate)
    }
    override func reset() { env.reset() }
    override func render(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ n: Int, _ ctx: FXContext) {
        for i in 0..<n {
            let e = env.tick(max(abs(l[i]), abs(r[i])))
            var g: Float = 1
            if e > threshold { g = powf(e / threshold, 1 / ratio - 1) }
            l[i] *= g * makeup; r[i] *= g * makeup
        }
    }
}

// MARK: - Freeze / Roll / Beat Repeat / Vinyl Flick (capture-based)

/// Captures ~180 ms when switched on and sustains it with a cross-faded grain loop.
final class FreezeFX: FXProcessor {
    private let cap: Int
    private let bufL: UnsafeMutablePointer<Float>, bufR: UnsafeMutablePointer<Float>
    private var writePos = 0, capturing = true, pos1 = 0.0, pos2 = 0.0
    private var level = Smoother(0)
    override init(type: FXType, sampleRate: Double) {
        cap = Int(sampleRate * 0.18)
        bufL = .allocate(capacity: cap); bufR = .allocate(capacity: cap)
        bufL.initialize(repeating: 0, count: cap); bufR.initialize(repeating: 0, count: cap)
        super.init(type: type, sampleRate: sampleRate)
    }
    deinit { bufL.deallocate(); bufR.deallocate() }
    override func reset() {
        writePos = 0; capturing = true; pos1 = 0; pos2 = Double(cap) / 2
        level = Smoother(0); level.set(1, frames: max(64, Int(p(0) / 100 * sampleRate)))
    }
    override func render(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ n: Int, _ ctx: FXContext) {
        let out = p(2) / 100 * 1.2
        let half = Double(cap) / 2
        for i in 0..<n {
            if capturing {
                bufL[writePos] = l[i]; bufR[writePos] = r[i]; writePos += 1
                if writePos >= cap { capturing = false }
                continue // dry passes through while capturing
            }
            // two overlapping read heads with triangular windows → smooth sustain
            let w1 = Float(1 - abs(pos1 - half) / half), w2 = 1 - w1
            let i1 = Int(pos1), i2 = Int(pos2)
            let g = level.next() * out
            l[i] = (bufL[i1] * w1 + bufL[i2] * w2) * g + l[i] * (1 - level.value)
            r[i] = (bufR[i1] * w1 + bufR[i2] * w2) * g + r[i] * (1 - level.value)
            pos1 += 1; if pos1 >= Double(cap) { pos1 -= Double(cap) }
            pos2 += 1; if pos2 >= Double(cap) { pos2 -= Double(cap) }
        }
    }
}

/// Grid-synchronised stutter: captures one note-length slice and repeats it.
class RepeatBaseFX: FXProcessor {
    let cap: Int
    let bufL: UnsafeMutablePointer<Float>, bufR: UnsafeMutablePointer<Float>
    var sliceLen = 0, writePos = 0, readPos = 0, armed = true
    override init(type: FXType, sampleRate: Double) {
        cap = Int(sampleRate * 4)
        bufL = .allocate(capacity: cap); bufR = .allocate(capacity: cap)
        bufL.initialize(repeating: 0, count: cap); bufR.initialize(repeating: 0, count: cap)
        super.init(type: type, sampleRate: sampleRate)
    }
    deinit { bufL.deallocate(); bufR.deallocate() }
    override func reset() { writePos = 0; readPos = 0; armed = true; sliceLen = 0 }
    func lengthMeasures(_ ctx: FXContext) -> Double { 0.25 }
    var feedback: Float { 1 }
    var reverse: Bool { false }
    var balance: Float { 1 }
    override func render(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ n: Int, _ ctx: FXContext) {
        if armed { sliceLen = clamp(Int(lengthMeasures(ctx) * ctx.measureFrames), 64, cap); armed = false }
        let fade = min(64, sliceLen / 4)
        for i in 0..<n {
            if writePos < sliceLen {
                bufL[writePos] = l[i]; bufR[writePos] = r[i]; writePos += 1
                continue
            }
            let idx = reverse ? sliceLen - 1 - readPos : readPos
            var w: Float = 1
            if readPos < fade { w = Float(readPos) / Float(fade) } else if readPos > sliceLen - fade { w = Float(sliceLen - readPos) / Float(fade) }
            let yl = bufL[idx] * w, yr = bufR[idx] * w
            l[i] = l[i] * (1 - balance) + yl * balance
            r[i] = r[i] * (1 - balance) + yr * balance
            readPos += 1
            if readPos >= sliceLen {
                readPos = 0
                if feedback < 1 { for k in 0..<sliceLen { bufL[k] *= feedback; bufR[k] *= feedback } }
            }
        }
    }
}

final class RollFX: RepeatBaseFX {
    override func lengthMeasures(_ ctx: FXContext) -> Double {
        let q = Double(ctx.beatsPerMeasure) * 4 / Double(ctx.beatUnit)
        return [1.0, 0.5, 0.25, 0.125][clamp(choice(0), 0, 3)] / q
    }
    override var feedback: Float { max(0.3, p(1) / 100) }
    override var balance: Float { p(2) / 100 }
}

final class BeatRepeatFX: RepeatBaseFX {
    override func lengthMeasures(_ ctx: FXContext) -> Double {
        let q = Double(ctx.beatsPerMeasure) * 4 / Double(ctx.beatUnit)
        return [2.0, 1.0, 0.5, 0.25][clamp(choice(0), 0, 3)] / q
    }
    override var reverse: Bool { choice(1) == 1 }
}

final class VinylFlickFX: FXProcessor {
    private var noise = Noise(seed: 4242), lp = Biquad(), lpR = Biquad(), hp = Biquad(), hpR = Biquad()
    private var wow = LFO()
    private let dl: DelayLine, dr: DelayLine
    override init(type: FXType, sampleRate: Double) {
        dl = DelayLine(maxFrames: Int(sampleRate * 0.02)); dr = DelayLine(maxFrames: Int(sampleRate * 0.02))
        super.init(type: type, sampleRate: sampleRate)
        lp.set(.lowpass, freq: 6000, q: 0.7, sampleRate: self.sampleRate); lpR = lp
        hp.set(.highpass, freq: 150, q: 0.7, sampleRate: self.sampleRate); hpR = hp
    }
    override func reset() { dl.reset(); dr.reset() }
    override func render(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ n: Int, _ ctx: FXContext) {
        let flick = p(0) / 100, dry = p(1) / 100, wet = p(2) / 100
        let base = 0.004 * sampleRate
        for i in 0..<n {
            let d = base + wow.tick(freq: 0.55, sampleRate: Double(sampleRate)) * base * 0.25
            dl.write(l[i]); dr.write(r[i])
            var crackle: Float = 0
            let z = noise.next()
            if abs(z) > 1 - flick * 0.002 { crackle = z * 0.5 }
            let hiss = noise.next() * 0.004 * flick
            let yl = hp.tick(lp.tick(dl.read(d))) + crackle + hiss
            let yr = hpR.tick(lpR.tick(dr.read(d))) + crackle + hiss
            l[i] = l[i] * dry + yl * wet
            r[i] = r[i] * dry + yr * wet
        }
    }
}
