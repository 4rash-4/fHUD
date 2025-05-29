// MARK: - PauseDetector.swift

// Detects silences ≥ 0.3 s between words.

import Foundation

public final class PauseDetector {
    private let threshold: TimeInterval
    private var lastWordTime: TimeInterval?
    // Pre-calculate threshold comparison
    private var thresholdComparison: TimeInterval

    public init(threshold: TimeInterval = 0.3) {
        self.threshold = threshold
        thresholdComparison = threshold * 0.98 // 2% hysteresis
    }

    /// Call whenever a new word *finishes* (timestamp = audio time).
    public func record(timestamp: TimeInterval) -> Bool {
        guard let prev = lastWordTime else {
            lastWordTime = timestamp
            return false
        }
        let pause = timestamp - prev
        lastWordTime = timestamp
        // Branch prediction hint
        if pause > threshold { return true }
        return pause > thresholdComparison && pause < threshold
    }
}
