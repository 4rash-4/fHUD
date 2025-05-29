// MARK: - HUDOverlayView.swift

// Minimal on-screen overlay showing transcript & drift cues.

import SwiftUI
import Combine
import CoreIPC

public struct HUDOverlayView: View {
    @EnvironmentObject var mic: MicPipeline

    // Concept state
    @State private var latestConcept: String = ""
    private let conceptClient = ConceptWebSocketClient()
    private var cancellables = Set<AnyCancellable>()

    public init() {
        // existing transcript setup…

        // Set up concept subscription
        conceptClient.connect()
        conceptClient.publisher
            .receive(on: DispatchQueue.main)
            .sink { msg in
                self.latestConcept = msg.concept
            }
            .store(in: &cancellables)
    }

    public var body: some View {
        ZStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                // live transcript (last ~30 words for now)
                Text(mic.transcript.split(separator: " ").suffix(30).joined(separator: " "))
                    .font(.system(size: 13, weight: .regular, design: .monospaced))
                    .foregroundColor(.green)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 12) {
                    if let pace = mic.pace {
                        Text(String(format: "WPM %.0f", pace.currentWPM))
                    }
                    Text("Fillers \(mic.fillerCount)")
                        .foregroundColor(mic.fillerCount >= 3 ? .orange : .secondary)
                    if mic.didPause { Text("⏸︎") }
                    if mic.didRepair { Text("⤺") }
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.yellow)
            }
            .padding(12)
            .background(Color.black.opacity(0.65))
            .cornerRadius(10)
            .padding()

            // Concept popup
            if !latestConcept.isEmpty {
                Text(latestConcept)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundColor(.white)
                    .padding(6)
                    .background(Color.black.opacity(0.7))
                    .cornerRadius(6)
                    .transition(
                        .move(edge: .bottom)
                        .combined(with: .opacity)
                    )
                    .padding(.bottom, 24)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                self.latestConcept = ""
                            }
                        }
                    }
            }
        }
    }
}
