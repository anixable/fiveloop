import Foundation

/// One effect slot ([A]–[D] button). Lives on the audio thread.
public final class FXSlotRuntime {
    public var processor: FXProcessor?
    public var on = false
    /// -1 = ALL, 0…4 = TRACK1–5 (Track FX INSERT parameter). Ignored for Input FX.
    public var insert = -1
    private var mix = Smoother(0)
    private let dryL: UnsafeMutablePointer<Float>, dryR: UnsafeMutablePointer<Float>
    private let maxFrames: Int

    init(maxFrames: Int) {
        self.maxFrames = maxFrames
        dryL = .allocate(capacity: maxFrames); dryR = .allocate(capacity: maxFrames)
        dryL.initialize(repeating: 0, count: maxFrames); dryR.initialize(repeating: 0, count: maxFrames)
    }
    deinit { dryL.deallocate(); dryR.deallocate() }

    func setOn(_ v: Bool, sampleRate: Double) {
        if v && !on { processor?.reset() }
        on = v
        mix.set(v ? 1 : 0, frames: Int(sampleRate * 0.008)) // 8 ms click-free switch
    }

    var isActive: Bool { processor != nil && (on || mix.value > 0 || mix.isRamping) }

    func process(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ n: Int, _ ctx: FXContext) {
        guard let p = processor, isActive else { return }
        let fullyOn = !mix.isRamping && mix.value >= 1
        if !fullyOn { dryL.update(from: l, count: n); dryR.update(from: r, count: n) }
        p.render(l, r, n, ctx)
        if !fullyOn {
            for i in 0..<n {
                let g = mix.next()
                l[i] = dryL[i] + (l[i] - dryL[i]) * g
                r[i] = dryR[i] + (r[i] - dryR[i]) * g
            }
        }
    }
}

public enum FXBankMode: String, Codable { case single, multi }

/// Four banks (A–D) × four slots (A–D), as on the hardware.
public final class FXRack {
    public static let banks = 4, slotsPerBank = 4
    public var activeBank = 0
    public var bankOn = true
    public var mode: FXBankMode = .multi
    public let slots: [[FXSlotRuntime]]

    init(maxFrames: Int) {
        slots = (0..<FXRack.banks).map { _ in (0..<FXRack.slotsPerBank).map { _ in FXSlotRuntime(maxFrames: maxFrames) } }
    }

    func setSlotOn(bank: Int, slot: Int, on: Bool, sampleRate: Double) {
        guard bank >= 0, bank < FXRack.banks, slot >= 0, slot < FXRack.slotsPerBank else { return }
        if on && mode == .single {
            for s in 0..<FXRack.slotsPerBank where s != slot && slots[bank][s].on { slots[bank][s].setOn(false, sampleRate: sampleRate) }
        }
        slots[bank][slot].setOn(on, sampleRate: sampleRate)
    }

    /// Process every slot of the active bank whose insert matches `insert` (nil = any).
    func process(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ n: Int, _ ctx: FXContext, insert: Int? = nil) {
        guard bankOn else { return }
        for s in slots[activeBank] where insert == nil || s.insert == insert! {
            s.process(l, r, n, ctx)
        }
    }

    func hasActive(insert: Int) -> Bool {
        guard bankOn else { return false }
        for s in slots[activeBank] where s.insert == insert && s.isActive { return true }
        return false
    }
}
