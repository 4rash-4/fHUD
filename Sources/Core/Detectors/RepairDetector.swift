// MARK: - RepairDetector.swift

// Flags immediate word repetitions (e.g., “I I think”)

import Foundation

public final class RepairDetector {
    private var lastWord: String?

    /// Feed lowercase words in sequence. Returns `true` on a repetition.
    public func record(word: String) -> Bool {
        defer { lastWord = word }
        return lastWord == word
    }
}
