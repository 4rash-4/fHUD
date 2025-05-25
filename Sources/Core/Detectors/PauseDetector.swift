// MARK: - PauseDetector.swift
// Detects silences ≥ 0.3 s between words.

import Foundation

public final class PauseDetector {
    private let threshold: TimeInterval
    private var lastWordTime: TimeInterval?

    public init(threshold: TimeInterval = 0.3) {
        self.threshold = threshold
    }

    /// Call whenever a new word *finishes* (timestamp = audio time).
    public func record(timestamp: TimeInterval) -> Bool {
        defer { lastWordTime = timestamp }
        guard let prev = lastWordTime else { return false }
        return (timestamp - prev) >= threshold
    }
}
