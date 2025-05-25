// MARK: - FillerDetector.swift

// Counts “um / uh / er / hmm” tokens in a sliding window.

import Foundation

public final class FillerDetector {
    private let fillers: Set<String> = ["um", "uh", "erm", "hmm", "like"] // tweak anytime
    private let window = RingBuffer<String>(capacity: 30) // last 30 words

    /// Feed *one* lowercase word at a time.
    public func record(word: String) -> Int {
        window.push(word)
        return window.toArray().filter { fillers.contains($0) }.count
    }

    /// Simple threshold helper (≥ 3 fillers in the last 30 words = drift).
    public func isDrifting() -> Bool {
        return window.count >= 15 && record(word: "") >= 3
    }
}
