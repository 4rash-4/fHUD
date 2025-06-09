// MARK: - RepairDetector.swift

//
// Detects immediate word repetitions which often indicate hesitation or
// cognitive overload.  The detector is intentionally simple – only two
// consecutive identical words are flagged.

import Foundation

public final class RepairDetector {
    private var lastWord: String?

    /// Feed lowercase words in sequence. Returns `true` on a repetition.
    public func record(word: String) -> Bool {
        defer { lastWord = word }
        return lastWord == word
    }
}
