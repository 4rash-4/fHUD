import Foundation
import Combine

/// Represents a single drift indicator snapshot.
struct DriftEvent: Codable {
    let fillerCount: Int
    let paceWPM: Int
    let didPause: Bool
    let didRepair: Bool
    let timestamp: TimeInterval
}

/// Container for batching multiple drift events.
struct EventBatch: Codable {
    let events: [DriftEvent]
}

/// Batches drift events and sends them over WebSocket at regular intervals.
final class DriftEventBatcher {
    private var pendingEvents: [DriftEvent] = []
    private var timerCancellable: AnyCancellable?
    private let sendHandler: (EventBatch) -> Void

    init(interval: TimeInterval = 0.1, sendHandler: @escaping (EventBatch) -> Void) {
        self.sendHandler = sendHandler
        timerCancellable = Timer
            .publish(every: interval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.batchAndSend()
            }
    }

    /// Queue an event to be sent in the next batch.
    func add(_ event: DriftEvent) {
        pendingEvents.append(event)
    }

    private func batchAndSend() {
        guard !pendingEvents.isEmpty else { return }
        let batch = EventBatch(events: pendingEvents)
        sendHandler(batch)
        pendingEvents.removeAll()
    }

    deinit {
        timerCancellable?.cancel()
    }
}
