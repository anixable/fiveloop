import XCTest
@testable import LooperCore

/// Renders a short demo session to /tmp/fiveloop_demo.wav (only when FIVELOOP_DEMO=1).
final class ZDemoRender: XCTestCase {
    func testRenderDemo() throws {
        guard ProcessInfo.processInfo.environment["FIVELOOP_DEMO"] == "1" else { return }
        let h = Harness(seconds: 20, block: 256)
        var g = GlobalLoopSettings(); g.recAction = .recPlay
        h.send(.global(g))
        var r = RhythmSettings(); r.startTrigger = .beforeLoop
        r.patternIndex = patternDefs.firstIndex { $0.name == "Funk 1" }!; r.kitIndex = 0; r.level = 70
        h.send(.rhythm(r)); h.send(.tempo(100)); h.send(.rhythmOn(true))
        let M = Int((60.0 * 44100 / 100 * 4).rounded())
        let bass: [Double] = [41.2, 41.2, 49.0, 55.0, 41.2, 61.7, 55.0, 49.0]
        func tone(_ f: Int, _ freqs: [Double], _ amp: Float, _ dec: Double) -> Float {
            let eighth = M / 8
            let i = (f / eighth) % freqs.count, t = Double(f % eighth) / 44100
            return amp * Float(sin(2 * .pi * freqs[i] * 2 * t) * exp(-t * dec))
        }
        h.run(until: M - 300)
        // track 1: bass (2 measures)
        h.input = { f in let v = tone(f, bass, 0.45, 3); return (v, v) }
        h.send(.recPlay(0)); h.run(until: 3 * M - 300); h.send(.recPlay(0))
        // track 2: chord stabs with input FX delay
        h.e.send(.fxInstall(.input, bank: 0, slot: 0, FXType.delay.make(sampleRate: 44100)))
        h.e.send(.fxParam(.input, bank: 0, slot: 0, index: 0, 6)); h.e.send(.fxSwitch(.input, bank: 0, slot: 0, true))
        let chord: [Double] = [261.6, 329.6, 392.0]
        h.input = { f in
            let beat = (f / (M / 4)) % 4
            guard beat == 1 || beat == 3 else { return (0, 0) }
            let t = Double(f % (M / 4)) / 44100
            let v = Float(chord.reduce(0) { $0 + sin(2 * .pi * $1 * t) } * exp(-t * 6)) * 0.12
            return (v, v)
        }
        h.run(until: 3 * M + 1000); h.send(.recPlay(1)); h.run(until: 5 * M + 2000)
        h.e.send(.fxSwitch(.input, bank: 0, slot: 0, false))
        h.input = { _ in (0, 0) }
        // track FX: filter sweep on everything for two measures
        h.e.send(.fxInstall(.track, bank: 0, slot: 0, FXType.lpf.make(sampleRate: 44100)))
        h.e.send(.fxParam(.track, bank: 0, slot: 0, index: 0, 2)); h.e.send(.masterReverb(10))
        h.run(until: 8 * M); h.e.send(.fxSwitch(.track, bank: 0, slot: 0, true))
        h.run(until: 10 * M); h.e.send(.fxSwitch(.track, bank: 0, slot: 0, false))
        h.run(until: 12 * M)
        let wav = WAV.encode(left: h.outL, right: h.outR, sampleRate: 44100, format: .int16)
        try wav.write(to: URL(fileURLWithPath: "/tmp/fiveloop_demo.wav"))
        // click check: largest sample-to-sample jump relative to signal level
        var maxJump: Float = 0
        for i in 1..<h.outL.count { maxJump = max(maxJump, abs(h.outL[i] - h.outL[i - 1])) }
        print("DEMO: \(h.outL.count) frames, peak \(h.outL.map { abs($0) }.max()!), max step \(maxJump)")
    }
}
