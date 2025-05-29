// MARK: - PaceAnalyzer.swift

// Calculates live words-per-minute and flags slowdowns.

import Foundation

public struct PaceMetrics {
    public let currentWPM: Float
    public let baselineWPM: Float
    public let percentChange: Float
    public let isBelowThreshold: Bool
}

public final class PaceAnalyzer {
    private var baselineWPM: Float = 150 // default
    private var runningSum: Float = 0
    private var buffer: [Float] = []
    private let capacity = 12
    private let secondsPerBucket: Float = 5

    /// Feed number of *words* spoken during the last 5 seconds.
    public func record(words: Int) -> PaceMetrics {
        let currentWPM = Float(words) / secondsPerBucket * 60
        // Maintain running sum instead of full reduce
        if buffer.count == capacity {
            runningSum -= buffer.removeFirst()
        }
        buffer.append(currentWPM)
        runningSum += currentWPM
        // Update baseline only when buffer is full
        if buffer.count == capacity {
            let avg = runningSum / Float(capacity)
            baselineWPM = (baselineWPM * 0.9) + (avg * 0.1) // slow drift
        }
        let change = (currentWPM - baselineWPM) / baselineWPM
        return PaceMetrics(
            currentWPM: currentWPM,
            baselineWPM: baselineWPM,
            percentChange: change,
            isBelowThreshold: change < -0.25 // 25 % slower
        )
    }
}
