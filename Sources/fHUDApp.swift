// MARK: - fHUDApp.swift
//
// Application entry point for the Thought Crystallizer prototype.
//
// This file wires together the microphone processing pipeline, the
// WebSocket bridge to the Python backend and the main SwiftUI views.
// It intentionally keeps global state to a minimum and exposes only
// `MicPipeline` and `ASRBridge` via `EnvironmentObject` so that views
// remain lightweight.  The window itself is configured to float above
// other windows in a translucent cassette‑futuristic style.

import SwiftUI

@main
struct fHUDApp: App {
    // Shared state objects initialized properly
    @StateObject private var micPipeline = MicPipeline()
    @StateObject private var asrBridge: ASRBridge
    @State private var showDebugHUD = false

    init() {
        // Initialize ASRBridge with MicPipeline in init
        let pipeline = MicPipeline()
        _micPipeline = StateObject(wrappedValue: pipeline)
        _asrBridge = StateObject(wrappedValue: ASRBridge(mic: pipeline))
    }

    var body: some Scene {
        // Main ambient display window
        WindowGroup("Thought Crystallizer") {
            AmbientDisplayView()
                .environmentObject(micPipeline)
                .environmentObject(asrBridge)
                .frame(minWidth: 800, minHeight: 600)
                .background(Color.black)
                .onAppear {
                    configureWindow()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

        // Menu bar controls
        MenuBarExtra("Thought Crystallizer", systemImage: "brain.head.profile") {
            MenuBarContent(showDebugHUD: $showDebugHUD)
                .environmentObject(micPipeline)
                .environmentObject(asrBridge)
        }
        .menuBarExtraStyle(.window)
    }

    private func configureWindow() {
        // Configure main window appearance
        if let window = NSApplication.shared.windows.first {
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        }
    }
}

// MARK: - Menu Bar Content

struct MenuBarContent: View {
    @EnvironmentObject var mic: MicPipeline
    @EnvironmentObject var asrBridge: ASRBridge
    @Binding var showDebugHUD: Bool
    @State private var isPaused = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            headerSection

            Divider()

            // Status section
            statusSection

            if !mic.transcript.isEmpty {
                Divider()
                // Minimal stats (no gamification)
                statsSection
            }

            Divider()

            // Controls
            controlsSection

            Divider()

            // Quit button
            Button("Quit Thought Crystallizer") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
        .padding()
        .frame(width: 280)
    }

    private var headerSection: some View {
        HStack(spacing: 12) {
            Image(systemName: "brain.head.profile")
                .font(.title2)
                .foregroundColor(.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text("Thought Crystallizer")
                    .font(.headline)

                HStack(spacing: 4) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)

                    Text(statusText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()
        }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !mic.transcript.isEmpty {
                Label("\(getWordCount()) words captured", systemImage: "text.bubble")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if !asrBridge.recentConcepts.isEmpty {
                Label("\(asrBridge.recentConcepts.count) concepts identified", systemImage: "lightbulb")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var statsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let pace = mic.pace {
                HStack {
                    Image(systemName: "speedometer")
                        .foregroundColor(.blue)
                    Text("\(Int(pace.currentWPM)) WPM")
                        .font(.caption)

                    if pace.isBelowThreshold {
                        Text("(slow)")
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }
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

            if mic.didPause {
                HStack {
                    Image(systemName: "stop.circle")
                        .foregroundColor(.yellow)
                    Text("Pause detected")
                        .font(.caption)
                }
                .transition(.opacity)
            }
        }
    }

    private var controlsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Debug Overlay", isOn: $showDebugHUD)
                .toggleStyle(.switch)
                .onChange(of: showDebugHUD) { newValue in
                    toggleDebugWindow(show: newValue)
                }

            Button(isPaused ? "Resume" : "Pause", systemImage: isPaused ? "play.fill" : "pause.fill") {
                isPaused.toggle()
                // TODO: Implement pause functionality
            }
            .controlSize(.small)

            Button("Clear History", systemImage: "trash") {
                mic.clearTranscript()
                // Also clear concepts
                asrBridge.recentConcepts.removeAll()
                asrBridge.thoughtConnections.removeAll()
            }
            .controlSize(.small)
        }
    }

    private var statusColor: Color {
        if mic.transcript.isEmpty {
            return .gray
        } else if mic.didPause || mic.fillerCount > 3 {
            return .orange
        } else {
            return .green
        }
    }

    private var statusText: String {
        if mic.transcript.isEmpty {
            return "Waiting for speech..."
        } else if mic.didPause {
            return "Pause detected"
        } else if mic.fillerCount > 3 {
            return "Drift detected"
        } else {
            return "Active"
        }
    }

    private func getWordCount() -> Int {
        return mic.getWordCount()
    }

    private func toggleDebugWindow(show: Bool) {
        // Implementation for debug window toggle
        if show {
            // Open debug window
            let debugView = HUDOverlayView()
                .environmentObject(mic)
                .environmentObject(asrBridge)

            let hostingController = NSHostingController(rootView: debugView)
            let window = NSWindow(contentViewController: hostingController)
            window.title = "Debug HUD"
            window.styleMask = [.titled, .closable, .resizable]
            window.setContentSize(NSSize(width: 400, height: 200))
            window.makeKeyAndOrderFront(nil)
        } else {
            // Close debug window
            NSApplication.shared.windows
                .first { $0.title == "Debug HUD" }?
                .close()
        }
    }
}
