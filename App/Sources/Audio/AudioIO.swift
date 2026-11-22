import AVFoundation
import AudioToolbox
import Atomics
import LooperCore

/// Low-latency duplex audio through the RemoteIO unit. The render callback pulls the
/// input bus, runs the LooperEngine and writes the output – all on the real-time thread,
/// without locks, allocation or Objective-C messaging.
final class AudioIO: NSObject {
    static let sampleRate: Double = 44100
    static let maxFrames = 4096

    let engine: LooperEngine
    /// Timed MIDI clock bytes for the MIDI thread: (hostTime, status byte).
    let midiTimed = SPSCQueue<(UInt64, UInt8)>(capacity: 4096)

    private var unit: AudioUnit?
    private let inL: UnsafeMutablePointer<Float>, inR: UnsafeMutablePointer<Float>
    private let inputList: UnsafeMutableAudioBufferListPointer
    private(set) var inputChannels: UInt32 = 1
    private var hostTicksPerFrame: Double = 0
    private var outputLatencyTicks: UInt64 = 0

    // diagnostics (written on the audio thread)
    private let cpuBits = ManagedAtomic<UInt32>(0)
    private let lastFrames = ManagedAtomic<Int>(0)
    private let overloads = ManagedAtomic<Int>(0)
    private let inputErrors = ManagedAtomic<Int>(0)

    private(set) var isRunning = false
    var onStateChange: (() -> Void)?

    init(engine: LooperEngine) {
        self.engine = engine
        inL = .allocate(capacity: AudioIO.maxFrames); inR = .allocate(capacity: AudioIO.maxFrames)
        inL.initialize(repeating: 0, count: AudioIO.maxFrames); inR.initialize(repeating: 0, count: AudioIO.maxFrames)
        inputList = AudioBufferList.allocate(maximumBuffers: 2)
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        // host ticks per audio frame
        hostTicksPerFrame = (1e9 / AudioIO.sampleRate) * Double(info.denom) / Double(info.numer)
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(interruption(_:)),
                                               name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(routeChange(_:)),
                                               name: AVAudioSession.routeChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(mediaReset(_:)),
                                               name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
    }

    deinit {
        stop()
        inL.deallocate(); inR.deallocate()
        free(inputList.unsafeMutablePointer)
    }

    // MARK: - Session

    func configureSession(preferredBufferFrames: Int) throws {
        let s = AVAudioSession.sharedInstance()
        try s.setCategory(.playAndRecord, mode: .default,
                          options: [.defaultToSpeaker, .allowBluetoothA2DP, .mixWithOthers])
        try s.setPreferredSampleRate(AudioIO.sampleRate)
        try s.setPreferredIOBufferDuration(Double(preferredBufferFrames) / AudioIO.sampleRate)
        try s.setActive(true)
        if s.isInputGainSettable { try? s.setInputGain(1.0) }
    }

    static func requestMicrophone(_ done: @escaping (Bool) -> Void) {
        AVAudioSession.sharedInstance().requestRecordPermission { ok in DispatchQueue.main.async { done(ok) } }
    }

    // MARK: - RemoteIO

    func start() throws {
        if unit == nil { try buildUnit() }
        guard let u = unit else { return }
        try check(AudioOutputUnitStart(u), "start")
        isRunning = true
        updateLatency()
        onStateChange?()
    }

    func stop() {
        if let u = unit { AudioOutputUnitStop(u) }
        isRunning = false
        onStateChange?()
    }

    private func teardown() {
        if let u = unit {
            AudioOutputUnitStop(u); AudioUnitUninitialize(u); AudioComponentInstanceDispose(u)
        }
        unit = nil; isRunning = false
    }

    private func buildUnit() throws {
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_RemoteIO,
                                             componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else { throw AudioIOError.failed("RemoteIO not found", 0) }
        var u: AudioUnit?
        try check(AudioComponentInstanceNew(comp, &u), "new")
        guard let au = u else { throw AudioIOError.failed("RemoteIO instance", 0) }

        let session = AVAudioSession.sharedInstance()
        let hasInput = session.isInputAvailable
        var one: UInt32 = 1
        var enableIn: UInt32 = hasInput ? 1 : 0
        try check(AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1,
                                       &enableIn, UInt32(MemoryLayout<UInt32>.size)), "enable input")
        try check(AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0,
                                       &one, UInt32(MemoryLayout<UInt32>.size)), "enable output")

        var out = AudioIO.format(channels: 2)
        try check(AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                                       &out, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "out format")
        inputChannels = hasInput ? UInt32(max(1, min(2, session.inputNumberOfChannels))) : 0
        if hasInput {
            var inf = AudioIO.format(channels: inputChannels)
            try check(AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
                                           &inf, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "in format")
        }
        var maxF = UInt32(AudioIO.maxFrames)
        try check(AudioUnitSetProperty(au, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
                                       &maxF, UInt32(MemoryLayout<UInt32>.size)), "max frames")
        var cb = AURenderCallbackStruct(inputProc: audioRenderCallback,
                                        inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try check(AudioUnitSetProperty(au, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                                       &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "callback")
        try check(AudioUnitInitialize(au), "initialize")
        unit = au
    }

    static func format(channels: UInt32) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
                                    mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagIsPacked,
                                    mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                                    mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)
    }

    private func check(_ status: OSStatus, _ what: String) throws {
        if status != noErr { throw AudioIOError.failed(what, status) }
    }

    /// Rebuilds the unit (e.g. after the input channel count changed).
    func restart() {
        let wasRunning = isRunning
        teardown()
        if wasRunning { try? start() }
    }

    func updateLatency() {
        let s = AVAudioSession.sharedInstance()
        let seconds = s.inputLatency + s.outputLatency + 2 * s.ioBufferDuration
        latencySeconds = seconds
        engine.send(.latency(Int((seconds + manualLatencyOffset) * AudioIO.sampleRate)))
        outputLatencyTicks = UInt64(max(0, s.outputLatency + s.ioBufferDuration) * AudioIO.sampleRate * hostTicksPerFrame)
    }
    private(set) var latencySeconds: Double = 0
    /// User calibration (seconds, may be negative). Main thread.
    var manualLatencyOffset: Double = 0 { didSet { updateLatency() } }

    // MARK: - Render (real-time thread)

    fileprivate func render(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                            _ ts: UnsafePointer<AudioTimeStamp>, _ frames: UInt32,
                            _ ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
        let t0 = mach_absolute_time()
        guard let ioData = ioData, let au = unit else { return noErr }
        let n = Int(min(frames, UInt32(AudioIO.maxFrames)))
        var haveInput = false
        if inputChannels > 0 {
            inputList.count = Int(inputChannels)
            inputList[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(n * 4), mData: UnsafeMutableRawPointer(inL))
            if inputChannels > 1 {
                inputList[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(n * 4), mData: UnsafeMutableRawPointer(inR))
            }
            let st = AudioUnitRender(au, flags, ts, 1, UInt32(n), inputList.unsafeMutablePointer)
            if st == noErr { haveInput = true } else { inputErrors.wrappingIncrement(ordering: .relaxed) }
        }
        let out = UnsafeMutableAudioBufferListPointer(ioData)
        guard out.count >= 1, let d0 = out[0].mData else { return noErr }
        let oL = d0.assumingMemoryBound(to: Float.self)
        let oR = out.count > 1 ? (out[1].mData?.assumingMemoryBound(to: Float.self) ?? oL) : oL
        engine.process(frames: n,
                       inL: haveInput ? UnsafePointer(inL) : nil,
                       inR: haveInput ? (inputChannels > 1 ? UnsafePointer(inR) : UnsafePointer(inL)) : nil,
                       outL: oL, outR: oR)

        // forward MIDI clock with host-time stamps
        let base = ts.pointee.mHostTime &+ outputLatencyTicks
        while let ev = engine.midiOut.pop() {
            midiTimed.push((base &+ UInt64(Double(ev.frameOffset) * hostTicksPerFrame), ev.status))
        }

        let used = Double(mach_absolute_time() - t0)
        let budget = Double(n) * hostTicksPerFrame
        let load = Float(used / max(budget, 1))
        cpuBits.store(load.bitPattern, ordering: .relaxed)
        lastFrames.store(n, ordering: .relaxed)
        if load > 0.9 { overloads.wrappingIncrement(ordering: .relaxed) }
        return noErr
    }

    // MARK: - Diagnostics (main thread)

    struct Diagnostics {
        var cpu: Float; var bufferFrames: Int; var overloads: Int; var inputErrors: Int
        var sampleRate: Double; var hardwareRate: Double; var inputChannels: Int; var route: String; var latencyMs: Double
    }
    func diagnostics() -> Diagnostics {
        let s = AVAudioSession.sharedInstance()
        let route = (s.currentRoute.inputs.map { $0.portName } + ["→"] + s.currentRoute.outputs.map { $0.portName }).joined(separator: " ")
        return Diagnostics(cpu: Float(bitPattern: cpuBits.load(ordering: .relaxed)), bufferFrames: lastFrames.load(ordering: .relaxed),
                           overloads: overloads.load(ordering: .relaxed), inputErrors: inputErrors.load(ordering: .relaxed),
                           sampleRate: AudioIO.sampleRate, hardwareRate: s.sampleRate, inputChannels: Int(inputChannels),
                           route: route, latencyMs: latencySeconds * 1000)
    }

    var isHeadphoneOrInterfaceOutput: Bool {
        let external: [AVAudioSession.Port] = [.headphones, .usbAudio, .lineOut, .bluetoothA2DP, .bluetoothLE, .HDMI, .airPlay]
        return AVAudioSession.sharedInstance().currentRoute.outputs.contains { external.contains($0.portType) }
    }

    // MARK: - Session events

    @objc private func interruption(_ n: Notification) {
        guard let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        if type == .began {
            isRunning = false
            DispatchQueue.main.async { self.onStateChange?() }
        } else {
            DispatchQueue.main.async {
                try? AVAudioSession.sharedInstance().setActive(true)
                try? self.start()
            }
        }
    }

    @objc private func routeChange(_ n: Notification) {
        DispatchQueue.main.async {
            let s = AVAudioSession.sharedInstance()
            let wanted = s.isInputAvailable ? UInt32(max(1, min(2, s.inputNumberOfChannels))) : 0
            if wanted != self.inputChannels { self.restart() } else { self.updateLatency() }
            self.onStateChange?()
        }
    }

    @objc private func mediaReset(_ n: Notification) {
        DispatchQueue.main.async {
            self.teardown()
            try? self.configureSession(preferredBufferFrames: 256)
            try? self.start()
        }
    }
}

enum AudioIOError: LocalizedError {
    case failed(String, OSStatus)
    var errorDescription: String? {
        switch self { case .failed(let w, let s): return "Audio error (\(w)): \(s)" }
    }
}

private let audioRenderCallback: AURenderCallback = { refCon, flags, ts, _, frames, ioData in
    let io = Unmanaged<AudioIO>.fromOpaque(refCon).takeUnretainedValue()
    return io.render(flags, ts, frames, ioData)
}
