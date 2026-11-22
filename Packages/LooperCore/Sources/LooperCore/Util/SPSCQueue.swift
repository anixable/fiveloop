import Atomics

/// Lock-free single-producer / single-consumer ring buffer.
///
/// Used for every UI → audio-thread and audio-thread → UI message.
/// `push` must only be called from one thread and `pop` from one (other) thread.
/// Neither side allocates or blocks after initialisation.
public final class SPSCQueue<Element> {
    private let storage: UnsafeMutablePointer<Element?>
    private let mask: Int
    public let capacity: Int
    private let head = ManagedAtomic<Int>(0) // next index to read  (consumer owns)
    private let tail = ManagedAtomic<Int>(0) // next index to write (producer owns)

    public init(capacity requested: Int) {
        var cap = 2
        while cap < requested { cap <<= 1 }
        capacity = cap
        mask = cap - 1
        storage = .allocate(capacity: cap)
        storage.initialize(repeating: nil, count: cap)
    }

    deinit {
        storage.deinitialize(count: capacity)
        storage.deallocate()
    }

    /// Producer side. Returns false if the queue is full (message dropped).
    @discardableResult
    public func push(_ value: Element) -> Bool {
        let t = tail.load(ordering: .relaxed)
        let h = head.load(ordering: .acquiring)
        if t - h >= capacity { return false }
        storage[t & mask] = value
        tail.store(t + 1, ordering: .releasing)
        return true
    }

    /// Consumer side.
    public func pop() -> Element? {
        let h = head.load(ordering: .relaxed)
        let t = tail.load(ordering: .acquiring)
        if h == t { return nil }
        let v = storage[h & mask]
        storage[h & mask] = nil
        head.store(h + 1, ordering: .releasing)
        return v
    }

    public var isEmpty: Bool {
        head.load(ordering: .acquiring) == tail.load(ordering: .acquiring)
    }
}
