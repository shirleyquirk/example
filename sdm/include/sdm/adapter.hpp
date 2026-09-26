#pragma once
// The only place that knows the shape of SdmService's API. If the real class differs from
// these assumptions, fix it here and nothing else changes.
//
// Assumed:
//   Response r = sdm.template sendCommand<Command::X>();                           // no args
//   Response r = sdm.template sendCommand<Command::X>(std::span<const uint32_t>);  // with args
//   r.code()  -> SDM error code (response header [10:0])
//   r.data()  -> contiguous range of uint32_t response words, header excluded   <-- ASSUMPTION
#include "sdm/command.hpp"

#include <concepts>
#include <cstdint>
#include <span>
#include <vector>

namespace sdm {

template <class S>
concept SdmServiceLike = requires(S& s, std::span<const std::uint32_t> args) {
    { s.template sendCommand<Command::NOOP>().code() } -> std::convertible_to<std::uint32_t>;
    { s.template sendCommand<Command::QSPI_READ>(args).code() } -> std::convertible_to<std::uint32_t>;
};

template <Command C, SdmServiceLike S>
auto send(S& s, std::span<const std::uint32_t> args = {})
{
    if (args.empty()) return s.template sendCommand<C>();
    return s.template sendCommand<C>(args);
}

template <class Response>
std::vector<std::uint32_t> words(const Response& r)
{
    const auto& d = r.data();
    return std::vector<std::uint32_t>(std::begin(d), std::end(d));
}

} // namespace sdm
