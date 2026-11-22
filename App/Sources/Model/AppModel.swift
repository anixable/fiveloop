import Foundation
import SwiftUI
import Combine
import AVFoundation
import QuartzCore
import LooperCore

enum Screen: String, CaseIterable, Identifiable {
    case loop = "LOOP", mixer = "MIXER", inputFX = "INPUT FX", trackFX = "TRACK FX", master = "MASTER",
         rhythm = "RHYTHM", memory = "MEMORY", midi = "MIDI", audio = "AUDIO", system = "SYSTEM", diagnostics = "DIAG"
    var id: String { rawValue }
}

/// Main-thread application state. Owns the engine, audio I/O, MIDI and storage.
/// The UI only talks to this object; this object only talks to the engine via commands.
final class AppModel: ObservableObject {
    // engine & services
    let engine: LooperEngine
    let audio: AudioIO
    let midi: MIDIIO
    let store: MemoryStore?

    // published state
    @Published var snap = StatusBoard.Snapshot()
    @Published var memory = MemoryData()
    @Published var memoryIndex = 1
    @Published var memoryList: [MemorySummary] = []
    @Published var screen: Screen = .loop
    @Published var currentTrack = 0
    @Published var dirty = false
    @Published var message: String? = nil
    @Published var micGranted = true
    @Published var audioRunning = false
    @Published var recoveryAvailable = false
    @Published var learnTarget: AssignTarget? = nil
    @Published var midiSettings: MIDISettings
    @Published var lastMIDI: String = "—"
    @Published var diag: AudioIO.Diagnostics? = nil
    @Published var shareItems: [URL] = []
    @Published var busy: String? = nil
    /// Global LED blink phase (~3 Hz) driven by the poll timer – no SwiftUI animations,
    /// which on iPadOS 15 made the whole layout bounce.
    @Published var blink = false
    @Published var trackColors: [Color] = [.green, .cyan, .yellow, .orange, .pink]
    @Published var bufferFrames: Int = UserDefaults.standard.integer(forKey: "bufferFrames").nonZero ?? 256
    @Published var latencyOffsetMs: Double = UserDefaults.standard.double(forKey: "latencyOffsetMs")
    @Published var maxLoopSeconds: Int = UserDefaults.standard.integer(forKey: "maxLoopSeconds").nonZero ?? 60

    private var tap = TapTempo()
    private var timer: AnyCancellable?
    private var autosaveWork: DispatchWorkItem?
    private var audioDirty = false
    private let ioQueue = DispatchQueue(label: "fiveloop.io", qos: .utility)

    init() {
        let seconds = Double(UserDefaults.standard.integer(forKey: "maxLoopSeconds").nonZero ?? 60)
        engine = LooperEngine(sampleRate: AudioIO.sampleRate, maxFrames: AudioIO.maxFrames, maxLoopSeconds: seconds)
        audio = AudioIO(engine: engine)
        midi = MIDIIO(audio: audio)
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        store = try? MemoryStore(root: docs.appendingPathComponent("Memories", isDirectory: true), sampleRate: Int(AudioIO.sampleRate))
        if let d = UserDefaults.standard.data(forKey: "midiSettings"), let m = try? JSONDecoder().decode(MIDISettings.self, from: d) {
            midiSettings = m
        } else { midiSettings = MIDISettings() }

        recoveryAvailable = store?.beginSession() ?? false
        memoryList = store?.list() ?? []
        memoryIndex = max(1, UserDefaults.standard.integer(forKey: "memoryIndex"))
        applySettingsToEngine(memory)

        audio.onStateChange = { [weak self] in DispatchQueue.main.async { self?.audioRunning = self?.audio.isRunning ?? false } }
        midi.onMessage = { [weak self] m in self?.handleMIDI(m) }
        midi.onClockTempo = { [weak self] bpm in self?.externalTempo(bpm) }
        midi.onSetupChanged = { [weak self] in self?.objectWillChange.send() }

        timer = Timer.publish(every: 1.0 / 30, on: .main, in: .common).autoconnect().sink { [weak self] _ in self?.poll() }
    }

    // MARK: - Startup

    func startAudio() {
        AudioIO.requestMicrophone { [weak self] ok in
            guard let self = self else { return }
            self.micGranted = ok
            do {
                try self.audio.configureSession(preferredBufferFrames: self.bufferFrames)
                self.audio.manualLatencyOffset = self.latencyOffsetMs / 1000
                try self.audio.start()
                self.audioRunning = true
                // Built-in speaker + mic would howl: monitor only with headphones/interface.
                if !self.audio.isHeadphoneOrInterfaceOutput && self.memory.mixer.monitor {
                    self.memory.mixer.monitor = false; self.engine.send(.monitor(false))
                    self.message = "Input monitoring off (built-in speaker). Connect headphones to monitor."
                }
            } catch {
                self.message = error.localizedDescription
            }
            self.midi.start()
            self.midi.clockOutEnabled = self.midiSettings.clockOut
            if !self.recoveryAvailable, self.store?.exists(self.memoryIndex) == true { self.loadMemory(self.memoryIndex) }
        }
    }

    func appWillTerminate() { store?.endSession() }

    func enterBackground() {
        // keep running if audio is playing (UIBackgroundModes audio); always snapshot for recovery
        autosave(now: true)
    }

    // MARK: - Polling

    private func poll() {
        let s = engine.status.snapshot()
        if s != snap { snap = s }
        let b = Int(CACurrentMediaTime() * 3.3) % 2 == 0
        if b != blink { blink = b }
        while let ev = engine.events.pop() {
            switch ev {
            case .recordingFinished:
                audioDirty = true; dirty = true; scheduleAutosave()
            case .gridLocked(let tempo, _):
                memory.tempo = tempo
            case .gridUnlocked: break
            case .transportStarted, .transportStopped: break
            case .retired: break // released here, on the main thread
            }
        }
        if screen == .diagnostics || screen == .audio { diag = audio.diagnostics() }
    }

    // MARK: - Transport / tracks

    func recPlay(_ t: Int) { currentTrack = t; engine.send(.recPlay(t)); dirty = true }
    func stop(_ t: Int) { currentTrack = t; engine.send(.stop(t)) }
    func clear(_ t: Int) { engine.send(.clear(t)); audioDirty = true; dirty = true; scheduleAutosave() }
    func undoRedo() {
        let t = snap.tracks[currentTrack]
        if t.canUndo || t.state == .recording || t.state == .overdubbing { engine.send(.undo(currentTrack)) }
        else if t.canRedo { engine.send(.redo(currentTrack)) }
        audioDirty = true; dirty = true
    }
    func undo() { engine.send(.undo(currentTrack)); audioDirty = true }
    func redo() { engine.send(.redo(currentTrack)); audioDirty = true }
    func allStartStop() { engine.send(.allStartStop) }
    func stopAllNow() { engine.send(.stopAllImmediately) }

    func tapTempo() {
        if let bpm = tap.tap(at: CACurrentMediaTime()) { setTempo(bpm) }
    }
    func setTempo(_ bpm: Double) { engine.send(.tempo(bpm)); memory.tempo = bpm; dirty = true }
    func resetTempoToLoop() { if let g = memory.grid ?? (snap.locked ? engine.gridInfo : nil) { setTempo(g.refTempo) } }
    func setBeat(_ beats: Int, _ unit: Int) {
        guard !snap.locked else { message = "Beat can't change after a loop is recorded (clear all tracks first)."; return }
        memory.beatsPerMeasure = beats; memory.beatUnit = unit; engine.send(.beat(beats, unit)); dirty = true
    }

    func updateTrack(_ t: Int, _ f: (inout TrackSettings) -> Void) {
        f(&memory.tracks[t]); engine.send(.trackSettings(t, memory.tracks[t])); dirty = true
    }
    func setLevel(_ t: Int, _ v: Float) { updateTrack(t) { $0.playLevel = v } }
    func setPan(_ t: Int, _ v: Float) { updateTrack(t) { $0.pan = v } }
    func toggleTrackFX(_ t: Int) { updateTrack(t) { $0.fxOn.toggle() } }
    func toggleMute(_ t: Int) { memory.trackMeta[t].muted.toggle(); engine.send(.mute(t, memory.trackMeta[t].muted)); dirty = true }
    func updateGlobal(_ f: (inout GlobalLoopSettings) -> Void) { f(&memory.global); engine.send(.global(memory.global)); dirty = true }

    // MARK: - Rhythm

    func rhythmStartStop() { engine.send(.rhythmToggle); memory.rhythmOn.toggle() }
    func updateRhythm(_ f: (inout RhythmSettings) -> Void) { f(&memory.rhythm); engine.send(.rhythm(memory.rhythm)); dirty = true }

    // MARK: - Mixer / master

    func updateMixer(_ f: (inout MixerModel) -> Void) {
        f(&memory.mixer)
        let m = memory.mixer
        engine.send(.inputLevel(m.inputLevel)); engine.send(.masterLevel(m.masterLevel)); engine.send(.monitor(m.monitor))
        engine.send(.masterComp(m.masterComp)); engine.send(.masterReverb(m.masterReverb))
        dirty = true
    }

    // MARK: - FX

    func rackModel(_ r: RackID) -> FXRackModel { r == .input ? memory.inputFX : memory.trackFX }
    private func mutateRack(_ r: RackID, _ f: (inout FXRackModel) -> Void) {
        if r == .input { f(&memory.inputFX) } else { f(&memory.trackFX) }
        dirty = true
    }
    func selectBank(_ r: RackID, _ b: Int) { mutateRack(r) { $0.activeBank = b }; engine.send(.fxBank(r, b)) }
    func setBankOn(_ r: RackID, _ on: Bool) { mutateRack(r) { $0.bankOn = on }; engine.send(.fxBankOn(r, on)) }
    func setBankMode(_ r: RackID, _ m: FXBankMode) { mutateRack(r) { $0.mode = m }; engine.send(.fxMode(r, m)) }

    /// [A]–[D] button press. Momentary slots call with `down` false on release.
    func fxButton(_ r: RackID, _ slot: Int, down: Bool, bank: Int? = nil) {
        let model = rackModel(r)
        let b = bank ?? model.activeBank
        let sm = model.banks[b][slot]
        guard sm.type != nil else { return }
        let newOn: Bool
        if sm.switchMode == .momentary { newOn = down } else { guard down else { return }; newOn = !sm.on }
        mutateRack(r) { m in
            if newOn && m.mode == .single { for s in 0..<4 { m.banks[b][s].on = false } }
            m.banks[b][slot].on = newOn
        }
        engine.send(.fxSwitch(r, bank: b, slot: slot, newOn))
    }

    func setFXType(_ r: RackID, bank b: Int, slot s: Int, _ type: FXType?) {
        mutateRack(r) { m in
            var sm = type.map { FXSlotModel(type: $0) } ?? FXSlotModel()
            sm.insert = m.banks[b][s].insert; sm.switchMode = m.banks[b][s].switchMode
            m.banks[b][s] = sm
        }
        engine.send(.fxSwitch(r, bank: b, slot: s, false))
        engine.send(.fxInstall(r, bank: b, slot: s, type?.make(sampleRate: AudioIO.sampleRate)))
    }
    func setFXParam(_ r: RackID, bank b: Int, slot s: Int, _ i: Int, _ v: Float) {
        mutateRack(r) { m in
            if m.banks[b][s].params.count > i { m.banks[b][s].params[i] = v }
        }
        engine.send(.fxParam(r, bank: b, slot: s, index: i, v))
    }
    func setFXInsert(_ r: RackID, bank b: Int, slot s: Int, _ ins: Int) {
        mutateRack(r) { $0.banks[b][s].insert = ins }; engine.send(.fxInsert(r, bank: b, slot: s, ins))
    }
    func setFXSwitchMode(_ r: RackID, bank b: Int, slot s: Int, _ m: SwitchMode) { mutateRack(r) { $0.banks[b][s].switchMode = m } }

    // MARK: - Memory

    var anyRecording: Bool { snap.tracks.contains { $0.state == .recording || $0.state == .overdubbing || $0.state == .recStandby || $0.finishing } }

    private func applySettingsToEngine(_ m: MemoryData) { for c in engine.commands(for: m) { engine.send(c) } }

    /// Builds the MemoryData for the current engine state (main thread).
    func currentMemory() -> MemoryData {
        var m = memory
        for i in 0..<5 {
            let t = engine.tracks[i]
            m.trackMeta[i].hasAudio = t.hasAudio
            m.trackMeta[i].length = t.length
            m.trackMeta[i].measures = t.measures
            m.trackMeta[i].scale = t.scale
        }
        m.grid = engine.gridInfo
        m.tempo = snap.tempo
        m.currentTrack = currentTrack
        return m
    }

    func saveMemory(_ index: Int? = nil) {
        guard let store = store else { return }
        guard !anyRecording else { message = "Finish recording/overdubbing before saving."; return }
        let idx = index ?? memoryIndex
        let m = currentMemory(), a = engine.captureAudio()
        busy = "Saving…"
        ioQueue.async {
            do { try store.save(idx, data: m, audio: a) } catch { DispatchQueue.main.async { self.message = "Save failed: \(error)" } }
            DispatchQueue.main.async {
                self.busy = nil; self.dirty = false; self.memoryIndex = idx
                UserDefaults.standard.set(idx, forKey: "memoryIndex")
                self.memoryList = store.list()
            }
        }
    }

    func loadMemory(_ index: Int) {
        guard let store = store else { return }
        busy = "Loading…"
        ioQueue.async {
            let loaded = (try? store.load(index)) ?? (MemoryData(), [nil, nil, nil, nil, nil])
            DispatchQueue.main.async { self.install(loaded.0, audio: loaded.1, index: index) }
        }
    }

    /// Installs a memory into the live engine (stops playback).
    func install(_ m: MemoryData, audio a: [TrackAudio?], index: Int?) {
        let ok = engine.load(m, audio: a) { [engine] in
            let deadline = Date().addingTimeInterval(0.5)
            while Date() < deadline { if engine.status.snapshot().suspended { return true }; usleep(2000) }
            return !self.audioRunning // engine not running → safe anyway
        }
        if !ok { message = "Audio engine did not respond; memory not loaded." }
        memory = m
        currentTrack = m.currentTrack
        if let i = index { memoryIndex = i; UserDefaults.standard.set(i, forKey: "memoryIndex") }
        dirty = false; busy = nil; audioDirty = false
    }

    func newMemory() { install(MemoryData(), audio: [nil, nil, nil, nil, nil], index: nil); dirty = true }
    func renameMemory(_ i: Int, _ name: String) {
        try? store?.rename(i, to: name)
        if i == memoryIndex { memory.name = String(name.prefix(12)).uppercased() }
        memoryList = store?.list() ?? []
    }
    func duplicateMemory(_ from: Int, to: Int) { try? store?.duplicate(from, to: to); memoryList = store?.list() ?? [] }
    func deleteMemory(_ i: Int) { try? store?.delete(i); memoryList = store?.list() ?? [] }

    func restoreRecovery() {
        guard let store = store, let loaded = try? store.load(0) else { recoveryAvailable = false; return }
        install(loaded.0, audio: loaded.1, index: nil); dirty = true; recoveryAvailable = false
    }

    private func scheduleAutosave() {
        autosaveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.autosave(now: true) }
        autosaveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: w)
    }

    func autosave(now: Bool) {
        guard let store = store, !anyRecording else { if !now { scheduleAutosave() }; return }
        let m = currentMemory(), a = engine.captureAudio()
        ioQueue.async { try? store.save(0, data: m, audio: a) }
        audioDirty = false
    }

    // MARK: - Import / export

    func exportsFolder() -> URL {
        let u = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    private func stamp() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; return f.string(from: Date())
    }
    private func safeName() -> String {
        memory.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: " ", with: "_")
    }

    func exportTrack(_ t: Int, format: WAVFormat = .int24) {
        guard engine.tracks[t].hasAudio else { message = "Track \(t + 1) is empty."; return }
        let a = engine.tracks[t].copyAudio()
        let url = exportsFolder().appendingPathComponent("\(safeName())_T\(t + 1)_\(stamp()).wav")
        ioQueue.async {
            try? WAV.encode(left: a.left, right: a.right, sampleRate: Int(AudioIO.sampleRate), format: format).write(to: url)
            DispatchQueue.main.async { self.shareItems = [url] }
        }
    }

    func exportMix(stems: Bool, repeats: Int = 1, format: WAVFormat = .int24) {
        guard !anyRecording else { message = "Finish recording first."; return }
        let m = currentMemory(), a = engine.captureAudio()
        guard a.contains(where: { $0 != nil }) else { message = "Nothing recorded yet."; return }
        busy = stems ? "Rendering stems…" : "Rendering mix…"
        let folder = exportsFolder(), name = safeName(), st = stamp()
        ioQueue.async {
            var urls: [URL] = []
            var opts = OfflineRenderer.Options(); opts.repeats = repeats
            let mix = OfflineRenderer.render(m, audio: a, sampleRate: AudioIO.sampleRate, options: opts)
            let mixURL = folder.appendingPathComponent("\(name)_MIX_\(st).wav")
            try? WAV.encode(left: mix.left, right: mix.right, sampleRate: Int(AudioIO.sampleRate), format: format).write(to: mixURL)
            urls.append(mixURL)
            if stems {
                for t in 0..<5 where a[t] != nil {
                    var o = opts; o.soloTrack = t
                    let s = OfflineRenderer.render(m, audio: a, sampleRate: AudioIO.sampleRate, options: o)
                    let u = folder.appendingPathComponent("\(name)_STEM\(t + 1)_\(st).wav")
                    try? WAV.encode(left: s.left, right: s.right, sampleRate: Int(AudioIO.sampleRate), format: format).write(to: u)
                    urls.append(u)
                }
            }
            DispatchQueue.main.async { self.busy = nil; self.shareItems = urls }
        }
    }

    func exportMemoryBundle(_ index: Int) {
        guard let store = store else { return }
        let url = exportsFolder().appendingPathComponent(String(format: "M%03d_%@.floop", index, stamp()))
        ioQueue.async {
            do { try store.exportBundle(index, to: url); DispatchQueue.main.async { self.shareItems = [url] } }
            catch { DispatchQueue.main.async { self.message = "Export failed: \(error)" } }
        }
    }

    func importMemoryBundle(_ url: URL, to index: Int) {
        guard let store = store else { return }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do { try store.importBundle(from: url, to: index); memoryList = store.list(); message = "Imported into memory \(index)." }
        catch { message = "Import failed: \(error)" }
    }

    func backupAll() {
        guard let store = store else { return }
        let url = exportsFolder().appendingPathComponent("FiveLoop_Backup_\(stamp()).flbk")
        busy = "Backing up…"
        ioQueue.async {
            do { try store.backupAll(to: url); DispatchQueue.main.async { self.busy = nil; self.shareItems = [url] } }
            catch { DispatchQueue.main.async { self.busy = nil; self.message = "Backup failed: \(error)" } }
        }
    }

    func restoreBackup(_ url: URL) {
        guard let store = store else { return }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do { let n = try store.restoreAll(from: url); memoryList = store.list(); message = "Restored \(n) memories." }
        catch { message = "Restore failed: \(error)" }
    }

    /// Imports a WAV file into a track (stops playback while loading).
    func importWAV(_ url: URL, track t: Int) {
        guard !anyRecording else { message = "Finish recording first."; return }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let d = try? Data(contentsOf: url), let w = try? WAV.decode(d) else { message = "Not a supported WAV file."; return }
        var l = w.channels[0], r = w.channels.count > 1 ? w.channels[1] : w.channels[0]
        if w.sampleRate != Int(AudioIO.sampleRate) {
            l = WAV.resample(l, from: w.sampleRate, to: Int(AudioIO.sampleRate)); r = WAV.resample(r, from: w.sampleRate, to: Int(AudioIO.sampleRate))
        }
        let cap = engine.tracks[t].capacity
        if l.count > cap { l = Array(l.prefix(cap)); r = Array(r.prefix(cap)); message = "File trimmed to \(cap / Int(AudioIO.sampleRate)) s (track memory limit)." }
        var m = currentMemory()
        var a = engine.captureAudio()
        a[t] = (l, r)
        m.trackMeta[t].hasAudio = true; m.trackMeta[t].scale = 1
        let qpm = Double(m.beatsPerMeasure) * 4 / Double(m.beatUnit)
        if m.grid?.locked == true, let g = m.grid {
            m.trackMeta[t].measures = Double(l.count) / g.refMeasure
        } else {
            var meas = 1.0
            while 60 * AudioIO.sampleRate * qpm * meas / Double(l.count) < 70 && meas < 64 { meas *= 2 }
            let refM = floor(Double(l.count) / meas)
            let tempo = 60 * AudioIO.sampleRate * qpm / refM
            m.grid = GridInfo(locked: true, refMeasure: refM, refTempo: tempo, tempo: tempo, autoMeasures: meas,
                              beatsPerMeasure: m.beatsPerMeasure, beatUnit: m.beatUnit)
            m.tempo = tempo; m.trackMeta[t].measures = meas
        }
        install(m, audio: a, index: nil)
        dirty = true; scheduleAutosave()
    }

    // MARK: - MIDI

    func saveMIDISettings() {
        if let d = try? JSONEncoder().encode(midiSettings) { UserDefaults.standard.set(d, forKey: "midiSettings") }
        midi.clockOutEnabled = midiSettings.clockOut
        midi.txChannel = midiSettings.txChannel
    }

    private func externalTempo(_ bpm: Double) {
        guard midiSettings.clockSync == .auto else { return }
        engine.send(.midiSync(true))
        engine.send(.tempo(bpm))
    }

    private func handleMIDI(_ m: MIDIMessage) {
        lastMIDI = "\(m)"
        if let target = learnTarget, let src = AssignmentMap.learnSource(from: m) {
            memory.assignments.items.removeAll { $0.target == target }
            memory.assignments.items.append(Assignment(source: src, target: target))
            learnTarget = nil; dirty = true
            message = "Assigned \(src.label) → \(target.label)"
            return
        }
        switch m {
        case .start, .continue:
            guard midiSettings.clockSync == .auto else { break }
            engine.send(.midiSync(true))
            switch midiSettings.startMode {
            case .all: engine.send(.externalStart)
            case .rhythm: engine.send(.rhythmOn(true))
            case .off: break
            }
        case .stop:
            guard midiSettings.clockSync == .auto else { break }
            if midiSettings.startMode != .off { engine.send(.externalStop) }
            engine.send(.midiSync(false))
        case .programChange(let ch, let p) where midiSettings.programChangeIn && ch == midiSettings.rxControlChannel:
            if p + 1 <= MemoryStore.memoryCount { loadMemory(p + 1) }
        case .noteOn(let ch, let n, let v) where ch == midiSettings.rxRhythmChannel:
            if let dv = drumVoice(forNote: n) { engine.send(.drumHit(dv.rawValue, Float(v) / 127)) }
        default: break
        }
        for a in memory.assignments.actions(for: m) { perform(a) }
    }

    func perform(_ a: AssignmentAction) {
        switch a.target {
        case .recPlay(let t): if a.pressed { recPlay(t) }
        case .stop(let t): if a.pressed { stop(t) }
        case .clear(let t): if a.pressed { clear(t) }
        case .undo(let t): if a.pressed { currentTrack = t; undo() }
        case .redo(let t): if a.pressed { currentTrack = t; redo() }
        case .mute(let t): if a.pressed { toggleMute(t) }
        case .trackLevel(let t): setLevel(t, a.value * 200)
        case .currentRecPlay: if a.pressed { recPlay(currentTrack) }
        case .currentStop: if a.pressed { stop(currentTrack) }
        case .undoRedoCurrent: if a.pressed { undoRedo() }
        case .inputFX(let s): if a.pressed || a.released { fxButton(.input, s, down: a.pressed) }
        case .trackFX(let s): if a.pressed || a.released { fxButton(.track, s, down: a.pressed) }
        case .rhythmStartStop: if a.pressed { rhythmStartStop() }
        case .rhythmLevel: updateRhythm { $0.level = a.value * 200 }
        case .tempo: setTempo(40 + Double(a.value) * 210)
        case .tapTempo: if a.pressed { tapTempo() }
        case .allStartStop: if a.pressed { allStartStop() }
        case .memoryNext: if a.pressed { loadMemory(min(MemoryStore.memoryCount, memoryIndex + 1)) }
        case .memoryPrev: if a.pressed { loadMemory(max(1, memoryIndex - 1)) }
        case .masterLevel: updateMixer { $0.masterLevel = a.value * 200 }
        }
    }

    // MARK: - Audio settings

    func applyBufferFrames(_ f: Int) {
        bufferFrames = f; UserDefaults.standard.set(f, forKey: "bufferFrames")
        try? AVAudioSession.sharedInstance().setPreferredIOBufferDuration(Double(f) / AudioIO.sampleRate)
        audio.updateLatency()
    }
    func applyLatencyOffset(_ ms: Double) {
        latencyOffsetMs = ms; UserDefaults.standard.set(ms, forKey: "latencyOffsetMs")
        audio.manualLatencyOffset = ms / 1000
    }
    func applyMaxLoopSeconds(_ s: Int) {
        maxLoopSeconds = s; UserDefaults.standard.set(s, forKey: "maxLoopSeconds")
        message = "Track length limit changes after restarting the app."
    }
}

extension Int { var nonZero: Int? { self == 0 ? nil : self } }
