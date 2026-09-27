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

enum class EraseMethod {
    Sdm,     // QSPI_ERASE: the SDM picks the flash opcode (probably from SFDP; see ERASE_AND_CLOCK.md)
    Direct,  // flash erase opcodes via QSPI_WRITE_DEVICE_REG + WIP polling; op sizes must be 4K/32K/64K
};

struct WriteOptions {
    std::uint32_t chipSelect = 0;
    QspiLimits limits;
    EraseMethod eraseMethod = EraseMethod::Sdm;
    // Direct erase address width. nullopt = 4-byte if the JEDEC capacity is > 16 MiB.
    std::optional<bool> fourByteAddr;
    // Speculative speed-up for factory-fresh flash: program without erasing, verify, and only
    // erase + rewrite a span whose readback mismatches. Leaves non-file bytes in a span
    // untouched. Requires verify. NOT safe on flash with internal ECC that forbids re-programming
    // (e.g. Infineon SEMPER) - it is fine on plain NOR like MT25Q/MX25.
    bool writeFirst = false;
    bool verify = true;
    std::ostream* log = &std::clog;
};

struct WriteReport {
    std::optional<std::uint32_t> idcode;
    std::optional<JedecId> jedec;
    double eraseSeconds = 0, writeSeconds = 0, verifySeconds = 0, totalSeconds = 0;
    std::uint64_t erasedBytes = 0, writtenBytes = 0, verifiedBytes = 0;
    std::size_t spansRepaired = 0;  // writeFirst: spans that were not blank
    std::uint64_t busyPolls = 0;    // direct erase: WIP polls
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

    if (opt.writeFirst && !opt.verify) throw UsageError("writeFirst needs verify: it detects non-blank flash by readback");
    if (opt.eraseMethod == EraseMethod::Direct)
        for (const auto& s : plan.spans)
            for (const auto& e : s.erases)
                if (!std::ranges::contains(kEraseOpcodes, e.bytes, &EraseOpcode::bytes))
                    throw UsageError(std::format("direct erase needs 4K/32K/64K ops, plan has 0x{:x} at 0x{:08x} "
                                                 "(set PlanOptions::eraseOpSizes)", e.bytes, e.addr));

    WriteReport rep;

    if (auto r = send<Command::GET_IDCODE>(sdm); r.code() == code::OK && !words(r).empty()) {
        rep.idcode = words(r)[0];
        log(std::format("IDCODE 0x{:08x}", *rep.idcode));
    } else {
        log(std::format("GET_IDCODE returned 0x{:03x} {} (continuing)", r.code(), errorName(r.code())));
    }

    QspiSession q(sdm, opt.chipSelect, opt.limits, &rep.stats);
    rep.jedec = q.jedecId();
    auto cap = rep.jedec->capacity();
    log(std::format("QSPI open, JEDEC {:02x} {:02x} {:02x}", rep.jedec->manufacturer, rep.jedec->type,
                    rep.jedec->density));

    // Host-side bounds check: past-end SDM error codes are unreliable (Altera KB 343452).
    if (cap && !plan.spans.empty() && plan.spans.back().end > *cap)
        throw FlashWriteError("plan", "", plan.spans.back().end, 0, 0,
                              std::format("plan ends at 0x{:x} but flash is 0x{:x} bytes (from JEDEC ID)",
                                          plan.spans.back().end, *cap));
    const bool fourByte = opt.fourByteAddr.value_or(!cap || *cap > (16u << 20));

    for (const auto& s : plan.spans) {
        auto fail = [&](const char* phase, const std::string& file, std::uint32_t addr, const std::exception& e) {
            return FlashWriteError(phase, file, addr, s.begin, s.end, e.what());
        };

        auto eraseSpan = [&] {
            auto t = Clock::now();
            for (const auto& e : s.erases) {
                try {
                    if (opt.eraseMethod == EraseMethod::Direct)
                        rep.busyPolls += q.eraseDirect(e.addr, e.bytes, fourByte);
                    else
                        q.erase(e.addr, e.bytes);
                } catch (const std::exception& ex) {
                    throw fail("erase", "", e.addr, ex);
                }
                rep.erasedBytes += e.bytes;
            }
            rep.eraseSeconds += secondsSince(t);
        };

        auto writeSpan = [&] {
            auto t = Clock::now();
            for (const auto& w : s.writes) {
                try {
                    q.write(w.addr, w.data);
                } catch (const std::exception& ex) {
                    throw fail("write", plan.files[w.file].name, w.addr, ex);
                }
                rep.writtenBytes += w.data.size();
            }
            rep.writeSeconds += secondsSince(t);
        };

        // Returns a description of the first mismatch in this span's files, if any.
        auto verifySpan = [&]() -> std::optional<FlashWriteError> {
            auto t = Clock::now();
            constexpr std::uint32_t kChunk = 64 * 1024;
            for (const auto& f : plan.files) {
                if (f.offset < s.begin || f.offset >= s.end) continue;
                for (std::size_t off = 0; off < f.data.size(); off += kChunk) {
                    auto n = static_cast<std::uint32_t>(std::min<std::size_t>(kChunk, f.data.size() - off));
                    auto addr = static_cast<std::uint32_t>(f.offset + off);
                    std::vector<std::byte> got;
                    try {
                        got = q.read(addr, n);
                    } catch (const std::exception& ex) {
                        throw fail("verify", f.name, addr, ex);
                    }
                    auto [g, e] = std::ranges::mismatch(got, std::span(f.data).subspan(off, n));
                    rep.verifiedBytes += n;
                    if (g != got.end()) {
                        rep.verifySeconds += secondsSince(t);
                        auto at = static_cast<std::uint32_t>(addr + (g - got.begin()));
                        return FlashWriteError("verify", f.name, at, s.begin, s.end,
                                               std::format("read 0x{:02x}, expected 0x{:02x}", std::to_integer<int>(*g),
                                                           std::to_integer<int>(*e)));
                    }
                }
            }
            rep.verifySeconds += secondsSince(t);
            return std::nullopt;
        };

        if (!opt.writeFirst) eraseSpan();
        writeSpan();
        if (opt.verify) {
            auto bad = verifySpan();
            if (bad && opt.writeFirst) {
                log(std::format("span [0x{:08x}, 0x{:08x}) not blank ({}), erasing and rewriting", s.begin, s.end,
                                bad->what()));
                ++rep.spansRepaired;
                eraseSpan();
                writeSpan();
                bad = verifySpan();
            }
            if (bad) throw *bad;
        }
        log(std::format("span [0x{:08x}, 0x{:08x}) done: {} erase op(s), {} write(s){}", s.begin, s.end,
                        opt.writeFirst ? 0 : s.erases.size(), s.writes.size(), opt.verify ? ", verified" : ""));
    }

    rep.totalSeconds = secondsSince(start);
    return rep;
}

} // namespace sdm
