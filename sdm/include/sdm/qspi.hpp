#pragma once
// Typed, checked QSPI access through the SDM. QspiSession is the only way to reach QSPI
// commands: constructing it sends QSPI_OPEN + QSPI_SET_CS, destroying it sends QSPI_CLOSE.
#include "sdm/adapter.hpp"
#include "sdm/error.hpp"
#include "sdm/stats.hpp"

#include <array>
#include <bit>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <format>
#include <iostream>
#include <optional>
#include <span>
#include <vector>

namespace sdm {

struct QspiLimits {
    // Max words per QSPI_WRITE / QSPI_READ. ATF allows 0x1000, the Mailbox Client IP UG says
    // 1024; the conservative value is the default until characterisation says otherwise.
    std::uint32_t maxRwWords = 1024;
};

inline constexpr std::uint32_t kEraseAlign = 4096;  // QSPI_ERASE address and length granularity
inline constexpr std::uint32_t kMaxDeviceRegBytes = 8;

// QSPI_SET_CS argument (bit positions from ATF socfpga_mailbox.h).
constexpr std::uint32_t setCsArg(std::uint32_t chipSelect, bool extDecoder = false,
                                 bool combinedAddr = false)
{
    return (chipSelect << 28) | (std::uint32_t{extDecoder} << 27) |
           (std::uint32_t{combinedAddr} << 26);
}

constexpr std::uint32_t bswap32(std::uint32_t x)
{
    return (x >> 24) | ((x >> 8) & 0xFF00) | ((x << 8) & 0xFF0000) | (x << 24);
}

// Flash bytes are packed little-endian into words (byte 0 = bits [7:0] of word 0), matching
// ATF, which hands the SDM an in-memory byte buffer as a uint32_t* on a little-endian core.
inline std::vector<std::uint32_t> packWords(std::span<const std::byte> bytes)
{
    std::vector<std::uint32_t> w((bytes.size() + 3) / 4, 0xFFFFFFFFu);
    std::memcpy(w.data(), bytes.data(), bytes.size());
    if constexpr (std::endian::native == std::endian::big)
        for (auto& x : w) x = bswap32(x);
    return w;
}

inline std::vector<std::byte> unpackWords(std::span<const std::uint32_t> words, std::size_t nbytes)
{
    std::vector<std::byte> b(nbytes);
    std::vector<std::uint32_t> w(words.begin(), words.end());
    if constexpr (std::endian::native == std::endian::big)
        for (auto& x : w) x = bswap32(x);
    std::memcpy(b.data(), w.data(), std::min(nbytes, w.size() * 4));
    return b;
}

// Best-effort capacity from the JEDEC density byte. Heuristic: most vendors encode log2(bytes);
// Micron jumps 0x19 -> 0x20 for 512 Mb and above.
constexpr std::optional<std::uint64_t> jedecCapacityBytes(std::uint8_t density)
{
    if (density >= 0x10 && density <= 0x1F) return std::uint64_t{1} << density;
    if (density >= 0x20 && density <= 0x22) return std::uint64_t{1} << (density - 6);
    return std::nullopt;
}

struct JedecId {
    std::uint8_t manufacturer, type, density;
    std::optional<std::uint64_t> capacity() const { return jedecCapacityBytes(density); }
};

template <SdmServiceLike Sdm>
class QspiSession {
public:
    explicit QspiSession(Sdm& sdm, std::uint32_t chipSelect = 0, QspiLimits limits = {},
                         CommandStats* stats = nullptr)
        : sdm_(sdm), limits_(limits), stats_(stats)
    {
        call<Command::QSPI_OPEN>({}, "");
        try {
            std::uint32_t cs = setCsArg(chipSelect);
            call<Command::QSPI_SET_CS>({&cs, 1}, std::format("cs={}", chipSelect));
        } catch (...) {
            close();
            throw;
        }
    }

    ~QspiSession() { close(); }

    QspiSession(const QspiSession&) = delete;
    QspiSession& operator=(const QspiSession&) = delete;

    const QspiLimits& limits() const { return limits_; }

    // Raw 8-word QSPI_GET_DEVICE_INFO response. Layout undocumented in public sources.
    std::vector<std::uint32_t> deviceInfo() { return words(call<Command::QSPI_GET_DEVICE_INFO>({}, "")); }

    std::vector<std::byte> readDeviceReg(std::uint8_t opcode, std::uint32_t nbytes)
    {
        if (nbytes == 0 || nbytes > kMaxDeviceRegBytes)
            throw UsageError(std::format("QSPI_READ_DEVICE_REG: nbytes {} not in 1..8", nbytes));
        std::array<std::uint32_t, 2> args{opcode, nbytes};
        auto r = call<Command::QSPI_READ_DEVICE_REG>(args, std::format("op=0x{:02x} n={}", opcode, nbytes));
        return unpackWords(words(r), nbytes);
    }

    void writeDeviceReg(std::uint8_t opcode, std::span<const std::byte> data)
    {
        if (data.size() > kMaxDeviceRegBytes)
            throw UsageError(std::format("QSPI_WRITE_DEVICE_REG: {} bytes > 8", data.size()));
        std::vector<std::uint32_t> args{opcode, static_cast<std::uint32_t>(data.size())};
        auto packed = packWords(data);
        args.insert(args.end(), packed.begin(), packed.end());
        call<Command::QSPI_WRITE_DEVICE_REG>(args, std::format("op=0x{:02x} n={}", opcode, data.size()));
    }

    void sendDeviceOp(std::uint8_t opcode)
    {
        std::uint32_t arg = opcode;
        call<Command::QSPI_SEND_DEVICE_OP>({&arg, 1}, std::format("op=0x{:02x}", opcode));
    }

    JedecId jedecId()
    {
        auto b = readDeviceReg(0x9F, 3);
        return {std::to_integer<std::uint8_t>(b[0]), std::to_integer<std::uint8_t>(b[1]),
                std::to_integer<std::uint8_t>(b[2])};
    }

    // One QSPI_ERASE command. Splitting into several commands is the caller's (FlashPlan's) job,
    // because the best command size is an open question (see ROADMAP: erase_sweep).
    void erase(std::uint32_t addr, std::uint32_t bytes)
    {
        if (addr % kEraseAlign || bytes == 0 || bytes % kEraseAlign)
            throw UsageError(std::format("QSPI_ERASE addr=0x{:08x} bytes=0x{:x}: both must be "
                                         "non-zero multiples of 4 KiB", addr, bytes));
        std::array<std::uint32_t, 2> args{addr, bytes / 4};
        call<Command::QSPI_ERASE>(args, std::format("addr=0x{:08x} bytes=0x{:x}", addr, bytes));
    }

    // Splits into QSPI_WRITE commands of at most limits().maxRwWords. The tail is padded with 0xFF.
    void write(std::uint32_t addr, std::span<const std::byte> data)
    {
        checkWordAligned("QSPI_WRITE", addr);
        auto w = packWords(data);
        for (std::size_t i = 0; i < w.size(); i += limits_.maxRwWords) {
            auto n = static_cast<std::uint32_t>(std::min<std::size_t>(limits_.maxRwWords, w.size() - i));
            std::uint32_t a = addr + static_cast<std::uint32_t>(i * 4);
            std::vector<std::uint32_t> args{a, n};
            args.insert(args.end(), w.begin() + i, w.begin() + i + n);
            call<Command::QSPI_WRITE>(args, std::format("addr=0x{:08x} words={}", a, n));
        }
    }

    std::vector<std::byte> read(std::uint32_t addr, std::uint32_t nbytes)
    {
        checkWordAligned("QSPI_READ", addr);
        std::vector<std::uint32_t> all;
        std::uint32_t total = (nbytes + 3) / 4;
        all.reserve(total);
        for (std::uint32_t i = 0; i < total; i += limits_.maxRwWords) {
            std::uint32_t n = std::min(limits_.maxRwWords, total - i);
            std::array<std::uint32_t, 2> args{addr + i * 4, n};
            auto r = words(call<Command::QSPI_READ>(args, std::format("addr=0x{:08x} words={}", args[0], n)));
            if (r.size() != n)
                throw SdmError(Command::QSPI_READ, code::OK,
                               std::format("addr=0x{:08x}: asked for {} words, got {}", args[0], n, r.size()));
            all.insert(all.end(), r.begin(), r.end());
        }
        return unpackWords(all, nbytes);
    }

    // Anything not wrapped above: raw access, still timed and error-checked.
    template <Command C>
    auto raw(std::span<const std::uint32_t> args = {}) { return call<C>(args, "raw"); }

private:
    template <Command C>
    auto call(std::span<const std::uint32_t> args, std::string context)
    {
        auto t0 = std::chrono::steady_clock::now();
        auto r = send<C>(sdm_, args);
        std::uint32_t c = r.code();
        if (stats_) stats_->record(C, std::chrono::steady_clock::now() - t0, c);
        if (c != code::OK) throw SdmError(C, c, std::move(context));
        return r;
    }

    static void checkWordAligned(const char* what, std::uint32_t addr)
    {
        if (addr % 4) throw UsageError(std::format("{} addr=0x{:08x} is not word aligned", what, addr));
    }

    void close() noexcept
    {
        if (closed_) return;
        closed_ = true;
        try {
            call<Command::QSPI_CLOSE>({}, "");
        } catch (const std::exception& e) {
            // Nothing sensible to do in a destructor; make it loud because a stale OPEN may block
            // the next session (ROADMAP: err_stale_open).
            std::clog << "[sdm] WARNING: " << e.what() << '\n';
        }
    }

    Sdm& sdm_;
    QspiLimits limits_;
    CommandStats* stats_;
    bool closed_ = false;
};

} // namespace sdm
