// MARK: - PauseDetector.swift

//
// Simple drift detector that records the time between spoken words.
// If a pause longer than the configured threshold (default 0.3 s) is
// observed it signals potential loss of focus.

import Foundation

public class PauseDetector {
    // Expose properties for subclasses
    let threshold: TimeInterval
    var lastWordTime: TimeInterval?
    // Pre-calculate threshold comparison
    var thresholdComparison: TimeInterval

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
