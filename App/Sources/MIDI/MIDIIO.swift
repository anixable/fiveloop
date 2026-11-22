import CoreMIDI
import Foundation
import LooperCore

/// CoreMIDI wrapper: connects every MIDI source (USB, network, Bluetooth once paired in
/// another app, virtual), publishes a virtual source/destination named "FiveLoop",
/// and sends sample-accurate MIDI clock produced by the engine.
final class MIDIIO {
    struct Endpoint: Identifiable, Hashable { let id: MIDIUniqueID; let name: String }

    private var client = MIDIClientRef()
    private var inPort = MIDIPortRef()
    private var outPort = MIDIPortRef()
    private var virtualSource = MIDIEndpointRef()
    private var virtualDest = MIDIEndpointRef()
    private var parser = MIDIParser()
    private var follower = ClockFollower()
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "fiveloop.midi", qos: .userInteractive)
    private weak var audio: AudioIO?

    /// Called on the main thread for every parsed message (except clock ticks).
    var onMessage: ((MIDIMessage) -> Void)?
    /// Called on the main thread when the incoming clock tempo changes.
    var onClockTempo: ((Double) -> Void)?
    var onSetupChanged: (() -> Void)?
    var clockOutEnabled = true
    var txChannel = 1
    private(set) var sources: [Endpoint] = []
    private(set) var destinations: [Endpoint] = []
    private(set) var lastClockTime: Double = 0

    init(audio: AudioIO) { self.audio = audio }

    func start() {
        let name = "FiveLoop" as CFString
        let status = MIDIClientCreateWithBlock(name, &client) { [weak self] note in
            if note.pointee.messageID == .msgSetupChanged {
                DispatchQueue.main.async { self?.connectAllSources(); self?.onSetupChanged?() }
            }
        }
        guard status == noErr else { return }
        MIDIInputPortCreateWithBlock(client, "FiveLoop In" as CFString, &inPort) { [weak self] list, _ in
            self?.receive(list)
        }
        MIDIOutputPortCreate(client, "FiveLoop Out" as CFString, &outPort)
        MIDISourceCreate(client, "FiveLoop" as CFString, &virtualSource)
        MIDIDestinationCreateWithBlock(client, "FiveLoop" as CFString, &virtualDest) { [weak self] list, _ in
            self?.receive(list)
        }
        connectAllSources()
        startClockPump()
    }

    func connectAllSources() {
        var src: [Endpoint] = []
        for i in 0..<MIDIGetNumberOfSources() {
            let ep = MIDIGetSource(i)
            if ep == virtualSource { continue }
            MIDIPortConnectSource(inPort, ep, nil)
            src.append(Endpoint(id: uniqueID(ep), name: displayName(ep)))
        }
        sources = src
        destinations = (0..<MIDIGetNumberOfDestinations()).compactMap {
            let ep = MIDIGetDestination($0)
            return ep == virtualDest ? nil : Endpoint(id: uniqueID(ep), name: displayName(ep))
        }
    }

    private func uniqueID(_ ep: MIDIObjectRef) -> MIDIUniqueID {
        var v: Int32 = 0; MIDIObjectGetIntegerProperty(ep, kMIDIPropertyUniqueID, &v); return v
    }
    private func displayName(_ ep: MIDIObjectRef) -> String {
        var s: Unmanaged<CFString>?
        MIDIObjectGetStringProperty(ep, kMIDIPropertyDisplayName, &s)
        return (s?.takeRetainedValue() as String?) ?? "MIDI"
    }

    // MARK: input (CoreMIDI thread)

    private func receive(_ list: UnsafePointer<MIDIPacketList>) {
        var msgs: [MIDIMessage] = []
        var tempo: Double? = nil
        for packet in list.unsafeSequence() {
            let bytes = Array(packet.bytes())
            let ts = packet.pointee.timeStamp
            let t = Double(ts == 0 ? mach_absolute_time() : ts) * MIDIIO.secondsPerTick
            for b in bytes {
                guard let m = parser.feed(b) else { continue }
                switch m {
                case .clock:
                    lastClockTime = t
                    if let bpm = follower.tick(at: t) { tempo = bpm }
                case .start, .continue: follower.reset(); msgs.append(m)
                default: msgs.append(m)
                }
            }
        }
        if msgs.isEmpty && tempo == nil { return }
        DispatchQueue.main.async { [weak self] in
            if let t = tempo { self?.onClockTempo?(t) }
            for m in msgs { self?.onMessage?(m) }
        }
    }

    static let secondsPerTick: Double = {
        var i = mach_timebase_info_data_t(); mach_timebase_info(&i)
        return Double(i.numer) / Double(i.denom) / 1e9
    }()

    // MARK: output

    func send(_ m: MIDIMessage, at hostTime: MIDITimeStamp = 0) {
        let bytes = MIDIParser.bytes(m)
        guard !bytes.isEmpty else { return }
        queue.async { self.sendBytes(bytes, at: hostTime) }
    }

    private func sendBytes(_ bytes: [UInt8], at time: MIDITimeStamp) {
        var list = MIDIPacketList()
        let pkt = MIDIPacketListInit(&list)
        _ = MIDIPacketListAdd(&list, MemoryLayout<MIDIPacketList>.size, pkt, time, bytes.count, bytes)
        for i in 0..<MIDIGetNumberOfDestinations() {
            let d = MIDIGetDestination(i)
            if d != virtualDest { MIDISend(outPort, d, &list) }
        }
        MIDIReceived(virtualSource, &list)
    }

    /// Drains the audio thread's timed clock events every 2 ms and schedules them.
    private func startClockPump() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(2), leeway: .microseconds(500))
        t.setEventHandler { [weak self] in
            guard let self = self, let audio = self.audio else { return }
            while let ev = audio.midiTimed.pop() {
                if self.clockOutEnabled || ev.1 != 0xF8 { self.sendBytes([ev.1], at: ev.0) }
            }
        }
        t.resume()
        timer = t
    }

    var externalClockActive: Bool {
        Double(mach_absolute_time()) * MIDIIO.secondsPerTick - lastClockTime < 0.5
    }
}
