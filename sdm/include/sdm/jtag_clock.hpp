#pragma once
// JTAG TCK control: the equivalent of `jtagconfig --setparam <cable> JtagClock <freq>`.
//
// jtagconfig is a jtagd client. The setting is one AJI message (SET_PARAMETER, 0xAA) carrying
// {chain_id, "JtagClock", DWORD}; see intel/libaji_client src/jtag/jtag_client_chain.cpp.
// The AJI API is aji_set_parameter(chain, name, value), and the chain must be locked.
//
// Two ways in:
//   1. setJtagClock(chain, hz): if aji.h is available (libaji_client, or the header matching the
//      Quartus libjtag_client.so that SdmService already talks to jtagd through).
//   2. setJtagClockViaJtagconfig(cable, hz): shells out to jtagconfig. Costs one process start
//      (well under Quartus' startup) and works with no extra headers.
//
// SPECULATION until checked on hardware: the DWORD is in Hz (jtagconfig prints "24M"). setJtagClock
// returns the value read before and after, so the first bench run shows the real units.
#include <charconv>
#include <cstdint>
#include <cstdlib>
#include <format>
#include <optional>
#include <string>
#include <string_view>

namespace sdm::jtag {

// "16M", "16MHz", "400k", "6000000" -> Hz.
constexpr std::optional<std::uint32_t> parseFrequency(std::string_view s)
{
    std::uint64_t v = 0;
    auto [p, ec] = std::from_chars(s.data(), s.data() + s.size(), v);
    if (ec != std::errc{} || p == s.data()) return std::nullopt;
    std::string_view suffix(p, s.data() + s.size() - p);
    if (suffix.ends_with("Hz") || suffix.ends_with("hz")) suffix.remove_suffix(2);
    if (suffix == "M" || suffix == "m") v *= 1'000'000;
    else if (suffix == "k" || suffix == "K") v *= 1'000;
    else if (!suffix.empty()) return std::nullopt;
    if (v == 0 || v > 0xFFFFFFFFu) return std::nullopt;
    return static_cast<std::uint32_t>(v);
}

// Hz -> jtagconfig's notation ("16M", "400k", "123").
inline std::string formatFrequency(std::uint32_t hz)
{
    if (hz % 1'000'000 == 0) return std::format("{}M", hz / 1'000'000);
    if (hz % 1'000 == 0) return std::format("{}k", hz / 1'000);
    return std::format("{}", hz);
}

// POSIX single-quote escaping; cable names look like "USB-BlasterII [1-3]".
inline std::string shellQuote(std::string_view s)
{
    std::string out = "'";
    for (char c : s) out += c == '\'' ? std::string("'\\''") : std::string(1, c);
    return out + "'";
}

inline std::string jtagconfigSetClockCommand(std::string_view cable, std::uint32_t hz)
{
    return std::format("jtagconfig --setparam {} JtagClock {}", shellQuote(cable), formatFrequency(hz));
}

// Returns jtagconfig's exit status (0 = success).
inline int setJtagClockViaJtagconfig(std::string_view cable, std::uint32_t hz)
{
    return std::system(jtagconfigSetClockCommand(cable, hz).c_str());
}

} // namespace sdm::jtag

#if __has_include(<aji.h>)
#include <aji.h>

#include <expected>

namespace sdm::jtag {

struct ClockChange {
    DWORD before, after;
};

// Locks the chain, reads JtagClock, sets it, reads it back, unlocks. Call it when SdmService
// does not hold the chain lock (e.g. before constructing it), or give SdmService a hook to call
// aji_set_parameter under its own lock.
inline std::expected<ClockChange, AJI_ERROR> setJtagClock(AJI_CHAIN_ID chain, DWORD hz, DWORD lockTimeoutMs = 1000)
{
    if (auto e = aji_lock_chain(chain, lockTimeoutMs); e != AJI_NO_ERROR) return std::unexpected(e);
    struct Unlock {
        AJI_CHAIN_ID c;
        ~Unlock() { aji_unlock_chain(c); }
    } unlock{chain};

    ClockChange r{};
    if (auto e = aji_get_parameter(chain, "JtagClock", &r.before); e != AJI_NO_ERROR) return std::unexpected(e);
    if (auto e = aji_set_parameter(chain, "JtagClock", hz); e != AJI_NO_ERROR) return std::unexpected(e);
    if (auto e = aji_get_parameter(chain, "JtagClock", &r.after); e != AJI_NO_ERROR) return std::unexpected(e);
    return r;
}

} // namespace sdm::jtag
#endif
