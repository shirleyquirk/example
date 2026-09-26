#pragma once
#include "sdm/command.hpp"

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <format>
#include <map>
#include <string>
#include <vector>

namespace sdm {

// Per-command latency samples. Cheap enough to always keep on: a full 256 MiB flash is
// ~65k commands at 4 KiB each.
class CommandStats {
public:
    using Duration = std::chrono::duration<double, std::milli>;

    void record(Command c, Duration d, std::uint32_t code) {
        auto& e = entries_[c];
        e.samples.push_back(d.count());
        if (code != 0) ++e.errors;
    }

    std::string summary() const {
        std::string out = std::format("{:<24} {:>7} {:>6} {:>9} {:>9} {:>9} {:>10}\n", "command",
                                      "count", "errors", "p50 ms", "p99 ms", "max ms", "total s");
        for (auto [cmd, e] : entries_) {
            std::ranges::sort(e.samples);
            auto pct = [&](double p) {
                return e.samples[std::min(e.samples.size() - 1,
                                          static_cast<std::size_t>(p * e.samples.size()))];
            };
            double total = 0;
            for (double s : e.samples) total += s;
            out += std::format("{:<24} {:>7} {:>6} {:>9.3f} {:>9.3f} {:>9.3f} {:>10.3f}\n",
                               name(cmd), e.samples.size(), e.errors, pct(0.5), pct(0.99),
                               e.samples.back(), total / 1000.0);
        }
        return out;
    }

private:
    struct Entry {
        std::vector<double> samples;
        std::size_t errors = 0;
    };
    std::map<Command, Entry> entries_;
};

} // namespace sdm
