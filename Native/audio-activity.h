#pragma once

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <vector>

namespace dictation_audio {
constexpr uint32_t sample_rate = 16000;
constexpr uint32_t maximum_samples = sample_rate * 300;
constexpr size_t window_samples = sample_rate / 50; // 20 milliseconds.
constexpr size_t padding_samples = sample_rate / 4;
constexpr size_t minimum_active_windows = 3;
constexpr double activity_rms = 0.0015;

struct ActivityRange {
    size_t begin = 0;
    size_t end = 0; // Exclusive. All pauses inside this range stay intact.
    bool has_speech = false;
    size_t size() const { return end - begin; }
};

/// Sanitize once and decide activity locally, so silence around a quiet phrase
/// cannot dilute its RMS. Three adjacent complete active windows qualify the
/// recording; edge trimming then conservatively includes every active window.
inline ActivityRange prepare(std::vector<float> &audio) {
    size_t first_active = audio.size(), last_active = 0, consecutive = 0;
    bool qualified = false;
    for (size_t begin = 0; begin < audio.size(); begin += window_samples) {
        const size_t end = std::min(begin + window_samples, audio.size());
        double energy = 0;
        for (size_t i = begin; i < end; ++i) {
            float &sample = audio[i];
            if (!std::isfinite(sample)) sample = 0;
            sample = std::clamp(sample, -1.0f, 1.0f);
            energy += static_cast<double>(sample) * sample;
        }
        const bool active = energy / static_cast<double>(end - begin) > activity_rms * activity_rms;
        if (active) {
            first_active = std::min(first_active, begin);
            last_active = end;
        }
        if (active && end - begin == window_samples) {
            if (++consecutive >= minimum_active_windows) qualified = true;
        } else { consecutive = 0; }
    }
    if (!qualified) return {};
    return {first_active > padding_samples ? first_active - padding_samples : 0,
            std::min(audio.size(), last_active + padding_samples), true};
}
} // namespace dictation_audio
