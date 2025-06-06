# Optimization and Debugging Guide

This document collects quick tips for running the Thought Crystallizer smoothly on low-memory Apple Silicon systems.

## Swift
- **Metal Acceleration** (`MetalDetectors.swift`)
  - Offloads filler and pause detection to the GPU when available.
  - Falls back to Swift implementations if the GPU is busy or unavailable.
- **Ring Buffers** (`RingBuffer.swift` / `SharedRingBuffer.swift`)
  - Use fixed-size buffers to avoid unbounded memory growth.
  - Shared memory avoids copying audio between processes.
- **Object Pools** (`AdvancedAnimations.swift`)
  - Particle views are reused instead of recreated.
- **Release Optimizations**
  - Build with `-O2` and enable dead code stripping for best performance.

## Python
- **Streaming ASR** (`parakeet_mlx_server.py`)
  - Processes audio chunks incrementally to keep memory usage small.
- **Concept Deduplication** (`gemma_concept_extractor.py`)
  - Filters repeated mentions before writing to the database.
- **Memory Cap** (`Scripts/start_backend.sh`)
  - Launch backend with `ulimit -v` to prevent runaway memory consumption.

## Debugging
- Run `Scripts/monitor_memory.sh` in a separate terminal to observe memory pressure.
- Use `Scripts/setup.sh` to create a clean virtual environment.
- Temporary logs can be enabled in Swift files with `print` statements guarded by `#if DEBUG`.

