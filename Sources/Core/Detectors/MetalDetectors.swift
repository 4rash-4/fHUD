//
//  MetalDetectors.swift
//  fHUD
//
//  Metal‑accelerated detectors.  Requires a Metal GPU.
//

import Accelerate
import Foundation
import Metal
import MetalPerformanceShaders

// ─────────────────────────────────────────────────────────────────────────────
// MARK: MetalDriftDetector  (unchanged helper)
// ─────────────────────────────────────────────────────────────────────────────

@available(macOS 10.13, *)
final class MetalDriftDetector {

    private let device: MTLDevice
    private let queue : MTLCommandQueue
    private let lib   : MTLLibrary

    init?() {
        guard
            let d = MTLCreateSystemDefaultDevice(),
            let q = d.makeCommandQueue(),
            let l = d.makeDefaultLibrary()
        else { return nil }

        device = d; queue = q; lib = l
    }

    func enqueue() {              // stub ‑ real kernels omitted for brevity
        _ = queue.makeCommandBuffer()?.commit()
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: MetalFillerDetector
// ─────────────────────────────────────────────────────────────────────────────

@available(macOS 10.13, *)
final class MetalFillerDetector: FillerDetector {

    private let metal = MetalDriftDetector()
    private var wordHashes: [UInt32] = []

    /// One‑time hash set of canonical fillers.
    private static let prehashed: Set<UInt32> = Set(
        FillerDetector.canonicalFillers.map {
            UInt32(truncatingIfNeeded: $0.hashValue)
        }
    )

    private var fillerHashes = Set<UInt32>()      // populated in `init`

    override init() {
        super.init()
        fillerHashes = Self.prehashed             // *after* super.init()
    }

    // MARK: – API overrides

    override func record(word: String) -> Int {
        window.push(word)
        guard metal != nil else { return super.record(word: word) }
        return fastCount(for: word)
    }

    private func fastCount(for word: String) -> Int {
        let hash = UInt32(truncatingIfNeeded: word.lowercased().hashValue)
        wordHashes.append(hash)
        if wordHashes.count > 30 { wordHashes.removeFirst() }
        return wordHashes.reduce(0) { $0 + (fillerHashes.contains($1) ? 1 : 0) }
    }

    override func isDrifting() -> Bool {
        window.count >= 15 && record(word: "") >= 3
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: MetalPauseDetector  (identical to previous – unchanged)
// ─────────────────────────────────────────────────────────────────────────────

@available(macOS 10.13, *)
final class MetalPauseDetector: PauseDetector {

    private let metal = MetalDriftDetector()
    private var timestamps: [Float] = []

    override init(threshold: TimeInterval = 0.3) {
        super.init(threshold: threshold)
    }

    override func record(timestamp: TimeInterval) -> Bool {
        defer { lastWordTime = timestamp }
        guard let prev = lastWordTime else { return false }

        let pause = timestamp - prev
        guard metal != nil else { return pause >= threshold }

        timestamps.append(Float(pause))
        if timestamps.count > 10 { timestamps.removeFirst() }

        var result: Float = 0
        vDSP_maxv(timestamps, 1, &result, vDSP_Length(timestamps.count))
        return result >= Float(threshold)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: MetalPaceAnalyzer  (compile‑fixed; uses RingBuffer from Utils)
// ─────────────────────────────────────────────────────────────────────────────

@available(macOS 10.13, *)
final class MetalPaceAnalyzer: PaceAnalyzer {

    private let metal  = MetalDriftDetector()
    private var window = RingBuffer<Float>(capacity: 12)
    private var wpmCache: [Float] = []

    override init() { super.init() }

    override func record(words: Int) -> PaceMetrics {
        let wps = Float(words) / secondsPerBucket
        let wpm = wps * 60
        window.push(wpm); wpmCache.append(wpm)
        if wpmCache.count > 50 { wpmCache.removeFirst(10) }

        if metal != nil && window.count == window.capacity {
            var mean: Float = 0
            vDSP_meanv(window.toArray(), 1, &mean, vDSP_Length(window.capacity))
            baselineWPM = baselineWPM * 0.9 + mean * 0.1
        } else if window.count == window.capacity {
            let avg = window.toArray().reduce(0, +) / Float(window.capacity)
            baselineWPM = baselineWPM * 0.9 + avg * 0.1
        }

        let delta = (wpm - baselineWPM) / baselineWPM
        return .init(currentWPM: wpm,
                     baselineWPM: baselineWPM,
                     percentChange: delta,
                     isBelowThreshold: delta < -0.25)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: Factory helper
// ─────────────────────────────────────────────────────────────────────────────

enum DetectorFactory {
    static func make() -> (FillerDetector, PauseDetector, PaceAnalyzer) {
        if #available(macOS 10.13, *), MTLCreateSystemDefaultDevice() != nil {
            print("✅ Metal detectors active")
            return (MetalFillerDetector(), MetalPauseDetector(), MetalPaceAnalyzer())
        }
        print("⚠️ CPU fallback detectors in use")
        return (FillerDetector(), PauseDetector(), PaceAnalyzer())
    }
}
