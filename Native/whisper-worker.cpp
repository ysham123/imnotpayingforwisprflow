#include "whisper.h"
#include "audio-activity.h"
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
    std::cout << "{\"ready\":true,\"protocol\":2,\"vocabulary_token_budget\":200}\n" << std::flush;
    for (;;) {
        uint32_t count = 0;
        std::cin.read(reinterpret_cast<char *>(&count), sizeof(count));
        if (!std::cin || count == 0) break;
        if (count > dictation_audio::maximum_samples) break;
        uint32_t hints = 0;
        std::cin.read(reinterpret_cast<char *>(&hints), sizeof(hints));
        if (!std::cin || hints > 100) break;
        std::vector<std::pair<std::string, std::string>> terms;
        bool valid = true;
        for (uint32_t i = 0; i < hints; ++i) {
            std::string id(36, '\0'); uint32_t length = 0;
            std::cin.read(id.data(), id.size());
            std::cin.read(reinterpret_cast<char *>(&length), sizeof(length));
            if (!std::cin || length == 0 || length > 256) { valid = false; break; }
            std::string term(length, '\0'); std::cin.read(term.data(), term.size());
            if (!std::cin || term.find('\0') != std::string::npos) { valid = false; break; }
            terms.emplace_back(id, term);
        }
        if (!valid) break;
        std::vector<float> audio(count);
        std::cin.read(reinterpret_cast<char *>(audio.data()), count * sizeof(float));
        if (!std::cin) break;
        // Pack complete terms in saved order. Never cut a name through a token
        // boundary or restart the resident model just because words changed.
        std::string prompt; std::vector<whisper_token> prompt_tokens, candidate_tokens(1024);
        std::vector<std::string> overflow;
        const int budget = std::min(200, whisper_n_text_ctx(ctx)/2 - 1);
        for (const auto &entry : terms) {
            const std::string candidate = prompt.empty() ? " " + entry.second : prompt + ", " + entry.second;
            const int n = whisper_tokenize(ctx, candidate.c_str(), candidate_tokens.data(), candidate_tokens.size());
            if (n <= 0 || n > budget) { overflow.push_back(entry.first); continue; }
            prompt = candidate;
            prompt_tokens.assign(candidate_tokens.begin(), candidate_tokens.begin() + n);
        }
        std::string status = ",\"vocabulary_overflow\":[";
        for (size_t i = 0; i < overflow.size(); ++i) { if (i) status += ","; status += json_string(overflow[i]); }
        status += "]";
        const auto activity = dictation_audio::prepare(audio);
        if (count < 4000 || !activity.has_speech) {
            std::cout << "{\"text\":\"\"" << status << "}\n" << std::flush;
            continue;
        }
        auto params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
        params.n_threads = 6;
        params.language = "en";
        params.translate = false;
        params.no_context = true;
        if (!prompt_tokens.empty()) {
            params.prompt_tokens = prompt_tokens.data();
            params.prompt_n_tokens = static_cast<int>(prompt_tokens.size());
            params.carry_initial_prompt = true;
        }
        params.print_progress = false;
        params.print_realtime = false;
        params.print_timestamps = false;
        params.print_special = false;
        params.suppress_blank = true;
        params.suppress_nst = true;
        params.temperature = 0.0f;
        if (whisper_full(ctx, params, audio.data() + activity.begin, static_cast<int>(activity.size())) != 0) {
            std::cout << "{\"error\":\"Speech recognition failed\"}\n" << std::flush;
            continue;
        }
        std::string text;
        for (int i = 0; i < whisper_full_n_segments(ctx); ++i) {
            // Decoder-level speech confidence prevents common silence hallucinations.
            if (whisper_full_get_segment_no_speech_prob(ctx, i) > 0.65f) continue;
            text += whisper_full_get_segment_text(ctx, i);
        }
        std::cout << "{\"text\":" << json_string(text) << status << "}\n" << std::flush;
    }
    whisper_free(ctx);
    return 0;
}
