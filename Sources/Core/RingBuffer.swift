// MARK: - RingBuffer.swift

// Thread-safe generic circular buffer for real-time signal data

import Foundation

/// Thread-safe FIFO ring buffer. Keeps the last `capacity` elements.
public final class RingBuffer<Element> {
    private let lock = NSLock()
    private var store: [Element?]
    private var writeIndex = 0
    private var readIndex = 0
    public private(set) var count = 0
    public let capacity: Int

    public init(capacity: Int) {
        precondition(capacity > 0, "Capacity must be > 0")
        self.capacity = capacity
        store = Array(repeating: nil, count: capacity)
    }

    /// Append a new element, dropping the oldest if full.
    public func push(_ element: Element) {
        lock.lock()
        defer { lock.unlock() }

        store[writeIndex] = element
        writeIndex = (writeIndex + 1) % capacity

        if count < capacity {
            count += 1
        } else {
            // Buffer is full, advance read index
            readIndex = (readIndex + 1) % capacity
        }
    }

    /// Push multiple elements efficiently
    public func pushAll(_ elements: [Element]) {
        lock.lock()
        defer { lock.unlock() }

        for element in elements {
            store[writeIndex] = element
            writeIndex = (writeIndex + 1) % capacity

            if count < capacity {
                count += 1
            } else {
                readIndex = (readIndex + 1) % capacity
            }
        }
    }

    /// Return elements in time-order, oldest → newest.
    public func toArray() -> [Element] {
        lock.lock()
        defer { lock.unlock() }

        var result: [Element] = []
        result.reserveCapacity(count)

        var index = readIndex
        for _ in 0 ..< count {
            if let element = store[index] {
                result.append(element)
            }
            index = (index + 1) % capacity
        }

        return result
    }

    /// Get the most recent N elements (newest first)
    public func recent(_ n: Int) -> [Element] {
        lock.lock()
        defer { lock.unlock() }

        let itemsToGet = min(n, count)
        var result: [Element] = []
        result.reserveCapacity(itemsToGet)

        // Start from the most recent element
        var index = (writeIndex - 1 + capacity) % capacity

        for _ in 0 ..< itemsToGet {
            if let element = store[index] {
                result.append(element)
            }
            index = (index - 1 + capacity) % capacity
        }

        return result
    }

    /// Peek at the oldest element without removing it
    public func peekOldest() -> Element? {
        lock.lock()
        defer { lock.unlock() }

        return count > 0 ? store[readIndex] : nil
    }

    /// Peek at the newest element without removing it
    public func peekNewest() -> Element? {
        lock.lock()
        defer { lock.unlock() }

        if count == 0 { return nil }
        let newestIndex = (writeIndex - 1 + capacity) % capacity
        return store[newestIndex]
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }

        store = Array(repeating: nil, count: capacity)
        writeIndex = 0
        readIndex = 0
        count = 0
    }

    /// Check if buffer is empty
    public var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return count == 0
    }

    /// Check if buffer is full
    public var isFull: Bool {
        lock.lock()
        defer { lock.unlock() }
        return count == capacity
    }
}

// MARK: - Sendable Conformance for Swift Concurrency

extension RingBuffer: @unchecked Sendable where Element: Sendable {}
