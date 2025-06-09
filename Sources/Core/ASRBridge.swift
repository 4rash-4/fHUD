// ASRBridge.swift
//
// Minimal shims so we can access Timer / AnyCancellable from
// non‑isolated contexts (e.g. default deinits) without warnings.

import Combine
import Foundation

extension Timer: @unchecked Sendable {}
extension AnyCancellable: @unchecked Sendable {}
extension PassthroughSubject: @unchecked Sendable {} // ← NEW

// MARK: - ASRBridge.swift

//
// Bridges the Python back end with the SwiftUI interface.  This class
// manages two WebSocket connections – one for real‑time transcription
// and one for concept extraction results.  Incoming words are fed into
// `MicPipeline` while high level concepts update the UI.  Connection
// logic includes reconnection and shared memory reading via
// `SharedRingBuffer`.

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
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 5
    private var reconnectTimer: Timer?
    private var isReconnecting = false
    private var webSocketTask: URLSessionWebSocketTask?

    // Concept processing
    // Use Combine for efficient state management
    @Published var recentConcepts: [ConceptNode] = [] {
        didSet {
            // Limit to last 20 items
            if recentConcepts.count > 20 {
                recentConcepts = Array(recentConcepts.suffix(20))
            }
        }
    }

    @Published var thoughtConnections: [ThoughtConnection] = []

    private var conceptBuffer: [String] = []
    private let conceptBufferLimit = 50
    private var lastConceptExtraction = Date()

    private var ringBuffer: SharedRingBuffer?
    private var ringCancellable: AnyCancellable?
    private var sharedMemoryPoller: Timer?
    private var lastReadPosition: UInt32 = 0

    private var wsWordCount = 0
    private var shmWordCount = 0
    private var wsLatencySum = 0.0
    private var shmLatencySum = 0.0
    private lazy var eventBatcher = DriftEventBatcher { [weak self] batch in
        self?.sendEventBatch(batch)
    }

    init(mic: MicPipeline) {
        self.mic = mic
        // set up shared‐memory reader
        let memPath = "/tc_rb" // must match Python writer
        initializeSharedMemory(path: memPath)
        Task {
            await connectToTranscription()
            await connectToConcepts()
        }
    }

    deinit {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        webSocket?.cancel(with: .goingAway, reason: nil)
        conceptSocket?.cancel(with: .goingAway, reason: nil)
        cancellables.removeAll()
    }

    private func cleanup() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil

        webSocket?.cancel(with: .goingAway, reason: nil)
        conceptSocket?.cancel(with: .goingAway, reason: nil)

        cancellables.removeAll()
    }

    // MARK: - Shared Memory

    private func initializeSharedMemory(path: String) {
        guard ringBuffer == nil else { return }
        if let reader = SharedRingBuffer(name: path) {
            ringBuffer = reader
            sharedMemoryPoller = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                self?.checkSharedMemory()
            }
        }
    }

    private func checkSharedMemory() {
        guard let buffer = ringBuffer else { return }
        var mutableBuffer = buffer
        while let entry = mutableBuffer.readNextWord(lastTail: &lastReadPosition) {
            mic?.ingest(word: entry.0, at: entry.1)
            shmWordCount += 1
            shmLatencySum += Date().timeIntervalSince1970 - entry.1
            if shmWordCount % 100 == 0 {
                logStats()
            }
        }
    }

    private func logStats() {
        let wsAvg = wsWordCount > 0 ? wsLatencySum / Double(wsWordCount) : 0
        let shmAvg = shmWordCount > 0 ? shmLatencySum / Double(shmWordCount) : 0
        print("[ASR Stats] WS: \(wsWordCount) words, avg latency \(Int(wsAvg * 1000))ms")
        print("[ASR Stats] SHM: \(shmWordCount) words, avg latency \(Int(shmAvg * 1000))ms")
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
                    processTranscriptionEvent(text)
                case let .data(data):
                    if let text = String(data: data, encoding: .utf8) {
                        processTranscriptionEvent(text)
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

    // MARK: - Optimized WebSocket Handling

    private let decodingQueue = DispatchQueue(label: "ASRBridge.decoding", qos: .userInitiated, attributes: .concurrent)

    private func processTranscriptionEvent(_ text: String) {
        decodingQueue.async { [weak self] in
            guard let self else { return }
            guard let data = text.data(using: .utf8) else {
                print("⚠️ Invalid UTF-8 in transcription event")
                return
            }
            let event: TranscriptionEvent
            do {
                event = try JSONDecoder().decode(TranscriptionEvent.self, from: data)
            } catch {
                print("❌ Failed to decode transcription event: \(error)")
                return
            }
            Task { @MainActor in
                self.mic?.ingest(word: event.w, at: event.t)
                self.wsWordCount += 1
                self.wsLatencySum += Date().timeIntervalSince1970 - event.t
                if self.wsWordCount % 100 == 0 {
                    self.logStats()
                }
                // Buffer for concept extraction
                self.conceptBuffer.append(event.w)
                if self.conceptBuffer.count > self.conceptBufferLimit {
                    self.conceptBuffer.removeFirst()
                }
                if let mic = self.mic {
                    let driftEvent = DriftEvent(
                        fillerCount: mic.fillerCount,
                        paceWPM: Int(mic.pace?.currentWPM ?? 0),
                        didPause: mic.didPause,
                        didRepair: mic.didRepair,
                        timestamp: event.t
                    )
                    self.eventBatcher.add(driftEvent)
                }
                // Trigger concept extraction periodically
                let now = Date()
                if now.timeIntervalSince(self.lastConceptExtraction) > 5.0 && self.conceptBuffer.count >= 10 {
                    await self.requestConceptExtraction()
                    self.lastConceptExtraction = now
                }
            }
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
                    processConceptEvent(text)
                case let .data(data):
                    if let text = String(data: data, encoding: .utf8) {
                        processConceptEvent(text)
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

    // Optimize WebSocket handling for concept events
    private func processConceptEvent(_ text: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let data = text.data(using: .utf8) else { return }
            // Decode on background thread
            guard let event = try? JSONDecoder().decode(ConceptEvent.self, from: data) else { return }
            DispatchQueue.main.async {
                self?.handleConceptEvent(event)
            }
        }
    }

    // Add a new handler for concept events to update recentConcepts and thoughtConnections
    private func handleConceptEvent(_ event: ConceptEvent?) {
        guard let event = event else { return }
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
            recentConcepts.append(contentsOf: concepts)
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
        // Cancel immediately instead of waiting for Task.sleep
        (isTranscription ? webSocket : conceptSocket)?.cancel()

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

    public func start() {
        // 1. start WebSocket only for control frames
        startWebSocketControl()
    }

    private func startWebSocketControl() {
        // Listen for JSON control frames (e.g., "pause", "resume", "calibrate")
        webSocket?.receive { [weak self] result in
            switch result {
            case let .success(.string(json)):
                // Handle control frame
                // self?.handleControlFrame(json)
                _ = json // silence unused variable warning
            case let .failure(err):
                print("WS control error:", err)
            default:
                break
            }
            if let self = self {
                Task { @MainActor in
                    self.startWebSocketControl()
                }
            }
        }
    }

    // Remove old WebSocket transcript parsing entirely
    // transcripts now come from SharedRingBuffer.publisher

    func connect() {
        guard !isReconnecting else { return }

        let url = URL(string: "ws://localhost:8765")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 10.0

        webSocketTask = URLSession.shared.webSocketTask(with: request)
        webSocketTask?.resume()

        receiveMessage()
    }

    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            switch result {
            case .success:
                // ...handle message...
                if let self = self {
                    Task { @MainActor in
                        self.receiveMessage()
                    }
                }
            case .failure:
                if let self = self {
                    Task { @MainActor in
                        self.handleDisconnection()
                    }
                }
            }
        }
    }

    private func handleDisconnection() {
        guard !isReconnecting else { return }
        isReconnecting = true

        if reconnectAttempts < maxReconnectAttempts {
            let delay = min(pow(2.0, Double(reconnectAttempts)), 30.0) // Exponential backoff, max 30s

            reconnectTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                guard let self = self else { return }
                Task { @MainActor in
                    self.reconnectAttempts += 1
                    self.isReconnecting = false
                    self.connect()
                }
            }
        } else {
            // Max attempts reached, stop trying
            isReconnecting = false
            print("❌ Max reconnection attempts reached")
        }
    }

    func disconnect() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        reconnectAttempts = 0
        isReconnecting = false
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
    }

    private func sendEventBatch(_ batch: EventBatch) {
        guard let conceptSocket = conceptSocket else { return }
        do {
            let data = try JSONEncoder().encode(batch)
            conceptSocket.send(.data(data)) { error in
                if let error {
                    print("❌ Failed to send event batch: \(error)")
                }
            }
        } catch {
            print("❌ Failed to encode event batch: \(error)")
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
