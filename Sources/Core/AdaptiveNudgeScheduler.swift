import Foundation

/// Schedules gentle reminders that decay over time.
final class AdaptiveNudgeScheduler {
    private var nudgeFrequency: TimeInterval = 30.0
    private var lastNudge: Date = .init()
    private var sessionStartDate: Date = .init()

    var shouldNudge: Bool {
        let timeSinceStart = Date().timeIntervalSince(sessionStartDate)
        let daysSinceStart = timeSinceStart / 86400
        let adjusted = nudgeFrequency * pow(2.0, daysSinceStart / 30.0)
        return Date().timeIntervalSince(lastNudge) > adjusted
    }

    func recordNudge() {
        lastNudge = Date()
    }
}
