// MARK: - ASRBridge.swift

// Enhanced bridge that processes both words and concepts from Python MLX backend

import Combine
import Foundation
import Network

/// Enhanced bridge that handles real-time Parakeet transcription and Gemma concept extraction
final class ASRBridge {
    private let mic: MicPipeline
    private var webSocket: URLSessionWebSocketTask?
    private var conceptSocket: URLSessionWebSocketTask?
    private var cancellables = Set<AnyCancellable>()

    // Concept processing
    @Published var recentConcepts: [ConceptNode] = []
    @Published var thoughtConnections: [ThoughtConnection] = []

    private var conceptBuffer: [String] = []
    private let conceptBufferLimit = 50 // words
    private var lastConceptExtraction = Date()

    init(mic: MicPipeline) {
        self.mic = mic
        connectToTranscription()
        connectToConcepts()
    }

    // MARK: - Transcription Connection (Port 8765)

    private func connectToTranscription() {
        guard webSocket == nil else { return }
        let url = URL(string: "ws://127.0.0.1:8765")!
        webSocket = URLSession(configuration: .default)
            .webSocketTask(with: url)
        webSocket?.resume()
        listenForWords()
    }

    private func listenForWords() {
        webSocket?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case let .failure(err):
                print("🔌 Transcription WebSocket error: \(err)")
                self.webSocket = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    self.connectToTranscription()
                }
            case let .success(.string(text)):
                self.processTranscriptionEvent(text)
                self.listenForWords() // Continue listening
            default:
                self.listenForWords()
            }
        }
    }

    private func processTranscriptionEvent(_ text: String) {
        guard let data = text.data(using: .utf8),
              let event = try? JSONDecoder().decode(TranscriptionEvent.self, from: data)
        else {
            return
        }

        Task { @MainActor in
            // Feed word to main pipeline
            mic.ingest(word: event.w, at: event.t)

            // Buffer for concept extraction
            conceptBuffer.append(event.w)
            if conceptBuffer.count > conceptBufferLimit {
                conceptBuffer.removeFirst()
            }

            // Trigger concept extraction periodically
            let now = Date()
            if now.timeIntervalSince(lastConceptExtraction) > 5.0 && conceptBuffer.count >= 10 {
                await requestConceptExtraction()
                lastConceptExtraction = now
            }
        }
    }

    // MARK: - Concept Connection (Port 8766)

    private func connectToConcepts() {
        guard conceptSocket == nil else { return }
        let url = URL(string: "ws://127.0.0.1:8766")!
        conceptSocket = URLSession(configuration: .default)
            .webSocketTask(with: url)
        conceptSocket?.resume()
        listenForConcepts()
    }

    private func listenForConcepts() {
        conceptSocket?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case let .failure(err):
                print("🧠 Concept WebSocket error: \(err)")
                self.conceptSocket = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    self.connectToConcepts()
                }
            case let .success(.string(text)):
                self.processConceptEvent(text)
                self.listenForConcepts() // Continue listening
            default:
                self.listenForConcepts()
            }
        }
    }

    private func processConceptEvent(_ text: String) {
        guard let data = text.data(using: .utf8),
              let event = try? JSONDecoder().decode(ConceptEvent.self, from: data)
        else {
            return
        }

        Task { @MainActor in
            switch event.type {
            case "concepts":
                if let conceptsData = event.data as? [[String: Any]] {
                    let concepts = conceptsData.compactMap { dict -> ConceptNode? in
                        guard let text = dict["text"] as? String,
                              let category = dict["category"] as? String,
                              let confidence = dict["confidence"] as? Double
                        else {
                            return nil
                        }

                        return ConceptNode(
                            text: text,
                            category: ConceptCategory(rawValue: category) ?? .task,
                            confidence: Float(confidence),
                            timestamp: Date(),
                            emotionalTone: dict["emotional_tone"] as? String
                        )
                    }

                    // Update recent concepts (keep last 20)
                    recentConcepts.append(contentsOf: concepts)
                    if recentConcepts.count > 20 {
                        recentConcepts.removeFirst(recentConcepts.count - 20)
                    }
                }

            case "connections":
                if let connectionsData = event.data as? [[String: Any]] {
                    let connections = connectionsData.compactMap { dict -> ThoughtConnection? in
                        guard let from = dict["from"] as? String,
                              let to = dict["to"] as? String,
                              let strength = dict["strength"] as? Double
                        else {
                            return nil
                        }

                        return ThoughtConnection(
                            from: from,
                            to: to,
                            strength: Float(strength),
                            createdAt: Date()
                        )
                    }

                    thoughtConnections = connections
                }

            default:
                break
            }
        }
    }

    // MARK: - Concept Extraction Request

    private func requestConceptExtraction() async {
        guard !conceptBuffer.isEmpty else { return }

        let text = conceptBuffer.joined(separator: " ")
        let request = ConceptExtractionRequest(
            text: text,
            timestamp: Date().timeIntervalSince1970,
            driftIndicators: getCurrentDriftIndicators()
        )

        guard let data = try? JSONEncoder().encode(request),
              let jsonString = String(data: data, encoding: .utf8)
        else {
            return
        }

        do {
            try await conceptSocket?.send(.string(jsonString))
        } catch {
            print("❌ Failed to send concept extraction request: \(error)")
        }
    }

    private func getCurrentDriftIndicators() -> [String: Any] {
        return [
            "filler_count": mic.fillerCount,
            "pace_wpm": mic.pace?.currentWPM ?? 0,
            "did_pause": mic.didPause,
            "did_repair": mic.didRepair,
        ]
    }
}

// MARK: - Data Models

struct TranscriptionEvent: Decodable {
    let w: String // word
    let t: TimeInterval // timestamp
    let confidence: Float? // optional confidence score
}

struct ConceptEvent: Decodable {
    let type: String // "concepts" or "connections"
    let data: Any // flexible data payload

    private enum CodingKeys: String, CodingKey {
        case type, data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)

        // Decode data as generic JSON
        if let jsonObject = try? container.decode([String: Any].self, forKey: .data) {
            data = jsonObject
        } else if let jsonArray = try? container.decode([[String: Any]].self, forKey: .data) {
            data = jsonArray
        } else {
            data = [:]
        }
    }
}

struct ConceptExtractionRequest: Encodable {
    let text: String
    let timestamp: TimeInterval
    let driftIndicators: [String: Any]

    private enum CodingKeys: String, CodingKey {
        case text, timestamp, driftIndicators
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(text, forKey: .text)
        try container.encode(timestamp, forKey: .timestamp)

        // Encode drift indicators as JSON object
        let jsonData = try JSONSerialization.data(withJSONObject: driftIndicators)
        let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"
        try container.encode(jsonString, forKey: .driftIndicators)
    }
}

// MARK: - Concept Data Models

struct ConceptNode {
    let text: String
    let category: ConceptCategory
    let confidence: Float
    let timestamp: Date
    let emotionalTone: String?
}

enum ConceptCategory: String, CaseIterable {
    case project
    case task
    case person
    case technology
    case emotion
    case decision
}

struct ThoughtConnection {
    let from: String
    let to: String
    let strength: Float
    let createdAt: Date
}
