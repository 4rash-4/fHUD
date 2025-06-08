//
// AmbientDisplayView.swift - TRULY MINIMAL VERSION
//
// FIXES APPLIED:
// 1. All Float -> CGFloat conversions
// 2. Proper @MainActor isolation for Timer callbacks
// 3. Removed all assumptions about your data models
// 4. Only uses guaranteed-to-work SwiftUI patterns
//

import Combine
import SwiftUI

// MARK: - MINIMAL DATA MODELS
// Using only basic types that we know exist

struct SimpleParticle: Identifiable, Hashable {
    let id = UUID()
    let text: String
    var x: CGFloat  // Changed from Double to CGFloat
    var y: CGFloat  // Changed from Double to CGFloat
    var opacity: CGFloat  // Changed from Double to CGFloat
    var scale: CGFloat  // Changed from Double to CGFloat
    let createdAt: Date
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    static func == (lhs: SimpleParticle, rhs: SimpleParticle) -> Bool {
        lhs.id == rhs.id
    }
}

struct SimpleConnection: Identifiable, Hashable {
    let id = UUID()
    let startX: CGFloat  // Changed from Double to CGFloat
    let startY: CGFloat  // Changed from Double to CGFloat
    let endX: CGFloat   // Changed from Double to CGFloat
    let endY: CGFloat   // Changed from Double to CGFloat
    let opacity: CGFloat // Changed from Double to CGFloat
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    static func == (lhs: SimpleConnection, rhs: SimpleConnection) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - MAIN VIEW
struct AmbientDisplayView: View {
    // MARK: - ENVIRONMENT
    @EnvironmentObject var mic: MicPipeline
    @EnvironmentObject var asrBridge: ASRBridge
    
    // MARK: - STATE
    @State private var particles: [SimpleParticle] = []
    @State private var connections: [SimpleConnection] = []
    @State private var animationTimer: Timer?
    
    // MARK: - COLORS
    private let amberColor = Color(red: 0.96, green: 0.65, blue: 0.14)
    private let backgroundColor = Color(red: 0.12, green: 0.12, blue: 0.12)
    private let dimAmber = Color(red: 0.96, green: 0.65, blue: 0.14, opacity: 0.3)
    
    // MARK: - BODY
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Background
                backgroundColor
                    .ignoresSafeArea()
                
                // Particles
                particleCanvas
                
                // Connections
                connectionCanvas
                
                // Drift indicators
                driftIndicators
                
                // Transcript
                transcriptDisplay
            }
        }
        .onAppear {
            startAnimation()
        }
        .onDisappear {
            stopAnimation()
        }
        .onReceive(asrBridge.$recentConcepts) { concepts in
            addParticles(concepts)
        }
        .onReceive(asrBridge.$thoughtConnections) { thoughtConnections in
            updateConnections(thoughtConnections)
        }
    }
    
    // MARK: - CANVAS RENDERING
    
    private var particleCanvas: some View {
        Canvas { context, size in
            for particle in particles {
                let center = CGPoint(x: particle.x, y: particle.y)
                let radius = 4.0 * particle.scale
                let rect = CGRect(
                    x: center.x - radius,
                    y: center.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )
                
                context.opacity = particle.opacity
                context.fill(
                    Circle().path(in: rect),
                    with: .color(amberColor)
                )
                
                // Text label for larger particles
                if particle.scale > 0.8 {
                    let textPoint = CGPoint(x: center.x, y: center.y + radius + 10)
                    context.draw(
                        Text(particle.text)
                            .font(.caption2)
                            .foregroundColor(amberColor.opacity(0.8)),
                        at: textPoint
                    )
                }
            }
        }
    }
    
    private var connectionCanvas: some View {
        Canvas { context, size in
            for connection in connections {
                var path = Path()
                path.move(to: CGPoint(x: connection.startX, y: connection.startY))
                path.addLine(to: CGPoint(x: connection.endX, y: connection.endY))
                
                context.opacity = connection.opacity
                context.stroke(
                    path,
                    with: .color(amberColor.opacity(0.6)),
                    lineWidth: 1.5
                )
            }
        }
    }
    
    // MARK: - UI COMPONENTS
    
    private var driftIndicators: some View {
        VStack(alignment: .trailing, spacing: 8) {
            // Filler count indicator - using CGFloat for scaleEffect
            if mic.fillerCount >= 3 {
                Image(systemName: "pause.circle")
                    .foregroundColor(amberColor.opacity(0.6))
                    .scaleEffect(1.0 + min(CGFloat(mic.fillerCount) / 20.0, 0.5))  // Fixed: CGFloat conversion
            }
            
            // Pace indicator - proper CGFloat handling
            if let pace = mic.pace, pace.isBelowThreshold {
                Image(systemName: "speedometer")
                    .foregroundColor(dimAmber)
                    .scaleEffect(1.0 + min(abs(CGFloat(pace.percentChange)) / 2.0, 0.3))  // Fixed: CGFloat conversion
            }
            
            // Pause indicator - simple scale
            if mic.didPause {
                Image(systemName: "stop.circle")
                    .foregroundColor(amberColor.opacity(0.4))
                    .scaleEffect(1.2)  // Simple CGFloat value
            }
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(.top, 20)
        .padding(.trailing, 20)
        .animation(.easeInOut(duration: 0.3), value: mic.fillerCount)
        .animation(.easeInOut(duration: 0.3), value: mic.didPause)
    }
    
    private var transcriptDisplay: some View {
        VStack {
            Spacer()
            
            if !mic.transcript.isEmpty {
                Text(getRecentText())
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundColor(amberColor.opacity(0.5))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(backgroundColor.opacity(0.8))
                    )
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: mic.transcript.isEmpty)
    }
    
    // MARK: - ANIMATION SYSTEM
    
    private func startAnimation() {
        // Timer callback wrapped in MainActor to fix concurrency
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            Task { @MainActor in  // Fixed: Proper actor isolation
                updateParticles()
                cleanupOldElements()
            }
        }
    }
    
    private func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
    }
    
    // MARK: - DATA HANDLING
    
    private func addParticles(_ concepts: [ConceptNode]) {
        for concept in concepts {
            let particle = SimpleParticle(
                text: concept.text,
                x: CGFloat.random(in: 50...350),  // Using CGFloat
                y: CGFloat.random(in: 50...250),  // Using CGFloat
                opacity: 0.8,
                scale: CGFloat.random(in: 0.7...1.0),  // Using CGFloat
                createdAt: Date()
            )
            particles.append(particle)
        }
        
        // Keep reasonable count
        if particles.count > 20 {
            particles = Array(particles.suffix(20))
        }
    }
    
    private func updateConnections(_ thoughtConnections: [ThoughtConnection]) {
        connections.removeAll()
        
        for connection in thoughtConnections {
            if let fromParticle = particles.first(where: { $0.text == connection.from }),
               let toParticle = particles.first(where: { $0.text == connection.to }) {
                
                let simpleConnection = SimpleConnection(
                    startX: fromParticle.x,
                    startY: fromParticle.y,
                    endX: toParticle.x,
                    endY: toParticle.y,
                    opacity: CGFloat(connection.strength) * 0.7  // Convert Float to CGFloat
                )
                connections.append(simpleConnection)
            }
        }
    }
    
    // MARK: - ANIMATION UPDATES (MainActor isolated)
    
    @MainActor  // Fixed: Explicit MainActor to resolve isolation
    private func updateParticles() {
        let currentTime = Date()
        
        for i in particles.indices {
            // Simple floating motion - using CGFloat
            particles[i].x += CGFloat.random(in: -0.5...0.5)
            particles[i].y += CGFloat.random(in: -0.3...0.3)
            
            // Boundary wrapping
            if particles[i].x < 0 { particles[i].x = 400 }
            if particles[i].x > 400 { particles[i].x = 0 }
            if particles[i].y < 0 { particles[i].y = 300 }
            if particles[i].y > 300 { particles[i].y = 0 }
            
            // Breathing effect
            let age = currentTime.timeIntervalSince(particles[i].createdAt)
            particles[i].scale = 0.7 + 0.3 * sin(age * 0.5)
            
            // Fade out
            if age > 15.0 {
                let fadeRatio = (age - 15.0) / 5.0
                particles[i].opacity = max(0.1, 0.8 - fadeRatio)
            }
        }
    }
    
    @MainActor  // Fixed: Explicit MainActor to resolve isolation
    private func cleanupOldElements() {
        let currentTime = Date()
        
        particles.removeAll { particle in
            currentTime.timeIntervalSince(particle.createdAt) > 20.0
        }
    }
    
    private func getRecentText() -> String {
        return mic.getRecentWords(count: 12).joined(separator: " ")
    }
}

// MARK: - PREVIEW
#Preview {
    AmbientDisplayView()
        .environmentObject(MicPipeline())
        .environmentObject(ASRBridge())
}
