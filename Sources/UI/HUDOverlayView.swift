//  HUDOverlayView.swift
//  fHUD
//
//  Optional debug overlay that shows the rolling transcript, a few drift
//  metrics, and a transient pop‑up whenever the backend broadcasts a new
//  “concept” message.
//
//  Swift 6‑safe: no escaping closures mutate `self` from inside `init`.

import Combine
import SwiftUI

public struct HUDOverlayView: View {
    // --------------------------------------------------------------------
    // Dependencies
    @EnvironmentObject private var mic: MicPipeline

    // --------------------------------------------------------------------
    // Concept‑popup state
    @State private var latestConcept = ""

    // Web‑socket client that publishes “concept” messages.
    private let conceptClient = ConceptWebSocketClient()

    // --------------------------------------------------------------------
    // Life‑cycle
    public init() {
        // Existing transcript setup can stay here …

        // Only connect — *do not* create Combine sinks that mutate `self`.
        conceptClient.connect()
    }

    // --------------------------------------------------------------------
    public var body: some View {
        ZStack(alignment: .bottom) {
            // ----------------------------------------------------------------
            // Debug overlay
            VStack(alignment: .leading, spacing: 6) {
                // Live transcript (last ±30 words)
                Text(
                    mic.transcript.split(separator: " ")
                        .suffix(30)
                        .joined(separator: " ")
                )
                .font(.system(size: 13, weight: .regular, design: .monospaced))
                .foregroundColor(.green)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)

                // Simple drift metrics
                HStack(spacing: 12) {
                    if let pace = mic.pace {
                        Text(String(format: "WPM %.0f", pace.currentWPM))
                    }
                    Text("Fillers \(mic.fillerCount)")
                        .foregroundColor(
                            mic.fillerCount >= 3 ? .orange : .secondary
                        )
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

            // ----------------------------------------------------------------
            // Concept pop‑up
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
                        // Auto‑dismiss after three seconds
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                latestConcept = ""
                            }
                        }
                    }
            }
        }
        // ----------------------------------------------------------------
        // Combine subscription *outside* of init → safe to mutate @State.
        .onReceive(conceptClient.publisher) { msg in
            latestConcept = msg.concept
        }
    }
}
