// fHUDApp.swift
// Ultra‑minimal spoken‑focus HUD prototype – application entry point

import SwiftUI

@main
struct fHUDApp: App {
    // Shared speech/ASR pipeline available app‑wide
    @StateObject private var micPipeline = MicPipeline()
    private let _bridge = ASRBridge(mic: micPipeline)

    var body: some Scene {
        WindowGroup {
            HUDOverlayView()
                .environmentObject(micPipeline)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.clear) // transparent overlay feel
                .ignoresSafeArea()
        }
        .windowStyle(.hiddenTitleBar) // minimal chrome
    }
}
