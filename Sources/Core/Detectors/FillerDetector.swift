//
//  FillerDetector.swift
//  fHUD
//
//  CPU fallback detector (used if Metal unavailable).
//

import Foundation

public class FillerDetector {
    /// Canonical filler list shared by *all* detectors.
    public static let canonicalFillers: Set<String> =
        ["um", "uh", "erm", "hmm", "like"]

    // subclasses can read this
    let fillers = FillerDetector.canonicalFillers
    let window = RingBuffer<String>(capacity: 30) // last 30 words

    public init() {}

    /// Feed **one lowercase word** at a time.  Returns current filler count.
    @discardableResult
    public func record(word: String) -> Int {
        window.push(word)
        return window.toArray().filter { fillers.contains($0) }.count
    }

    /// ≥ 3 fillers in the last 30 words **and** at least 15 words spoken.
    public func isDrifting() -> Bool {
        let words = window.toArray()
        let fillerCount = words.filter { fillers.contains($0) }.count
        return words.count >= 15 && fillerCount >= 3
    }
}
