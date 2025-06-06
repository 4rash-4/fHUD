// MARK: - FillerDetector.swift
//
// Pure Swift fallback detector used when no hardware accelerated
// implementation is available.  It simply counts common filler words
// in a ring buffer of recent terms to provide a lightweight measure of
// attention drift.

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
