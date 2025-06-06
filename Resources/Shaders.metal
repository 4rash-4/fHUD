// Metal compute kernels used by MetalDetectors.swift
#include <metal_stdlib>
using namespace metal;

// Filler detection kernel
kernel void detect_fillers(device float* words [[buffer(0)]],
                          device float* filler_hashes [[buffer(1)]],
                          device float* results [[buffer(2)]],
                          uint index [[thread_position_in_grid]]) {
    if (index >= 30) return;

    float word_hash = words[index];
    float count = 0;

    // Check against all filler hashes
    for (int i = 0; i < 5; i++) {
        if (abs(word_hash - filler_hashes[i]) < 0.1) {
            count += 1.0;
        }
    }

    results[0] = count;
}

// Pause detection kernel
kernel void detect_pauses(device float* timestamps [[buffer(0)]],
                         device float* threshold [[buffer(1)]],
                         device float* results [[buffer(2)]],
                         uint index [[thread_position_in_grid]]) {
    if (index == 0) return;

    float pause_duration = timestamps[index] - timestamps[index - 1];
    results[index] = pause_duration > threshold[0] ? 1.0 : 0.0;
}

// Pace analysis kernel
kernel void analyze_pace(device float* wpm_values [[buffer(0)]],
                        device float* baseline [[buffer(1)]],
                        device float* results [[buffer(2)]],
                        uint index [[thread_position_in_grid]]) {
    if (index >= 12) return;

    float current = wpm_values[index];
    float base = baseline[0];
    float change = (current - base) / base;

    results[0] = current;           // current WPM
    results[1] = base;              // baseline WPM
    results[2] = change;            // percent change
    results[3] = change < -0.25 ? 1.0 : 0.0; // below threshold
}
