// MARK: - PaceAnalyzer.swift
//
// Tracks speaking rate over a sliding window.  This lightweight analyzer
// forms part of the drift detection layer by monitoring words per minute
// and signalling when the user's pace drops more than 25 % below their
// baseline.

import Foundation

public struct PaceMetrics {
    public let currentWPM: Float
    public let baselineWPM: Float
    public let percentChange: Float
    public let isBelowThreshold: Bool
}

public class PaceAnalyzer {
    // Allow subclasses to reuse core properties
    var baselineWPM: Float = 150 // default
    var runningSum: Float = 0
    var buffer: [Float] = []
    let capacity = 12
    let secondsPerBucket: Float = 5

    public init() {}

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
