// MARK: - ASRBridge.swift

// Fixed version with proper memory management and error handling

import Combine
import Foundation
import Network

/// Enhanced bridge that handles real-time Parakeet transcription and Gemma concept extraction
@MainActor
final class ASRBridge: ObservableObject {
    // Use weak reference to prevent retain cycles
    private weak var mic: MicPipeline?
    private var webSocket: URLSessionWebSocketTask?
    private var conceptSocket: URLSessionWebSocketTask?
    private var cancellables = Set<AnyCancellable>()

    // Reconnection handling
    private var reconnectTimer: Timer?
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 5

    // Concept processing
    @Published var recentConcepts: [ConceptNode] = []
    @Published var thoughtConnections: [ThoughtConnection] = []

    private var conceptBuffer: [String] = []
    private let conceptBufferLimit = 50
    private var lastConceptExtraction = Date()

    init(mic: MicPipeline) {
        self.mic = mic
        Task {
            await connectToTranscription()
            await connectToConcepts()
        }
    }

    deinit {
        cleanup()
    }

    private func cleanup() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil

        webSocket?.cancel(with: .goingAway, reason: nil)
        conceptSocket?.cancel(with: .goingAway, reason: nil)

        cancellables.removeAll()
    }

    // MARK: - Transcription Connection (Port 8765)

    private func connectToTranscription() async {
        guard webSocket == nil else { return }

        let url = URL(string: "ws://127.0.0.1:8765")!
        let session = URLSession(configuration: .default)
        webSocket = session.webSocketTask(with: url)
        webSocket?.resume()

        print("🔌 Connecting to transcription WebSocket...")
        await listenForWords()
    }

    private func listenForWords() async {
        guard let webSocket = webSocket else { return }

        do {
            while webSocket.state == .running {
                let message = try await webSocket.receive()

                switch message {
                case let .string(text):
                    await processTranscriptionEvent(text)
                case let .data(data):
                    if let text = String(data: data, encoding: .utf8) {
                        await processTranscriptionEvent(text)
                    }
                @unknown default:
                    break
                }
            }
        } catch {
            print("🔌 Transcription WebSocket error: \(error)")
            await handleDisconnection(isTranscription: true)
        }
    }

    private func processTranscriptionEvent(_ text: String) async {
        do {
            guard let data = text.data(using: .utf8) else {
                print("⚠️ Failed to convert text to data")
                return
            }

            let event = try JSONDecoder().decode(TranscriptionEvent.self, from: data)

            // Feed word to main pipeline
            await mic?.ingest(word: event.w, at: event.t)

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

        } catch {
            print("🔥 Failed to decode transcription event: \(error)")
        }
    }

    // MARK: - Concept Connection (Port 8766)

    private func connectToConcepts() async {
        guard conceptSocket == nil else { return }

        let url = URL(string: "ws://127.0.0.1:8766")!
        let session = URLSession(configuration: .default)
        conceptSocket = session.webSocketTask(with: url)
        conceptSocket?.resume()

        print("🧠 Connecting to concept WebSocket...")
        await listenForConcepts()
    }

    private func listenForConcepts() async {
        guard let conceptSocket = conceptSocket else { return }

        do {
            while conceptSocket.state == .running {
                let message = try await conceptSocket.receive()

                switch message {
                case let .string(text):
                    await processConceptEvent(text)
                case let .data(data):
                    if let text = String(data: data, encoding: .utf8) {
                        await processConceptEvent(text)
                    }
                @unknown default:
                    break
                }
            }
        } catch {
            print("🧠 Concept WebSocket error: \(error)")
            await handleDisconnection(isTranscription: false)
        }
    }

    private func processConceptEvent(_ text: String) async {
        do {
            guard let data = text.data(using: .utf8) else {
                print("⚠️ Failed to convert concept text to data")
                return
            }

            let event = try JSONDecoder().decode(ConceptEvent.self, from: data)

            switch event.type {
            case "concepts":
                let concepts = event.concepts.compactMap { dict -> ConceptNode? in
                    ConceptNode(
                        text: dict.text,
                        category: ConceptCategory(rawValue: dict.category) ?? .task,
                        confidence: Float(dict.confidence),
                        timestamp: Date(),
                        emotionalTone: dict.emotionalTone
                    )
                }

                // Update recent concepts (keep last 20)
                recentConcepts.append(contentsOf: concepts)
                if recentConcepts.count > 20 {
                    recentConcepts.removeFirst(recentConcepts.count - 20)
                }

            case "connections":
                let connections = event.connections.compactMap { dict -> ThoughtConnection? in
                    ThoughtConnection(
                        from: dict.from,
                        to: dict.to,
                        strength: Float(dict.strength),
                        createdAt: Date()
                    )
                }

                thoughtConnections = connections

            default:
                break
            }

        } catch {
            print("🔥 Failed to decode concept event: \(error)")
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

        do {
            let data = try JSONEncoder().encode(request)
            guard let conceptSocket = conceptSocket else { return }

            try await conceptSocket.send(.data(data))

        } catch {
            print("❌ Failed to send concept extraction request: \(error)")
        }
    }

    private func getCurrentDriftIndicators() -> DriftIndicators {
        guard let mic = mic else {
            return DriftIndicators(fillerCount: 0, paceWPM: 0, didPause: false, didRepair: false)
        }

        return DriftIndicators(
            fillerCount: mic.fillerCount,
            paceWPM: Int(mic.pace?.currentWPM ?? 0),
            didPause: mic.didPause,
            didRepair: mic.didRepair
        )
    }

    // MARK: - Reconnection Logic

    private func handleDisconnection(isTranscription: Bool) async {
        if isTranscription {
            webSocket = nil
        } else {
            conceptSocket = nil
        }

        guard reconnectAttempts < maxReconnectAttempts else {
            print("❌ Max reconnection attempts reached. Giving up.")
            return
        }

        reconnectAttempts += 1
        let delay = Double(reconnectAttempts) * 2.0 // Exponential backoff

        print("🔄 Reconnecting in \(delay) seconds... (attempt \(reconnectAttempts)/\(maxReconnectAttempts))")

        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

        if isTranscription {
            await connectToTranscription()
        } else {
            await connectToConcepts()
        }
    }
}

// MARK: - Fixed Data Models

struct TranscriptionEvent: Codable {
    let w: String // word
    let t: TimeInterval // timestamp
    let c: Float? // optional confidence score
}

struct ConceptEvent: Codable {
    let type: String
    let concepts: [ConceptData]
    let connections: [ConnectionData]

    enum CodingKeys: String, CodingKey {
        case type, data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)

        // Handle polymorphic data field
        if type == "concepts" {
            concepts = try container.decode([ConceptData].self, forKey: .data)
            connections = []
        } else if type == "connections" {
            connections = try container.decode([ConnectionData].self, forKey: .data)
            concepts = []
        } else {
            concepts = []
            connections = []
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)

        if type == "concepts" {
            try container.encode(concepts, forKey: .data)
        } else if type == "connections" {
            try container.encode(connections, forKey: .data)
        }
    }
}

struct ConceptData: Codable {
    let text: String
    let category: String
    let confidence: Double
    let emotionalTone: String?

    enum CodingKeys: String, CodingKey {
        case text, category, confidence
        case emotionalTone = "emotional_tone"
    }
}

struct ConnectionData: Codable {
    let from: String
    let to: String
    let strength: Double
}

struct ConceptExtractionRequest: Codable {
    let text: String
    let timestamp: TimeInterval
    let driftIndicators: DriftIndicators
}

struct DriftIndicators: Codable {
    let fillerCount: Int
    let paceWPM: Int
    let didPause: Bool
    let didRepair: Bool

    enum CodingKeys: String, CodingKey {
        case fillerCount = "filler_count"
        case paceWPM = "pace_wpm"
        case didPause = "did_pause"
        case didRepair = "did_repair"
    }
}

// MARK: - Concept Data Models

struct ConceptNode: Identifiable {
    let id = UUID()
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

struct ThoughtConnection: Identifiable {
    let id = UUID()
    let from: String
    let to: String
    let strength: Float
    let createdAt: Date
}
