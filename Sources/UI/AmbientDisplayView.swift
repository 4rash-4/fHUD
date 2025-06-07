// MARK: - AmbientDisplayView.swift
//
// Main on‑screen view that renders the flowing concept particles,
// animated connections and gentle drift cues.  It listens to
// `ASRBridge` for incoming concepts and updates the animation engine
// accordingly.

import Combine
import SwiftUI

struct AmbientDisplayView: View {
    @EnvironmentObject var mic: MicPipeline
    @EnvironmentObject var asrBridge: ASRBridge

    // Animation engine
    @StateObject private var animationEngine = AnimationEngine()

    // Animation states
    @State private var conceptParticles: [ConceptParticle] = []
    @State private var connectionLines: [ConnectionLine] = []
    @State private var animationTimer: Timer?

    // Cassette futurism colors
    private let amberGlow = Color(red: 0.96, green: 0.65, blue: 0.14)
    private let charcoalBase = Color(red: 0.12, green: 0.12, blue: 0.12)
    private let dimAmber = Color(red: 0.96, green: 0.65, blue: 0.14).opacity(0.3)

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Background - deep charcoal
                charcoalBase.ignoresSafeArea()

                // Animated particles layer
                AnimatedParticlesView(engine: animationEngine)

                // Ambient concept flow
                conceptFlowLayer(geometry)
                    .drawingGroup()

                // Connection visualization
                connectionLayer(geometry)
                    .drawingGroup()

                // Gentle drift indicators (top-right)
                driftIndicatorLayer(geometry)

                // Live transcript (bottom, minimal)
                transcriptLayer(geometry)
            }
        }
        .onAppear {
            startAnimations()
        }
        .onDisappear {
            stopAnimations()
        }
        .onReceive(asrBridge.$recentConcepts) { concepts in
            updateConceptParticles(concepts)
        }
        .onReceive(asrBridge.$thoughtConnections) { connections in
            updateConnectionLines(connections)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didReceiveMemoryWarningNotification)) { _ in
            animationEngine.handleMemoryPressure()
        }
        .onReceive( /* ... */ ) { _ in
            // Batch updates for performance
            withTransaction(Transaction(animation: nil)) {
                self.updateViews()
            }
        }
    }

    // MARK: - Animation Management

    private func startAnimations() {
        animationEngine.startEngine()

        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            updateParticleAnimation()
            cleanupExpiredElements()
        }
    }

    private func stopAnimations() {
        Task { @MainActor in
            await animationEngine.stopEngine()
        }
        animationTimer?.invalidate()
        animationTimer = nil
    }

    // MARK: - Concept Flow Visualization

    private func conceptFlowLayer(_: GeometryProxy) -> some View {
        // Use LazyVStack for long lists
        LazyVStack {
            ForEach(conceptParticles) { particle in
                // Use EquatableView for expensive components
                EquatableView(content: {
                    ConceptParticleView(particle: particle)
                })
                .position(particle.position)
                .opacity(particle.opacity)
                .scaleEffect(particle.scale)
                .animation(
                    .easeInOut(duration: particle.animationDuration)
                        .repeatForever(autoreverses: true),
                    value: particle.scale
                )
            }
        }
    }

    // MARK: - Connection Visualization

    private func connectionLayer(_: GeometryProxy) -> some View {
        ForEach(connectionLines) { line in
            ConnectionLineView(line: line)
                .stroke(
                    LinearGradient(
                        colors: [amberGlow.opacity(line.strength), dimAmber],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    lineWidth: 1 + (line.strength * 2)
                )
                .opacity(line.opacity)
                .animation(.easeInOut(duration: 2.0), value: line.opacity)
        }
    }

    // MARK: - Gentle Drift Indicators

    private func driftIndicatorLayer(_: GeometryProxy) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            // Subtle drift cues - no numbers, just presence
            if mic.fillerCount >= 3 {
                DriftIndicator(
                    icon: "pause.circle",
                    color: amberGlow.opacity(0.6),
                    intensity: Float(mic.fillerCount) / 10.0
                )
                .transition(.opacity.combined(with: .scale))
            }

            if let pace = mic.pace, pace.isBelowThreshold {
                DriftIndicator(
                    icon: "speedometer",
                    color: dimAmber,
                    intensity: abs(pace.percentChange)
                )
                .transition(.opacity.combined(with: .scale))
            }

            if mic.didPause {
                DriftIndicator(
                    icon: "stop.circle",
                    color: amberGlow.opacity(0.4),
                    intensity: 0.5
                )
                .transition(.opacity.combined(with: .scale))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(.top, 20)
        .padding(.trailing, 20)
        .animation(.easeInOut(duration: 0.3), value: mic.fillerCount)
        .animation(.easeInOut(duration: 0.3), value: mic.didPause)
    }

    // MARK: - Minimal Transcript

    private func transcriptLayer(_: GeometryProxy) -> some View {
        VStack {
            Spacer()

            if !mic.transcript.isEmpty {
                Text(getRecentTranscript())
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundColor(amberGlow.opacity(0.5))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(charcoalBase.opacity(0.8))
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(.ultraThinMaterial)
                            )
                    )
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
            }
        }
    }

    // MARK: - Update Methods

    private func updateConceptParticles(_ concepts: [ConceptNode]) {
        for concept in concepts {
            let particle = ConceptParticle(
                id: UUID(),
                text: concept.text,
                category: concept.category,
                position: CGPoint(
                    x: CGFloat.random(in: 100 ... 300),
                    y: CGFloat.random(in: 100 ... 200)
                ),
                velocity: CGPoint(
                    x: CGFloat.random(in: -0.5 ... 0.5),
                    y: CGFloat.random(in: -0.3 ... 0.1)
                ),
                opacity: 0.8,
                scale: 0.8,
                createdAt: Date(),
                lifespan: 15.0,
                animationDuration: Double.random(in: 2.0 ... 8.0)
            )

            conceptParticles.append(particle)

            // Add to animation engine
            animationEngine.addThoughtParticle(at: particle.position, concept: concept.text)
        }

        // Keep only recent particles (max 20)
        if conceptParticles.count > 20 {
            conceptParticles = Array(conceptParticles.suffix(20))
        }
    }

    private func updateConnectionLines(_ connections: [ThoughtConnection]) {
        connectionLines.removeAll()

        for connection in connections {
            // Find particles for this connection
            if let fromParticle = conceptParticles.first(where: { $0.text == connection.from }),
               let toParticle = conceptParticles.first(where: { $0.text == connection.to })
            {
                let line = ConnectionLine(
                    id: UUID(),
                    from: fromParticle.position,
                    to: toParticle.position,
                    strength: connection.strength,
                    opacity: Double(connection.strength * 0.8),
                    createdAt: Date()
                )

                connectionLines.append(line)

                // Add to animation engine
                animationEngine.addConnection(from: fromParticle.position, to: toParticle.position)
            }
        }
    }

    private func updateParticleAnimation() {
        for i in conceptParticles.indices {
            // Gentle floating motion
            conceptParticles[i].position.x += conceptParticles[i].velocity.x
            conceptParticles[i].position.y += conceptParticles[i].velocity.y

            // Wrap around screen edges
            if conceptParticles[i].position.x < 0 {
                conceptParticles[i].position.x = 800
            } else if conceptParticles[i].position.x > 800 {
                conceptParticles[i].position.x = 0
            }

            if conceptParticles[i].position.y < 0 {
                conceptParticles[i].position.y = 600
            } else if conceptParticles[i].position.y > 600 {
                conceptParticles[i].position.y = 0
            }

            // Breathing scale effect
            let timeSinceCreation = Date().timeIntervalSince(conceptParticles[i].createdAt)
            let breathingScale = 0.8 + 0.2 * sin(timeSinceCreation * 0.5)
            conceptParticles[i].scale = breathingScale

            // Fade out near end of life
            let ageRatio = timeSinceCreation / conceptParticles[i].lifespan
            if ageRatio > 0.7 {
                conceptParticles[i].opacity = max(0.1, 1.0 - (ageRatio - 0.7) / 0.3)
            }
        }
    }

    private func cleanupExpiredElements() {
        let now = Date()

        // Remove expired particles
        conceptParticles.removeAll { particle in
            now.timeIntervalSince(particle.createdAt) > particle.lifespan
        }

        // Remove old connections
        connectionLines.removeAll { line in
            now.timeIntervalSince(line.createdAt) > 10.0
        }
    }

    private func getRecentTranscript() -> String {
        return mic.getRecentWords(count: 15).joined(separator: " ")
    }

    private func updateViews() {
        // This function can be used to batch update any view-related state
        // For example, you could update the position of particles or the opacity of connections here
    }
}

// MARK: - Supporting Views

struct AnimatedParticlesView: View {
    @ObservedObject var engine: AnimationEngine

    var body: some View {
        Canvas { context, _ in
            // Draw particles
            for particle in engine.animatedParticles {
                let color = particleColor(for: particle.particleType)
                let opacity = particle.alpha * engine.ambientPulse

                context.opacity = opacity
                context.fill(
                    Circle().path(in: CGRect(
                        x: CGFloat(particle.position.x) - CGFloat(particle.size) / 2,
                        y: CGFloat(particle.position.y) - CGFloat(particle.size) / 2,
                        width: CGFloat(particle.size),
                        height: CGFloat(particle.size)
                    )),
                    with: .color(color)
                )
            }

            // Draw connections
            for connection in engine.animatedConnections {
                let gradient = Gradient(colors: [
                    AnimationEngine.amberGlow.opacity(Double(connection.strength)),
                    AnimationEngine.amberGlow.opacity(Double(connection.strength * 0.3)),
                ])

                var path = Path()
                path.move(to: CGPoint(x: CGFloat(connection.startPoint.x), y: CGFloat(connection.startPoint.y)))
                path.addCurve(
                    to: CGPoint(x: CGFloat(connection.endPoint.x), y: CGFloat(connection.endPoint.y)),
                    control1: CGPoint(x: CGFloat(connection.controlPoint1.x), y: CGFloat(connection.controlPoint1.y)),
                    control2: CGPoint(x: CGFloat(connection.controlPoint2.x), y: CGFloat(connection.controlPoint2.y))
                )

                context.stroke(
                    path,
                    with: .linearGradient(
                        gradient,
                        startPoint: CGPoint(x: CGFloat(connection.startPoint.x), y: CGFloat(connection.startPoint.y)),
                        endPoint: CGPoint(x: CGFloat(connection.endPoint.x), y: CGFloat(connection.endPoint.y))
                    ),
                    lineWidth: 1 + CGFloat(connection.strength)
                )
            }
        }
    }

    private func particleColor(for type: AnimatedParticle.ParticleType) -> Color {
        switch type {
        case .thought:
            return AnimationEngine.amberGlow
        case .connection:
            return AnimationEngine.amberPrimary
        case .drift:
            return AnimationEngine.amberGlow.opacity(0.5)
        case .crystallization:
            return AnimationEngine.amberGlow
        }
    }
}
