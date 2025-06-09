# fHUD Architecture Deep Dive - Note to Self

## Executive Summary
fHUD is a thought crystallizer app combining ASR (Parakeet) + LLM (Gemma) with an ambient particle visualization. Currently Python+Swift hybrid targeting macOS, with future goal of pure Swift for iOS compatibility.

## Critical Architecture Issue Discovered
**THE CORE BUG**: main_server.py sends concepts on port 8765, but Swift expects individual ASR words. This is why no words appear in the UI despite successful audio processing.

## Component Analysis

### Python Side (Current Implementation)

#### 1. main_server.py - The Orchestrator
- **Purpose**: Central hub coordinating ASR, concepts, persistence
- **Tech Stack**: Tornado async web framework
- **Key Design Choices**:
  - Shared memory ring buffer for IPC (brilliant for zero-copy)
  - SQLite with WAL mode for persistence
  - WebSocket on 8765 BUT only sends concepts, not words
- **Memory Optimizations**:
  - Ring buffer avoids copies
  - SQLite batching with 32MB cache
  - Async/await throughout
- **Issue**: Architectural mismatch - sends wrong data type

#### 2. SharedRingBuffer.py - The Speed Demon
- **Purpose**: Lock-free IPC between processes
- **Design**: Header [head, tail] + circular data buffer
- **Optimization Level**: EXTREME
  - Zero-copy data transfer
  - Single producer, multiple consumer safe
  - Memory-mapped for direct access
- **Future**: Keep this even in Swift migration as fallback

#### 3. parakeet_mlx_server.py - The ASR Engine
- **Multiple versions found** (RED FLAG):
  - Original in main dir
  - Optimized version with deduplication
  - Archive versions
- **Tech**: MLX framework for Apple Silicon
- **Design Choices**:
  - Circular audio buffer (smart)
  - Streaming inference context
  - Performance tracking (words/sec)
- **Issues**:
  - WebSocket library API mismatch
  - Audio buffer overflows (processing can't keep up)
  - No actual word emission to Swift

#### 4. concept_ws_server.py - The Thinker
- **Purpose**: Extract concepts from transcripts
- **Tech**: Gemma 3 1B via MLX
- **Port**: 8766 (correct)
- **Design**: Simple request-response pattern
- **Memory**: Model kept hot in memory

#### 5. circular_audio_buffer.py - The Audio Queue
- **Purpose**: Buffer real-time audio
- **Design**: NumPy circular buffer with locks
- **Good**: Handles overflow gracefully
- **Optimization opportunity**: Could use lock-free design

### Swift Side (UI Layer)

#### 1. ASRBridge.swift - The Connector
- **Expects**: 
  - Port 8765: Individual words `{"w": "word", "t": timestamp, "c": confidence}`
  - Port 8766: Concepts
- **Has SharedRingBuffer reader** (but unused!)
- **Design flaw**: Relies on WebSocket when shared memory available

#### 2. AmbientDisplayView.swift - The Visualizer
- **Tech**: SpriteKit for hardware acceleration
- **Optimizations**:
  - Particle count limits
  - Node reuse
  - Efficient physics
- **Beautiful**: Organic connections between concepts
- **Memory conscious**: Cleans up old nodes

#### 3. ContentView.swift - The Coordinator
- **Clean SwiftUI design**
- **Menu bar app architecture**
- **Debug overlay for monitoring**

## Architecture Smells & Opportunities

### 1. The Version Sprawl
- Multiple Parakeet implementations
- Archive folder with abandoned attempts
- No clear "blessed" version
- **Fix**: Delete all but one optimized version

### 2. The IPC Confusion
- Shared memory implemented but underutilized
- WebSocket overhead for word-by-word transmission
- Swift has SharedRingBuffer code but doesn't use it
- **Fix**: Either go all-in on shared memory OR WebSocket, not both

### 3. The Data Flow Mismatch
- Python processes: Audio → Words → Concepts → Storage
- Swift expects: Words (8765) + Concepts (8766)
- Reality: Only Concepts on 8765
- **Fix**: Add word emission to main_server.py

### 4. The Memory Architecture
- Good: Ring buffer, MLX unified memory
- Bad: SQLite for real-time data (why?)
- Ugly: Multiple models in memory simultaneously
- **Fix**: Sequential model loading as per feasibility study

### 5. The Performance Bottlenecks
- Audio buffer overflows = processing too slow
- WebSocket per-word overhead
- Python GIL limiting parallelism
- **Fix**: Batch processing, larger chunks

## Future Swift Migration Path

Based on feasibility report analysis:

### Phase 1: Fix Current Architecture (1 week)
1. Make main_server.py emit words on WebSocket
2. Choose single Parakeet implementation
3. Fix WebSocket handler signatures
4. Optimize buffer sizes

### Phase 2: Hybrid Optimization (1 month)
1. Implement shared memory reading in Swift
2. Batch word transmission
3. Add performance monitoring
4. Reduce Python dependencies

### Phase 3: Swift Components (2 months)
1. Replace Parakeet with WhisperKit
2. Convert Gemma to Core ML
3. Keep Python as fallback
4. A/B test performance

### Phase 4: Pure Swift (3 months)
1. Remove Python completely
2. Core ML for both models
3. Sequential loading for memory
4. Ship to iOS

## Memory Budget (M1 8GB Target)

Current usage:
- Parakeet MLX: ~1.2GB (FP16)
- Gemma MLX: ~2GB (FP16)
- Python overhead: ~500MB
- Swift UI: ~200MB
- Total: ~4GB (50% of system)

Optimized target:
- Parakeet INT4: ~730MB
- Gemma INT4: ~500MB
- Swift only: ~300MB
- Total: ~1.5GB (19% of system)

## Critical Insights

1. **The shared memory ring buffer is genius** - keep it even in Swift
2. **MLX is the right choice for now** - native Apple Silicon
3. **WebSocket word-by-word is wasteful** - batch or use shared memory
4. **Multiple versions = technical debt** - consolidate immediately
5. **SQLite is unnecessary overhead** - remove for real-time path

## Performance Optimization Checklist

- [ ] Fix word emission to Swift
- [ ] Consolidate to single Parakeet server
- [ ] Implement proper flow control for audio
- [ ] Batch WebSocket messages
- [ ] Profile memory usage in Instruments
- [ ] Add circuit breakers for overload
- [ ] Implement model quantization
- [ ] Test on 8GB M1 continuously

## The Philosophical Architecture

This codebase shows signs of rapid experimentation (good) but lacks consolidation (bad). The core ideas are sound:
- Real-time ASR + concept extraction
- Beautiful ambient visualization  
- Memory-efficient IPC

But execution suffers from:
- Incomplete refactoring
- Abandoned experiments
- Mismatched expectations

The path forward is clear: consolidate, optimize, then migrate to Swift.
