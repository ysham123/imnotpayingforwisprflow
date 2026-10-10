#include "audio-activity.h"
#include <cassert>
#include <iostream>
#include <limits>
#include <string>

using namespace dictation_audio;

int main(int argc, char **argv) {
    if (argc == 2 && std::string(argv[1]) == "--policy") {
        std::cout << sample_rate << " " << maximum_samples << "\n";
        return 0;
    }
    assert(maximum_samples == 4'800'000 && window_samples == 320 && padding_samples == 4'000);
    std::vector<float> empty;
    assert(!prepare(empty).has_speech);
    std::vector<float> silence(maximum_samples, 0);
    assert(!prepare(silence).has_speech);
    std::vector<float> noise(sample_rate, 0.001f);
    assert(!prepare(noise).has_speech);
    std::vector<float> spikes(20 * window_samples, 0);
    for (size_t i = 0; i < spikes.size(); i += window_samples * 3) {
        std::fill(spikes.begin() + i, spikes.begin() + std::min(i + window_samples * 2, spikes.size()), 0.1f);
    }
    assert(!prepare(spikes).has_speech);
    std::vector<float> partial(window_samples * 3 - 1, 0.1f);
    assert(!prepare(partial).has_speech);
    std::vector<float> minimum(window_samples * 3, 0.01f);
    auto minimal = prepare(minimum);
    assert(minimal.has_speech && minimal.begin == 0 && minimal.end == minimum.size());
    std::cout << "PASS silence, quiet noise, isolated bursts, and three complete adjacent windows\n";

    for (size_t seconds : {0, 5, 15, 60}) {
        const size_t prefix = seconds * sample_rate;
        std::vector<float> passage(prefix + 8 * window_samples + prefix, 0);
        std::fill(passage.begin() + prefix, passage.begin() + prefix + 8 * window_samples, 0.002f);
        const auto range = prepare(passage);
        assert(range.has_speech);
        assert(range.begin == (prefix > padding_samples ? prefix - padding_samples : 0));
        assert(range.end == std::min(passage.size(), prefix + 8 * window_samples + padding_samples));
    }
    std::cout << "PASS quiet speech with 0/5/15/60 seconds of surrounding silence\n";

    std::vector<float> pauses(20 * sample_rate, 0);
    std::fill(pauses.begin() + sample_rate, pauses.begin() + sample_rate * 2, 0.01f);
    std::fill(pauses.begin() + sample_rate * 17, pauses.begin() + sample_rate * 18, 0.01f);
    const auto pauseRange = prepare(pauses);
    assert(pauseRange.begin == sample_rate - padding_samples);
    assert(pauseRange.end == sample_rate * 18 + padding_samples);
    assert(pauses[sample_rate * 10] == 0 && pauseRange.size() == sample_rate * 17 + padding_samples * 2);
    std::cout << "PASS long internal pauses are retained in one continuous range\n";

    std::vector<float> invalid(4000, std::numeric_limits<float>::quiet_NaN());
    invalid[10] = std::numeric_limits<float>::infinity();
    invalid[20] = -std::numeric_limits<float>::infinity();
    assert(!prepare(invalid).has_speech);
    for (const auto sample : invalid) assert(sample == 0);
    std::vector<float> overrange(4000, 2);
    overrange[0] = -2;
    assert(prepare(overrange).has_speech && overrange[0] == -1 && overrange[1] == 1);
    std::cout << "PASS nonfinite samples sanitized and overrange input clamped\n";

    // A short edge burst remains present once the passage qualifies as speech.
    std::vector<float> edge(30 * sample_rate, 0);
    edge[10] = 0.1f;
    std::fill(edge.begin() + sample_rate * 10, edge.begin() + sample_rate * 11, 0.01f);
    edge.back() = 0.1f;
    const auto edges = prepare(edge);
    assert(edges.has_speech && edges.begin == 0 && edges.end == edge.size());
    std::cout << "PASS conservative edge padding preserves isolated active edges\n";
    std::cout << "Passed 12 native activity and silence-padding cases\n";
}
