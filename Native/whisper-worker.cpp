#include "whisper.h"
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <string>
#include <vector>

static std::string json_string(const std::string &text) {
    std::string escaped = "\"";
    for (unsigned char c : text) {
        switch (c) {
            case '"': escaped += "\\\""; break;
            case '\\': escaped += "\\\\"; break;
            case '\n': escaped += "\\n"; break;
            case '\r': escaped += "\\r"; break;
            case '\t': escaped += "\\t"; break;
            default:
                if (c < 0x20) {
                    const char *digits = "0123456789abcdef";
                    escaped += "\\u00";
                    escaped += digits[c >> 4]; escaped += digits[c & 15];
                } else { escaped += static_cast<char>(c); }
        }
    }
    return escaped + "\"";
}

int main(int argc, char **argv) {
    if (argc != 2) { std::cerr << "Expected local Whisper model path\n"; return 2; }
    auto init = whisper_context_default_params();
    init.use_gpu = true;
    whisper_context *ctx = whisper_init_from_file_with_params(argv[1], init);
    if (!ctx) { std::cout << "{\"error\":\"Speech model could not load\"}\n" << std::flush; return 3; }
    std::cout << "{\"ready\":true}\n" << std::flush;
    for (;;) {
        uint32_t count = 0;
        std::cin.read(reinterpret_cast<char *>(&count), sizeof(count));
        if (!std::cin || count == 0) break;
        if (count > 16000u * 120u) break;
        std::vector<float> audio(count);
        std::cin.read(reinterpret_cast<char *>(audio.data()), count * sizeof(float));
        if (!std::cin) break;
        double energy = 0;
        for (float &sample : audio) {
            if (!std::isfinite(sample)) sample = 0;
            sample = std::clamp(sample, -1.0f, 1.0f);
            energy += static_cast<double>(sample) * sample;
        }
        if (count < 4000 || std::sqrt(energy / count) < 0.0015) {
            std::cout << "{\"text\":\"\"}\n" << std::flush;
            continue;
        }
        auto params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
        params.n_threads = 6;
        params.language = "en";
        params.translate = false;
        params.no_context = true;
        params.print_progress = false;
        params.print_realtime = false;
        params.print_timestamps = false;
        params.print_special = false;
        params.suppress_blank = true;
        params.suppress_nst = true;
        params.temperature = 0.0f;
        if (whisper_full(ctx, params, audio.data(), count) != 0) {
            std::cout << "{\"error\":\"Speech recognition failed\"}\n" << std::flush;
            continue;
        }
        std::string text;
        for (int i = 0; i < whisper_full_n_segments(ctx); ++i) {
            // Decoder-level speech confidence prevents common silence hallucinations.
            if (whisper_full_get_segment_no_speech_prob(ctx, i) > 0.65f) continue;
            text += whisper_full_get_segment_text(ctx, i);
        }
        std::cout << "{\"text\":" << json_string(text) << "}\n" << std::flush;
    }
    whisper_free(ctx);
    return 0;
}
