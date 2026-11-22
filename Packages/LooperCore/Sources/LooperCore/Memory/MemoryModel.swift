import Foundation

public struct FXSlotModel: Codable, Equatable {
    public var type: FXType? = nil
    public var params: [Float] = []
    public var on = false
    public var switchMode: SwitchMode = .toggle
    public var insert = -1
    public init() {}
    public init(type: FXType) { self.type = type; params = type.params.map { $0.defaultValue } }
}

public struct FXRackModel: Codable, Equatable {
    public var banks: [[FXSlotModel]]
    public var activeBank = 0
    public var bankOn = true
    public var mode: FXBankMode = .multi
    public init(defaults: [[FXType]]) {
        banks = (0..<4).map { b in (0..<4).map { s in
            if b < defaults.count, s < defaults[b].count { return FXSlotModel(type: defaults[b][s]) }
            return FXSlotModel()
        } }
    }
    public static var inputDefault: FXRackModel {
        FXRackModel(defaults: [[.lpf, .delay, .reverb, .dist], [.phaser, .flanger, .chorus, .tapeEcho],
                               [.isolator, .eq, .dynamics, .lofi], [.freeze, .roll, .ringMod, .radio]])
    }
    public static var trackDefault: FXRackModel {
        FXRackModel(defaults: [[.isolator, .patternSlicer, .delay, .beatRepeat], [.lpf, .hpf, .tremolo, .autoPan],
                               [.roll, .vinylFlick, .reverb, .bpf], [.tapeEcho, .flanger, .lofi, .freeze]])
    }
}

public struct MixerModel: Codable, Equatable {
    public var inputLevel: Float = 100
    public var masterLevel: Float = 100
    public var monitor = true
    public var masterComp: Float = 0      // OFF, 1–40
    public var masterReverb: Float = 0    // 0–40
    public init() {}
}

public struct TrackMeta: Codable, Equatable {
    public var hasAudio = false
    public var length = 0
    public var measures: Double = 0
    public var scale: Double = 1
    public var muted = false
    public var color: String = "default"
    public init() {}
}

/// Everything stored in one memory (one "project").
public struct MemoryData: Codable, Equatable {
    public var formatVersion = 1
    public var name = "INIT MEMORY"
    public var tracks = [TrackSettings](repeating: TrackSettings(), count: 5)
    public var trackMeta = [TrackMeta](repeating: TrackMeta(), count: 5)
    public var global = GlobalLoopSettings()
    public var rhythm = RhythmSettings()
    public var rhythmOn = false
    public var tempo: Double = 120
    public var beatsPerMeasure = 4
    public var beatUnit = 4
    public var grid: GridInfo? = nil
    public var inputFX = FXRackModel.inputDefault
    public var trackFX = FXRackModel.trackDefault
    public var mixer = MixerModel()
    public var assignments = AssignmentMap.defaults
    public var currentTrack = 0
    public init() {}

    public var hasAudio: Bool { trackMeta.contains { $0.hasAudio } }
}

public typealias TrackAudio = (left: [Float], right: [Float])

extension LooperEngine {
    /// Commands that reproduce a memory's settings (no audio). Creates FX processors (allocates) –
    /// call on the main thread.
    public func commands(for m: MemoryData) -> [EngineCommand] {
        var c: [EngineCommand] = []
        if m.grid?.locked != true { c.append(.beat(m.beatsPerMeasure, m.beatUnit)); c.append(.tempo(m.tempo)) }
        for i in 0..<5 { c.append(.trackSettings(i, m.tracks[i])); c.append(.mute(i, m.trackMeta[i].muted)) }
        c.append(.global(m.global))
        c.append(.rhythm(m.rhythm))
        c.append(.inputLevel(m.mixer.inputLevel)); c.append(.masterLevel(m.mixer.masterLevel))
        c.append(.monitor(m.mixer.monitor)); c.append(.masterComp(m.mixer.masterComp)); c.append(.masterReverb(m.mixer.masterReverb))
        for (rack, model) in [(RackID.input, m.inputFX), (RackID.track, m.trackFX)] {
            c.append(.fxBank(rack, model.activeBank)); c.append(.fxBankOn(rack, model.bankOn)); c.append(.fxMode(rack, model.mode))
            for b in 0..<4 { for s in 0..<4 {
                let slot = model.banks[b][s]
                let proc = slot.type?.make(sampleRate: sampleRate)
                if let p = proc { for (i, v) in slot.params.enumerated() { p.setParam(i, v) } }
                c.append(.fxInstall(rack, bank: b, slot: s, proc))
                c.append(.fxInsert(rack, bank: b, slot: s, slot.insert))
                c.append(.fxSwitch(rack, bank: b, slot: s, slot.on && slot.switchMode == .toggle))
            } }
        }
        return c
    }

    /// Loads a memory into the engine: suspends the audio thread, copies audio, resumes.
    /// `waitForSuspend` must return true once `status.snapshot().suspended` is set
    /// (live engine) – for an offline engine pass `{ self.pumpCommands(); return true }`.
    @discardableResult
    public func load(_ m: MemoryData, audio: [TrackAudio?], waitForSuspend: () -> Bool) -> Bool {
        send(.suspend)
        guard waitForSuspend() else { return false }
        for i in 0..<5 {
            if let a = audio[i], m.trackMeta[i].hasAudio, !a.left.isEmpty {
                tracks[i].load(left: a.left, right: a.right.isEmpty ? a.left : a.right, measures: m.trackMeta[i].measures, scale: m.trackMeta[i].scale)
            } else {
                tracks[i].clear()
            }
        }
        for cmd in commands(for: m) { send(cmd) }
        var g = m.grid
        let anyAudio = (0..<5).contains { m.trackMeta[$0].hasAudio && audio[$0] != nil }
        if g == nil || !anyAudio {
            g = GridInfo(locked: false, refMeasure: 0, refTempo: m.tempo, tempo: m.tempo, autoMeasures: nil,
                         beatsPerMeasure: m.beatsPerMeasure, beatUnit: m.beatUnit)
        }
        send(.resume(g))
        if m.rhythmOn { /* rhythm starts with the first loop (START TRIG = LOOP START) */ }
        return true
    }

    /// Main-thread only, when no audio thread is running (offline rendering / tests).
    public func pumpCommands() {
        let z = UnsafeMutablePointer<Float>.allocate(capacity: 1); defer { z.deallocate() }
        process(frames: 1, inL: nil, inR: nil, outL: z, outR: z)
    }

    /// Captures the current audio of every track (main thread; tracks must not be recording).
    public func captureAudio() -> [TrackAudio?] {
        tracks.map { t in t.hasAudio ? t.copyAudio() : nil }
    }
}
