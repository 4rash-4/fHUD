# Thought Crystallizer (fHUD)

This repository contains a macOS prototype for a personal "heads up display" that helps reinforce healthy self‑talk patterns. The app continuously transcribes live microphone input, detects moments of attention drift and gently visualises themes that appear in your speech. The project was intentionally built for very small Apple Silicon machines (8 GB M1) and therefore contains many memory‑conscious optimisations.

## Features

- **Real‑time speech recognition** powered by a local Parakeet model (via MLX)
- **Concept extraction** using a lightweight Gemma model
- **Hardware accelerated detectors** (`MetalDetectors.swift`) for pause, filler and pace analysis when a GPU is available
- **Zero‑copy audio sharing** between the Python backend and Swift UI through a POSIX shared memory ring buffer
- **Minimal SwiftUI interface** with a cassette‑futuristic aesthetic. The `AmbientDisplayView` shows gentle drift cues and floating concept particles while `HUDOverlayView` provides an optional debug overlay.
- **Python backend servers** for transcription and concept extraction. `main_server.py` orchestrates these services and exposes WebSocket endpoints consumed by Swift.

## Repository Layout

```
fHUD/
├── Resources/         – Metal shader source used by the detectors
├── Scripts/           – Utility scripts (memory monitoring etc.)
├── Sources/           – All Swift code
│   ├── Core/          – ASR bridge, drift detectors and utilities
│   ├── UI/            – SwiftUI visual components and animations
│   └── fHUDApp.swift  – Application entry point
├── python/            – Python servers and concept extraction logic
└── Tests/             – Empty placeholders for future unit tests
```

## Building

The Swift portion is a standard Swift Package. On macOS 13+ with Xcode installed you can build and run the app with:

```bash
swift build
open .build/debug/fHUD.app
```

The Python backend requires the packages listed in `python/requirements.txt`. If running locally ensure you have Python 3.10+ and install the dependencies:

```bash
python3 -m venv venv
source venv/bin/activate
pip install -r python/requirements.txt
```

Then launch the backend:

```bash
python python/main_server.py
```

The Swift app expects the backend to be available on `ws://127.0.0.1:8765` for transcription events and `ws://127.0.0.1:8766` for concept messages.

## Usage

1. Start `main_server.py`.
2. Build and run the Swift app.
3. Speak naturally. The bottom overlay will show a short transcript along with subtle drift indicators.
4. The ambient view will display softly moving particles and concept links as the system learns from your speech.

## Development Notes

- The project intentionally keeps dependencies minimal. Some files such as `ASRProvider.swift` or the test stubs are empty placeholders for future expansion.
- `Scripts/monitor_memory.sh` is helpful when testing on lower‑RAM machines. Run it in a separate terminal to observe memory pressure.
- The Python and Swift components communicate through a tiny 64 kB shared memory region defined in `SharedRingBuffer.swift` and used from `main_server.py`.
- `Scripts/setup.sh` creates a Python virtual environment and installs dependencies.
- `Scripts/start_backend.sh` launches the Tornado backend with a 2 GB memory cap and automatically starts the memory monitor.

## Optimization & Debugging

See [OPTIMIZATION_GUIDE.md](OPTIMIZATION_GUIDE.md) for a checklist of low-hanging performance tips. The highlights:

- GPU-based detectors via Metal when available
- Zero-copy shared memory between Swift and Python
- Object pooling and adaptive animation quality
- Start the backend with `Scripts/start_backend.sh` to keep memory usage in check

## License

This project is released under the MIT license. See [LICENSE](LICENSE) for details.

