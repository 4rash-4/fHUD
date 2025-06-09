// MARK: - ConceptWebSocketClient.swift

import Combine

//
// Lightweight client used by the optional debug overlay to receive
// concept summaries from the backend.
import Foundation

/// v1 Message contract for versioning and payload typing
public struct MessageContract<T: Codable>: Codable {
    public let v: Int
    public let type: String
    public let payload: T
}

/// Concept payload
public struct ConceptMessage: Codable {
    public let transcript_id: Int
    public let concept: String
    public let timestamp: String
}

/// WebSocket client for concept messages
@MainActor
public final class ConceptWebSocketClient: Sendable {
    private let url = URL(string: "ws://127.0.0.1:8765/concepts")!
    private var task: URLSessionWebSocketTask?
    private let decoder = JSONDecoder()
    public let publisher = PassthroughSubject<ConceptMessage, Never>()
    private var reconnectDelay = 1.0

    public init() {}

    public func connect() {
        let session = URLSession(configuration: .ephemeral)
        task = session.webSocketTask(with: url)
        task?.resume()
        receive()
    }

    private func receive() {
        task?.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }

                switch result {
                case .failure:
                    self.scheduleReconnect()

                case let .success(.string(text)):
                    self.decodeAndPublish(text)

                default:
                    self.receive()
                }
            }
        }
    }

    private func decodeAndPublish(_ text: String) {
        do {
            let wrapper = try decoder.decode(
                MessageContract<ConceptMessage>.self,
                from: Data(text.utf8)
            )
            guard wrapper.type == "concept" else { return }

            publisher.send(wrapper.payload)

        } catch {
            print("Concept decode error:", error)
        }
    }

    private func scheduleReconnect() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(reconnectDelay * 1_000_000_000))
            reconnectDelay = min(reconnectDelay * 2, 30)
            connect()
        }
    }

    public func disconnect() {
        task?.cancel(with: .goingAway, reason: nil)
    }
}
