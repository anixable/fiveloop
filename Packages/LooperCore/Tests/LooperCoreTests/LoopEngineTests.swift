import XCTest
@testable import LooperCore

final class LoopEngineTests: XCTestCase {

    func recPlayGlobal() -> GlobalLoopSettings { var g = GlobalLoopSettings(); g.recAction = .recPlay; return g }

    /// First free recording defines the tempo; playback is sample-exact, with a seam crossfade.
    func testFreeRecordingDefinesTempoAndPlaysBackExactly() {
        let h = Harness(block: 100)
        h.send(.global(recPlayGlobal()))
        h.input = { f in f < 88200 + 256 ? (signal(f), signal(f) * 0.5) : (0, 0) }
        h.send(.recPlay(0))
        h.run(until: 88200)
        XCTAssertEqual(h.snap.tracks[0].state, .recording)
        h.send(.recPlay(0))
        h.run(until: 88200 * 3)
        let s = h.snap
        XCTAssertEqual(s.tracks[0].state, .playing)
        XCTAssertEqual(s.tracks[0].length, 88200)
        XCTAssertEqual(s.tempo, 120, accuracy: 1e-9)
        XCTAssertTrue(s.locked)
        XCTAssertEqual(s.tracks[0].measures, 1)
        // second playback cycle
        var maxErr: Float = 0
        for k in 0..<(88200 - 256) { maxErr = max(maxErr, abs(h.outL[88200 * 2 + k] - signal(k))) }
        XCTAssertLessThan(maxErr, 1e-6)      // body is bit-exact
        // seam: last 256 frames fade into the pre-roll (silence before the take) → ends near 0
        XCTAssertLessThan(abs(h.outL[88200 * 3 - 1]), 0.01)
        XCTAssertEqual(h.outL[88200 * 2], signal(0), accuracy: 1e-6) // downbeat attack preserved
    }

    /// Long recording → tempo guess picks a measure count giving 70–140 BPM.
    func testTempoGuessForLongLoop() {
        let h = Harness(block: 100)
        h.send(.global(recPlayGlobal()))
        h.input = { f in (signal(f), signal(f)) }
        h.send(.recPlay(0)); h.run(until: 352800)        // 8 s
        h.send(.recPlay(0)); h.run(until: 352800 + 1000)
        XCTAssertEqual(h.snap.tempo, 120, accuracy: 1e-6)
        XCTAssertEqual(h.snap.tracks[0].measures, 4)
    }

    /// Second track: quantized start at the next measure, AUTO measure → auto-stop at the
    /// first track's length, and both tracks stay phase-locked.
    func testQuantizedSecondTrackAutoLengthAndSync() {
        let h = Harness(block: 64)
        h.send(.global(recPlayGlobal()))
        // track 1: 1 measure at 120 BPM with an impulse at its start
        h.input = { f in (f % 88200 == 0 ? 0.5 : 0, 0) }
        h.send(.recPlay(0)); h.run(until: 88200)
        h.send(.recPlay(0)); h.run(until: 88200 + 30000)
        // track 2 pressed mid-measure: must wait for the boundary at 176400
        h.input = { f in (0, f == 176400 ? 0.5 : 0) }
        h.send(.recPlay(1)); h.run(until: 88200 + 30000 + 64)
        XCTAssertEqual(h.snap.tracks[1].state, .recStandby)
        h.run(until: 176400 + 64)
        XCTAssertEqual(h.snap.tracks[1].state, .recording)
        h.run(until: 176400 + 88200 + 64)                  // AUTO → stops after 1 measure by itself
        XCTAssertEqual(h.snap.tracks[1].state, .playing)
        XCTAssertEqual(h.snap.tracks[1].length, 88200)
        h.input = { _ in (0, 0) }
        h.run(until: 88200 * 10)
        // both impulses must land exactly on measure starts for the rest of the run
        for m in 4..<10 {
            XCTAssertEqual(h.outL[m * 88200], 0.5, accuracy: 1e-6, "track 1 at measure \(m)")
            XCTAssertEqual(h.outR[m * 88200], 0.5, accuracy: 1e-6, "track 2 at measure \(m)")
            XCTAssertEqual(h.outL[m * 88200 + 1], 0, accuracy: 1e-6)
        }
    }

    /// FREE measure setting: recording end is rounded to the nearest whole measure.
    func testFreeMeasureQuantizesToNearestMeasure() {
        let h = Harness(block: 100)
        h.send(.global(recPlayGlobal()))
        h.input = { f in (signal(f), 0) }
        h.send(.recPlay(0)); h.run(until: 88200); h.send(.recPlay(0)); h.run(until: 88300)
        var s = TrackSettings(); s.measure = .free
        h.send(.trackSettings(1, s))
        h.send(.recPlay(1))
        h.run(until: 176400 + 2 * 88200 + 5000)            // pressed slightly late in measure 3
        h.send(.recPlay(1)); h.run(until: 176400 + 3 * 88200)
        XCTAssertEqual(h.snap.tracks[1].length, 2 * 88200)
        XCTAssertEqual(h.snap.tracks[1].measures, 2)
    }

    func testOverdubUndoRedoAreExact() {
        let h = Harness(block: 100)
        h.send(.global(recPlayGlobal()))
        h.input = { f in (f < 44100 + 512 ? signal(f) : 0, 0) }
        h.send(.recPlay(0)); h.run(until: 44100)            // 1 s loop
        h.send(.recPlay(0)); h.run(until: 44100 * 2)
        let original = h.e.tracks[0].copyAudio().left
        // overdub a constant for exactly one loop pass
        h.input = { _ in (0.1, 0) }
        h.send(.recPlay(0)); h.run(until: 44100 * 3)
        h.send(.recPlay(0)); h.run(until: 44100 * 3 + 300)
        h.input = { _ in (0, 0) }
        let dubbed = h.e.tracks[0].copyAudio().left
        XCTAssertEqual(dubbed[1000] - original[1000], 0.1, accuracy: 1e-5)
        XCTAssertTrue(h.snap.tracks[0].canUndo)
        h.send(.undo(0)); h.run(seconds: 1)
        XCTAssertEqual(h.e.tracks[0].copyAudio().left, original)
        XCTAssertTrue(h.snap.tracks[0].canRedo)
        h.send(.redo(0)); h.run(seconds: 1)
        XCTAssertEqual(h.e.tracks[0].copyAudio().left, dubbed)
    }

    func testUndoFirstRecordingThenRedo() {
        let h = Harness(block: 128)
        h.send(.global(recPlayGlobal()))
        h.input = { f in (signal(f), 0) }
        h.send(.recPlay(0)); h.run(until: 44100); h.send(.recPlay(0)); h.run(until: 50000)
        h.send(.undo(0)); h.run(until: 51000)
        XCTAssertEqual(h.snap.tracks[0].state, .empty)
        XCTAssertFalse(h.snap.locked)
        h.send(.redo(0)); h.run(until: 52000)
        XCTAssertNotEqual(h.snap.tracks[0].state, .empty)
        XCTAssertTrue(h.snap.locked)
    }

    /// 30 minutes of playback: no drift between tracks and the grid.
    func testNoDriftOverLongPlayback() {
        let h = Harness(block: 512)
        h.send(.global(recPlayGlobal()))
        h.input = { f in (f == 0 ? 0.5 : 0, 0) }
        h.send(.recPlay(0)); h.run(until: 97_123)            // odd length → non-integer tempo
        h.send(.recPlay(0)); h.run(until: 97_123 + 512)
        let len = h.snap.tracks[0].length
        h.input = { _ in (0, 0) }
        let thirtyMin = 44100 * 60 * 30
        h.run(until: thirtyMin, keep: false)
        let startOut = h.frame
        h.outL = []; h.outR = []
        h.run(until: startOut + len * 2 + 512)
        let hits = h.outL.indices.filter { h.outL[$0] > 0.3 }.map { $0 + startOut }
        XCTAssertFalse(hits.isEmpty)
        for x in hits { XCTAssertEqual(x % len, 0, "impulse drifted to \(x % len)") }
    }

    func testReverseAndHalfSpeed() {
        let h = Harness(block: 100)
        h.send(.global(recPlayGlobal()))
        h.input = { f in (f < 44100 ? Float(f) / 44100 : 0, 0) }   // ramp
        h.send(.recPlay(0)); h.run(until: 44100); h.send(.recPlay(0))
        var s = TrackSettings(); s.reverse = true
        h.send(.trackSettings(0, s))
        h.run(until: 44100 * 3)
        // reversed ramp: second cycle should go downwards
        XCTAssertGreaterThan(h.outL[88200 + 1000], h.outL[88200 + 30000])
        s.reverse = false; s.speed = .half
        h.send(.trackSettings(0, s))
        let start = h.frame
        h.run(until: start + 44100 * 4)
        // at half speed one pass of the ramp takes 2 s
        let seg = Array(h.outL[(start + 1000)..<(start + 88200 - 1000)])
        let rising = zip(seg, seg.dropFirst()).filter { $1 > $0 }.count
        XCTAssertGreaterThan(Double(rising) / Double(seg.count), 0.45)
    }

    func testStopModes() {
        let h = Harness(block: 100)
        h.send(.global(recPlayGlobal()))
        h.input = { f in (f < 44100 + 300 ? 0.5 : 0, 0) }
        h.send(.recPlay(0)); h.run(until: 44100); h.send(.recPlay(0)); h.run(until: 50000)
        var s = TrackSettings(); s.stopMode = .loop
        h.send(.trackSettings(0, s))
        h.send(.stop(0)); h.run(until: 60000)
        XCTAssertEqual(h.snap.tracks[0].state, .stopping)
        h.run(until: 88300)
        XCTAssertEqual(h.snap.tracks[0].state, .stopped)
        // immediate
        s.stopMode = .immediate; h.send(.trackSettings(0, s))
        h.send(.recPlay(0)); h.run(until: 90000)
        XCTAssertEqual(h.snap.tracks[0].state, .playing)
        h.send(.stop(0)); h.run(until: 90000 + 400)
        XCTAssertEqual(h.snap.tracks[0].state, .stopped)
        XCTAssertFalse(h.snap.running)
    }

    /// Tempo change with TEMPO SYNC (PITCH): the loop plays faster and stays aligned to the grid.
    func testTempoChangeKeepsSync() {
        let h = Harness(block: 100)
        h.send(.global(recPlayGlobal()))
        h.input = { f in (f == 0 ? 1 : 0, 0) }
        h.send(.recPlay(0)); h.run(until: 88200); h.send(.recPlay(0)); h.run(until: 88300)
        h.input = { _ in (0, 0) }
        h.send(.tempo(240)); h.run(until: 88300 + 100)
        let start = h.frame
        h.run(until: start + 88200 * 2)
        let hits = (start..<h.frame).filter { h.outL[$0] > 0.3 }
        XCTAssertGreaterThanOrEqual(hits.count, 3)
        for (a, b) in zip(hits, hits.dropFirst()) { XCTAssertEqual(Double(b - a), 44100, accuracy: 2) }
    }

    func testLatencyCompensationShiftsRecording() {
        let h = Harness(block: 100)
        h.send(.global(recPlayGlobal()))
        var r = RhythmSettings(); r.startTrigger = .beforeLoop
        h.send(.rhythm(r)); h.send(.rhythmOn(true))      // rhythm running → grid → compensation applies
        h.send(.latency(500))
        h.run(until: 100)
        h.input = { f in (f == 88200 + 10_500 ? 1 : 0, 0) }
        h.send(.recPlay(0))                               // standby until the boundary at 88200
        h.run(until: 88200 * 2 + 50)
        h.send(.recPlay(0))
        h.run(until: 88200 * 3)
        XCTAssertEqual(h.snap.tracks[0].length, 88200)
        let audio = h.e.tracks[0].copyAudio().left
        XCTAssertEqual(audio.firstIndex { $0 > 0.5 }, 10_000)   // heard 500 frames late → placed 500 earlier
    }

    func testSingleModeSwitchesTracks() {
        let h = Harness(block: 100)
        var g = recPlayGlobal(); g.playMode = .single
        h.send(.global(g))
        h.input = { f in (signal(f), 0) }
        h.send(.recPlay(0)); h.run(until: 44100); h.send(.recPlay(0)); h.run(until: 50000)
        h.send(.recPlay(1)); h.run(until: 50100)
        XCTAssertNotEqual(h.snap.tracks[0].state, .playing)
    }

    func testAllStartStopAndClearUnlocks() {
        let h = Harness(block: 100)
        h.send(.global(recPlayGlobal()))
        h.input = { f in (signal(f), 0) }
        h.send(.recPlay(0)); h.run(until: 44100); h.send(.recPlay(0)); h.run(until: 50000)
        h.send(.allStartStop); h.run(until: 51000)
        XCTAssertEqual(h.snap.tracks[0].state, .stopped)
        h.send(.allStartStop); h.run(until: 52000)
        XCTAssertEqual(h.snap.tracks[0].state, .playing)
        h.send(.clear(0)); h.run(until: 53000)
        XCTAssertEqual(h.snap.tracks[0].state, .empty)
        XCTAssertFalse(h.snap.locked)
    }

    func testOneShotPlaysOnceAndRetriggers() {
        let h = Harness(block: 100)
        h.send(.global(recPlayGlobal()))
        h.input = { f in (f < 44100 + 300 ? 0.3 : 0, 0) }
        h.send(.recPlay(0)); h.run(until: 44100); h.send(.recPlay(0)); h.run(until: 44400)
        h.send(.stop(0)); h.run(until: 45000)
        var s = TrackSettings(); s.oneShot = true; h.send(.trackSettings(0, s))
        h.send(.recPlay(0)); h.run(until: 46000)
        XCTAssertEqual(h.snap.tracks[0].state, .playing)
        h.run(until: 46000 + 44100 + 500)
        XCTAssertEqual(h.snap.tracks[0].state, .stopped)
    }

    func testBounceAndRhythmToTrack() {
        let h = Harness(block: 100)
        h.send(.global(recPlayGlobal()))
        h.input = { f in (f < 44100 + 300 ? 0.25 : 0, 0) }
        h.send(.recPlay(0)); h.run(until: 44100); h.send(.recPlay(0)); h.run(until: 44400)
        h.input = { _ in (0, 0) }
        var s = TrackSettings(); s.bounceIn = true; s.inputOn = false
        h.send(.trackSettings(1, s))
        h.send(.recPlay(1)); h.run(until: 44100 * 3 + 300)
        let a = h.e.tracks[1].copyAudio().left
        XCTAssertFalse(a.isEmpty)
        XCTAssertEqual(a[a.count / 2], 0.25, accuracy: 0.01) // track 1's audio was bounced into track 2
    }

    func testCountInDelaysRecording() {
        let h = Harness(block: 100)
        h.send(.global(recPlayGlobal()))
        var r = RhythmSettings(); r.countInMeasures = 1       // START TRIG = LOOP START (default)
        h.send(.rhythm(r)); h.send(.rhythmOn(true))
        h.run(until: 1000)
        XCTAssertFalse(h.snap.running)                     // armed, waiting for the loop
        XCTAssertTrue(h.snap.rhythmArmed)
        h.send(.recPlay(0)); h.run(until: 1000 + 88200 - 200)
        XCTAssertEqual(h.snap.tracks[0].state, .recStandby) // still counting in
        XCTAssertGreaterThan(h.outL.map { abs($0) }.max() ?? 0, 0.01) // guide click audible
        h.run(until: 1000 + 88200 + 200)
        XCTAssertEqual(h.snap.tracks[0].state, .recording)
    }
}
