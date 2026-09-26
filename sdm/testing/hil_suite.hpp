#pragma once
// Hardware-in-the-loop suite, templated on the service so it runs against FakeSdm in CI and
// against the real SdmService on a bench. Only touches [scratchBase, scratchBase + scratchBytes).
//
//  runAssertions(): stable pass/fail checks.
//  characterise():  probes that RECORD behaviour (one JSON object per line) and never fail.
//                   The output is the raw material for the failure-mode catalogue.
#include "sdm/adapter.hpp"
#include "sdm/error.hpp"
#include "sdm/qspi.hpp"

#include <algorithm>
#include <array>
#include <chrono>
#include <cstdint>
#include <format>
#include <functional>
#include <ostream>
#include <string>
#include <vector>

namespace sdm::hil {

struct Config {
    std::uint32_t scratchBase = 0x00F00000;  // must be 4 KiB aligned
    std::uint32_t scratchBytes = 1u << 20;   // must be >= 256 KiB for the erase sweep
    std::uint32_t chipSelect = 0;
    QspiLimits limits;
};

struct Result {
    std::string name;
    bool pass;
    std::string detail;
};

namespace detail {

inline std::vector<std::byte> pattern(std::size_t n, std::uint32_t seed)
{
    std::vector<std::byte> v(n);
    std::uint32_t x = seed * 2654435761u + 1;
    for (auto& b : v) {
        x ^= x << 13; x ^= x >> 17; x ^= x << 5;
        b = std::byte(x);
    }
    return v;
}

inline double msSince(std::chrono::steady_clock::time_point t)
{
    return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t).count();
}

} // namespace detail

template <SdmServiceLike Sdm>
std::vector<Result> runAssertions(Sdm& sdm, const Config& cfg)
{
    std::vector<Result> out;
    auto check = [&](std::string name, auto&& body) {
        try {
            std::string detail;
            bool ok = body(detail);
            out.push_back({std::move(name), ok, std::move(detail)});
        } catch (const std::exception& e) {
            out.push_back({std::move(name), false, e.what()});
        }
    };
    using detail::pattern;
    const auto base = cfg.scratchBase;

    check("identity", [&](std::string& d) {
        auto r = send<Command::GET_IDCODE>(sdm);
        auto w = words(r);
        d = w.empty() ? "" : std::format("IDCODE 0x{:08x}", w[0]);
        return r.code() == code::OK && w.size() == 1 && w[0] != 0 && w[0] != 0xFFFFFFFF;
    });
    check("config_status", [&](std::string& d) {
        auto r = send<Command::CONFIG_STATUS>(sdm);
        auto w = words(r);
        d = w.empty() ? "" : std::format("state 0x{:08x}", w[0]);
        return r.code() == code::OK && !w.empty() && (w[0] & 0xF0000000) != 0xF0000000;
    });
    check("qspi_session_reopen", [&](std::string&) {
        { QspiSession q(sdm, cfg.chipSelect, cfg.limits); }
        { QspiSession q(sdm, cfg.chipSelect, cfg.limits); }
        return true;
    });
    check("jedec", [&](std::string& d) {
        QspiSession q(sdm, cfg.chipSelect, cfg.limits);
        auto a = q.jedecId(), b = q.jedecId();
        d = std::format("{:02x} {:02x} {:02x}", a.manufacturer, a.type, a.density);
        bool stable = a.manufacturer == b.manufacturer && a.type == b.type && a.density == b.density;
        return stable && a.manufacturer != 0x00 && a.manufacturer != 0xFF;
    });
    check("wel_toggle", [&](std::string& d) {
        QspiSession q(sdm, cfg.chipSelect, cfg.limits);
        q.sendDeviceOp(0x06);  // WREN
        auto on = std::to_integer<int>(q.readDeviceReg(0x05, 1)[0]);
        q.sendDeviceOp(0x04);  // WRDI
        auto off = std::to_integer<int>(q.readDeviceReg(0x05, 1)[0]);
        d = std::format("SR after WREN 0x{:02x}, after WRDI 0x{:02x}", on, off);
        return (on & 0x02) && !(off & 0x02);
    });
    check("erase_reads_ff", [&](std::string&) {
        QspiSession q(sdm, cfg.chipSelect, cfg.limits);
        q.erase(base, 4096);
        auto r = q.read(base, 4096);
        return std::ranges::all_of(r, [](std::byte b) { return b == std::byte{0xFF}; });
    });
    for (std::uint32_t words : {1u, 64u, cfg.limits.maxRwWords}) {
        check(std::format("write_read_{}w", words), [&](std::string&) {
            QspiSession q(sdm, cfg.chipSelect, cfg.limits);
            auto data = pattern(words * 4, words);
            q.erase(base, 16384);
            q.write(base, data);
            return q.read(base, words * 4) == data;
        });
    }
    check("close_on_throw", [&](std::string& d) {
        try {
            QspiSession q(sdm, cfg.chipSelect, cfg.limits);
            q.erase(base + 1, 4096);  // UsageError, thrown before anything is sent
        } catch (const UsageError&) {
        }
        QspiSession again(sdm, cfg.chipSelect, cfg.limits);  // would fail if CLOSE was skipped
        d = "reopened after exception";
        return true;
    });
    return out;
}

// NOTE: probes deliberately send commands the host-side checks would refuse, via raw<>().
template <SdmServiceLike Sdm>
void characterise(Sdm& sdm, const Config& cfg, std::ostream& jsonl)
{
    using namespace std::chrono;
    const auto base = cfg.scratchBase;
    auto emit = [&](const std::string& probe, const std::string& fields) {
        jsonl << std::format("{{\"probe\":\"{}\",{}}}\n", probe, fields);
    };
    auto codeOf = [&](auto&& fn) -> std::uint32_t {
        try { fn(); return code::OK; }
        catch (const SdmError& e) { return e.sdmCode; }
    };

    // latency_floor: per-command overhead of the transport (jtagd round trip + SDM).
    {
        std::vector<double> ms;
        for (int i = 0; i < 200; ++i) {
            auto t = steady_clock::now();
            send<Command::NOOP>(sdm);
            ms.push_back(detail::msSince(t));
        }
        std::ranges::sort(ms);
        emit("latency_floor", std::format("\"n\":200,\"p50_ms\":{:.3f},\"p99_ms\":{:.3f},\"max_ms\":{:.3f}",
                                          ms[100], ms[198], ms[199]));
    }

    // err_no_open: QSPI command with no session.
    {
        std::array<std::uint32_t, 2> a{base, 1};
        emit("err_no_open", std::format("\"code\":\"0x{:03x}\"", send<Command::QSPI_READ>(sdm, a).code()));
    }

    QspiSession q(sdm, cfg.chipSelect, QspiLimits{0x2000}, nullptr);  // limits lifted for probing

    // max_words: largest accepted QSPI_READ size (binary search), then the code just above it.
    {
        std::uint32_t lo = 1, hi = 0x2000;
        auto ok = [&](std::uint32_t n) {
            std::array<std::uint32_t, 2> a{base, n};
            return codeOf([&] { q.template raw<Command::QSPI_READ>(a); }) == code::OK;
        };
        while (lo < hi) {
            std::uint32_t mid = (lo + hi + 1) / 2;
            if (ok(mid)) lo = mid; else hi = mid - 1;
        }
        std::array<std::uint32_t, 2> a{base, lo + 1};
        auto c = codeOf([&] { q.template raw<Command::QSPI_READ>(a); });
        emit("max_words_read", std::format("\"max\":{},\"code_above\":\"0x{:03x}\"", lo, c));
    }

    // erase_sweep: same total region, varying erase size per command. Answers whether bigger
    // erase commands are faster (sector vs subsector erase inside the SDM).
    for (std::uint32_t block : {4096u, 32768u, 65536u, 262144u}) {
        const std::uint32_t total = 262144;
        auto t = steady_clock::now();
        std::uint32_t c = code::OK;
        for (std::uint32_t a = 0; a < total && c == code::OK; a += block)
            c = codeOf([&] { q.erase(base + a, block); });
        emit("erase_sweep", std::format("\"block\":{},\"total\":{},\"ms\":{:.3f},\"code\":\"0x{:03x}\"", block,
                                        total, detail::msSince(t), c));
    }

    // write_throughput by chunk size.
    for (std::uint32_t words : {64u, 256u, 1024u, 4096u}) {
        const std::uint32_t total = 65536;
        q.erase(base, total);
        auto data = detail::pattern(total, words);
        auto t = steady_clock::now();
        std::uint32_t c = code::OK;
        for (std::uint32_t off = 0; off < total && c == code::OK; off += words * 4) {
            std::vector<std::uint32_t> a{base + off, words};
            auto w = packWords(std::span(data).subspan(off, words * 4));
            a.insert(a.end(), w.begin(), w.end());
            c = codeOf([&] { q.template raw<Command::QSPI_WRITE>(a); });
        }
        double ms = detail::msSince(t);
        emit("write_throughput", std::format("\"words\":{},\"ms\":{:.3f},\"MBps\":{:.3f},\"code\":\"0x{:03x}\"",
                                             words, ms, total / 1e3 / ms, c));
    }

    // Error codes for misuse (compare against the table in PROTOCOL.md §2).
    auto probe = [&](const char* name, auto&& fn) { emit(name, std::format("\"code\":\"0x{:03x}\"", codeOf(fn))); };
    probe("err_erase_unaligned", [&] { std::array<std::uint32_t, 2> a{base + 4, 0x400}; q.template raw<Command::QSPI_ERASE>(a); });
    probe("err_erase_len", [&] { std::array<std::uint32_t, 2> a{base, 0x10}; q.template raw<Command::QSPI_ERASE>(a); });
    probe("err_write_unaligned", [&] { std::array<std::uint32_t, 3> a{base + 2, 1, 0}; q.template raw<Command::QSPI_WRITE>(a); });
    probe("err_past_end", [&] { std::array<std::uint32_t, 2> a{0xFFFFF000, 1}; q.template raw<Command::QSPI_READ>(a); });
    probe("err_direct", [&] { q.template raw<Command::QSPI_DIRECT>(); });
    probe("err_double_open", [&] { q.template raw<Command::QSPI_OPEN>(); });

    // write_unerased: program over programmed data. NOR ANDs; does the SDM refuse instead?
    {
        q.erase(base, 4096);
        std::array<std::uint32_t, 3> a{base, 1, 0x0F0F0F0F};
        q.template raw<Command::QSPI_WRITE>(a);
        a[2] = 0xFF00FF00;
        auto c = codeOf([&] { q.template raw<Command::QSPI_WRITE>(a); });
        auto r = q.read(base, 4);
        std::uint32_t v = std::to_integer<std::uint32_t>(r[0]) | std::to_integer<std::uint32_t>(r[1]) << 8 |
                          std::to_integer<std::uint32_t>(r[2]) << 16 | std::to_integer<std::uint32_t>(r[3]) << 24;
        emit("write_unerased", std::format("\"code\":\"0x{:03x}\",\"readback\":\"0x{:08x}\",\"and\":\"0x{:08x}\"",
                                           c, v, 0x0F0F0F0Fu & 0xFF00FF00u));
    }
}

} // namespace sdm::hil
