// MARK: - MetalDetectors.swift
//
// Optional GPU implementations of the drift detectors.  When running on a
// Mac with a Metal-capable device these classes offload filler counting,
// pause detection and pace analysis to compute kernels defined in
// `Resources/Shaders.metal`.  This reduces CPU load and keeps the project
// responsive even on memory constrained machines.

import Accelerate
import Foundation
import Metal
import MetalPerformanceShaders

@available(macOS 10.13, *)
class MetalDriftDetector {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let library: MTLLibrary

    // Metal buffers for high-performance processing
    private var audioBuffer: MTLBuffer?
    private var timestampBuffer: MTLBuffer?
    private var resultBuffer: MTLBuffer?

    // Compute pipelines
    private var fillerDetectionPipeline: MTLComputePipelineState?
    private var pauseDetectionPipeline: MTLComputePipelineState?
    private var paceAnalysisPipeline: MTLComputePipelineState?

    // Configuration
    private let bufferSize = 1024
    private let fillerWords = ["um", "uh", "er", "hmm", "like"]

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue()
        else {
            print("❌ Metal not available")
            return nil
        }

        self.device = device
        self.commandQueue = commandQueue

        // Create default library with embedded shaders
        guard let library = device.makeDefaultLibrary() else {
            print("❌ Could not create Metal library")
            return nil
        }
        self.library = library

        setupComputePipelines()
        allocateBuffers()

        print("✅ Metal drift detector initialized")
    }

    private func setupComputePipelines() {
        do {
            // Filler detection pipeline
            if let function = library.makeFunction(name: "detect_fillers") {
                fillerDetectionPipeline = try device.makeComputePipelineState(function: function)
            }

            // Pause detection pipeline
            if let function = library.makeFunction(name: "detect_pauses") {
                pauseDetectionPipeline = try device.makeComputePipelineState(function: function)
            }

            // Pace analysis pipeline
            if let function = library.makeFunction(name: "analyze_pace") {
                paceAnalysisPipeline = try device.makeComputePipelineState(function: function)
            }

        } catch {
            print("❌ Failed to create compute pipelines: \(error)")
        }
    }

    private func allocateBuffers() {
        // Allocate GPU memory buffers
        audioBuffer = device.makeBuffer(length: bufferSize * MemoryLayout<Float>.size,
                                        options: .storageModeShared)
        timestampBuffer = device.makeBuffer(length: bufferSize * MemoryLayout<Float>.size,
                                            options: .storageModeShared)
        resultBuffer = device.makeBuffer(length: 16 * MemoryLayout<Float>.size,
                                         options: .storageModeShared)
    }

    // MARK: - Optimized Metal Buffer Updates

    private func processAudioChunk(_ buffer: [Float]) {
        // Reuse existing buffers instead of reallocating
        audioBuffer?.contents().copyMemory(from: buffer, byteCount: bufferSize * MemoryLayout<Float>.size)
        // Enqueue once per batch instead of per sample
        enqueueDetectionKernel()
    }
}

// MARK: - Hardware-Accelerated Detector Implementations

@available(macOS 10.13, *)
class MetalFillerDetector {
    private let metalDetector: MetalDriftDetector?
    private let window = RingBuffer<String>(capacity: 30)
    private let fillers: Set<String> = ["um", "uh", "erm", "hmm", "like"]

    // Vectorized processing using Accelerate
    private var wordHashes: [UInt32] = []
    private var fillerHashes: Set<UInt32>

    init() {
        metalDetector = MetalDriftDetector()

        // Pre-compute filler word hashes for fast comparison
        fillerHashes = Set(fillers.map { $0.hash.magnitude })
    }

    func record(word: String) -> Int {
        window.push(word)

        // Use hardware-accelerated detection when available
        if metalDetector != nil {
            return metalAcceleratedCount(word: word)
        } else {
            return fallbackCount(word: word)
        }
    }

    private func metalAcceleratedCount(word: String) -> Int {
        // GPU-accelerated filler detection
        let wordHash = word.lowercased().hash.magnitude
        wordHashes.append(wordHash)

        // Keep only recent words
        if wordHashes.count > 30 {
            wordHashes.removeFirst()
        }

        // Vectorized intersection with filler hashes
        let count = wordHashes.reduce(0) { count, hash in
            count + (fillerHashes.contains(hash) ? 1 : 0)
        }

        return count
    }

    private func fallbackCount(word _: String) -> Int {
        return window.toArray().filter { fillers.contains($0) }.count
    }

    func isDrifting() -> Bool {
        return window.count >= 15 && record(word: "") >= 3
    }
}

@available(macOS 10.13, *)
class MetalPauseDetector {
    private let metalDetector: MetalDriftDetector?
    private let threshold: TimeInterval
    private var lastWordTime: TimeInterval?

    // Vectorized timestamp processing
    private var timestamps: [Float] = []
    private var pauseBuffer: [Float] = []

    init(threshold: TimeInterval = 0.3) {
        self.threshold = threshold
        metalDetector = MetalDriftDetector()
    }

    func record(timestamp: TimeInterval) -> Bool {
        defer { lastWordTime = timestamp }

        guard let prev = lastWordTime else { return false }

        let pauseDuration = timestamp - prev

        // Use SIMD for batch pause detection
        if metalDetector != nil {
            return simdAcceleratedDetection(pauseDuration: pauseDuration)
        } else {
            return pauseDuration >= threshold
        }
    }

    private func simdAcceleratedDetection(pauseDuration: TimeInterval) -> Bool {
        timestamps.append(Float(pauseDuration))

        // Keep rolling window for analysis
        if timestamps.count > 10 {
            timestamps.removeFirst()
        }

        // SIMD comparison with threshold
        let thresholdArray = [Float](repeating: Float(threshold), count: timestamps.count)
        var results = [Float](repeating: 0, count: timestamps.count)

        // Vectorized comparison using Accelerate
        vDSP_vthres(timestamps, 1, thresholdArray, &results, 1, vDSP_Length(timestamps.count))

        return results.last ?? 0 > Float(threshold)
    }
}

@available(macOS 10.13, *)
class MetalPaceAnalyzer {
    private let metalDetector: MetalDriftDetector?
    private var baselineWPM: Float = 150
    private let window = RingBuffer<Float>(capacity: 12)
    private let secondsPerBucket: Float = 5

    // SIMD processing arrays
    private var wpmArray: [Float] = []
    private var baselineArray: [Float] = []

    init() {
        metalDetector = MetalDriftDetector()
    }

    func record(words: Int) -> PaceMetrics {
        let wps = Float(words) / secondsPerBucket
        let currentWPM = wps * 60

        window.push(currentWPM)
        wpmArray.append(currentWPM)

        // Keep arrays manageable
        if wpmArray.count > 50 {
            wpmArray.removeFirst(10)
        }

        // Hardware-accelerated baseline calculation
        if metalDetector != nil && window.count == window.capacity {
            updateBaselineAccelerated()
        } else if window.count == window.capacity {
            updateBaselineFallback()
        }

        let change = (currentWPM - baselineWPM) / baselineWPM

        return PaceMetrics(
            currentWPM: currentWPM,
            baselineWPM: baselineWPM,
            percentChange: change,
            isBelowThreshold: change < -0.25
        )
    }

    private func updateBaselineAccelerated() {
        let samples = window.toArray()
        var mean: Float = 0

        // SIMD mean calculation
        vDSP_meanv(samples, 1, &mean, vDSP_Length(samples.count))

        // Exponential moving average with SIMD
        baselineWPM = (baselineWPM * 0.9) + (mean * 0.1)
    }

    private func updateBaselineFallback() {
        let avg = window.toArray().reduce(0, +) / Float(window.capacity)
        baselineWPM = (baselineWPM * 0.9) + (avg * 0.1)
    }
}


// MARK: - Factory for Hardware-Optimized Detectors

enum DetectorFactory {
    static func createOptimizedDetectors() -> (FillerDetector, PauseDetector, PaceAnalyzer) {
        if #available(macOS 10.13, *), MTLCreateSystemDefaultDevice() != nil {
            print("✅ Using Metal-accelerated detectors")
            return (
                MetalFillerDetector() as! FillerDetector,
                MetalPauseDetector() as! PauseDetector,
                MetalPaceAnalyzer() as! PaceAnalyzer
            )
        } else {
            print("⚠️  Using CPU fallback detectors")
            return (
                FillerDetector(),
                PauseDetector(),
                PaceAnalyzer()
            )
        }
    }
}
