// MARK: - AdvancedAnimations.swift
//
// Houses the custom animation engine responsible for concept particles
// and ambient connections. The engine uses CADisplayLink and several
// memory‐conscious techniques (object pools, adaptive quality) to run
// smoothly on low-end hardware.

import Combine
import simd
import SwiftUI

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
        case thought, connection, drift, crystallization
    }
}

extension AnimatedParticle {
    init(position: simd_float2,
         velocity: simd_float2 = .zero,
         maxAge: Float = 30.0,
         concept: String = "",
         particleType: ParticleType = .thought,
         pulsePhase: Float = 0,
         size: Float = 2.0) {
        self.position = position
        self.velocity = velocity
        self.acceleration = .zero
        self.age = 0
        self.maxAge = maxAge
        self.alpha = 1.0
        self.size = size
        self.concept = concept
        self.particleType = particleType
        self.pulsePhase = pulsePhase
        self.targetPosition = nil
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
        let mid = (startPoint + endPoint) * 0.5
        let perp = simd_normalize(simd_float2(
            -(endPoint.y - startPoint.y),
             endPoint.x - startPoint.x))
        let offset = perp * (sin(age * 0.5) * 20 + 40)
        controlPoint1 = startPoint + (mid - startPoint) * 0.3 + offset * 0.7
        controlPoint2 = endPoint   + (mid - endPoint)   * 0.3 + offset * 0.3
    }
}

// MARK: - Animation Engine

@available(macOS 15.0, *)
@MainActor
class AnimationEngine: ObservableObject {
    private var displayLink: CADisplayLink?
    private var timer: DispatchSourceTimer?
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
    private let maxParticles = 100
    private let maxConnections = 50
    private var memoryPressureThreshold: Double = 0.8

    // Internal pools
    private var particles: [AnimatedParticle] = []
    private var connections: [AnimatedConnection] = []

    // Cassette Futurism Colors
    static let amberPrimary = Color(red: 0.96, green: 0.65, blue: 0.14)
    static let amberGlow    = Color(red: 1.0, green: 0.8,  blue: 0.4)
    static let charcoalDark = Color(red: 0.12, green: 0.12, blue: 0.12)
    static let charcoalMid  = Color(red: 0.20, green: 0.20, blue: 0.20)

    deinit {
        // synchronous teardown
        displayLink?.invalidate()
        displayLink = nil
        timer?.cancel()
        timer = nil
        animatedParticles.removeAll()
        animatedConnections.removeAll()
    }

    func startEngine() {
        guard displayLink == nil && timer == nil else { return }

        #if canImport(UIKit)
        displayLink = CADisplayLink(target: self, selector: #selector(frame(_:)))
        displayLink?.preferredFramesPerSecond = targetFPS
        displayLink?.add(to: .main, forMode: .common)
        #else
        timer = DispatchSource.makeTimerSource(queue: .main)
        timer?.schedule(deadline: .now(), repeating: 1.0 / Double(targetFPS))
        timer?.setEventHandler { [weak self] in
            guard let self = self else { return }
            Task { @MainActor in
                await self.frameTimer()
            }
        }
        timer?.resume()
        #endif

        print("🎬 Animation engine started – targeting \(targetFPS)fps")
        initializeAmbientParticles()
    }

    func stopEngine() async {
        displayLink?.invalidate()
        displayLink = nil
        timer?.cancel()
        timer = nil
        print("🎬 Animation engine stopped – final FPS: \(String(format: "%.1f", currentFPS))")
    }

    @objc private func frame(_ link: CADisplayLink) {
        Task { @MainActor in
            await frameTimer()
        }
    }

    private func frameTimer() async {
        let now = CACurrentMediaTime()
        let delta = now - lastFrameTime
        guard delta < 0.1 else {
            lastFrameTime = now
            return
        }
        lastFrameTime = now

        trackPerformance(currentTime: now, deltaTime: delta)
        updateAllAnimations(deltaTime: delta)
        updateGlobalEffects(deltaTime: delta)
        enforceMemoryLimits()
    }

    private func trackPerformance(currentTime: CFTimeInterval, deltaTime _: CFTimeInterval) {
        frameCount += 1
        if currentTime - lastFPSCheck >= 1.0 {
            currentFPS = Double(frameCount) / (currentTime - lastFPSCheck)
            frameCount = 0
            lastFPSCheck = currentTime
            adaptQualityForPerformance()
        }
    }

    private func adaptQualityForPerformance() {
        if currentFPS < 30 && animatedParticles.count > 20 {
            animatedParticles = Array(animatedParticles.prefix(15))
            print("⚡ Reduced particles – FPS: \(String(format: "%.1f", currentFPS))")
        } else if currentFPS > 55 && animatedParticles.count < 30 {
            targetFPS = 60
        }
    }

    private func updateAllAnimations(deltaTime: CFTimeInterval) {
        let dt = Float(deltaTime)
        // Particles
        for i in animatedParticles.indices.reversed() {
            updateParticlePhysics(&animatedParticles[i], deltaTime: dt)
            if animatedParticles[i].age >= animatedParticles[i].maxAge ||
               animatedParticles[i].alpha <= 0.01 {
                animatedParticles.remove(at: i)
            }
        }
        // Connections
        for i in animatedConnections.indices.reversed() {
            updateConnectionFlow(&animatedConnections[i], deltaTime: dt)
            if animatedConnections[i].age >= animatedConnections[i].maxAge ||
               animatedConnections[i].strength <= 0.01 {
                animatedConnections.remove(at: i)
            }
        }
    }

    private func updateGlobalEffects(deltaTime: CFTimeInterval) {
        let dt = Float(deltaTime)
        noiseOffset += dt * 0.5
        ambientPulse = sin(noiseOffset * 0.8) * 0.3 + 0.7
        globalFlow += dt * 0.3
        if globalFlow > 1.0 { globalFlow -= 1.0 }
    }

    // MARK: - Particle Physics

    private let dampingFactors: [AnimatedParticle.ParticleType: Float] = [
        .thought: 0.98,
        .connection: 0.95,
        .drift: 0.92,
        .crystallization: 0.96,
    ]

    private func updateParticlePhysics(_ particle: inout AnimatedParticle, deltaTime dt: Float) {
        let accel = simd_make_float2(particle.acceleration.x, particle.acceleration.y)
        particle.position += particle.velocity * dt
        particle.velocity += accel * dt
        if let d = dampingFactors[particle.particleType] {
            particle.velocity *= d
        }
    }

    private func applyFlockingBehavior(_ particle: inout AnimatedParticle) {
        guard particle.particleType == .thought else { return }
        var sep = simd_float2.zero, ali = simd_float2.zero, coh = simd_float2.zero
        var count = 0
        let radius: Float = 60
        for other in animatedParticles where other.id != particle.id {
            let dist = simd_distance(particle.position, other.position)
            if dist < radius && dist > 0 {
                let diff = particle.position - other.position
                sep += simd_normalize(diff) / max(dist, 0.1)
                ali += other.velocity
                coh += other.position
                count += 1
            }
        }
        if count > 0 {
            let n = Float(count)
            particle.acceleration += sep * 0.15
            particle.acceleration += (ali / n - particle.velocity) * 0.08
            particle.acceleration += (coh / n - particle.position) * 0.03
        }
    }

    private func applyBoundaryForces(_ particle: inout AnimatedParticle) {
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        let margin: Float = 80, force: Float = 0.2
        let x = particle.position.x, y = particle.position.y
        if x < margin {
            let s = (margin - x) / margin
            particle.acceleration.x += s * s * force
        }
        if x > Float(bounds.width) - margin {
            let s = (x - (Float(bounds.width) - margin)) / margin
            particle.acceleration.x -= s * s * force
        }
        if y < margin {
            let s = (margin - y) / margin
            particle.acceleration.y += s * s * force
        }
        if y > Float(bounds.height) - margin {
            let s = (y - (Float(bounds.height) - margin)) / margin
            particle.acceleration.y -= s * s * force
        }
    }

    private func applyDrift(_ particle: inout AnimatedParticle, dt: Float) {
        let t = particle.age + noiseOffset
        let amp: Float = (particle.particleType == .drift ? 15 : 5)
        let noiseX = sin(t * 0.7 + Float(particle.id.hashValue) * 0.01) * amp
        let noiseY = cos(t * 1.3 + Float(particle.id.hashValue) * 0.01) * amp
        particle.acceleration += simd_float2(noiseX, noiseY) * 0.1
        particle.pulsePhase += dt * 2.0
        if particle.pulsePhase > .pi * 2 {
            particle.pulsePhase -= .pi * 2
        }
    }

    private func applyTargetSeeking(_ particle: inout AnimatedParticle) {
        guard let target = particle.targetPosition else { return }
        let desired = target - particle.position
        let dist = simd_length(desired)
        if dist > 5 {
            particle.acceleration += simd_normalize(desired) * 0.3
        } else {
            particle.targetPosition = nil
        }
    }

    private func updateParticleLifecycle(_ particle: inout AnimatedParticle) {
        let ratio = particle.age / particle.maxAge
        particle.alpha = max(0, 1 - ratio * ratio)
        let pulse = sin(particle.pulsePhase) * 0.3 + 1.0
        switch particle.particleType {
        case .thought:
            particle.size = 3.0 * pulse
        case .connection:
            particle.size = 1.5 * pulse
        case .drift:
            particle.size = 2.0 * pulse * 0.7
        case .crystallization:
            particle.size = 4.0 * pulse * 1.2
        }
    }

    // MARK: - Connection Animation

    private func updateConnectionFlow(_ conn: inout AnimatedConnection, deltaTime dt: Float) {
        conn.age += dt
        conn.flowProgress += dt * 0.8
        if conn.flowProgress > 1.0 { conn.flowProgress -= 1.0 }
        conn.updateControlPoints()
        let ratio = conn.age / conn.maxAge
        conn.strength = max(0, 1 - ratio * ratio)
        conn.pulseOffset += dt * 3.0
        if conn.pulseOffset > .pi * 2 {
            conn.pulseOffset -= .pi * 2
        }
    }

    // MARK: - Public Interface

    func addThoughtParticle(at pos: CGPoint, concept: String) {
        guard animatedParticles.count < maxParticles else { return }
        let p = simd_float2(Float(pos.x), Float(pos.y))
        let v = simd_float2(
            Float.random(in: -20...20),
            Float.random(in: -20...20)
        )
        let part = AnimatedParticle(
            position: p,
            velocity: v,
            maxAge: Float.random(in: 15...25),
            concept: concept,
            particleType: .thought,
            pulsePhase: Float.random(in: 0...Float.pi*2)
        )
        animatedParticles.append(part)
    }

    func addDriftParticles(count: Int, bounds: CGRect) {
        let toAdd = min(count, maxParticles - animatedParticles.count)
        for _ in 0..<toAdd {
            let x = Float.random(in: 0...Float(bounds.width))
            let y = Float.random(in: 0...Float(bounds.height))
            let v = simd_float2(
                Float.random(in: -10...10),
                Float.random(in: -10...10)
            )
            let part = AnimatedParticle(
                position: simd_float2(x, y),
                velocity: v,
                maxAge: Float.random(in: 20...40),
                particleType: .drift,
                pulsePhase: Float.random(in: 0...Float.pi*2)
            )
            animatedParticles.append(part)
        }
    }

    func addConnection(from: CGPoint, to: CGPoint) {
        guard animatedConnections.count < maxConnections else { return }
        var c = AnimatedConnection(
            startPoint: simd_float2(Float(from.x), Float(from.y)),
            endPoint:   simd_float2(Float(to.x),   Float(to.y)),
            controlPoint1: .zero,
            controlPoint2: .zero,
            maxAge: Float.random(in: 10...20),
            pulseOffset: Float.random(in: 0...Float.pi*2)
        )
        c.updateControlPoints()
        animatedConnections.append(c)
    }

    func crystallizeConcept(at pos: CGPoint, concept: String) {
        guard animatedParticles.count + 9 <= maxParticles else { return }
        let base = simd_float2(Float(pos.x), Float(pos.y))
        let cryst = AnimatedParticle(
            position: base,
            velocity: .zero,
            maxAge: 45,
            concept: concept,
            particleType: .crystallization,
            pulsePhase: 0,
            size: 5
        )
        animatedParticles.append(cryst)
        for i in 0..<8 {
            let angle = Float(i) * (.pi*2) / 8
            let r: Float = 40
            let p = simd_float2(
                base.x + cos(angle)*r,
                base.y + sin(angle)*r
            )
            let cp = AnimatedParticle(
                position: p,
                velocity: simd_float2(cos(angle)*5, sin(angle)*5),
                maxAge: 20,
                particleType: .connection,
                pulsePhase: Float(i)*0.5
            )
            animatedParticles.append(cp)
        }
    }

    func setParticleTarget(_ id: UUID, target: CGPoint) {
        if let idx = animatedParticles.firstIndex(where: { $0.id == id }) {
            animatedParticles[idx].targetPosition = simd_float2(Float(target.x), Float(target.y))
        }
    }

    private func initializeAmbientParticles() {
        addDriftParticles(count: 12, bounds: CGRect(x: 0, y: 0, width: 800, height: 600))
    }

    // MARK: - Memory Pressure Handling

    func handleMemoryPressure() {
        if animatedParticles.count > 30 {
            animatedParticles = Array(animatedParticles.prefix(20))
        }
        if animatedConnections.count > 10 {
            animatedConnections = Array(animatedConnections.prefix(5))
        }
        print("⚠️ Memory pressure handled")
    }

    func addParticle(_ p: AnimatedParticle) {
        if particles.count >= maxParticles {
            particles.removeFirst()
        }
        particles.append(p)
    }

    func addConnection(_ c: AnimatedConnection) {
        if connections.count >= maxConnections {
            connections.removeFirst()
        }
        connections.append(c)
    }

    private func enforceMemoryLimits() {
        let usage = getCurrentMemoryUsage()
        if usage > 0.7 {
            let rem = animatedParticles.count * 3 / 10
            if rem > 0 { animatedParticles.removeFirst(rem) }
        }
    }

    private func getCurrentMemoryUsage() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let kerr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_,
                          task_flavor_t(MACH_TASK_BASIC_INFO),
                          $0, &count)
            }
        }
        if kerr == KERN_SUCCESS {
            let used = Double(info.resident_size) / (1024*1024*1024)
            return used / 8.0
        }
        return 0
    }

    private class ParticlePool {
        private var pool: [AnimatedParticle] = []
        private let maxPoolSize: Int
        init(maxPoolSize: Int) { self.maxPoolSize = maxPoolSize }
        func acquire() -> AnimatedParticle {
            pool.popLast() ?? AnimatedParticle(position: .zero)
        }
        func release(_ p: AnimatedParticle) {
            if pool.count < maxPoolSize { pool.append(p) }
        }
    }
}
