import Foundation

/// Schedules gentle reminders that decay over time.
final class AdaptiveNudgeScheduler {
    private var nudgeFrequency: TimeInterval = 30.0
    private var lastNudge: Date = Date()
    private var sessionStartDate: Date = Date()

    var shouldNudge: Bool {
        let timeSinceStart = Date().timeIntervalSince(sessionStartDate)
        let daysSinceStart = timeSinceStart / 86_400
        let adjusted = nudgeFrequency * pow(2.0, daysSinceStart / 30.0)
        return Date().timeIntervalSince(lastNudge) > adjusted
    }

    func recordNudge() {
        lastNudge = Date()
    }
}
