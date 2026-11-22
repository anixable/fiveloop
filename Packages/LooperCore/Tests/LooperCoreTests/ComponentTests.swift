import XCTest
@testable import LooperCore

final class FXTests: XCTestCase {
    func noise(_ n: Int, seed: UInt32 = 1) -> [Float] { var g = Noise(seed: seed); return (0..<n).map { _ in g.next() * 0.5 } }

    /// Every effect: stable (no NaN/Inf), bounded output, every parameter at min/default/max.
    func testAllEffectsStableAcrossParameterExtremes() {
        var ctx = FXContext(); ctx.running = true; ctx.measureFrames = 88200; ctx.measuresPerFrame = 1 / 88200
        for type in FXType.allCases {
            for setting in 0..<3 {
                let fx = type.make(sampleRate: 44100)
                for (i, p) in type.params.enumerated() {
                    fx.setParam(i, setting == 0 ? p.minValue : (setting == 1 ? p.defaultValue : p.maxValue))
                }
                fx.reset()
                var l = noise(44100), r = noise(44100, seed: 9)
                var peak: Float = 0
                for start in stride(from: 0, to: 44100, by: 512) {
                    let n = min(512, 44100 - start)
                    ctx.measurePos = Double(start) / 88200
                    l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
                        fx.render(lp.baseAddress! + start, rp.baseAddress! + start, n, ctx) } }
                }
                for v in l + r {
                    XCTAssertTrue(v.isFinite, "\(type) produced non-finite output (setting \(setting))")
                    peak = max(peak, abs(v))
                }
                XCTAssertLessThan(peak, 200, "\(type) exploded (setting \(setting))")
            }
        }
    }

    func testTempoSyncedDelayEchoLandsOnTheBeat() {
        let fx = FXType.delay.make(sampleRate: 44100)
        fx.setParam(0, 5)        // SYNC 1/4
        fx.setParam(2, 0)        // no feedback
        fx.setParam(4, 0)        // dry off
        fx.setParam(5, 100)      // wet
        var ctx = FXContext(); ctx.measureFrames = 88200; ctx.running = true
        var l = [Float](repeating: 0, count: 44100), r = l
        l[0] = 1; r[0] = 1
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
            fx.render(lp.baseAddress!, rp.baseAddress!, 44100, ctx) } }
        let peakIdx = l.indices.max { abs(l[$0]) < abs(l[$1]) }!
        XCTAssertEqual(peakIdx, 22050, accuracy: 2)   // quarter note at 120 BPM
    }

    func testRackCrossfadeIsClickFree() {
        let rack = FXRack(maxFrames: 512)
        rack.slots[0][0].processor = FXType.lpf.make(sampleRate: 44100)
        var ctx = FXContext(); ctx.running = false
        var prev: Float = 0, maxJump: Float = 0
        for block in 0..<40 {
            if block == 10 { rack.setSlotOn(bank: 0, slot: 0, on: true, sampleRate: 44100) }
            if block == 25 { rack.setSlotOn(bank: 0, slot: 0, on: false, sampleRate: 44100) }
            var l = (0..<512).map { Float(sin(Double(block * 512 + $0) * 0.01)) * 0.5 }, r = l
            l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
                rack.process(lp.baseAddress!, rp.baseAddress!, 512, ctx) } }
            for v in l { maxJump = max(maxJump, abs(v - prev)); prev = v }
        }
        XCTAssertLessThan(maxJump, 0.05)
    }
}

final class RhythmTests: XCTestCase {
    func testPatternLibrarySize() {
        XCTAssertGreaterThanOrEqual(patternDefs.count * 4, 200, "patterns × variations A–D")
        XCTAssertEqual(kitRecipes.count, 16)
        for d in patternDefs { XCTAssertTrue(rhythmGenres.contains(d.genre), d.genre) }
    }

    func testKickLandsOnDownbeat() {
        let r = RhythmEngine(sampleRate: 44100)
        var s = RhythmSettings(); s.patternIndex = patternDefs.firstIndex { $0.name == "Rock 8" }!
        r.apply(s)
        var l = [Float](repeating: 0, count: 88200 * 2), rr = l
        var pos = 0.0
        for start in stride(from: 0, to: l.count, by: 256) {
            let n = min(256, l.count - start)
            l.withUnsafeMutableBufferPointer { lp in rr.withUnsafeMutableBufferPointer { rp in
                r.render(n, songStart: pos, ratio: 1, refMeasure: 88200, beats: 4, unit: 4, playing: true, countIn: false,
                         outL: lp.baseAddress! + start, outR: rp.baseAddress! + start) } }
            pos += Double(n)
        }
        XCTAssertGreaterThan(abs(l[88200 + 20]), 0.01, "kick at measure 2")
        XCTAssertLessThan(abs(l[88200 - 30]), abs(l[88200 + 20]))
        XCTAssertEqual(l[0..<5].map { $0.isFinite }.allSatisfy { $0 }, true)
    }

    func testAllKitsRender() {
        for k in RhythmEngine(sampleRate: 44100).kits {
            XCTAssertEqual(k.lengths.count, DrumVoice.allCases.count)
            XCTAssertTrue(k.lengths.allSatisfy { $0 > 100 }, k.name)
        }
    }
}

final class MIDITests: XCTestCase {
    func testParserRunningStatusAndRealtime() {
        var p = MIDIParser()
        let msgs = p.feed([0x90, 60, 100, 62, 0, 0xF8, 0xB1, 7, 127, 0xFA, 0xC0, 5])
        XCTAssertEqual(msgs, [.noteOn(channel: 1, note: 60, velocity: 100), .noteOff(channel: 1, note: 62, velocity: 0),
                              .clock, .controlChange(channel: 2, controller: 7, value: 127), .start,
                              .programChange(channel: 1, program: 5)])
        XCTAssertEqual(MIDIParser.bytes(.controlChange(channel: 2, controller: 7, value: 127)), [0xB1, 7, 127])
    }

    func testClockFollowerFindsTempo() {
        var c = ClockFollower()
        var last: Double? = nil
        let dt = 60.0 / (97.5 * 24)
        for i in 0..<96 { if let b = c.tick(at: Double(i) * dt + (i % 2 == 0 ? 0.0002 : -0.0002)) { last = b } }
        XCTAssertEqual(last ?? 0, 97.5, accuracy: 0.2)
    }

    func testAssignmentsAndLearn() {
        var m = AssignmentMap()
        m.items.append(Assignment(source: .cc(channel: 0, number: 80), target: .recPlay(2)))
        m.items.append(Assignment(source: .note(channel: 10, number: 36), target: .allStartStop))
        XCTAssertEqual(m.actions(for: .controlChange(channel: 5, controller: 80, value: 127)).first?.target, .recPlay(2))
        XCTAssertEqual(m.actions(for: .noteOn(channel: 9, note: 36, velocity: 90)).count, 0)
        XCTAssertEqual(m.actions(for: .noteOn(channel: 10, note: 36, velocity: 90)).first?.pressed, true)
        XCTAssertEqual(AssignmentMap.learnSource(from: .controlChange(channel: 3, controller: 21, value: 1)), .cc(channel: 3, number: 21))
    }

    func testTapTempo() {
        var t = TapTempo()
        var b: Double? = nil
        for i in 0..<5 { b = t.tap(at: Double(i) * 0.5) }
        XCTAssertEqual(b!, 120, accuracy: 0.01)
    }

    func testEngineEmitsMIDIClock() {
        let e = LooperEngine(sampleRate: 44100, maxFrames: 512, maxLoopSeconds: 2)
        var r = RhythmSettings(); r.startTrigger = .beforeLoop
        e.send(.rhythm(r)); e.send(.rhythmOn(true))
        var o = [Float](repeating: 0, count: 512), o2 = o
        var ticks = 0, starts = 0
        for _ in 0..<(88200 / 512) {
            o.withUnsafeMutableBufferPointer { a in o2.withUnsafeMutableBufferPointer { b in
                e.process(frames: 512, inL: nil, inR: nil, outL: a.baseAddress!, outR: b.baseAddress!) } }
            while let ev = e.midiOut.pop() { if ev.status == 0xF8 { ticks += 1 } else if ev.status == 0xFA { starts += 1 } }
        }
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(ticks, 96 - 96 * (88200 % 512) / 88200, accuracy: 2) // one measure of 4/4 = 96 ticks
    }
}

final class StorageTests: XCTestCase {
    var tmp: URL!
    override func setUp() { tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    override func tearDown() { try? FileManager.default.removeItem(at: tmp) }

    func testWAVRoundTrip() throws {
        let l = (0..<1000).map { Float(sin(Double($0) * 0.05)) * 0.9 }, r = l.map { -$0 }
        for f in WAVFormat.allCases {
            let d = WAV.encode(left: l, right: r, sampleRate: 44100, format: f)
            let w = try WAV.decode(d)
            XCTAssertEqual(w.sampleRate, 44100); XCTAssertEqual(w.channels.count, 2)
            let tol: Float = f == .int16 ? 1e-4 : (f == .int24 ? 1e-6 : 0)
            for i in 0..<1000 { XCTAssertEqual(w.channels[0][i], l[i], accuracy: tol); XCTAssertEqual(w.channels[1][i], r[i], accuracy: tol) }
        }
        XCTAssertThrowsError(try WAV.decode(Data([1, 2, 3])))
        XCTAssertEqual(WAV.resample([0, 1, 2, 3], from: 2, to: 4).count, 8)
    }

    func testMemoryStoreLifecycle() throws {
        let s = try MemoryStore(root: tmp)
        var m = MemoryData(); m.name = "SONG A"; m.tempo = 97
        let a: TrackAudio = ((0..<500).map { Float($0) / 500 }, (0..<500).map { -Float($0) / 500 })
        try s.save(3, data: m, audio: [a, nil, nil, nil, nil])
        let (m2, audio) = try s.load(3)
        XCTAssertEqual(m2.name, "SONG A"); XCTAssertEqual(m2.tempo, 97)
        XCTAssertEqual(audio[0]?.left, a.left); XCTAssertEqual(audio[0]?.right, a.right); XCTAssertNil(audio[1])
        try s.rename(3, to: "my song"); XCTAssertEqual(try s.load(3).0.name, "MY SONG")
        try s.duplicate(3, to: 4); XCTAssertTrue(s.exists(4))
        let backup = tmp.appendingPathComponent("all.flbk")
        try s.backupAll(to: backup)
        try s.delete(3); try s.delete(4); XCTAssertFalse(s.exists(3))
        XCTAssertEqual(try s.restoreAll(from: backup), 2)
        XCTAssertEqual(try s.load(4).1[0]?.left, a.left)
        let bundle = tmp.appendingPathComponent("x.floop")
        try s.exportBundle(4, to: bundle); try s.importBundle(from: bundle, to: 10)
        XCTAssertEqual(try s.load(10).0.name, "MY SONG")
        XCTAssertEqual(s.list().filter { $0.hasAudio }.map { $0.index }, [3, 4, 10])
        XCTAssertFalse(s.beginSession()); XCTAssertFalse(s.beginSession()) // no recovery memory yet
        s.endSession()
    }

    func testEngineMemoryRoundTripAndOfflineMix() throws {
        // record a loop live, capture, reload into a fresh engine, then offline-render it
        let h = Harness(block: 100)
        var g = GlobalLoopSettings(); g.recAction = .recPlay
        h.send(.global(g))
        h.input = { f in (f < 44100 ? 0.3 : 0, 0) }
        h.send(.recPlay(0)); h.run(until: 44100); h.send(.recPlay(0)); h.run(until: 45000)
        var m = MemoryData(); m.global = g
        m.grid = h.e.gridInfo
        m.trackMeta[0].hasAudio = true; m.trackMeta[0].measures = h.e.tracks[0].measures
        let audio = h.e.captureAudio()
        XCTAssertEqual(audio[0]?.left.count, 44100)
        let mix = OfflineRenderer.render(m, audio: audio, options: { var o = OfflineRenderer.Options(); o.repeats = 2; return o }())
        XCTAssertEqual(mix.left.count, 88200)
        XCTAssertEqual(mix.left[20000], 0.3, accuracy: 1e-4)
        XCTAssertEqual(mix.left[44100 + 20000], 0.3, accuracy: 1e-4)
        let bundle = try MemoryStore.bundle(m, audio: audio)
        let (m2, a2) = try MemoryStore.unbundle(bundle)
        XCTAssertEqual(m2, m); XCTAssertEqual(a2[0]?.left, audio[0]?.left)
    }
}

final class PerformanceTests: XCTestCase {
    /// Worst-case load: 5 tracks playing (one overdubbing), 4 input FX + 4 track FX + rhythm + master FX.
    func testRealtimeFactor() {
        let e = LooperEngine(sampleRate: 44100, maxFrames: 256, maxLoopSeconds: 4)
        var g = GlobalLoopSettings(); g.recAction = .recPlay
        e.send(.global(g)); e.send(.masterComp(20)); e.send(.masterReverb(20))
        for (rack, types) in [(RackID.input, [FXType.reverb, .delay, .phaser, .dynamics]), (.track, [.reverb, .tapeEcho, .chorus, .lpf])] {
            for (s, t) in types.enumerated() {
                e.send(.fxInstall(rack, bank: 0, slot: s, t.make(sampleRate: 44100)))
                e.send(.fxSwitch(rack, bank: 0, slot: s, true))
            }
        }
        var inp = (0..<256).map { Float(sin(Double($0) * 0.1)) * 0.3 }
        var oL = [Float](repeating: 0, count: 256), oR = oL
        func run(_ blocks: Int) {
            for _ in 0..<blocks {
                inp.withUnsafeMutableBufferPointer { i in oL.withUnsafeMutableBufferPointer { a in oR.withUnsafeMutableBufferPointer { b in
                    e.process(frames: 256, inL: i.baseAddress!, inR: i.baseAddress!, outL: a.baseAddress!, outR: b.baseAddress!) } } }
            }
        }
        for t in 0..<5 { e.send(.recPlay(t)); run(345); e.send(.recPlay(t)); run(10) }
        e.send(.rhythmOn(true)); e.send(.recPlay(0))  // overdub on track 1
        let seconds = 20.0
        let blocks = Int(seconds * 44100 / 256)
        let t0 = Date()
        run(blocks)
        let elapsed = Date().timeIntervalSince(t0)
        let factor = seconds / elapsed
        print("PERF: \(String(format: "%.1f", factor))× real time (this build, this CPU), cpu ≈ \(String(format: "%.1f", 100 / factor))% of one core")
        #if DEBUG
        XCTAssertGreaterThan(factor, 0.3)   // unoptimised build on shared CI machines
        #else
        XCTAssertGreaterThan(factor, 1.0)
        #endif
        XCTAssertTrue(e.status.snapshot().tracks.allSatisfy { $0.state == .playing || $0.state == .overdubbing })
    }
}
