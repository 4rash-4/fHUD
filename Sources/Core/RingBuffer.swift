// MARK: - RingBuffer.swift

//
// Simple thread‑safe FIFO ring buffer used throughout the project for
// sliding window calculations.  It is `Sendable` so it can be shared
// across actor contexts.

import Foundation

/// Thread-safe FIFO ring buffer. Keeps the last `capacity` elements.
public final class RingBuffer<Element> {
    private var buffer: [Element?]
    private var head: Int = 0
    private var tail: Int = 0

    /// Number of elements currently stored (thread‑safe read)
    public private(set) var count: Int = 0

    /// Maximum size of the ring (immutable after init)
    public let capacity: Int

    // Use a more efficient lock
    private let lock = NSLock()

    public init(capacity: Int) {
        self.capacity = capacity
        buffer = Array(repeating: nil, count: capacity)
    }

    @discardableResult
    public func push(_ element: Element) -> Bool {
        return lock.withLock {
            buffer[tail] = element
            tail = (tail + 1) % capacity

            if count < capacity {
                count += 1
            } else {
                // Buffer is full, move head
                head = (head + 1) % capacity
            }
            return true
        }
    }

    public func pushMultiple(_ elements: [Element]) {
        lock.withLock {
            for element in elements {
                buffer[tail] = element
                tail = (tail + 1) % capacity

                if count < capacity {
                    count += 1
                } else {
                    head = (head + 1) % capacity
                }
            }
        }
    }

    public func toArray() -> [Element] {
        return lock.withLock {
            guard count > 0 else { return [] }

            var result: [Element] = []
            result.reserveCapacity(count)

            var index = head
            for _ in 0 ..< count {
                if let element = buffer[index] {
                    result.append(element)
                }
                index = (index + 1) % capacity
            }
            return result
        }
    }

    public func recent(_ n: Int) -> [Element] {
        return lock.withLock {
            let actualN = min(n, count)
            guard actualN > 0 else { return [] }

            var result: [Element] = []
            result.reserveCapacity(actualN)

            var index = (tail - actualN + capacity) % capacity
            for _ in 0 ..< actualN {
                if let element = buffer[index] {
                    result.append(element)
                }
                index = (index + 1) % capacity
            }
            return result
        }
    }

    public var isEmpty: Bool {
        return lock.withLock { count == 0 }
    }

    public var isFull: Bool {
        return lock.withLock { count == capacity }
    }

    /// Current number of elements in the buffer
    public var countValue: Int {
        return lock.withLock { count }
    }
}

// Extension for NSLock convenience
extension NSLock {
    func withLock<T>(_ block: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try block()
    }
}

// MARK: - Sendable Conformance for Swift Concurrency

extension RingBuffer: @unchecked Sendable where Element: Sendable {}
