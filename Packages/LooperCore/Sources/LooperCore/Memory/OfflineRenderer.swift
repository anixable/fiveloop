import Foundation

/// Renders a memory faster than real time (mix-down and stems). Uses its own engine
/// instance, so it never touches the live audio thread. Main/background thread only.
public enum OfflineRenderer {
    public struct Options {
        public var repeats = 1
        public var includeRhythm = true
        public var soloTrack: Int? = nil        // render a single stem
        public var tailSeconds: Double = 0
        public init() {}
    }

    public static func render(_ memory: MemoryData, audio: [TrackAudio?], sampleRate: Double = 44100,
                              options: Options = Options()) -> TrackAudio {
        let longest = audio.compactMap { $0?.left.count }.max() ?? 0
        guard longest > 0 else { return ([], []) }
        let engine = LooperEngine(sampleRate: sampleRate, maxFrames: 1024,
                                  maxLoopSeconds: Double(longest) / sampleRate + 1)
        var m = memory
        m.mixer.monitor = false
        for i in 0..<5 {
            if let s = options.soloTrack { m.trackMeta[i].muted = (i != s) }
            m.tracks[i].allStartTarget = m.trackMeta[i].hasAudio && audio[i] != nil
            m.tracks[i].startMode = .immediate
        }
        engine.load(m, audio: audio, waitForSuspend: { engine.pumpCommands(); return true })
        engine.pumpCommands()
        if options.includeRhythm && m.rhythmOn && options.soloTrack == nil { engine.send(.rhythmOn(true)) }
        engine.send(.allStartStop)
        let total = longest * max(1, options.repeats) + Int(options.tailSeconds * sampleRate)
        var outL = [Float](repeating: 0, count: total), outR = [Float](repeating: 0, count: total)
        let chunk = 1024
        var done = 0
        outL.withUnsafeMutableBufferPointer { l in
            outR.withUnsafeMutableBufferPointer { r in
                while done < total {
                    let n = min(chunk, total - done)
                    engine.process(frames: n, inL: nil, inR: nil, outL: l.baseAddress! + done, outR: r.baseAddress! + done)
                    done += n
                }
            }
        }
        while engine.events.pop() != nil {}
        return (outL, outR)
    }
}
