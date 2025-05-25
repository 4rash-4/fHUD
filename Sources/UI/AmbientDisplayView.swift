// MARK: - AmbientDisplayView.swift

// Beautiful ambient visualization of thought crystallization - no metrics, just flowing concepts

import Combine
import SwiftUI

struct AmbientDisplayView: View {
    @EnvironmentObject var mic: MicPipeline
    @StateObject private var asrBridge = ASRBridge(mic: MicPipeline())

    // Animation states
    @State private var conceptParticles: [ConceptParticle] = []
    @State private var connectionLines: [ConnectionLine] = []
    @State private var animationTimer: Timer?

    // Cassette futurism colors
    private let amberGlow = Color(red: 0.96, green: 0.65, blue: 0.14) // #F5A623
    private let charcoalBase = Color(red: 0.12, green: 0.12, blue: 0.12) // #1E1E1E
    private let dimAmber = Color(red: 0.96, green: 0.65, blue: 0.14).opacity(0.3)

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Background - deep charcoal
                charcoalBase.ignoresSafeArea()

                // Ambient concept flow
                conceptFlowLayer(geometry)

                // Connection visualization
                connectionLayer(geometry)

                // Gentle drift indicators (top-right)
                driftIndicatorLayer(geometry)

                // Live transcript (bottom, minimal)
                transcriptLayer(geometry)
            }
        }
        .onAppear {
            startAmbientAnimation()
        }
        .onDisappear {
            stopAmbientAnimation()
        }
        .onReceive(asrBridge.$recentConcepts) { concepts in
            updateConceptParticles(concepts)
        }
        .onReceive(asrBridge.$thoughtConnections) { connections in
            updateConnectionLines(connections)
        }
    }

    // MARK: - Concept Flow Visualization

    private func conceptFlowLayer(_: GeometryProxy) -> some View {
        ForEach(conceptParticles) { particle in
            ConceptParticleView(particle: particle)
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
            }

            if let pace = mic.pace, pace.isBelowThreshold {
                DriftIndicator(
                    icon: "speedometer",
                    color: dimAmber,
                    intensity: abs(pace.percentChange)
                )
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
                    .padding(.bottom, 20)
                    .background(
                        Rectangle()
                            .fill(charcoalBase.opacity(0.8))
                            .blur(radius: 10)
                    )
            }
        }
    }

    // MARK: - Animation Logic

    private func startAmbientAnimation() {
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            updateParticleAnimation()
            cleanupExpiredElements()
        }
    }

    private func stopAmbientAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
    }

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
                lifespan: 15.0, // 15 seconds
                animationDuration: Double.random(in: 2.0 ... 8.0)
            )

            conceptParticles.append(particle)
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
            }
        }
    }

    private func updateParticleAnimation() {
        for i in conceptParticles.indices {
            // Gentle floating motion
            conceptParticles[i].position.x += conceptParticles[i].velocity.x
            conceptParticles[i].position.y += conceptParticles[i].velocity.y

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
        let words = mic.transcript.split(separator: " ")
        return words.suffix(15).joined(separator: " ")
    }
}

// MARK: - Supporting Views

struct ConceptParticleView: View {
    let particle: ConceptParticle

    private let amberGlow = Color(red: 0.96, green: 0.65, blue: 0.14)

    var body: some View {
        Text(particle.text)
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundColor(amberGlow)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(amberGlow.opacity(0.1))
                    .overlay(
                        Capsule()
                            .stroke(amberGlow.opacity(0.3), lineWidth: 0.5)
                    )
            )
    }
}

struct ConnectionLineView: Shape {
    let line: ConnectionLine

    func path(in _: CGRect) -> Path {
        var path = Path()
        path.move(to: line.from)

        // Curved connection line
        let controlPoint = CGPoint(
            x: (line.from.x + line.to.x) / 2,
            y: min(line.from.y, line.to.y) - 20
        )

        path.addQuadCurve(to: line.to, control: controlPoint)
        return path
    }
}

struct DriftIndicator: View {
    let icon: String
    let color: Color
    let intensity: Float

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(color)
            .scaleEffect(0.8 + CGFloat(intensity * 0.4))
            .opacity(0.6 + Double(intensity * 0.4))
    }
}

// MARK: - Data Models

struct ConceptParticle: Identifiable {
    let id: UUID
    let text: String
    let category: ConceptCategory
    var position: CGPoint
    let velocity: CGPoint
    var opacity: Double
    var scale: Double
    let createdAt: Date
    let lifespan: TimeInterval
    let animationDuration: TimeInterval
}

struct ConnectionLine: Identifiable {
    let id: UUID
    let from: CGPoint
    let to: CGPoint
    let strength: Float
    var opacity: Double
    let createdAt: Date
}
