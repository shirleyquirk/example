#pragma once
// SDM response error codes (response header bits [10:0]). Source: U-Boot mailbox_s10.h.
#include "sdm/command.hpp"

#include <cstdint>
#include <format>
#include <stdexcept>
#include <string>
#include <string_view>

namespace sdm {

namespace code {
inline constexpr std::uint32_t OK = 0x000;
inline constexpr std::uint32_t INVALID_COMMAND = 0x001;
inline constexpr std::uint32_t UNKNOWN_BR = 0x002;
inline constexpr std::uint32_t UNKNOWN = 0x003;
inline constexpr std::uint32_t INVALID_LEN = 0x004;
inline constexpr std::uint32_t INVALID_INDIRECT_SETTING = 0x005;
inline constexpr std::uint32_t CMD_INVALID_ON_SRC = 0x006;
inline constexpr std::uint32_t CLIENT_ID_NO_MATCH = 0x008;
inline constexpr std::uint32_t INVALID_ADDR = 0x009;
inline constexpr std::uint32_t AUTH_FAIL = 0x00A;
inline constexpr std::uint32_t TIMEOUT = 0x00B;
inline constexpr std::uint32_t HW_NOT_RDY = 0x00C;
inline constexpr std::uint32_t FUNC_NOT_SUPPORTED = 0x00F;
inline constexpr std::uint32_t NOT_CONFIGURED = 0x100;
inline constexpr std::uint32_t DEVICE_BUSY = 0x1FF;
inline constexpr std::uint32_t NO_VALID_RESP_AVAILABLE = 0x2FF;
inline constexpr std::uint32_t ERROR = 0x3FF;
} // namespace code

constexpr std::string_view errorName(std::uint32_t c)
{
    switch (c) {
    case code::OK: return "OK";
    case code::INVALID_COMMAND: return "INVALID_COMMAND";
    case code::UNKNOWN_BR: return "UNKNOWN_BR";
    case code::UNKNOWN: return "UNKNOWN";
    case code::INVALID_LEN: return "INVALID_LEN";
    case code::INVALID_INDIRECT_SETTING: return "INVALID_INDIRECT_SETTING";
    case code::CMD_INVALID_ON_SRC: return "CMD_INVALID_ON_SRC";
    case code::CLIENT_ID_NO_MATCH: return "CLIENT_ID_NO_MATCH";
    case code::INVALID_ADDR: return "INVALID_ADDR";
    case code::AUTH_FAIL: return "AUTH_FAIL";
    case code::TIMEOUT: return "TIMEOUT";
    case code::HW_NOT_RDY: return "HW_NOT_RDY";
    case code::FUNC_NOT_SUPPORTED: return "FUNC_NOT_SUPPORTED";
    case code::NOT_CONFIGURED: return "NOT_CONFIGURED";
    case code::DEVICE_BUSY: return "DEVICE_BUSY";
    case code::NO_VALID_RESP_AVAILABLE: return "NO_VALID_RESP_AVAILABLE";
    case code::ERROR: return "ERROR";
    default:
        if (c >= 0x080 && c <= 0x0FF) return "SECURITY/PUF (0x80-0xFF)";
        return "UNDOCUMENTED";
    }
}

// An SDM command came back with a non-zero code.
class SdmError : public std::runtime_error {
public:
    SdmError(Command cmd, std::uint32_t sdmCode, std::string context)
        : std::runtime_error(std::format("{} failed: 0x{:03x} {}{}{}", name(cmd), sdmCode,
                                         errorName(sdmCode), context.empty() ? "" : " | ",
                                         context)),
          command(cmd), sdmCode(sdmCode), context(std::move(context))
    {}

    Command command;
    std::uint32_t sdmCode;
    std::string context;
};

// A request the host refuses to send because it breaks a documented constraint.
class UsageError : public std::invalid_argument {
    using std::invalid_argument::invalid_argument;
};

} // namespace sdm
