// MARK: - ASRBridge.swift

// Listens on ws://127.0.0.1:8765 for JSON lines: {"w":"hello","t":123.45}

import Combine
import Foundation
import Network

/// Small helper that forwards every incoming word to MicPipeline.
final class ASRBridge {
    private let mic: MicPipeline
    private var webSocket: URLSessionWebSocketTask?
    private var cancellables = Set<AnyCancellable>()

    init(mic: MicPipeline) {
        self.mic = mic
        connect()
    }

    private func connect() {
        guard webSocket == nil else { return }
        let url = URL(string: "ws://127.0.0.1:8765")!
        webSocket = URLSession(configuration: .default)
            .webSocketTask(with: url)
        webSocket?.resume()
        listen()
    }

    private func listen() {
        webSocket?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case let .failure(err):
                print("WebSocket error: \(err)")
                self.webSocket = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.connect() }
            case let .success(.string(text)):
                if let data = text.data(using: .utf8),
                   let obj = try? JSONDecoder().decode(Event.self, from: data)
                {
                    Task { @MainActor in
                        mic.ingest(word: obj.w, at: obj.t)
                    }
                }
                listen() // keep looping
            default:
                listen()
            }
        }
    }

    private struct Event: Decodable {
        let w: String // word
        let t: TimeInterval // timestamp in seconds
    }
}
