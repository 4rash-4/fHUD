//
// AmbientDisplayView.swift - Minimal Working Version
//
// A clean, functional implementation that:
// - Shows floating concept particles with text labels
// - Draws simple connections between related concepts
// - Displays drift indicators (filler, pause, pace)
// - Shows scrolling transcript at bottom
// - Fits perfectly on 13" MacBook (1280x800)
//

import SwiftUI
import Combine

// MARK: - Main View
struct AmbientDisplayView: View {
    // MARK: - Environment
    @EnvironmentObject var mic: MicPipeline
    @EnvironmentObject var asrBridge: ASRBridge
    @StateObject private var animationEngine = AnimationEngine()
    
    // MARK: - State
    @State private var conceptPositions: [String: CGPoint] = [:]
    @State private var particleLifetimes: [String: Date] = [:]
    
    // MARK: - Constants
    private let amber = Color(red: 0.96, green: 0.65, blue: 0.14)
    private let charcoal = Color(red: 0.12, green: 0.12, blue: 0.12)
    private let dimAmber = Color(red: 0.96, green: 0.65, blue: 0.14, opacity: 0.3)
    
    // Layout constants for 1280x800 display
    private let margin: CGFloat = 30
    private let transcriptHeight: CGFloat = 60
    private let particleSize: CGFloat = 50
    
    // MARK: - Body
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Layer 1: Background
                charcoal.ignoresSafeArea()
                
                // Layer 2: Animated particles from engine
                // Using Canvas directly since AnimatedParticlesView might not be accessible
                Canvas { context, size in
                    // Draw ambient particles
                    for particle in animationEngine.animatedParticles {
                        let opacity = Double(particle.alpha) * Double(animationEngine.ambientPulse)
                        
                        context.opacity = opacity
                        context.fill(
                            Circle().path(in: CGRect(
                                x: CGFloat(particle.position.x) - CGFloat(particle.size) / 2,
                                y: CGFloat(particle.position.y) - CGFloat(particle.size) / 2,
                                width: CGFloat(particle.size),
                                height: CGFloat(particle.size)
                            )),
                            with: .color(amber.opacity(0.3))
                        )
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                
                // Layer 3: Concept connections
                conceptConnectionsLayer
                
                // Layer 4: Concept particles
                conceptParticlesLayer
                
                // Layer 5: Drift indicators (top-right)
                driftIndicatorsLayer
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.top, 150)
                    .padding(.trailing, margin)
                
                // Layer 6: Transcript bar (bottom)
                transcriptBarLayer
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        }
        .onAppear {
            setupView()
        }
        .onReceive(asrBridge.$recentConcepts) { concepts in
            handleNewConcepts(concepts)
        }
        .onReceive(Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()) { _ in
            updateParticlePositions()
            cleanupOldParticles()
        }
    }
    
    // MARK: - Layer Components
    
    /// Simple concept particles with text labels
    private var conceptParticlesLayer: some View {
        ForEach(Array(conceptPositions.keys), id: \.self) { concept in
            if let position = conceptPositions[concept] {
                Text(concept)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(charcoal)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(amber.opacity(particleOpacity(for: concept)))
                    )
                    .position(position)
                    .animation(.easeInOut(duration: 0.3), value: position)
            }
        }
    }
    
    /// Simple lines between related concepts
    private var conceptConnectionsLayer: some View {
        Canvas { context, size in
            // Draw connections from ASRBridge
            for connection in asrBridge.thoughtConnections {
                if let fromPos = conceptPositions[connection.from],
                   let toPos = conceptPositions[connection.to] {
                    
                    var path = Path()
                    path.move(to: fromPos)
                    path.addLine(to: toPos)
                    
                    context.stroke(
                        path,
                        with: .color(amber.opacity(Double(connection.strength) * 0.5)),
                        lineWidth: 1.5
                    )
                }
            }
        }
    }
    
    /// Drift indicators with simple visual cues
    private var driftIndicatorsLayer: some View {
        VStack(alignment: .trailing, spacing: 12) {
            // Filler indicator
            if mic.fillerCount >= 3 {
                HStack {
                    Text("Drift detected")
                        .font(.caption)
                        .foregroundColor(amber.opacity(0.8))
                    
                    Image(systemName: "pause.circle.fill")
                        .foregroundColor(amber)
                        .scaleEffect(1.0 + CGFloat(mic.fillerCount - 3) * 0.1)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(charcoal.opacity(0.9))
                )
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            
            // Pace indicator
            if let pace = mic.pace, pace.isBelowThreshold {
                HStack {
                    Text("Pace slow")
                        .font(.caption)
                        .foregroundColor(dimAmber)
                    
                    Image(systemName: "speedometer")
                        .foregroundColor(dimAmber)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(charcoal.opacity(0.9))
                )
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            
            // Pause indicator
            if mic.didPause {
                HStack {
                    Text("Breathe")
                        .font(.caption)
                        .foregroundColor(amber.opacity(0.6))
                    
                    Image(systemName: "wind")
                        .foregroundColor(amber.opacity(0.6))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(charcoal.opacity(0.9))
                )
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: mic.fillerCount)
        .animation(.easeInOut(duration: 0.3), value: mic.didPause)
    }
    
    /// Scrolling transcript bar at bottom
    private var transcriptBarLayer: some View {
        VStack(spacing: 0) {
            if !mic.transcript.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(mic.transcript.suffix(200))  // Last 200 chars
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundColor(amber.opacity(0.6))
                        .lineLimit(1)
                        .padding(.horizontal, margin)
                }
                .frame(height: transcriptHeight)
                .background(
                    Rectangle()
                        .fill(charcoal.opacity(0.95))
                        .overlay(
                            Rectangle()
                                .fill(amber.opacity(0.1))
                                .frame(height: 1),
                            alignment: .top
                        )
                )
            }
        }
    }
    
    // MARK: - Helper Methods
    
    private func setupView() {
        animationEngine.startEngine()
        
        // Add some initial drift particles for ambience
        animationEngine.addDriftParticles(
            count: 5,
            bounds: CGRect(x: 0, y: 0, width: 1280, height: 800)
        )
    }
    
    private func handleNewConcepts(_ concepts: [ConceptNode]) {
        // Add new concept particles (max 3 at a time to avoid overwhelm)
        for concept in concepts.prefix(3) {
            // Skip if already displayed
            guard conceptPositions[concept.text] == nil else { continue }
            
            // Random position within safe bounds
            let x = CGFloat.random(in: margin + particleSize...(1280 - margin - particleSize))
            let y = CGFloat.random(in: margin + particleSize...(800 - transcriptHeight - particleSize))
            
            conceptPositions[concept.text] = CGPoint(x: x, y: y)
            particleLifetimes[concept.text] = Date()
            
            // Also add to animation engine for extra effects
            animationEngine.addThoughtParticle(
                at: CGPoint(x: x, y: y),
                concept: concept.text
            )
        }
        
        // Limit total particles to 20
        if conceptPositions.count > 20 {
            removeOldestParticles(count: conceptPositions.count - 20)
        }
    }
    
    private func updateParticlePositions() {
        // Simple floating motion for all particles
        for (concept, position) in conceptPositions {
            // Gentle drift
            let dx = sin(Date().timeIntervalSince1970 * 0.5 + Double(concept.hashValue)) * 0.3
            let dy = cos(Date().timeIntervalSince1970 * 0.3 + Double(concept.hashValue)) * 0.2
            
            var newPosition = position
            newPosition.x += dx
            newPosition.y += dy
            
            // Keep within bounds
            newPosition.x = max(margin + particleSize, min(1280 - margin - particleSize, newPosition.x))
            newPosition.y = max(margin + particleSize, min(800 - transcriptHeight - particleSize, newPosition.y))
            
            conceptPositions[concept] = newPosition
        }
    }
    
    private func cleanupOldParticles() {
        let now = Date()
        let maxAge: TimeInterval = 120 // 2 minutes
        
        // Find particles older than maxAge
        let expiredConcepts = particleLifetimes.compactMap { (concept, created) -> String? in
            return now.timeIntervalSince(created) > maxAge ? concept : nil
        }
        
        // Remove expired particles
        for concept in expiredConcepts {
            conceptPositions.removeValue(forKey: concept)
            particleLifetimes.removeValue(forKey: concept)
        }
    }
    
    private func removeOldestParticles(count: Int) {
        // Sort by age and remove oldest
        let sortedByAge = particleLifetimes.sorted { $0.value < $1.value }
        for (concept, _) in sortedByAge.prefix(count) {
            conceptPositions.removeValue(forKey: concept)
            particleLifetimes.removeValue(forKey: concept)
        }
    }
    
    private func particleOpacity(for concept: String) -> Double {
        guard let created = particleLifetimes[concept] else { return 0.8 }
        
        let age = Date().timeIntervalSince(created)
        let maxAge: TimeInterval = 120 // 2 minutes
        
        // Fade out in last 20 seconds
        if age > maxAge - 20 {
            let fadeRatio = (maxAge - age) / 20
            return 0.8 * fadeRatio
        }
        
        return 0.8
    }
}

// MARK: - Preview
#Preview {
    AmbientDisplayView()
        .environmentObject(MicPipeline())
        .environmentObject(ASRBridge(mic: MicPipeline()))
        .frame(width: 1280, height: 800)
}
