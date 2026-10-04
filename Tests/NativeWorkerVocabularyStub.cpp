#include "whisper.h"
#include <cassert>
#include <cstring>
#include <string>
static std::string result;
whisper_context_params whisper_context_default_params() { return {}; }
whisper_context *whisper_init_from_file_with_params(const char *, whisper_context_params) { return reinterpret_cast<whisper_context *>(1); }
void whisper_free(whisper_context *) {}
int whisper_n_text_ctx(whisper_context *) { return 448; }
int whisper_tokenize(whisper_context *, const char *text, whisper_token *tokens, int capacity) {
    const int size = std::strlen(text);
    if (size > capacity) return -size;
    for (int i = 0; i < size; ++i) tokens[i] = static_cast<unsigned char>(text[i]);
    return size;
}
whisper_full_params whisper_full_default_params(whisper_sampling_strategy) { return {}; }
int whisper_full(whisper_context *, whisper_full_params params, const float *, int) {
    assert(params.no_context && params.language && std::string(params.language) == "en");
    assert(!params.translate && params.temperature == 0);
    assert(params.prompt_n_tokens <= 200 && (params.prompt_n_tokens == 0 || params.carry_initial_prompt));
    result = "";
    for (int i = 0; i < params.prompt_n_tokens; ++i) result += static_cast<char>(params.prompt_tokens[i]);
    if (result.empty()) result = "no hints";
    return 0;
}
int whisper_full_n_segments(whisper_context *) { return 1; }
float whisper_full_get_segment_no_speech_prob(whisper_context *, int) { return 0; }
const char *whisper_full_get_segment_text(whisper_context *, int) { return result.c_str(); }
