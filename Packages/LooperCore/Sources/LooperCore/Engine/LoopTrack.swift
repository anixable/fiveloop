import Foundation

public enum TrackState: Int, Codable {
    case empty = 0, recStandby, recording, playing, overdubbing, stopped, stopping
}

enum AfterRecord { case play, dub, stop }
enum UndoKind { case none, firstRecording, dub }

/// Per-block timing info passed from the engine to each track.
struct TrackBlock {
    var songStart: Double      // song position (reference frames) at frame 0 of the block
    var ratio: Double          // reference frames advanced per real frame (tempo / refTempo)
    var refMeasure: Double     // one measure in reference frames
    var realMeasure: Double    // one measure in real frames at the current tempo
    var latency: Int           // input latency compensation (frames)
    var autoRecThreshold: Float
    var sampleRate: Double
    // Engine input history (ring), used to capture the pre-roll for the loop seam.
    var histL: UnsafePointer<Float>? = nil
    var histR: UnsafePointer<Float>? = nil
    var histSize = 0
    var blockStartFrame = 0          // absolute input frame of sample 0 of this block
}

/// One stereo loop track. All buffers are allocated once in `init` (main thread).
/// Every method except `init`/`deinit` and the `load…`/`copy…` helpers runs on the audio thread.
public final class LoopTrack {
    public let index: Int
    public let capacity: Int
    let bufL: UnsafeMutablePointer<Float>, bufR: UnsafeMutablePointer<Float>
    let undoL: UnsafeMutablePointer<Float>, undoR: UnsafeMutablePointer<Float>

    public internal(set) var state: TrackState = .empty
    public var settings = TrackSettings()
    public internal(set) var length = 0                  // content frames
    public internal(set) var scale: Double = 1           // content frames per reference frame
    public internal(set) var measures: Double = 0        // length in measures (0 = unknown/free)
    var anchor: Double = 0                               // song position of content frame 0
    var freePos: Double = 0                              // playhead for TEMPO SYNC OFF tracks
    var lastPos: Double = 0                              // for UI

    // recording
    var recFrames = 0
    var recTarget: Int? = nil
    var afterRecord: AfterRecord = .play
    var standbyBoundary: Double? = nil                   // nil + recStandby ⇒ AUTO REC waiting for signal
    var recLatency = 0
    var finishActive = false
    var finishEnd = 0                                    // capture continues while w < finishEnd
    /// Seam handling: the last `seam` frames of the loop are cross-faded into the audio that
    /// preceded the take (pre-roll), so the wrap from end → start is continuous while the
    /// downbeat at index 0 keeps its original attack.
    static let seam = 256
    let preL: UnsafeMutablePointer<Float>, preR: UnsafeMutablePointer<Float>
    /// Set by the engine when this recording defines the tempo grid (first free recording).
    var definesGrid = false
    public internal(set) var justFinishedRecording = false

    // undo / redo
    var undoKind: UndoKind = .none
    public internal(set) var undoAvailable = false
    public internal(set) var redoAvailable = false
    var dubStart = 0, dubCount = 0
    var swapping = false, swapStart = 0, swapCount = 0, swapDone = 0, swapOffset = 0
    var savedLength = 0, savedMeasures = 0.0, savedScale = 1.0

    // playback gain / stop handling
    var gain = Smoother(0)
    enum PendingStop { case none, fade, loopEnd }
    var pendingStop: PendingStop = .none
    public var muted = false
    public internal(set) var peak: Float = 0

    init(index: Int, capacityFrames: Int) {
        self.index = index
        capacity = capacityFrames
        bufL = .allocate(capacity: capacityFrames + 8); bufR = .allocate(capacity: capacityFrames + 8)
        undoL = .allocate(capacity: capacityFrames + 8); undoR = .allocate(capacity: capacityFrames + 8)
        for p in [bufL, bufR, undoL, undoR] { p.initialize(repeating: 0, count: capacityFrames + 8) }
        preL = .allocate(capacity: LoopTrack.seam); preR = .allocate(capacity: LoopTrack.seam)
        preL.initialize(repeating: 0, count: LoopTrack.seam); preR.initialize(repeating: 0, count: LoopTrack.seam)
    }
    deinit { for p in [bufL, bufR, undoL, undoR, preL, preR] { p.deallocate() } }

    public var hasAudio: Bool { length > 0 && state != .empty && state != .recording && state != .recStandby }
    public var isPlaying: Bool { state == .playing || state == .overdubbing || state == .stopping }
    public var isBusy: Bool { isPlaying || state == .recording || state == .recStandby }
    public var position: Double { length > 0 ? lastPos / Double(length) : 0 }
    public var isRecordingPhase: Bool { state == .recording || finishActive }

    /// Content frames advanced per real frame.
    func rate(_ b: TrackBlock) -> Double {
        let r = settings.tempoSync ? b.ratio * scale * settings.speed.factor : settings.speed.factor
        return abs(r - 1) < 1e-9 ? 1 : r
    }
    var canOverdub: Bool { !settings.reverse && !settings.oneShot }

    // MARK: - Commands (audio thread)

    /// `absFrame`: absolute input frame at which recording starts; history must contain frames before it.
    func beginRecording(at song: Double, ratio: Double, latency: Int, absFrame: Int = 0, block b: TrackBlock? = nil) {
        // pre-roll = input frames [absFrame + latency − seam, absFrame + latency); the part before
        // absFrame comes from the history ring, the rest arrives as w < 0 samples while recording.
        let X = LoopTrack.seam
        preL.update(repeating: 0, count: X); preR.update(repeating: 0, count: X)
        if let b = b, let hl = b.histL, let hr = b.histR, b.histSize > 0 {
            for k in 0..<X {
                let f = absFrame + latency - X + k
                if f < absFrame && f >= 0 && absFrame - f < b.histSize {
                    let idx = f % b.histSize
                    preL[k] = hl[idx]; preR[k] = hr[idx]
                }
            }
        }
        state = .recording
        anchor = song
        scale = 1 / ratio
        recFrames = 0
        recLatency = latency
        recTarget = nil
        finishActive = false
        undoKind = .none; undoAvailable = false; redoAvailable = false
        length = 0
        gain = Smoother(1)
        pendingStop = .none
        justFinishedRecording = false
    }

    /// Finish the take at `target` content frames (may be in the future: the track keeps recording).
    func requestRecordEnd(target: Int, then next: AfterRecord) {
        afterRecord = next
        let t = max(1, min(target, capacity))
        if t <= recFrames { completeRecording(target: t) } else { recTarget = t }
    }

    func completeRecording(target: Int) {
        length = max(1, min(target, capacity))
        recTarget = nil
        let writtenEnd = recFrames - recLatency
        finishEnd = length
        finishActive = writtenEnd < finishEnd
        if !finishActive { applySeam() }
        undoKind = .firstRecording; undoAvailable = true; redoAvailable = false
        justFinishedRecording = true
        switch afterRecord {
        case .play: state = .playing
        case .dub: state = canOverdub ? .overdubbing : .playing; if state == .overdubbing { startDubBackup() }
        case .stop: state = .stopped; gain = Smoother(0)
        }
    }

    /// Cross-fades the loop end into the pre-roll (equal-power).
    func applySeam() {
        let X = min(LoopTrack.seam, length / 4)
        guard X > 1 else { return }
        let off = LoopTrack.seam - X
        for k in 0..<X {
            let w = Float(k + 1) / Float(X)
            let a = cosf(w * Float.pi / 2), c = sinf(w * Float.pi / 2)
            let i = length - X + k
            bufL[i] = bufL[i] * a + preL[off + k] * c
            bufR[i] = bufR[i] * a + preR[off + k] * c
        }
    }

    func startDubBackup() {
        dubCount = 0
        undoKind = .dub; undoAvailable = false; redoAvailable = false
    }

    func endDub() {
        if state == .overdubbing { state = .playing }
        if undoKind == .dub && dubCount > 0 { undoAvailable = true; redoAvailable = false }
    }

    func startPlayback(song: Double, block: TrackBlock, resetAnchor: Bool) {
        guard length > 0 else { return }
        if resetAnchor || !settings.loopSync || settings.oneShot { anchor = song }
        freePos = 0
        state = .playing
        pendingStop = .none
        if settings.startMode == .fade {
            gain = Smoother(0)
            gain.set(1, frames: Int(settings.fadeInMeasures * block.realMeasure))
        } else {
            gain = Smoother(0); gain.set(1, frames: Int(block.sampleRate * 0.003))
        }
    }

    func requestStop(block: TrackBlock) {
        if state == .overdubbing { endDub() }
        if state == .stopping { // second press: stop immediately
            gain.set(0, frames: Int(block.sampleRate * 0.003)); pendingStop = .fade; return
        }
        guard state == .playing else { return }
        switch settings.stopMode {
        case .immediate:
            state = .stopping; pendingStop = .fade
            gain.set(0, frames: Int(block.sampleRate * 0.003))
        case .fade:
            state = .stopping; pendingStop = .fade
            gain.set(0, frames: max(64, Int(settings.fadeOutMeasures * block.realMeasure)))
        case .loop:
            state = .stopping; pendingStop = .loopEnd
        }
    }

    func stopNow() {
        if state == .overdubbing { endDub() }
        if state == .playing || state == .stopping || state == .overdubbing { state = .stopped }
        gain = Smoother(0); pendingStop = .none
    }

    func clear() {
        state = .empty; length = 0; measures = 0; recTarget = nil; finishActive = false
        undoKind = .none; undoAvailable = false; redoAvailable = false; swapping = false
        gain = Smoother(0); pendingStop = .none; lastPos = 0; peak = 0
    }

    func undo(transportRunning: Bool) {
        if state == .recording || state == .recStandby { clear(); return }
        if swapping { return }
        if state == .overdubbing { endDub() }
        guard undoAvailable else { return }
        switch undoKind {
        case .firstRecording:
            savedLength = length; savedMeasures = measures; savedScale = scale
            state = .empty; length = 0; finishActive = false
            undoAvailable = false; redoAvailable = true
        case .dub:
            beginSwap()
            undoAvailable = false; redoAvailable = true
        case .none: break
        }
    }

    func redo(transportRunning: Bool, song: Double, block: TrackBlock) {
        guard redoAvailable, !swapping else { return }
        switch undoKind {
        case .firstRecording:
            length = savedLength; measures = savedMeasures; scale = savedScale
            redoAvailable = false; undoAvailable = true
            state = .stopped
            if transportRunning { startPlayback(song: song, block: block, resetAnchor: false) }
        case .dub:
            beginSwap()
            redoAvailable = false; undoAvailable = true
        case .none: break
        }
    }

    /// Undo/redo of an overdub swaps the touched range between the loop and the backup.
    /// The swap is spread over several audio blocks, starting at the play head so the
    /// head never crosses the swap frontier (glitch-free).
    private func beginSwap() {
        swapping = true
        swapStart = dubStart; swapCount = min(dubCount, length); swapDone = 0
        let ph = Int(lastPos)
        let off = ((ph - swapStart) % length + length) % length
        swapOffset = off < swapCount ? off : 0
    }

    func continueSwap(maxFrames: Int) {
        guard swapping else { return }
        var budget = maxFrames
        while budget > 0 && swapDone < swapCount {
            let o = (swapOffset + swapDone) % swapCount
            let idx = (swapStart + o) % length
            let a = bufL[idx]; bufL[idx] = undoL[idx]; undoL[idx] = a
            let b = bufR[idx]; bufR[idx] = undoR[idx]; undoR[idx] = b
            swapDone += 1; budget -= 1
        }
        if swapDone >= swapCount { swapping = false }
    }

    // MARK: - Audio

    @inline(__always) private func read(_ pos: Double, exact: Bool) -> (Float, Float) {
        if exact {
            var i = Int(pos)
            if settings.reverse { i = length - 1 - i }
            return (bufL[i], bufR[i])
        }
        var p = settings.reverse ? Double(length) - 1 - pos : pos
        if p < 0 { p += Double(length) }
        let i0 = Int(p); let f = Float(p - Double(i0))
        let i1 = i0 + 1 >= length ? 0 : i0 + 1
        return (bufL[i0] + (bufL[i1] - bufL[i0]) * f, bufR[i0] + (bufR[i1] - bufR[i0]) * f)
    }

    /// Renders one block. `inL/inR` is what would be recorded (already routed);
    /// `outL/outR` receives the track's playback (pre level/pan/FX).
    func process(_ n: Int, _ b: TrackBlock,
                 inL: UnsafePointer<Float>, inR: UnsafePointer<Float>,
                 outL: UnsafeMutablePointer<Float>, outR: UnsafeMutablePointer<Float>,
                 onLoopWrap: (Int) -> Void) {
        outL.update(repeating: 0, count: n); outR.update(repeating: 0, count: n)
        var pk: Float = 0

        switch state {
        case .empty:
            peak = 0; return

        case .stopped:
            // A take that was stopped while its tail was still being captured.
            if finishActive {
                for i in 0..<n where finishActive { _ = finishCaptureSample(inL[i], inR[i]) }
            }
            peak = 0; return

        case .recStandby, .recording:
            var i = 0
            while i < n {
                let song = b.songStart + Double(i) * b.ratio
                if state == .recStandby {
                    if let boundary = standbyBoundary {
                        if song + 1e-9 >= boundary { beginRecording(at: boundary, ratio: b.ratio, latency: recLatency, absFrame: b.blockStartFrame + i, block: b) }
                    } else if max(abs(inL[i]), abs(inR[i])) >= b.autoRecThreshold {
                        beginRecording(at: song, ratio: b.ratio, latency: recLatency, absFrame: b.blockStartFrame + i, block: b)
                    }
                    if state == .recStandby { i += 1; continue }
                }
                let w = recFrames - recLatency
                if w >= 0 && w < capacity { bufL[w] = inL[i]; bufR[w] = inR[i] }
                else if w < 0 && w >= -LoopTrack.seam { preL[LoopTrack.seam + w] = inL[i]; preR[LoopTrack.seam + w] = inR[i] }
                recFrames += 1
                pk = max(pk, abs(inL[i]))
                if let t = recTarget, recFrames >= t { completeRecording(target: t) }
                else if recFrames - recLatency >= capacity { completeRecording(target: capacity) }
                i += 1
                if state != .recording && state != .recStandby {
                    // continue the rest of the block as playback
                    if i < n && isPlaying { playbackSegment(from: i, n, b, inL, inR, outL, outR, &pk, onLoopWrap) }
                    break
                }
            }
            lastPos = Double(max(0, recFrames - recLatency))
            peak = pk
            return

        case .playing, .overdubbing, .stopping:
            playbackSegment(from: 0, n, b, inL, inR, outL, outR, &pk, onLoopWrap)
            peak = pk
        }
    }

    /// Captures one more input sample after the loop length was fixed. Returns true if the
    /// sample was written inside the loop body (so an overdub must not write it again).
    @inline(__always) private func finishCaptureSample(_ l: Float, _ r: Float) -> Bool {
        let w = recFrames - recLatency
        recFrames += 1
        var body = false
        if w >= 0 && w < length {
            bufL[w] = l; bufR[w] = r; body = true
        }
        if w + 1 >= finishEnd { finishActive = false; applySeam() }
        return body
    }

    private func playbackSegment(from start: Int, _ n: Int, _ b: TrackBlock,
                                 _ inL: UnsafePointer<Float>, _ inR: UnsafePointer<Float>,
                                 _ outL: UnsafeMutablePointer<Float>, _ outR: UnsafeMutablePointer<Float>,
                                 _ pk: inout Float, _ onLoopWrap: (Int) -> Void) {
        guard length > 0 else { return }
        let len = Double(length)
        let r = rate(b)
        var pos: Double
        if settings.tempoSync {
            let song = b.songStart + Double(start) * b.ratio
            pos = (song - anchor) * scale * settings.speed.factor
        } else {
            pos = freePos
        }
        if !settings.oneShot { pos = pos.truncatingRemainder(dividingBy: len); if pos < 0 { pos += len } }
        // Snap tiny floating error so rate-1 playback stays sample exact.
        let rounded = pos.rounded()
        if abs(pos - rounded) < 1e-6 { pos = rounded }
        if pos >= len && !settings.oneShot { pos -= len }
        let exact = r == 1.0 && pos == pos.rounded()
        let dubbing = state == .overdubbing && exact && canOverdub

        var i = start
        while i < n {
            if settings.oneShot && pos >= len {
                state = .stopped; gain = Smoother(0); break
            }
            let g = gain.next()
            var (l, rr) = read(pos, exact: exact)
            if state == .overdubbing && settings.dubMode == .replace2 { l = 0; rr = 0 }
            outL[i] = l * g; outR[i] = rr * g
            pk = max(pk, abs(outL[i]), abs(outR[i]))

            // finish capturing the end of the take (latency compensation + seam crossfade)
            let finishedThisSample = finishActive ? finishCaptureSample(inL[i], inR[i]) : false

            if dubbing && !finishedThisSample {
                var wi = Int(pos) - recLatency
                if wi < 0 { wi += length }
                if dubCount == 0 { dubStart = wi }
                if dubCount < length { undoL[wi] = bufL[wi]; undoR[wi] = bufR[wi]; dubCount += 1 }
                switch settings.dubMode {
                case .overdub: bufL[wi] += inL[i]; bufR[wi] += inR[i]
                case .replace1, .replace2: bufL[wi] = inL[i]; bufR[wi] = inR[i]
                }
            }

            pos += r
            if pos >= len && !settings.oneShot {
                pos -= len
                if pendingStop == .loopEnd { state = .stopped; gain = Smoother(0); pendingStop = .none; i += 1; break }
                onLoopWrap(index)
            }
            if pendingStop == .fade && !gain.isRamping && gain.value <= 0 {
                state = .stopped; pendingStop = .none; i += 1; break
            }
            i += 1
        }
        if !settings.tempoSync { freePos = pos }
        lastPos = min(pos, len)
    }

    // MARK: - Main-thread helpers (only while the engine has the track suspended)

    /// Copies audio into the track. Caller guarantees the audio thread isn't using it.
    public func load(left: [Float], right: [Float], measures: Double, scale: Double = 1) {
        let n = min(left.count, capacity)
        left.withUnsafeBufferPointer { bufL.update(from: $0.baseAddress!, count: n) }
        right.withUnsafeBufferPointer { bufR.update(from: $0.baseAddress!, count: min(n, right.count)) }
        length = n; self.measures = measures; self.scale = scale; anchor = 0; freePos = 0
        gain = Smoother(0); pendingStop = .none; finishActive = false; recTarget = nil
        state = n > 0 ? .stopped : .empty
        undoKind = .none; undoAvailable = false; redoAvailable = false
    }

    public func copyAudio() -> (left: [Float], right: [Float]) {
        guard length > 0 else { return ([], []) }
        return (Array(UnsafeBufferPointer(start: bufL, count: length)), Array(UnsafeBufferPointer(start: bufR, count: length)))
    }
}
