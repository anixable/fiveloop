import Foundation
import Atomics

/// Lock-free snapshot of engine state, written by the audio thread once per block and
/// polled by the UI (≈30 Hz). Each field is an independent atomic: values may come from
/// adjacent blocks, which is fine for display purposes.
public final class StatusBoard {
    public static let trackCount = 5
    private let trackState = (0..<5).map { _ in ManagedAtomic<Int>(0) }
    private let trackPos = (0..<5).map { _ in ManagedAtomic<UInt32>(0) }
    private let trackPeak = (0..<5).map { _ in ManagedAtomic<UInt32>(0) }
    private let trackLength = (0..<5).map { _ in ManagedAtomic<Int>(0) }
    private let trackMeasures = (0..<5).map { _ in ManagedAtomic<UInt64>(0) }
    private let trackFlags = (0..<5).map { _ in ManagedAtomic<Int>(0) } // bit0 undo, bit1 redo, bit2 muted, bit3 finishing
    private let tempoBits = ManagedAtomic<UInt64>(0)
    private let songBits = ManagedAtomic<UInt64>(0)
    private let measureBits = ManagedAtomic<UInt64>(0)
    private let flags = ManagedAtomic<Int>(0) // bit0 running, bit1 locked, bit2 rhythm playing, bit3 suspended, bit4 grid
    private let beatsAtomic = ManagedAtomic<Int>(4)
    private let unitAtomic = ManagedAtomic<Int>(4)
    private let inPeak = ManagedAtomic<UInt32>(0), outPeak = ManagedAtomic<UInt32>(0)
    private let blockCount = ManagedAtomic<Int>(0)

    public init() {}

    // MARK: writer (audio thread)
    func write(track i: Int, state: TrackState, pos: Double, peak: Float, length: Int, measures: Double,
               undo: Bool, redo: Bool, muted: Bool, finishing: Bool) {
        trackState[i].store(state.rawValue, ordering: .relaxed)
        trackPos[i].store(Float(pos).bitPattern, ordering: .relaxed)
        trackPeak[i].store(peak.bitPattern, ordering: .relaxed)
        trackLength[i].store(length, ordering: .relaxed)
        trackMeasures[i].store(measures.bitPattern, ordering: .relaxed)
        trackFlags[i].store((undo ? 1 : 0) | (redo ? 2 : 0) | (muted ? 4 : 0) | (finishing ? 8 : 0), ordering: .relaxed)
    }
    func write(tempo: Double, song: Double, refMeasure: Double, running: Bool, locked: Bool, rhythm: Bool, armed: Bool,
               suspended: Bool, grid: Bool, beats: Int, unit: Int, inPeak ip: Float, outPeak op: Float) {
        tempoBits.store(tempo.bitPattern, ordering: .relaxed)
        songBits.store(song.bitPattern, ordering: .relaxed)
        measureBits.store(refMeasure.bitPattern, ordering: .relaxed)
        flags.store((running ? 1 : 0) | (locked ? 2 : 0) | (rhythm ? 4 : 0) | (suspended ? 8 : 0) | (grid ? 16 : 0) | (armed ? 32 : 0), ordering: .relaxed)
        beatsAtomic.store(beats, ordering: .relaxed); unitAtomic.store(unit, ordering: .relaxed)
        inPeak.store(ip.bitPattern, ordering: .relaxed); outPeak.store(op.bitPattern, ordering: .relaxed)
        blockCount.wrappingIncrement(ordering: .releasing)
    }

    // MARK: reader (UI)
    public struct TrackSnapshot: Equatable {
        public var state: TrackState = .empty
        public var position: Float = 0
        public var peak: Float = 0
        public var length = 0
        public var measures: Double = 0
        public var canUndo = false, canRedo = false, muted = false, finishing = false
    }
    public struct Snapshot: Equatable {
        public var tracks = [TrackSnapshot](repeating: TrackSnapshot(), count: 5)
        public var tempo: Double = 120
        public var songPos: Double = 0
        public var refMeasure: Double = 88200
        public var running = false, locked = false, rhythmPlaying = false, suspended = false, gridActive = false, rhythmArmed = false
        public var beatsPerMeasure = 4, beatUnit = 4
        public var inputPeak: Float = 0, outputPeak: Float = 0
        public var blocks = 0
        public init() {}
        /// 0-based measure index and beat index within the measure.
        public var measureAndBeat: (Int, Int) {
            guard refMeasure > 0 else { return (0, 0) }
            let m = songPos / refMeasure
            let mi = Int(floor(m))
            let beat = Int(floor((m - Double(mi)) * Double(beatsPerMeasure)))
            return (mi, min(beat, beatsPerMeasure - 1))
        }
    }

    public func snapshot() -> Snapshot {
        var s = Snapshot()
        s.blocks = blockCount.load(ordering: .acquiring)
        for i in 0..<5 {
            let f = trackFlags[i].load(ordering: .relaxed)
            s.tracks[i] = TrackSnapshot(
                state: TrackState(rawValue: trackState[i].load(ordering: .relaxed)) ?? .empty,
                position: Float(bitPattern: trackPos[i].load(ordering: .relaxed)),
                peak: Float(bitPattern: trackPeak[i].load(ordering: .relaxed)),
                length: trackLength[i].load(ordering: .relaxed),
                measures: Double(bitPattern: trackMeasures[i].load(ordering: .relaxed)),
                canUndo: f & 1 != 0, canRedo: f & 2 != 0, muted: f & 4 != 0, finishing: f & 8 != 0)
        }
        s.tempo = Double(bitPattern: tempoBits.load(ordering: .relaxed))
        s.songPos = Double(bitPattern: songBits.load(ordering: .relaxed))
        s.refMeasure = Double(bitPattern: measureBits.load(ordering: .relaxed))
        let fl = flags.load(ordering: .relaxed)
        s.running = fl & 1 != 0; s.locked = fl & 2 != 0; s.rhythmPlaying = fl & 4 != 0
        s.suspended = fl & 8 != 0; s.gridActive = fl & 16 != 0; s.rhythmArmed = fl & 32 != 0
        s.beatsPerMeasure = beatsAtomic.load(ordering: .relaxed); s.beatUnit = unitAtomic.load(ordering: .relaxed)
        s.inputPeak = Float(bitPattern: inPeak.load(ordering: .relaxed))
        s.outputPeak = Float(bitPattern: outPeak.load(ordering: .relaxed))
        return s
    }
}
