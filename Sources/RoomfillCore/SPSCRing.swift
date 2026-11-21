import Synchronization

/// Lock-free float ring for exactly one producer thread and one consumer thread.
public final class SPSCFloatRing: @unchecked Sendable {
    public let capacity: Int
    private let buffer: UnsafeMutablePointer<Float>
    private let written = Atomic<Int>(0)
    private let consumed = Atomic<Int>(0)

    public init(capacity: Int) {
        self.capacity = capacity
        buffer = .allocate(capacity: capacity)
        buffer.initialize(repeating: 0, count: capacity)
    }

    deinit {
        buffer.deallocate()
    }

    public var availableToRead: Int {
        written.load(ordering: .acquiring) - consumed.load(ordering: .acquiring)
    }

    /// Producer side. Writes up to `count` samples and returns how many fit; the rest are dropped.
    public func write(_ src: UnsafePointer<Float>, count: Int) -> Int {
        let w = written.load(ordering: .relaxed)
        let r = consumed.load(ordering: .acquiring)
        let n = min(count, capacity - (w - r))
        guard n > 0 else { return 0 }
        let start = w % capacity
        let first = min(n, capacity - start)
        (buffer + start).update(from: src, count: first)
        if n > first { buffer.update(from: src + first, count: n - first) }
        written.store(w + n, ordering: .releasing)
        return n
    }

    /// Consumer side. Reads up to `count` samples and returns how many were available.
    public func read(into dst: UnsafeMutablePointer<Float>, count: Int) -> Int {
        let r = consumed.load(ordering: .relaxed)
        let w = written.load(ordering: .acquiring)
        let n = min(count, w - r)
        guard n > 0 else { return 0 }
        let start = r % capacity
        let first = min(n, capacity - start)
        dst.update(from: buffer + start, count: first)
        if n > first { (dst + first).update(from: buffer, count: n - first) }
        consumed.store(r + n, ordering: .releasing)
        return n
    }
}
