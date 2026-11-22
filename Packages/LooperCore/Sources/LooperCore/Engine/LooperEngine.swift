import Foundation

public enum RackID: Int, Codable { case input = 0, track = 1 }

/// Everything the UI / MIDI layer can ask the audio thread to do.
public enum EngineCommand {
    case recPlay(Int), stop(Int), clear(Int), undo(Int), redo(Int)
    case allStartStop, stopAllImmediately
    case trackSettings(Int, TrackSettings)
    case mute(Int, Bool)
    case global(GlobalLoopSettings)
    case tempo(Double)
    case beat(Int, Int)
    case rhythmToggle, rhythmOn(Bool)
    case rhythm(RhythmSettings)
    case inputLevel(Float), masterLevel(Float), monitor(Bool)
    case masterComp(Float), masterReverb(Float)
    case latency(Int)
    case fxInstall(RackID, bank: Int, slot: Int, FXProcessor?)
    case fxSwitch(RackID, bank: Int, slot: Int, Bool)
    case fxParam(RackID, bank: Int, slot: Int, index: Int, Float)
    case fxInsert(RackID, bank: Int, slot: Int, Int)
    case fxBank(RackID, Int), fxBankOn(RackID, Bool), fxMode(RackID, FXBankMode)
    case suspend, resume(GridInfo?)
    case midiSync(Bool), externalStart, externalStop
    case drumHit(Int, Float)
}

/// Tempo grid description (saved with each memory).
public struct GridInfo: Codable, Equatable {
    public var locked: Bool
    public var refMeasure: Double
    public var refTempo: Double
    public var tempo: Double
    public var autoMeasures: Double?
    public var beatsPerMeasure: Int
    public var beatUnit: Int
    public init(locked: Bool, refMeasure: Double, refTempo: Double, tempo: Double, autoMeasures: Double?, beatsPerMeasure: Int, beatUnit: Int) {
        self.locked = locked; self.refMeasure = refMeasure; self.refTempo = refTempo; self.tempo = tempo
        self.autoMeasures = autoMeasures; self.beatsPerMeasure = beatsPerMeasure; self.beatUnit = beatUnit
    }
}

public enum EngineEvent {
    case recordingFinished(track: Int)
    case gridLocked(tempo: Double, measures: Double)
    case gridUnlocked
    case transportStarted, transportStopped
    case retired(FXProcessor)
}

public struct MIDIClockEvent { public var frameOffset: Int32; public var status: UInt8 } // 0xF8 / 0xFA / 0xFC

/// The real-time core: five loop tracks, FX racks, rhythm, mixer and master section.
/// `process` is the only entry point used by the audio thread.
public final class LooperEngine {
    public static let trackCount = 5
    public let sampleRate: Double
    public let maxFrames: Int
    public let tracks: [LoopTrack]
    public let inputRack: FXRack
    public let trackRack: FXRack
    public let rhythm: RhythmEngine
    public let status = StatusBoard()
    public let commands = SPSCQueue<EngineCommand>(capacity: 1024)
    public let events = SPSCQueue<EngineEvent>(capacity: 1024)
    public let midiOut = SPSCQueue<MIDIClockEvent>(capacity: 2048)

    private let masterComp: DynamicsFX
    private let masterReverb: ReverbFX

    // transport
    public private(set) var tempo: Double = 120
    private(set) var refTempo: Double = 120
    private(set) var refMeasure: Double = 88200
    public private(set) var songPos: Double = 0
    public private(set) var running = false
    public private(set) var locked = false
    private(set) var beats = 4, unit = 4
    private var autoMeasures: Double? = nil
    private var rhythmArmed = false
    private var rhythmStandalone = false
    private var midiSync = false
    private var suspended = false

    // settings
    private var global = GlobalLoopSettings()
    private var rhythmSettings = RhythmSettings()
    private var inputLevel: Float = 1, masterLevel: Float = 1, monitor = true
    private var compDepth: Float = 0, reverbDepth: Float = 0
    private var latency = 0
    private var pendingSingleStart: Int? = nil

    // scratch (allocated once)
    private let inL, inR, recL, recR, rhyL, rhyR, mixL, mixR, busL, busR, revL, revR, prevSumL, prevSumR: UnsafeMutablePointer<Float>
    private let tOutL: [UnsafeMutablePointer<Float>], tOutR: [UnsafeMutablePointer<Float>]
    private let tPostL: [UnsafeMutablePointer<Float>], tPostR: [UnsafeMutablePointer<Float>]
    private var trackGains: [Smoother]
    private var inPeak: Float = 0, outPeak: Float = 0
    private static let histSize = 8192
    private let histL: UnsafeMutablePointer<Float>, histR: UnsafeMutablePointer<Float>
    private var inputFrame = 0         // absolute frame counter of the input stream

    /// - Parameters:
    ///   - maxLoopSeconds: memory reserved per track (×2 for undo).
    public init(sampleRate: Double = 44100, maxFrames: Int = 4096, maxLoopSeconds: Double = 60) {
        self.sampleRate = sampleRate
        self.maxFrames = maxFrames
        let cap = Int(sampleRate * maxLoopSeconds)
        tracks = (0..<LooperEngine.trackCount).map { LoopTrack(index: $0, capacityFrames: cap) }
        inputRack = FXRack(maxFrames: maxFrames)
        trackRack = FXRack(maxFrames: maxFrames)
        rhythm = RhythmEngine(sampleRate: sampleRate)
        masterComp = DynamicsFX(type: .dynamics, sampleRate: sampleRate)
        masterReverb = ReverbFX(type: .reverb, sampleRate: sampleRate)
        masterReverb.setParam(0, 25); masterReverb.setParam(4, 0); masterReverb.setParam(5, 100)
        func buf() -> UnsafeMutablePointer<Float> { let p = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames); p.initialize(repeating: 0, count: maxFrames); return p }
        inL = buf(); inR = buf(); recL = buf(); recR = buf(); rhyL = buf(); rhyR = buf(); mixL = buf(); mixR = buf()
        busL = buf(); busR = buf(); revL = buf(); revR = buf(); prevSumL = buf(); prevSumR = buf()
        tOutL = (0..<5).map { _ in buf() }; tOutR = (0..<5).map { _ in buf() }
        tPostL = (0..<5).map { _ in buf() }; tPostR = (0..<5).map { _ in buf() }
        trackGains = (0..<5).map { _ in Smoother(1) }
        histL = .allocate(capacity: LooperEngine.histSize); histR = .allocate(capacity: LooperEngine.histSize)
        histL.initialize(repeating: 0, count: LooperEngine.histSize); histR.initialize(repeating: 0, count: LooperEngine.histSize)
        setTempoInternal(120)
        rhythm.apply(rhythmSettings)
    }

    deinit {
        for p in [inL, inR, recL, recR, rhyL, rhyR, mixL, mixR, busL, busR, revL, revR, prevSumL, prevSumR] { p.deallocate() }
        for p in tOutL + tOutR + tPostL + tPostR { p.deallocate() }
        histL.deallocate(); histR.deallocate()
    }

    // MARK: - Public helpers (main thread)

    public func send(_ c: EngineCommand) { commands.push(c) }

    public var quarterPerMeasure: Double { Double(beats) * 4 / Double(unit) }
    func measureFrames(forTempo t: Double) -> Double { 60 * sampleRate / t * quarterPerMeasure }

    public var gridInfo: GridInfo {
        GridInfo(locked: locked, refMeasure: refMeasure, refTempo: refTempo, tempo: tempo, autoMeasures: autoMeasures,
                 beatsPerMeasure: beats, beatUnit: unit)
    }

    // MARK: - Transport internals

    private var ratio: Double { locked ? tempo / refTempo : 1 }
    private var gridActive: Bool { locked || rhythmArmed || midiSync }

    private func setTempoInternal(_ t: Double) {
        let nt = clamp(t, 20, 300)
        if locked { tempo = nt; return }
        let old = refMeasure
        refMeasure = measureFrames(forTempo: nt).rounded()
        refTempo = 60 * sampleRate * quarterPerMeasure / refMeasure
        tempo = refTempo
        if running && old > 0 { songPos *= refMeasure / old }
    }

    private func block() -> TrackBlock {
        TrackBlock(songStart: songPos, ratio: ratio, refMeasure: refMeasure, realMeasure: refMeasure / ratio,
                   latency: latency, autoRecThreshold: powf(10, (-60 + global.autoRecSensitivity * 0.54) / 20),
                   sampleRate: sampleRate, histL: histL, histR: histR, histSize: LooperEngine.histSize,
                   blockStartFrame: inputFrame)
    }

    private func startTransport(countIn: Int = 0, offset: Int32 = 0) {
        guard !running else { return }
        running = true
        songPos = -Double(countIn) * refMeasure
        for t in tracks where t.hasAudio { t.anchor = 0; t.freePos = 0 }
        rhythm.reset()
        midiOut.push(MIDIClockEvent(frameOffset: offset, status: 0xFA))
        events.push(.transportStarted)
    }

    private func stopTransport() {
        guard running else { return }
        running = false
        midiOut.push(MIDIClockEvent(frameOffset: 0, status: 0xFC))
        events.push(.transportStopped)
    }

    private func lockGrid(measures m: Double) {
        if !locked {
            locked = true
            refTempo = 60 * sampleRate * quarterPerMeasure / refMeasure
            tempo = refTempo
        }
        events.push(.gridLocked(tempo: tempo, measures: m))
    }

    private func unlockIfEmpty() {
        guard tracks.allSatisfy({ $0.state == .empty }) else { return }
        locked = false; autoMeasures = nil
        setTempoInternal(tempo)
        events.push(.gridUnlocked)
    }

    // MARK: - Commands

    private func handle(_ c: EngineCommand) {
        switch c {
        case .recPlay(let i): if tracks.indices.contains(i) { recPlay(i) }
        case .stop(let i): if tracks.indices.contains(i) { stopTrack(i) }
        case .clear(let i):
            guard tracks.indices.contains(i) else { return }
            tracks[i].clear(); pendingPresetTarget[i] = nil; unlockIfEmpty()
        case .undo(let i):
            guard tracks.indices.contains(i) else { return }
            tracks[i].undo(transportRunning: running); unlockIfEmpty()
        case .redo(let i):
            guard tracks.indices.contains(i) else { return }
            let wasUnlocked = !locked
            tracks[i].redo(transportRunning: running, song: songPos, block: block())
            if wasUnlocked && tracks[i].hasAudio && tracks[i].settings.loopSync { lockGrid(measures: tracks[i].measures) }
        case .allStartStop: allStartStop()
        case .stopAllImmediately:
            for t in tracks { if t.state == .recording || t.state == .recStandby { t.clear() } else { t.stopNow() } }
            rhythmArmed = false; stopTransport(); unlockIfEmpty()
        case .trackSettings(let i, let s): if tracks.indices.contains(i) { tracks[i].settings = s }
        case .mute(let i, let m): if tracks.indices.contains(i) { tracks[i].muted = m }
        case .global(let g): global = g
        case .tempo(let t): setTempoInternal(t)
        case .beat(let b, let u):
            guard !locked else { return }
            beats = clamp(b, 2, 15); unit = (u == 8) ? 8 : 4
            setTempoInternal(tempo)
        case .rhythmToggle: setRhythm(!rhythmArmed)
        case .rhythmOn(let on): setRhythm(on)
        case .rhythm(let s): rhythmSettings = s; rhythm.apply(s)
        case .inputLevel(let v): inputLevel = clamp(v, 0, 200) / 100
        case .masterLevel(let v): masterLevel = clamp(v, 0, 200) / 100
        case .monitor(let m): monitor = m
        case .masterComp(let d):
            compDepth = clamp(d, 0, 40)
            masterComp.setParam(0, compDepth / 40 * 100); masterComp.setParam(1, 20); masterComp.setParam(2, 35)
        case .masterReverb(let d): reverbDepth = clamp(d, 0, 40)
        case .latency(let l): latency = max(0, l)
        case .fxInstall(let rack, let b, let s, let p):
            let slot = rackFor(rack).slots[b][s]
            let old = slot.processor
            p?.reset()
            slot.processor = p
            if let old = old { events.push(.retired(old)) }
        case .fxSwitch(let rack, let b, let s, let on): rackFor(rack).setSlotOn(bank: b, slot: s, on: on, sampleRate: sampleRate)
        case .fxParam(let rack, let b, let s, let idx, let v): rackFor(rack).slots[b][s].processor?.setParam(idx, v)
        case .fxInsert(let rack, let b, let s, let ins): rackFor(rack).slots[b][s].insert = ins
        case .fxBank(let rack, let b): rackFor(rack).activeBank = clamp(b, 0, 3)
        case .fxBankOn(let rack, let on): rackFor(rack).bankOn = on
        case .fxMode(let rack, let m): rackFor(rack).mode = m
        case .suspend:
            for t in tracks { t.stopNow(); if t.state == .recording || t.state == .recStandby { t.clear() } }
            rhythmArmed = false; stopTransport(); suspended = true
        case .resume(let g):
            if let g = g {
                beats = g.beatsPerMeasure; unit = g.beatUnit
                locked = g.locked; refMeasure = g.refMeasure; refTempo = g.refTempo; tempo = g.tempo
                autoMeasures = g.autoMeasures
                if !locked { setTempoInternal(g.tempo) }
            }
            suspended = false
        case .midiSync(let on): midiSync = on
        case .drumHit(let v, let vel): if let dv = DrumVoice(rawValue: v) { rhythm.hit(dv, vel) }
        case .externalStart:
            startTransport()
            for (i, t) in tracks.enumerated() where t.settings.midiStartTarget && t.hasAudio && !t.isPlaying { startTrack(i, forceMulti: true) }
        case .externalStop:
            for t in tracks where t.settings.midiStopTarget { if t.state == .recording { t.clear() } else { t.stopNow() } }
            stopTransport()
        }
    }

    private func rackFor(_ r: RackID) -> FXRack { r == .input ? inputRack : trackRack }

    private func setRhythm(_ on: Bool) {
        rhythmArmed = on
        if on && !running && rhythmSettings.startTrigger == .beforeLoop {
            rhythmStandalone = true
            startTransport()
        }
        if !on && !tracks.contains(where: { $0.isBusy }) { stopTransport() }
    }

    private func measuresSetting(_ t: LoopTrack) -> Double? {
        switch t.settings.measure {
        case .measures(let m): return m
        case .auto: return locked ? autoMeasures : nil
        case .free: return nil
        }
    }

    private func recPlay(_ i: Int) {
        let t = tracks[i]
        switch t.state {
        case .empty: startRecording(i)
        case .recStandby: t.clear()
        case .recording: finishRecording(i, then: global.recAction == .recDub ? .dub : .play)
        case .playing:
            if t.settings.oneShot { t.anchor = songPos; t.startPlayback(song: songPos, block: block(), resetAnchor: true) }
            else if t.canOverdub && t.rate(block()) == 1.0 && !t.swapping { t.state = .overdubbing; t.startDubBackup() }
        case .overdubbing: t.endDub()
        case .stopped, .stopping: startTrack(i)
        }
    }

    private func stopOthersForSingleMode(except i: Int) {
        guard global.playMode == .single else { return }
        for (j, o) in tracks.enumerated() where j != i && (o.isPlaying || o.state == .recording) {
            if o.state == .recording { finishRecording(j, then: .stop) } else { o.requestStop(block: block()) }
        }
    }

    private func startRecording(_ i: Int) {
        let t = tracks[i]
        stopOthersForSingleMode(except: i)
        let grid = gridActive
        if !running {
            let countIn = (rhythmArmed && grid) ? rhythmSettings.countInMeasures : 0
            startTransport(countIn: countIn)
        }
        t.recLatency = grid ? latency : 0
        var preset: Int? = nil
        if grid && t.settings.loopSync, let m = measuresSetting(t) {
            preset = Int((m * refMeasure / ratio).rounded())
            t.measures = m
        } else { t.measures = 0 }
        t.afterRecord = global.recAction == .recDub ? .dub : .play
        if grid && t.settings.loopSync && (global.quantize == .measure || songPos < 0) {
            let b = max(0, (songPos / refMeasure - 1e-9).rounded(.up) * refMeasure)
            t.state = .recStandby; t.standbyBoundary = b
        } else if global.autoRec {
            t.state = .recStandby; t.standbyBoundary = nil
        } else {
            t.beginRecording(at: songPos, ratio: ratio, latency: t.recLatency, absFrame: inputFrame, block: block())
        }
        t.recTarget = preset
        pendingPresetTarget[i] = preset
    }
    /// Preset (auto-stop) targets survive the standby → recording transition.
    private var pendingPresetTarget = [Int?](repeating: nil, count: 5)

    private func finishRecording(_ i: Int, then next: AfterRecord) {
        let t = tracks[i]
        pendingPresetTarget[i] = nil
        if t.state == .recStandby { t.clear(); return }
        guard t.state == .recording else { return }
        if gridActive && t.settings.loopSync {
            let unitFrames = refMeasure * t.scale
            let m = max(1, (Double(t.recFrames) / unitFrames).rounded())
            t.measures = m
            t.requestRecordEnd(target: Int((m * unitFrames).rounded()), then: next)
        } else if !gridActive && t.settings.loopSync {
            // First free recording defines the tempo grid.
            let T = max(1, t.recFrames)
            var m: Double
            if case .measures(let n) = t.settings.measure, n >= 1 { m = n }
            else {
                m = 1
                while 60 * sampleRate * quarterPerMeasure * m / Double(T) < 70 && m < 64 { m *= 2 }
            }
            refMeasure = floor(Double(T) / m)
            locked = false
            lockGrid(measures: m)
            if case .auto = t.settings.measure { autoMeasures = m }
            t.measures = m
            t.requestRecordEnd(target: Int(refMeasure * m), then: next)
        } else {
            t.measures = Double(t.recFrames) / (refMeasure * t.scale)
            t.requestRecordEnd(target: t.recFrames, then: next)
        }
    }

    private func stopTrack(_ i: Int) {
        let t = tracks[i]
        switch t.state {
        case .recording: finishRecording(i, then: .stop)
        case .recStandby: t.clear()
        case .playing, .overdubbing, .stopping: t.requestStop(block: block())
        default: break
        }
        if pendingSingleStart == i { pendingSingleStart = nil }
    }

    private func startTrack(_ i: Int, forceMulti: Bool = false) {
        let t = tracks[i]
        guard t.length > 0 else { return }
        if !forceMulti && global.playMode == .single && tracks.enumerated().contains(where: { $0.offset != i && $0.element.isPlaying }) {
            if global.singleTrackChange == .loopEnd { pendingSingleStart = i; return }
            stopOthersForSingleMode(except: i)
        }
        if !running { startTransport() }
        t.startPlayback(song: songPos, block: block(), resetAnchor: false)
    }

    private func allStartStop() {
        let anyActive = tracks.contains { $0.settings.allStopTarget && ($0.isPlaying || $0.state == .recording) }
        if anyActive {
            for (i, t) in tracks.enumerated() where t.settings.allStopTarget { stopTrack(i) }
        } else {
            for (i, t) in tracks.enumerated() where t.settings.allStartTarget && t.length > 0 && t.state != .recording {
                startTrack(i, forceMulti: true)
                if global.playMode == .single { break }
            }
        }
    }

    // MARK: - Audio

    /// Real-time entry point. `inL/inR` may be the same pointer for mono input.
    public func process(frames total: Int, inL srcL: UnsafePointer<Float>?, inR srcR: UnsafePointer<Float>?,
                        outL: UnsafeMutablePointer<Float>, outR: UnsafeMutablePointer<Float>) {
        var done = 0
        while done < total {
            let n = min(maxFrames, total - done)
            processChunk(n, srcL.map { $0 + done }, srcR.map { $0 + done }, outL + done, outR + done)
            done += n
        }
    }

    private func processChunk(_ n: Int, _ srcL: UnsafePointer<Float>?, _ srcR: UnsafePointer<Float>?,
                              _ outL: UnsafeMutablePointer<Float>, _ outR: UnsafeMutablePointer<Float>) {
        while let c = commands.pop() { handle(c) }

        if suspended {
            outL.update(repeating: 0, count: n); outR.update(repeating: 0, count: n)
            writeStatus(); return
        }

        // ---- input stage
        var ip: Float = 0
        for i in 0..<n {
            let l = (srcL?[i] ?? 0) * inputLevel
            let r = (srcR?[i] ?? srcL?[i] ?? 0) * inputLevel
            inL[i] = l; inR[i] = r
            ip = max(ip, abs(l), abs(r))
        }
        inPeak = ip
        let r = ratio
        var ctx = FXContext()
        ctx.sampleRate = sampleRate; ctx.tempo = tempo; ctx.beatsPerMeasure = beats; ctx.beatUnit = unit
        ctx.measureFrames = refMeasure / r; ctx.measurePos = songPos / refMeasure
        ctx.measuresPerFrame = running ? r / refMeasure : 0; ctx.running = running
        inputRack.process(inL, inR, n, ctx)

        // ---- rhythm
        rhyL.update(repeating: 0, count: n); rhyR.update(repeating: 0, count: n)
        rhythm.render(n, songStart: songPos, ratio: r, refMeasure: refMeasure, beats: beats, unit: unit,
                      playing: rhythmArmed && running, countIn: running && songPos < 0, outL: rhyL, outR: rhyR)
        let rhythmGain = rhythmSettings.level / 100

        // ---- tracks
        // input history (for the loop-seam pre-roll)
        for i in 0..<n {
            let idx = (inputFrame + i) % LooperEngine.histSize
            histL[idx] = inL[i]; histR[idx] = inR[i]
        }
        let blk = block()
        var singleWrap = false
        for (ti, t) in tracks.enumerated() {
            let needsInput = t.state == .recording || t.state == .recStandby || t.state == .overdubbing || t.finishActive
            if needsInput {
                for i in 0..<n {
                    var l: Float = t.settings.inputOn ? inL[i] : 0, rr: Float = t.settings.inputOn ? inR[i] : 0
                    if t.settings.rhythmToTrack { l += rhyL[i] * rhythmGain; rr += rhyR[i] * rhythmGain }
                    if t.settings.bounceIn { l += prevSumL[i] - tPostL[ti][i]; rr += prevSumR[i] - tPostR[ti][i] }
                    recL[i] = l; recR[i] = rr
                }
            }
            let wasStandby = t.state == .recStandby
            t.process(n, blk, inL: recL, inR: recR, outL: tOutL[ti], outR: tOutR[ti]) { idx in
                if idx != ti { return }
                if self.pendingSingleStart != nil { singleWrap = true }
            }
            if wasStandby && t.state != .recStandby, let p = pendingPresetTarget[ti] {
                // recording began during this block → arm the auto-stop length
                if t.recTarget == nil { t.recTarget = p }
                if t.recFrames >= p && t.state == .recording { t.completeRecording(target: p) }
            }
            if t.justFinishedRecording {
                t.justFinishedRecording = false
                pendingPresetTarget[ti] = nil
                if t.settings.loopSync && !locked { lockGrid(measures: t.measures) }
                if case .auto = t.settings.measure, autoMeasures == nil, t.settings.loopSync { autoMeasures = t.measures }
                events.push(.recordingFinished(track: ti))
            }
        }
        if singleWrap, let p = pendingSingleStart {
            pendingSingleStart = nil
            for (j, o) in tracks.enumerated() where j != p && o.isPlaying { o.stopNow() }
            tracks[p].startPlayback(song: songPos + Double(n) * r, block: blk, resetAnchor: false)
        }

        // ---- track FX, level / pan, mix
        mixL.update(repeating: 0, count: n); mixR.update(repeating: 0, count: n)
        busL.update(repeating: 0, count: n); busR.update(repeating: 0, count: n)
        prevSumL.update(repeating: 0, count: n); prevSumR.update(repeating: 0, count: n)
        let allBusActive = trackRack.hasActive(insert: -1)
        for (ti, t) in tracks.enumerated() {
            let oL = tOutL[ti], oR = tOutR[ti], pL = tPostL[ti], pR = tPostR[ti]
            if t.settings.fxOn { trackRack.process(oL, oR, n, ctx, insert: ti) }
            let (gl, gr) = panGains(t.settings.pan / 50)
            trackGains[ti].set(t.muted ? 0 : t.settings.playLevel / 100, frames: 256)
            let toBus = t.settings.fxOn && allBusActive
            for i in 0..<n {
                let g = trackGains[ti].next()
                let l = oL[i] * g * gl, rr = oR[i] * g * gr
                pL[i] = l; pR[i] = rr
                prevSumL[i] += l; prevSumR[i] += rr
                if toBus { busL[i] += l; busR[i] += rr } else { mixL[i] += l; mixR[i] += rr }
            }
        }
        if allBusActive {
            trackRack.process(busL, busR, n, ctx, insert: -1)
            for i in 0..<n { mixL[i] += busL[i]; mixR[i] += busR[i] }
        }
        for i in 0..<n {
            mixL[i] += rhyL[i] * rhythmGain; mixR[i] += rhyR[i] * rhythmGain
            if monitor { mixL[i] += inL[i]; mixR[i] += inR[i] }
        }

        // ---- master FX
        if compDepth > 0 { masterComp.render(mixL, mixR, n, ctx) }
        if reverbDepth > 0 {
            revL.update(from: mixL, count: n); revR.update(from: mixR, count: n)
            masterReverb.render(revL, revR, n, ctx)
            let w = reverbDepth / 40 * 0.6
            for i in 0..<n { mixL[i] += revL[i] * w; mixR[i] += revR[i] * w }
        }
        var op: Float = 0
        for i in 0..<n {
            let l = mixL[i] * masterLevel, rr = mixR[i] * masterLevel
            op = max(op, abs(l), abs(rr))
            // safety limiter: bit-transparent below −0.9 dBFS, soft knee above
            outL[i] = abs(l) <= 0.9 ? l : softClipOut(l)
            outR[i] = abs(rr) <= 0.9 ? rr : softClipOut(rr)
        }
        outPeak = op

        // ---- advance transport, MIDI clock
        if running {
            let start = songPos, end = songPos + Double(n) * r
            let tickLen = refMeasure / (quarterPerMeasure * 24)
            if end > 0 {
                var k = (max(0, start) / tickLen).rounded(.up)
                while k * tickLen < end {
                    let off = Int32(max(0, (k * tickLen - start) / r))
                    midiOut.push(MIDIClockEvent(frameOffset: off, status: 0xF8))
                    k += 1
                }
            }
            songPos = end
        }
        for t in tracks where t.swapping { t.continueSwap(maxFrames: 32768) }
        inputFrame += n

        let busy = tracks.contains { $0.isBusy || $0.finishActive }
        if busy { rhythmStandalone = false }
        if running && !busy && !midiSync {
            let keep = rhythmArmed && (rhythmStandalone || !rhythmSettings.stopWithLoops)
            if !keep { stopTransport() }
        }
        writeStatus()
    }

    @inline(__always) private func softClipOut(_ x: Float) -> Float {
        let s: Float = x < 0 ? -1 : 1
        let a = abs(x)
        return s * (0.9 + 0.1 * tanhf((a - 0.9) / 0.1))
    }

    private func writeStatus() {
        for (i, t) in tracks.enumerated() {
            status.write(track: i, state: t.state, pos: t.state == .recording ? 0 : t.position, peak: t.peak, length: t.length,
                         measures: t.measures, undo: t.undoAvailable, redo: t.redoAvailable, muted: t.muted, finishing: t.finishActive)
        }
        status.write(tempo: tempo, song: songPos, refMeasure: refMeasure, running: running, locked: locked,
                     rhythm: rhythmArmed && running, armed: rhythmArmed, suspended: suspended, grid: gridActive, beats: beats, unit: unit,
                     inPeak: inPeak, outPeak: outPeak)
    }
}
