// MARK: - MicPipeline.swift
//
// Core observable object that aggregates raw ASR events and updates the
// drift detectors.  It stores a rolling transcript, computes pace and
// exposes high level state for the SwiftUI views.  The pipeline is
// designed for frequent updates so most work happens off the main
// thread with results published via `@MainActor`.

import Combine
import Foundation
import SwiftUI

@MainActor
public final class MicPipeline: ObservableObject {
    // ―― Public state (UI can bind to these) ―――――――――――――――――――――――――――――――――
    @Published public var transcript: String = ""
    @Published public var rms: Float = 0 // live mic volume 0…1
    @Published public var fillerCount: Int = 0
    @Published public var pace: PaceMetrics?
    @Published public var didPause: Bool = false
    @Published public var didRepair: Bool = false

    // ―― Private helpers ――――――――――――――――――――――――――――――――――――――――――――――
    private let fillerDetector = FillerDetector()
    private let paceAnalyzer = PaceAnalyzer()
    private let pauseDetector = PauseDetector()
    private let repairDetector = RepairDetector()

    private var last5sWordCount = 0
    private var paceTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    // Memory management
    private let maxTranscriptWords = 1500
    private var transcriptBuffer = RingBuffer<String>(capacity: 1500)

    // MARK: - Init

    public init() {
        setupPaceTimer()
    }

    deinit {
        paceTimer?.invalidate()
        paceTimer = nil
        cancellables.removeAll()
    }

    private func cleanup() {
        paceTimer?.invalidate()
        paceTimer = nil
        cancellables.removeAll()
    }

    private func setupPaceTimer() {
        paceTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pace = self.paceAnalyzer.record(words: self.last5sWordCount)
                self.last5sWordCount = 0
            }
        }
    }

    // MARK: - Public sink — call from the ASR layer

    /// Feed each finalised *word* along with the audio-time it ended.
    public func ingest(word: String, at timestamp: TimeInterval) {
        let w = word.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        guard !w.isEmpty else { return }

        // Update detectors
        fillerCount = fillerDetector.record(word: w)
        didRepair = repairDetector.record(word: w)
        didPause = pauseDetector.record(timestamp: timestamp)

        last5sWordCount += 1

        // Efficient transcript management
        updateTranscript(with: w)
    }

    private func updateTranscript(with word: String) {
        transcriptBuffer.push(word)
        transcript = transcriptBuffer.toArray().joined(separator: " ")
    }

    // MARK: - Public Methods

    public func clearTranscript() {
        transcriptBuffer = RingBuffer<String>(capacity: maxTranscriptWords)
        transcript = ""
    }

    public func getRecentWords(count: Int) -> [String] {
        return transcriptBuffer.recent(count)
    }

    public func getWordCount() -> Int {
        return transcriptBuffer.toArray().count
    }
}
