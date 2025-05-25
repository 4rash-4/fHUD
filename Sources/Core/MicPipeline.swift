// MARK: - MicPipeline.swift

// Central publisher that glues mic input to our drift-detectors.
// • In this bare-bones phase we _simulate_ words arriving – real ASR hookup next.

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

    // MARK: - Init

    public init() {
        // update pace every 5 s
        paceTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            pace = paceAnalyzer.record(words: last5sWordCount)
            last5sWordCount = 0
        }
    }

    deinit { paceTimer?.invalidate() }

    // MARK: - Public sink — call from the ASR layer

    /// Feed each finalised *word* along with the audio-time it ended.
    public func ingest(word: String, at timestamp: TimeInterval) {
        let w = word.lowercased()

        // detectors
        fillerCount = fillerDetector.record(word: w)
        didRepair = repairDetector.record(word: w)
        didPause = pauseDetector.record(timestamp: timestamp)

        last5sWordCount += 1
        transcript += transcript.isEmpty ? w : " \(w)"
    }
}
