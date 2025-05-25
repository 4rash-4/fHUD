// MARK: - HUDOverlayView.swift

// Minimal on-screen overlay showing transcript & drift cues.

import SwiftUI

struct HUDOverlayView: View {
    @EnvironmentObject var mic: MicPipeline

    var body: some View {
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
    }
}
