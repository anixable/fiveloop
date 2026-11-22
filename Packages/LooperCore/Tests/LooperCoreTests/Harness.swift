import XCTest
@testable import LooperCore

/// Drives an engine offline in fixed-size blocks, like the real audio callback.
final class Harness {
    let e: LooperEngine
    let block: Int
    var frame = 0
    var outL: [Float] = [], outR: [Float] = []
    var input: (Int) -> (Float, Float) = { _ in (0, 0) }
    private var bufL: [Float], bufR: [Float], oL: [Float], oR: [Float]

    init(seconds: Double = 20, block: Int = 256, sampleRate: Double = 44100) {
        e = LooperEngine(sampleRate: sampleRate, maxFrames: 1024, maxLoopSeconds: seconds)
        self.block = block
        bufL = .init(repeating: 0, count: block); bufR = bufL; oL = bufL; oR = bufL
        e.send(.monitor(false))
    }

    func send(_ c: EngineCommand) { e.send(c) }

    /// Run until `frame` reaches `until` (commands sent before are applied at the next block).
    func run(until: Int, keep: Bool = true) {
        while frame < until {
            let n = min(block, until - frame)
            for i in 0..<n { let (l, r) = input(frame + i); bufL[i] = l; bufR[i] = r }
            bufL.withUnsafeBufferPointer { il in bufR.withUnsafeBufferPointer { ir in
                oL.withUnsafeMutableBufferPointer { ol in oR.withUnsafeMutableBufferPointer { or in
                    e.process(frames: n, inL: il.baseAddress!, inR: ir.baseAddress!, outL: ol.baseAddress!, outR: or.baseAddress!)
                } } } }
            if keep { outL += oL[0..<n]; outR += oR[0..<n] }
            frame += n
        }
    }
    func run(seconds: Double) { run(until: frame + Int(seconds * e.sampleRate)) }
    var snap: StatusBoard.Snapshot { e.status.snapshot() }
    func drainEvents() -> [EngineEvent] { var v: [EngineEvent] = []; while let x = e.events.pop() { v.append(x) }; return v }
}

/// Deterministic test signal: unique-ish value per absolute frame.
func signal(_ f: Int) -> Float { Float(sin(Double(f) * 0.0123) * 0.5 + sin(Double(f) * 0.00071) * 0.25) }
