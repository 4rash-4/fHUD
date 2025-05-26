// MARK: - AdvancedAnimations.swift
// Performance-optimized animation engine with proper memory management

import SwiftUI
import simd
import Combine

// MARK: - Data Models

struct AnimatedParticle: Identifiable {
    let id = UUID()
    var position: simd_float2
    var velocity: simd_float2 = .zero
    var acceleration: simd_float2 = .zero
    var age: Float = 0
    var maxAge: Float = 30.0
    var alpha: Float = 1.0
    var size: Float = 2.0
    var concept: String = ""
    var particleType: ParticleType = .thought
    var pulsePhase: Float = 0
    var targetPosition: simd_float2?
    
    enum ParticleType {
        case thought
        case connection
        case drift
        case crystallization
    }
}

struct AnimatedConnection: Identifiable {
    let id = UUID()
    var startPoint: simd_float2
    var endPoint: simd_float2
    var controlPoint1: simd_float2
    var controlPoint2: simd_float2
    var flowProgress: Float = 0
    var strength: Float = 1.0
    var age: Float = 0
    var maxAge: Float = 15.0
    var pulseOffset: Float = 0
    
    mutating func updateControlPoints() {
        let midPoint = (startPoint + endPoint) * 0.5
        let perpendicular = simd_normalize(simd_float2(-(endPoint.y - startPoint.y), endPoint.x - startPoint.x))
        let offset = perpendicular * (sin(age * 0.5) * 20 + 40)
        
        controlPoint1 = startPoint + (midPoint - startPoint) * 0.3 + offset * 0.7
        controlPoint2 = endPoint + (midPoint - endPoint) * 0.3 + offset * 0.3
    }
}

// MARK: - Animation Engine

@MainActor
class AnimationEngine: ObservableObject {
    private var displayLink: CADisplayLink?
    private var lastFrameTime: CFTimeInterval = 0
    private var noiseOffset: Float = 0
    
    @Published var animatedParticles: [AnimatedParticle] = []
    @Published var animatedConnections: [AnimatedConnection] = []
    @Published var ambientPulse: Float = 0
    @Published var globalFlow: Float = 0
    
    // Performance tracking
    private var frameCount = 0
    private var lastFPSCheck: CFTimeInterval = 0
    private var currentFPS: Double = 60.0
    private var targetFPS: Int = 60
    
    // Memory management
    private let maxParticles = 50
    private let maxConnections = 20
    
    // Cassette Futurism Colors
    static let amberPrimary = Color(red: 0.96, green: 0.65, blue: 0.14)
    static let amberGlow = Color(red: 1.0, green: 0.8, blue: 0.4)
    static let charcoalDark = Color(red: 0.12, green: 0.12, blue: 0.12)
    static let charcoalMid = Color(red: 0.2, green: 0.2, blue: 0.2)
    
    deinit {
        cleanup()
    }
    
    private func cleanup() {
        stopEngine()
        animatedParticles.removeAll()
        animatedConnections.removeAll()
    }
    
    func startEngine() {
        guard displayLink == nil else { return }
        
        displayLink = CADisplayLink(target: self, selector: #selector(frame))
        displayLink?.preferredFramesPerSecond = targetFPS
        displayLink?.add(to: .main, forMode: .common)
        
        print("🎬 Animation engine started - targeting \(targetFPS)fps")
        initializeAmbientParticles()
    }
    
    func stopEngine() {
        displayLink?.invalidate()
        displayLink = nil
        print("🎬 Animation engine stopped - final FPS: \(String(format: "%.1f", currentFPS))")
    }
    
    @objc private func frame(displayLink: CADisplayLink) {
        let currentTime = displayLink.timestamp
        let deltaTime = currentTime - lastFrameTime
        
        // Skip frame if delta is too large (e.g., app was backgrounded)
        guard deltaTime < 0.1 else {
            lastFrameTime = currentTime
            return
        }
        
        lastFrameTime = currentTime
        
        // Performance tracking
        trackPerformance(currentTime: currentTime, deltaTime: deltaTime)
        
        // Update animations
        updateAllAnimations(deltaTime: deltaTime)
        
        // Global effects
        updateGlobalEffects(deltaTime: deltaTime)
    }
    
    private func trackPerformance(currentTime: CFTimeInterval, deltaTime: CFTimeInterval) {
        frameCount += 1
        
        if currentTime - lastFPSCheck >= 1.0 {
            currentFPS = Double(frameCount) / (currentTime - lastFPSCheck)
            frameCount = 0
            lastFPSCheck = currentTime
            
            // Adaptive quality
            adaptQualityForPerformance()
        }
    }
    
    private func adaptQualityForPerformance() {
        if currentFPS < 30 && animatedParticles.count > 20 {
            // Reduce particle count for performance
            let keepCount = min(15, animatedParticles.count)
            animatedParticles = Array(animatedParticles.prefix(keepCount))
            print("⚡ Reduced particles for performance - FPS: \(String(format: "%.1f", currentFPS))")
        } else if currentFPS > 55 && animatedParticles.count < 30 {
            // Can handle more particles
            targetFPS = 60
        }
    }
    
    private func updateAllAnimations(deltaTime: CFTimeInterval) {
        let dt = Float(deltaTime)
        
        // Update particles - iterate backwards for safe removal
        for i in animatedParticles.indices.reversed() {
            updateParticlePhysics(&animatedParticles[i], deltaTime: dt)
            
            // Remove expired particles
            if animatedParticles[i].age >= animatedParticles[i].maxAge || animatedParticles[i].alpha <= 0.01 {
                animatedParticles.remove(at: i)
            }
        }
        
        // Update connections - iterate backwards for safe removal
        for i in animatedConnections.indices.reversed() {
            updateConnectionFlow(&animatedConnections[i], deltaTime: dt)
            
            // Remove expired connections
            if animatedConnections[i].age >= animatedConnections[i].maxAge || animatedConnections[i].strength <= 0.01 {
                animatedConnections.remove(at: i)
            }
        }
    }
    
    private func updateGlobalEffects(deltaTime: CFTimeInterval) {
        let dt = Float(deltaTime)
        noiseOffset += dt * 0.5
        
        // Subtle ambient pulse (breathing effect)
        ambientPulse = sin(noiseOffset * 0.8) * 0.3 + 0.7
        
        // Global flow for connections
        globalFlow += dt * 0.3
        if globalFlow > 1.0 {
            globalFlow -= 1.0
        }
    }
    
    // MARK: - Particle Physics
    
    private func updateParticlePhysics(_ particle: inout AnimatedParticle, deltaTime: Float) {
        // Apply forces
        applyFlockingBehavior(&particle)
        applyBoundaryForces(&particle)
        applyDrift(&particle, dt: deltaTime)
        applyTargetSeeking(&particle)
        
        // Verlet integration for smooth physics
        particle.position += particle.velocity * deltaTime
        particle.velocity += particle.acceleration * deltaTime
        
        // Apply damping based on particle type
        let damping: Float = particle.particleType == .drift ? 0.95 : 0.98
        particle.velocity *= damping
        particle.acceleration = .zero
        
        // Update lifecycle
        particle.age += deltaTime
        updateParticleLifecycle(&particle)
    }
    
    private func applyFlockingBehavior(_ particle: inout AnimatedParticle) {
        guard particle.particleType == .thought else { return }
        
        var separation = simd_float2.zero
        var alignment = simd_float2.zero
        var cohesion = simd_float2.zero
        var neighborCount = 0
        
        let perceptionRadius: Float = 60.0
        
        for other in animatedParticles {
            if other.id == particle.id || other.particleType != .thought { continue }
            
            let distance = simd_distance(particle.position, other.position)
            if distance < perceptionRadius && distance > 0 {
                // Separation - avoid crowding
                let diff = particle.position - other.position
                separation += simd_normalize(diff) / max(distance, 0.1)
                
                // Alignment - match velocity
                alignment += other.velocity
                
                // Cohesion - move toward center
                cohesion += other.position
                
                neighborCount += 1
            }
        }
        
        if neighborCount > 0 {
            let neighborCountF = Float(neighborCount)
            
            // Apply flocking forces with subtle influence
            particle.acceleration += separation * 0.15
            particle.acceleration += (alignment / neighborCountF - particle.velocity) * 0.08
            particle.acceleration += (cohesion / neighborCountF - particle.position) * 0.03
        }
    }
    
    private func applyBoundaryForces(_ particle: inout AnimatedParticle) {
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        let margin: Float = 80
        let force: Float = 0.2
        
        // Gentle boundary repulsion with easing
        if particle.position.x < margin {
            let strength = (margin - particle.position.x) / margin
            particle.acceleration.x += strength * strength * force
        }
        if particle.position.x > Float(bounds.width) - margin {
            let strength = (particle.position.x - (Float(bounds.width) - margin)) / margin
            particle.acceleration.x -= strength * strength * force
        }
        if particle.position.y < margin {
            let strength = (margin - particle.position.y) / margin
            particle.acceleration.y += strength * strength * force
        }
        if particle.position.y > Float(bounds.height) - margin {
            let strength = (particle.position.y - (Float(bounds.height) - margin)) / margin
            particle.acceleration.y -= strength * strength * force
        }
    }
    
    private func applyDrift(_ particle: inout AnimatedParticle, dt: Float) {
        // Subtle Perlin noise-like drift
        let time = particle.age + noiseOffset
        let frequency: Float = 0.7
        let amplitude: Float = particle.particleType == .drift ? 15.0 : 5.0
        
        let noiseX = sin(time * frequency + Float(particle.id.hashValue) * 0.01) * amplitude
        let noiseY = cos(time * frequency * 1.3 + Float(particle.id.hashValue) * 0.01) * amplitude
        
        particle.acceleration += simd_float2(noiseX, noiseY) * 0.1
        
        // Update pulse phase for visual effects
        particle.pulsePhase += dt * 2.0
        if particle.pulsePhase > Float.pi * 2 {
            particle.pulsePhase -= Float.pi * 2
        }
    }
    
    private func applyTargetSeeking(_ particle: inout AnimatedParticle) {
        guard let target = particle.targetPosition else { return }
        
        let desired = target - particle.position
        let distance = simd_length(desired)
        
        if distance > 5.0 {
            let seekForce = simd_normalize(desired) * 0.3
            particle.acceleration += seekForce
        } else {
            // Arrived at target
            particle.targetPosition = nil
        }
    }
    
    private func updateParticleLifecycle(_ particle: inout AnimatedParticle) {
        let ageRatio = particle.age / particle.maxAge
        
        // Fade out as particle ages
        particle.alpha = max(0, 1 - ageRatio * ageRatio)
        
        // Size pulsing based on type
        let basePulse = sin(particle.pulsePhase) * 0.3 + 1.0
        switch particle.particleType {
        case .thought:
            particle.size = 3.0 * basePulse
        case .connection:
            particle.size = 1.5 * basePulse
        case .drift:
            particle.size = 2.0 * basePulse * 0.7
        case .crystallization:
            particle.size = 4.0 * basePulse * 1.2
        }
    }
    
    // MARK: - Connection Animation
    
    private func updateConnectionFlow(_ connection: inout AnimatedConnection, deltaTime: Float) {
        connection.age += deltaTime
        
        // Update flow progress
        connection.flowProgress += deltaTime * 0.8
        if connection.flowProgress > 1.0 {
            connection.flowProgress -= 1.0
        }
        
        // Update control points for organic curves
        connection.updateControlPoints()
        
        // Fade based on age
        let ageRatio = connection.age / connection.maxAge
        connection.strength = max(0, 1 - ageRatio * ageRatio)
        
        // Update pulse offset
        connection.pulseOffset += deltaTime * 3.0
        if connection.pulseOffset > Float.pi * 2 {
            connection.pulseOffset -= Float.pi * 2
        }
    }
    
    // MARK: - Public Interface
    
    func addThoughtParticle(at position: CGPoint, concept: String) {
        guard animatedParticles.count < maxParticles else { return }
        
        let particle = AnimatedParticle(
            position: simd_float2(Float(position.x), Float(position.y)),
            velocity: simd_float2(
                Float.random(in: -20...20),
                Float.random(in: -20...20)
            ),
            maxAge: Float.random(in: 15...25),
            concept: concept,
            particleType: .thought,
            pulsePhase: Float.random(in: 0...Float.pi * 2)
        )
        animatedParticles.append(particle)
    }
    
    func addDriftParticles(count: Int, bounds: CGRect) {
        let particlesToAdd = min(count, maxParticles - animatedParticles.count)
        
        for _ in 0..<particlesToAdd {
            let particle = AnimatedParticle(
                position: simd_float2(
                    Float.random(in: 0...Float(bounds.width)),
                    Float.random(in: 0...Float(bounds.height))
                ),
                velocity: simd_float2(
                    Float.random(in: -10...10),
                    Float.random(in: -10...10)
                ),
                maxAge: Float.random(in: 20...40),
                particleType: .drift,
                pulsePhase: Float.random(in: 0...Float.pi * 2)
            )
            animatedParticles.append(particle)
        }
    }
    
    func addConnection(from startPoint: CGPoint, to endPoint: CGPoint) {
        guard animatedConnections.count < maxConnections else { return }
        
        var connection = AnimatedConnection(
            startPoint: simd_float2(Float(startPoint.x), Float(startPoint.y)),
            endPoint: simd_float2(Float(endPoint.x), Float(endPoint.y)),
            controlPoint1: .zero,
            controlPoint2: .zero,
            maxAge: Float.random(in: 10...20),
            pulseOffset: Float.random(in: 0...Float.pi * 2)
        )
        connection.updateControlPoints()
        animatedConnections.append(connection)
    }
    
    func crystallizeConcept(at position: CGPoint, concept: String) {
        guard animatedParticles.count + 9 <= maxParticles else { return }
        
        // Create a special crystallization particle
        let particle = AnimatedParticle(
            position: simd_float2(Float(position.x), Float(position.y)),
            velocity: .zero,
            maxAge: 45.0,
            concept: concept,
            particleType: .crystallization,
            pulsePhase: 0,
            size: 5.0
        )
        animatedParticles.append(particle)
        
        // Add radiating connection particles
        for i in 0..<8 {
            let angle = Float(i) * Float.pi * 2 / 8
            let radius: Float = 40
            let connectionPos = simd_float2(
                Float(position.x) + cos(angle) * radius,
                Float(position.y) + sin(angle) * radius
            )
            
            let connectionParticle = AnimatedParticle(
                position: connectionPos,
                velocity: simd_float2(cos(angle) * 5, sin(angle) * 5),
                maxAge: 20.0,
                particleType: .connection,
                pulsePhase: Float(i) * 0.5
            )
            animatedParticles.append(connectionParticle)
        }
    }
    
    func setParticleTarget(_ particleId: UUID, target: CGPoint) {
        if let index = animatedParticles.firstIndex(where: { $0.id == particleId }) {
            animatedParticles[index].targetPosition = simd_float2(Float(target.x), Float(target.y))
        }
    }
    
    private func initializeAmbientParticles() {
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        addDriftParticles(count: 12, bounds: bounds)
    }
    
    // MARK: - Memory Pressure Handling
    
    func handleMemoryPressure() {
        // Reduce particle count
        if animatedParticles.count > 30 {
            animatedParticles = Array(animatedParticles.prefix(20))
        }
        
        // Reduce connection count
        if animatedConnections.count > 10 {
            animatedConnections = Array(animatedConnections.prefix(5))
        }
        
        print("⚠️ Memory pressure handled - reduced animations")
    }
}