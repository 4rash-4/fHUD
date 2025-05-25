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
    private var baselineWPM: Float = 150        // default
    private let window = RingBuffer<Float>(capacity: 12)  // 12 × 5-sec = 1 min
    private let secondsPerBucket: Float = 5

    /// Feed number of *words* spoken during the last 5 seconds.
    public func record(words: Int) -> PaceMetrics {
        let wps = Float(words) / secondsPerBucket      // words per second
        window.push(wps * 60)                          // → WPM

        // update baseline once we have a full minute
        if window.count == window.capacity {
            let avg = window.toArray().reduce(0, +) / Float(window.capacity)
            baselineWPM = (baselineWPM * 0.9) + (avg * 0.1)   // slow drift
        }

        let current = window.toArray().last ?? 0
        let change = (current - baselineWPM) / baselineWPM
        return PaceMetrics(
            currentWPM: current,
            baselineWPM: baselineWPM,
            percentChange: change,
            isBelowThreshold: change < -0.25                 // 25 % slower
        )
    }
}
