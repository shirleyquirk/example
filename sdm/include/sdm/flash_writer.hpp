#pragma once
// Execute a FlashPlan through an SDM service. Phase 1 error policy: optimistic. The first
// failure stops the run and says exactly what was done and which flash range is now suspect.
// QSPI_CLOSE is always sent (QspiSession's destructor).
#include "sdm/adapter.hpp"
#include "sdm/error.hpp"
#include "sdm/flash_plan.hpp"
#include "sdm/qspi.hpp"
#include "sdm/stats.hpp"

#include <chrono>
#include <cstdint>
#include <format>
#include <iostream>
#include <optional>
#include <stdexcept>
#include <string>

namespace sdm {

struct WriteOptions {
    std::uint32_t chipSelect = 0;
    QspiLimits limits;
    bool verify = true;
    std::ostream* log = &std::clog;
};

struct WriteReport {
    std::optional<std::uint32_t> idcode;
    std::optional<JedecId> jedec;
    double eraseSeconds = 0, writeSeconds = 0, verifySeconds = 0, totalSeconds = 0;
    std::uint64_t erasedBytes = 0, writtenBytes = 0, verifiedBytes = 0;
    CommandStats stats;
};

class FlashWriteError : public std::runtime_error {
public:
    FlashWriteError(std::string phase, std::string file, std::uint32_t addr,
                    std::uint32_t suspectBegin, std::uint32_t suspectEnd, const std::string& cause)
        : std::runtime_error(std::format("{} failed at 0x{:08x} ({}): {}\n  flash in [0x{:08x}, 0x{:08x}) "
                                         "is in an unknown state",
                                         phase, addr, file.empty() ? "-" : file, cause, suspectBegin,
                                         suspectEnd)),
          phase(std::move(phase)), file(std::move(file)), addr(addr), suspectBegin(suspectBegin),
          suspectEnd(suspectEnd)
    {}
    std::string phase, file;
    std::uint32_t addr, suspectBegin, suspectEnd;
};

template <SdmServiceLike Sdm>
WriteReport writeFlash(Sdm& sdm, const FlashPlan& plan, const WriteOptions& opt = {})
{
    using Clock = std::chrono::steady_clock;
    const auto start = Clock::now();
    auto secondsSince = [](Clock::time_point t) {
        return std::chrono::duration<double>(Clock::now() - t).count();
    };
    auto log = [&](const std::string& msg) {
        if (opt.log) *opt.log << std::format("[sdm {:8.3f}s] {}\n", secondsSince(start), msg);
    };

    WriteReport rep;

    if (auto r = send<Command::GET_IDCODE>(sdm); r.code() == code::OK && !words(r).empty()) {
        rep.idcode = words(r)[0];
        log(std::format("IDCODE 0x{:08x}", *rep.idcode));
    } else {
        log(std::format("GET_IDCODE returned 0x{:03x} {} (continuing)", r.code(), errorName(r.code())));
    }

    QspiSession q(sdm, opt.chipSelect, opt.limits, &rep.stats);
    rep.jedec = q.jedecId();
    log(std::format("QSPI open, JEDEC {:02x} {:02x} {:02x}", rep.jedec->manufacturer, rep.jedec->type,
                    rep.jedec->density));

    // Host-side bounds check: past-end SDM error codes are unreliable (Altera KB 343452).
    if (auto cap = rep.jedec->capacity(); cap && !plan.spans.empty() && plan.spans.back().end > *cap)
        throw FlashWriteError("plan", "", plan.spans.back().end, 0, 0,
                              std::format("plan ends at 0x{:x} but flash is 0x{:x} bytes (from JEDEC ID)",
                                          plan.spans.back().end, *cap));

    for (const auto& s : plan.spans) {
        auto fail = [&](const char* phase, const std::string& file, std::uint32_t addr, const std::exception& e) {
            return FlashWriteError(phase, file, addr, s.begin, s.end, e.what());
        };

        auto t = Clock::now();
        for (const auto& e : s.erases) {
            try {
                q.erase(e.addr, e.bytes);
            } catch (const std::exception& ex) {
                throw fail("erase", "", e.addr, ex);
            }
            rep.erasedBytes += e.bytes;
        }
        rep.eraseSeconds += secondsSince(t);

        t = Clock::now();
        for (const auto& w : s.writes) {
            try {
                q.write(w.addr, w.data);
            } catch (const std::exception& ex) {
                throw fail("write", plan.files[w.file].name, w.addr, ex);
            }
            rep.writtenBytes += w.data.size();
        }
        rep.writeSeconds += secondsSince(t);
        log(std::format("span [0x{:08x}, 0x{:08x}) erased + {} write(s)", s.begin, s.end, s.writes.size()));
    }

    if (opt.verify) {
        auto t = Clock::now();
        constexpr std::uint32_t kChunk = 64 * 1024;
        for (const auto& f : plan.files) {
            for (std::size_t off = 0; off < f.data.size(); off += kChunk) {
                auto n = static_cast<std::uint32_t>(std::min<std::size_t>(kChunk, f.data.size() - off));
                auto addr = static_cast<std::uint32_t>(f.offset + off);
                std::vector<std::byte> got;
                try {
                    got = q.read(addr, n);
                } catch (const std::exception& ex) {
                    throw FlashWriteError("verify", f.name, addr, f.offset,
                                          static_cast<std::uint32_t>(f.offset + f.data.size()), ex.what());
                }
                for (std::uint32_t i = 0; i < n; ++i) {
                    if (got[i] != f.data[off + i])
                        throw FlashWriteError(
                            "verify", f.name, addr + i, f.offset, static_cast<std::uint32_t>(f.offset + f.data.size()),
                            std::format("read 0x{:02x}, expected 0x{:02x}", std::to_integer<int>(got[i]),
                                        std::to_integer<int>(f.data[off + i])));
                }
                rep.verifiedBytes += n;
            }
        }
        rep.verifySeconds = secondsSince(t);
        log(std::format("verified 0x{:x} bytes", rep.verifiedBytes));
    }

    rep.totalSeconds = secondsSince(start);
    return rep;
}

} // namespace sdm
