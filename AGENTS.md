# fHUD Agent Development Guide

## CRITICAL: Read This First
This is a living breathing app that works on M1 MacBook Pro with 8GB RAM. Every line of code serves a purpose. Do NOT break what works. Do NOT add complexity without removing equal complexity elsewhere.

## Current State (December 2024)
**THE ISSUE**: Swift expects ASR words via WebSocket on port 8765, but Python writes them to shared memory. Audio IS processing correctly (see logs showing 30+ words/sec), but Swift never reads from shared memory.

## CRITICAL MIGRATION: WebSocket → Shared Memory for ASR Words

### Why This Migration?
- **Performance**: Eliminates network overhead for high-frequency data (30+ words/sec)
- **Efficiency**: Zero-copy data transfer between processes
- **Latency**: Direct memory access is orders of magnitude faster
- **Resource Usage**: Reduces CPU usage from WebSocket frame processing

### Migration Strategy: Incremental Batches
Each batch MUST leave the system fully functional. Test thoroughly after each batch before proceeding.

## Swift Concurrency Safety Rules

### CRITICAL: Swift Concurrency Checklist
Before making ANY changes involving async/await, actors, or concurrent code:

1. **Retroactive Conformances (Swift 5.9+)**
   ```swift
   // WRONG - Old pattern
   extension Timer: @unchecked Sendable {}
   
   // CORRECT - Modern Swift
   extension Timer: @retroactive @unchecked Sendable {}
   ```
   **Rule**: Always use `@retroactive` when extending external types

2. **Actor Isolation with Callbacks**
   ```swift
   // WRONG - Timer callback not on MainActor
   Timer.scheduledTimer { _ in
       self?.mainActorMethod() // ERROR!
   }
   
   // CORRECT - Explicit actor context
   Timer.scheduledTimer { _ in
       Task { @MainActor in
           self?.mainActorMethod()
       }
   }
   ```
   **Rule**: Timer, DispatchQueue, and similar callbacks are NOT on MainActor

3. **Sendable Conformance for Concurrent Contexts**
   ```swift
   // If a class is captured in @Sendable closures:
   final class MyClass: Sendable {
       // All stored properties must be Sendable
       // Use locks or actors for mutable state
   }
   ```
   **Rule**: Any type captured in concurrent contexts MUST be Sendable

4. **Mutability Assumptions**
   ```swift
   // Check API docs before assuming mutability
   let buffer = ringBuffer  // Try 'let' first
   // Only use 'var' if compiler requires it
   ```
   **Rule**: Start with `let`, only use `var` when proven necessary

### CRITICAL: Actor Isolation Rules

**NEVER convert a class to an actor without understanding these rules:**

1. **Actor Method Calls Require Await**
   ```swift
   // WRONG - Calling actor method from non-actor context
   actor MyActor {
       func doWork() { }
   }
   
   DispatchQueue.global().async {
       myActor.doWork() // ERROR: Missing await
   }
   
   // CORRECT
   DispatchQueue.global().async {
       Task {
           await myActor.doWork()
       }
   }
   ```

2. **No Cross-Actor Property Mutations**
   ```swift
   // WRONG - Mutating actor property from different actor
   actor MyActor {
       var count = 0
   }
   
   Task { @MainActor in
       myActor.count = 5 // ERROR: Cannot mutate from MainActor
   }
   
   // CORRECT - Add a method to perform mutation
   actor MyActor {
       var count = 0
       func setCount(_ n: Int) { count = n }
   }
   
   Task { @MainActor in
       await myActor.setCount(5)
   }
   ```

3. **Don't Mix GCD with Actors**
   ```swift
   // WRONG - Mixing DispatchQueue with actor
   actor MyActor {
       let queue = DispatchQueue(label: "MyQueue")
       func badIdea() {
           queue.async { self.doWork() } // Multiple isolation issues!
       }
   }
   
   // CORRECT - Use Task for actor-based concurrency
   actor MyActor {
       func goodIdea() {
           Task { await doWork() }
       }
   }
   ```

4. **Actor Conversion Decision Tree**
   ```
   Should I convert this class to an actor?
   ├─ Is it primarily for data isolation? → Maybe actor
   ├─ Does it use DispatchQueue/locks? → Needs major refactor
   ├─ Is it UI-bound? → Consider @MainActor class instead
   └─ Does it need synchronous access? → Don't use actor
   ```

### Actor vs Sendable Class Guidelines

**Use Actor when:**
- Primary goal is data isolation
- Async access is acceptable
- Want automatic synchronization

**Use Sendable Class when:**
- Need synchronous access
- Already using GCD effectively
- Integrating with non-async APIs

**Use @MainActor Class when:**
- Primarily UI-related
- Needs main thread execution
- Simpler than cross-actor communication

### Pre-Change Verification
Before modifying ANY concurrent code:
1. Check if the class/struct is marked with `@MainActor`
2. Verify all captured types are Sendable
3. Understand which actor/thread callbacks execute on
4. Read API documentation for mutability requirements
5. **NEW**: If converting to actor, plan to refactor ALL call sites to use await

### Common Swift Concurrency Pitfalls
- **Timer callbacks**: Execute on arbitrary threads, not MainActor
- **URLSession callbacks**: Execute on background queues
- **DispatchQueue closures**: Execute on their specified queue
- **Task {}**: Inherits actor context from enclosing scope
- **Task.detached {}**: No actor context inherited
- **Actor methods**: Always async when called from outside
- **Actor properties**: Cannot be mutated from outside the actor

## Swift Type System Guidelines

### CRITICAL: Type Inference Rules

1. **Heterogeneous Collections Require Explicit Types**
   ```swift
   // WRONG - Ambiguous type inference
   let msg = ["type": "retransmit", "from": sequence]  // Error!
   
   // CORRECT - Explicit type annotation
   let msg: [String: Any] = ["type": "retransmit", "from": sequence]
   
   // BETTER - Use Codable struct
   struct RetransmitRequest: Codable {
       let type = "retransmit"
       let from: UInt32
   }
   ```
   **Rule**: Always explicitly type mixed-type collections or use structs

2. **withCString and "with" Pattern APIs**
   ```swift
   // WRONG - Ignoring return value
   name.withCString { ptr in
       doSomething(ptr)  // Warning: Result unused
   }
   
   // CORRECT - Return from closure
   let result = name.withCString { ptr in
       return doSomething(ptr)
   }
   
   // OR - Use @discardableResult if truly void
   _ = name.withCString { ptr in
       doSomething(ptr)
       return () // Explicit void return
   }
   ```
   **Rule**: "with" pattern APIs expect you to return from the closure

3. **Type Annotations Best Practices**
   ```swift
   // Prefer explicit types for:
   - Mixed-type collections: [String: Any]
   - Empty collections: [String] = []
   - Numeric literals with specific types: let port: UInt16 = 8080
   - Protocol conformances: let delegate: MyProtocol = MyClass()
   ```

4. **Void/Discardable Results**
   ```swift
   // If a function returns a value you don't need:
   _ = functionThatReturnsValue()
   
   // For withCString specifically:
   _ = string.withCString { cStr in
       // Use cStr
       return someValue
   }
   ```

### Type Safety Checklist
Before writing any Swift code involving collections or closures:
1. ✓ Are all collection literals homogeneous? If not, add explicit type
2. ✓ Do "with" pattern methods have proper return values?
3. ✓ Are unused results explicitly discarded with `_`?
4. ✓ Do empty collections have type annotations?

### Swift API Patterns to Remember
- **"with" methods** (withCString, withUnsafeBytes, etc.): Always return from closure
- **Heterogeneous dictionaries**: Always use explicit `[String: Any]` or Codable structs
- **Unused results**: Use `_ =` to explicitly discard
- **Type inference limits**: Swift won't infer complex generic types

---

## BATCH 1: Parallel Implementation (WebSocket + SharedMem)
**Goal**: Add shared memory reading to Swift WITHOUT breaking WebSocket

### Task 1.1: Verify Shared Memory Structure
**DO:**
1. Document the exact binary format in SharedRingBuffer:
   ```
   Header (8 bytes):
   - head: uint32 (4 bytes) - next write position
   - tail: uint32 (4 bytes) - last read position
   
   Data format per word:
   - length: uint16 (2 bytes) - total size of this entry
   - timestamp: float64 (8 bytes) - seconds since start
   - confidence: float32 (4 bytes) - 0.0 to 1.0
   - word_length: uint16 (2 bytes) - UTF-8 byte count
   - word_data: [uint8] (variable) - UTF-8 encoded word
   - padding: [uint8] (0-7 bytes) - align to 8-byte boundary
   ```
2. Add version byte at offset 8 (after header) = 0x01
3. Verify Python writes this EXACT format

**VERIFY:**
- Use `hexdump -C /path/to/shared/memory` to inspect
- Confirm byte order (little-endian on Apple Silicon)
- Test with known words like "hello" (68 65 6C 6C 6F)

### Task 1.2: Swift Shared Memory Reader Setup
**DO:**
1. In `ASRBridge.swift`, add parallel reader:
   ```swift
   private var sharedMemoryPoller: Timer?
   private var lastReadPosition: UInt32 = 0
   ```
2. Initialize memory mapping in `init()`:
   ```swift
   // Keep existing WebSocket connection
   // ADD shared memory initialization
   let memPath = "/path/to/shared/memory" // Same as Python
   initializeSharedMemory(path: memPath)
   ```
3. Start polling timer (100ms initially):
   ```swift
   sharedMemoryPoller = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
       self.checkSharedMemory()
   }
   ```

**DO NOT:**
- Remove WebSocket functionality
- Change existing data flow
- Modify Python side yet

### Task 1.3: Implement Safe Memory Reading
**DO:**
1. Add memory barrier reads for head/tail
2. Handle ring buffer wraparound:
   ```swift
   func readNextWord() -> (word: String, timestamp: Double, confidence: Float)? {
       // 1. Read head position with memory barrier
       // 2. Check if new data available (head != lastRead)
       // 3. Read word data
       // 4. Update lastRead position
       // 5. Handle wraparound if needed
   }
   ```
3. Add data validation:
   - Check length fields are reasonable (<1000 bytes)
   - Validate UTF-8 encoding
   - Verify timestamp monotonicity

**VERIFY:**
- Log both WebSocket and SharedMem words
- They MUST match exactly
- No crashes on malformed data

### Task 1.4: Add Comparison Metrics
**DO:**
1. Add counters for both sources:
   ```swift
   private var wsWordCount = 0
   private var shmWordCount = 0
   private var wsLatencySum = 0.0
   private var shmLatencySum = 0.0
   ```
2. Log every 100 words:
   ```
   [ASR Stats] WS: 500 words, avg latency 15ms
   [ASR Stats] SHM: 500 words, avg latency 0.2ms
   ```
3. Detect discrepancies immediately

**Success Criteria for Batch 1:**
- Words appear from BOTH sources
- No crashes or hangs
- Latency metrics show SharedMem is faster
- Can disable either source and system still works

---

## BATCH 2: Data Integrity & Synchronization
**Goal**: Ensure zero data loss and perfect synchronization

### Task 2.1: Add Sequence Numbers
**DO:**
1. Python side adds monotonic sequence number to each word
2. Swift tracks sequence gaps:
   ```swift
   if word.sequence != lastSequence + 1 {
       log.warn("Sequence gap: expected \(lastSequence + 1), got \(word.sequence)")
   }
   ```
3. Add recovery for gaps (request retransmission via WebSocket)

### Task 2.2: Implement Ring Buffer State Validation
**DO:**
1. Add CRC32 checksum for each word entry
2. Detect torn writes (partial data):
   ```swift
   // Read length, then validate we can read that much
   // Read data, compute checksum
   // Read stored checksum, compare
   ```
3. Add poisoned entries for debugging

### Task 2.3: Handle Edge Cases
**DO:**
1. Python crash mid-write:
   - Add sentinel values
   - Timeout detection in Swift
2. Buffer overflow:
   - Track overflow count in shared header
   - Log but don't crash
3. Swift starts before Python:
   - Graceful initialization
   - Wait for valid header

**Success Criteria for Batch 2:**
- Zero data loss over 1 hour test
- Correct recovery from all edge cases
- Performance metrics stable

---

## BATCH 3: Performance Optimization
**Goal**: Minimize CPU usage and latency

### Task 3.1: Optimize Polling
**DO:**
1. Replace timer with dispatch_source:
   ```swift
   // Monitor shared memory file for changes
   let source = DispatchSource.makeFileSystemObjectSource(
       fileDescriptor: fd,
       eventMask: .write,
       queue: .global(qos: .userInteractive)
   )
   ```
2. Fallback to efficient polling if needed
3. Batch read multiple words per wake

### Task 3.2: Memory Efficiency
**DO:**
1. Use memory-mapped I/O (already done)
2. Align reads to cache lines (64 bytes)
3. Minimize memory barriers:
   - One barrier for head read
   - Batch process all available words
   - One barrier for tail update

### Task 3.3: CPU Profiling
**DO:**
1. Profile with Instruments
2. Target <1% CPU for reader
3. Optimize hot paths:
   - Inline critical functions
   - Avoid allocations in tight loop

**Success Criteria for Batch 3:**
- CPU usage <1% for shared memory reading
- Latency consistently <1ms
- No UI stuttering

---

## BATCH 4: Primary Source Switch
**Goal**: Make shared memory the primary source

### Task 4.1: Add Automatic Fallback
**DO:**
1. Detect SharedMem health:
   ```swift
   var shmHealthy: Bool {
       // Words received in last 5 seconds
       // Sequence numbers correct
       // No checksum errors
   }
   ```
2. Auto-switch to WebSocket if unhealthy
3. Log all transitions

### Task 4.2: Update UI Indicators
**DO:**
1. Show current data source in debug overlay
2. Different particle color for fallback mode
3. User notification if persistent issues

### Task 4.3: Gradual Rollout
**DO:**
1. Add feature flag: `useSharedMemoryPrimary`
2. Start with 10% of sessions
3. Monitor error rates
4. Increase gradually to 100%

**Success Criteria for Batch 4:**
- Automatic failover works reliably
- No user-visible issues
- Performance improvement confirmed

---

## BATCH 5: WebSocket Removal & Cleanup
**Goal**: Remove redundant WebSocket word transmission

### Task 5.1: Remove Python WebSocket Words
**DO:**
1. Comment out word emission in main_server.py
2. Keep WebSocket server running (for concepts)
3. Add deprecation log for old clients

### Task 5.2: Clean Swift Implementation
**DO:**
1. Remove WebSocket word parsing
2. Keep connection for concepts only
3. Simplify error handling

### Task 5.3: Documentation & Monitoring
**DO:**
1. Update architecture diagrams
2. Document new data flow
3. Add production metrics:
   - Words per second
   - Latency percentiles
   - Error rates

**Success Criteria for Batch 5:**
- Shared memory is sole source for words
- WebSocket only handles concepts
- System more efficient than before

---

## Critical Implementation Notes

### Memory Safety
- ALWAYS validate bounds before reading
- Use Swift's UnsafeRawPointer carefully
- Never trust data from shared memory

### Concurrency
- Single writer (Python) principle
- Lock-free reads in Swift
- Memory barriers for cross-CPU coherence

### Testing Each Batch
1. Run for 30 minutes minimum
2. Monitor memory usage (must stay <2GB)
3. Verify word accuracy
4. Check CPU usage
5. Test failure scenarios

### Rollback Plan
Each batch must be revertible:
- Git commit after each batch
- Feature flags for gradual rollout
- Keep WebSocket code until Batch 5
- Monitor error rates continuously

### Performance Targets
- Latency: <1ms (vs ~15ms WebSocket)
- CPU: <1% for reading
- Memory: No additional allocation
- Throughput: >1000 words/sec capability

Remember: The goal is a faster, more efficient system. Each batch must demonstrably improve performance while maintaining reliability.

## Code Architecture Rules

### Rule 1: One Implementation Per Feature
**Current violation**: Multiple Parakeet servers exist
- `parakeet_mlx_server.py` (main)
- `optimized_parakeet_server.py` 
- `archive/parakeet_ws_server.py`

**DO**: Use ONLY `parakeet_mlx_server.py` after fixing WebSocket handler
**DO NOT**: Create new implementations "just to try"

### Rule 2: Memory is Sacred (8GB M1 Constraint)
**Current usage**: ~4GB (too high)
**Target**: <2GB total

**DO:**
- Use INT4 quantization when available
- Leverage MLX's unified memory (no CPU/GPU copies)
- Utilize MLX's lazy evaluation (arrays materialized only when needed)
- Unload models when not in use
- Reuse buffers and inference contexts
- Profile with Instruments regularly

**DO NOT:**
- Load multiple models simultaneously
- Cache unnecessarily (MLX handles this)
- Create new inference contexts per request
- Ignore buffer overflow warnings
- Forget that MLX uses shared memory with GPU

**MLX-specific optimizations**:
- Keep models in mx.float16 or mx.bfloat16
- Use streaming inference contexts for ASR
- Let MLX handle memory management (it's optimized for Apple Silicon)
- Monitor unified memory pressure via Activity Monitor

### Rule 3: Shared Memory > WebSocket
**Current**: Shared memory implemented but unused by Swift
**Future**: Swift should read shared memory directly

**DO:**
- Keep SharedRingBuffer implementation pristine
- Document the memory layout clearly:
  - Header: [head (4 bytes), tail (4 bytes)]
  - Data: Circular buffer following header
  - Use memory barriers for cross-CPU coherence
- Add version field for future compatibility
- Consider memory alignment for cache efficiency

**DO NOT:**
- Break the lock-free guarantees
- Add complex synchronization
- Change the header format
- Use locks (defeats the purpose)

**Performance notes**:
- Lock-free ring buffer can achieve millions of ops/sec
- Zero-copy between processes via mmap
- Cache-aligned structures prevent false sharing
- Single writer principle avoids contention

## The Data Flow (How It Should Work)

```
Audio Input (16kHz)
    ↓
Circular Audio Buffer
    ↓
Parakeet ASR (MLX)
    ↓
Individual Words → Shared Memory Ring Buffer
    ↓                      ↓
    ↓                 Swift Direct Read (FUTURE)
    ↓
WebSocket 8765 (CURRENT)
    ↓
Swift ASRBridge
    ↓
AmbientDisplayView (SpriteKit)
    ↓
Concept Extraction Request → WebSocket 8766
                                ↓
                           Gemma (MLX)
                                ↓
                           Concepts back
```

## WebSocket Protocol Specification

### Port 8765 - ASR Words
**Message format:**
```json
{
  "w": "word",      // The transcribed word
  "t": 1234.56,     // Timestamp (float, seconds)
  "c": 0.95         // Confidence (0.0-1.0)
}
```

### Port 8766 - Concepts
**Request format:**
```json
{
  "type": "extract_concepts",
  "text": "transcribed text here"
}
```

**Response format:**
```json
{
  "type": "concepts",
  "data": ["concept1", "concept2"],
  "timestamp": 1234.56
}
```

## Performance Optimization Guidelines

### Audio Processing
**Buffer size**: 1.5 seconds (24000 samples at 16kHz)
**Overlap**: 0.5 seconds for streaming
**DO NOT** change without profiling

### Model Inference
**Parakeet**: Keep stream context alive between chunks
**Gemma**: Batch multiple sentences when possible
**DO NOT** create new contexts repeatedly

### WebSocket Optimization
**Current issue**: Per-word overhead
**Future fix**: Batch 5-10 words per message
**Implementation**: Create asyncio.Queue per client, dedicated sender coroutine
**Format for batched:**
```json
{
  "batch": [
    {"w": "word1", "t": 1.0, "c": 0.95},
    {"w": "word2", "t": 1.1, "c": 0.94}
  ]
}
```

**Key optimizations from research**:
- Disable permessage-deflate (do compression manually if needed)
- Use asyncio.Queue for each client to avoid create_task() overhead
- Keep send buffer small to detect backpressure early
- Merge messages to reduce frame construction overhead

## Future Swift Migration Plan

### Phase 1 (Current): Python Backend + Swift UI
- Fix word emission bug
- Optimize memory usage
- Consolidate implementations

### Phase 2 (Month 1): Hybrid Optimization
- Swift reads shared memory directly
- Reduce WebSocket usage
- Add performance metrics

### Phase 3 (Month 2): Swift Components
- Replace Parakeet with WhisperKit
- Convert Gemma to Core ML
- Keep Python for development

### Phase 4 (Month 3): Pure Swift
- Remove all Python
- Ship to iOS
- Maintain <1.5GB memory

## Testing Requirements

### Before EVERY Commit
1. Run on M1 MacBook Pro 8GB
2. Monitor memory usage (must stay <2GB)
3. Check for buffer overflows
4. Verify words appear in UI
5. Test for 5 minutes continuous operation

### Performance Benchmarks
- ASR: >7x realtime (RTF)
- Concepts: <2 second response
- Memory: <2GB peak
- CPU: <50% sustained

## Common Pitfalls to Avoid

### 1. The WebSocket Handler Trap
**Wrong**: `async def handle_client(self, websocket, path):`
**Right**: `async def handle_client(self, websocket):`
(Check your websockets library version!)

### 2. The Memory Leak Pattern
**Wrong**: Creating new inference contexts per request
**Right**: Reuse contexts, explicit cleanup

### 3. The Threading Disaster
**Wrong**: Spawning threads everywhere
**Right**: Use async/await consistently

### 4. The Import Hell
**Wrong**: Adding new dependencies freely
**Right**: Every import needs justification

## Code Style Rules

### Python
- Type hints for all functions
- Docstrings for public methods
- logging.info() for important events
- logging.debug() for detailed traces
- NO print() statements

### Swift
- SwiftUI for UI components
- Combine for reactive patterns
- SpriteKit for visualization only
- Clear separation of concerns

## Emergency Procedures

### If Memory Explodes
1. Check for model duplication
2. Profile with Instruments
3. Add explicit deallocation
4. Reduce buffer sizes

### If Words Stop Appearing
1. Check WebSocket connections
2. Verify message format
3. Check for Python exceptions
4. Monitor buffer overflows

### If App Crashes
1. Check console logs
2. Reduce concurrent operations
3. Add circuit breakers
4. Test on higher-spec machine

## The Golden Rules

1. **It works on 8GB M1** - Don't break this
2. **Real-time is non-negotiable** - No user-visible delays
3. **Memory efficiency over features** - We're not building Siri
4. **One way to do things** - No alternative implementations
5. **Swift is the future** - Every decision should help migration

## Contact for Clarification
If something is unclear, ASK before implementing. Bad assumptions create technical debt. The codebase should get simpler over time, not more complex.

Remember: We're building a focused tool that does one thing perfectly - crystallize thoughts through ambient visualization. Everything else is secondary.
