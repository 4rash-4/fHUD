// MARK: - RingBuffer.swift
// Lightweight generic circular buffer for real-time signal data.

import Foundation

/// Simple FIFO ring buffer. Keeps the last `capacity` elements.
public final class RingBuffer<Element> {
    private var store: [Element?]
    private var idx = 0
    public private(set) var count = 0
    public let capacity: Int

    public init(capacity: Int) {
        precondition(capacity > 0, "Capacity must be > 0")
        self.capacity = capacity
        self.store = Array(repeating: nil, count: capacity)
    }

    /// Append a new element, dropping the oldest if full.
    public func push(_ element: Element) {
        store[idx] = element
        idx = (idx + 1) % capacity
        if count < capacity { count += 1 }
    }

    /// Return elements in time-order, oldest → newest.
    public func toArray() -> [Element] {
        var out: [Element] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            let j = (idx + i) % capacity
            if let e = store[j] { out.append(e) }
        }
        return out
    }

    public func clear() {
        store.replaceSubrange(store.indices, with: repeatElement(nil, count: capacity))
        idx = 0
        count = 0
    }
}
