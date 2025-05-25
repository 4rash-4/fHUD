// fHUDApp.swift
// Thought Crystallizer - MLX-powered ambient intelligence for self-talk cultivation

import SwiftUI

@main
struct fHUDApp: App {
    // Shared speech/ASR pipeline available app-wide
    @StateObject private var micPipeline = MicPipeline()

    // Initialize ASR bridge with concept processing
    private var asrBridge: ASRBridge {
        ASRBridge(mic: micPipeline)
    }

    var body: some Scene {
        // Main ambient display window
        WindowGroup("Thought Crystallizer") {
            AmbientDisplayView()
                .environmentObject(micPipeline)
                .frame(minWidth: 800, minHeight: 600)
                .background(Color.black)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

        // Optional: Minimal HUD overlay for debugging
        WindowGroup("Debug HUD") {
            HUDOverlayView()
                .environmentObject(micPipeline)
                .frame(width: 400, height: 200)
                .background(Color.clear)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.disabled)
        .defaultPosition(.topTrailing)

        // Menu bar controls
        MenuBarExtra("fHUD", systemImage: "brain.head.profile") {
            MenuBarContent()
                .environmentObject(micPipeline)
        }
    }
}

// MARK: - Menu Bar Content

struct MenuBarContent: View {
    @EnvironmentObject var mic: MicPipeline
    @State private var showingDebugHUD = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Status indicator
            HStack {
                Circle()
                    .fill(mic.transcript.isEmpty ? Color.gray : Color.green)
                    .frame(width: 8, height: 8)

                Text("Thought Crystallizer")
                    .font(.headline)
            }

            if !mic.transcript.isEmpty {
                Text("Active - \(getWordCount()) words captured")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text("Waiting for speech...")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()

            // Quick stats (minimal, no gamification)
            if let pace = mic.pace {
                HStack {
                    Image(systemName: "speedometer")
                        .foregroundColor(.blue)
                    Text("\(Int(pace.currentWPM)) WPM")
                        .font(.caption)
                }
            }

            if mic.fillerCount > 0 {
                HStack {
                    Image(systemName: "pause.circle")
                        .foregroundColor(.orange)
                    Text("\(mic.fillerCount) drift signals")
                        .font(.caption)
                }
            }

            Divider()

            // Controls
            Button("Show Debug HUD") {
                showingDebugHUD.toggle()
                // Toggle debug window visibility
                if let debugWindow = NSApplication.shared.windows.first(where: { $0.title == "Debug HUD" }) {
                    if showingDebugHUD {
                        debugWindow.orderFront(nil)
                    } else {
                        debugWindow.orderOut(nil)
                    }
                }
            }

            Button("Clear History") {
                mic.transcript = ""
                // Could also clear concept history here
            }

            Divider()

            Button("Quit fHUD") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding()
        .frame(width: 200)
    }

    private func getWordCount() -> Int {
        return mic.transcript.split(separator: " ").count
    }
}
