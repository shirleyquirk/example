#pragma once
// In-memory SDM model for tests. Behaviour follows PROTOCOL.md; the error codes returned for
// misuse are GUESSES until HIL characterisation (ROADMAP §2 L2) replaces them with observed ones.
#include "sdm/command.hpp"
#include "sdm/error.hpp"

#include <algorithm>
#include <cstdint>
#include <functional>
#include <map>
#include <optional>
#include <span>
#include <vector>

namespace sdm::testing {

struct FakeResponse {
    std::uint32_t code_ = 0;
    std::vector<std::uint32_t> data_;
    std::uint32_t code() const { return code_; }
    const std::vector<std::uint32_t>& data() const { return data_; }
};

class FakeSdm {
public:
    struct Config {
        std::uint32_t flashBytes = 16u << 20;
        std::uint32_t maxRwWords = 1024;
        std::uint8_t jedec[3] = {0x20, 0xBB, 0x18};  // Micron MT25QU128
        std::uint32_t idcode = 0x4341A0DD;           // made-up value
        bool configured = true;                      // helper design loaded
        std::uint8_t initialFill = 0x00;             // non-0xFF so a missing erase shows up
        std::uint32_t pastEndCode = code::INVALID_ADDR;
        std::uint32_t sdmEraseSize = 65536;  // what QSPI_GET_DEVICE_INFO reports as erasesize
        std::uint32_t busyPolls = 3;         // status reads showing WIP after a direct erase
    };

    // Called before every command; return a code to fail it (fault injection).
    using Fault = std::function<std::optional<std::uint32_t>(Command, std::span<const std::uint32_t> args,
                                                             std::size_t commandIndex)>;

    FakeSdm() : FakeSdm(Config{}) {}
    explicit FakeSdm(Config c) : cfg(c), flash(c.flashBytes, c.initialFill) {}

    template <Command C>
    FakeResponse sendCommand(std::span<const std::uint32_t> args = {})
    {
        std::size_t index = log.size();
        log.push_back(C);
        ++counts[C];
        if (fault)
            if (auto c = fault(C, args, index)) return {*c, {}};
        return handle(C, args);
    }

    Config cfg;
    std::vector<std::uint8_t> flash;
    Fault fault;
    std::vector<Command> log;
    std::map<Command, std::size_t> counts;
    bool qspiOpen = false;
    std::optional<std::uint32_t> chipSelect;
    bool wel = false;
    std::uint32_t busy = 0;                          // remaining WIP polls
    std::map<std::uint32_t, std::size_t> directErases;  // erase size -> count

private:
    static std::uint32_t eraseSizeForOpcode(std::uint32_t op)
    {
        switch (op) {
        case 0x20: case 0x21: return 4096;
        case 0x52: case 0x5C: return 32768;
        case 0xD8: case 0xDC: return 65536;
        default: return 0;
        }
    }

    FakeResponse handle(Command c, std::span<const std::uint32_t> a)
    {
        auto nargs = [&](std::size_t n) { return a.size() == n; };
        switch (c) {
        case Command::NOOP: return {};
        case Command::GET_IDCODE: return {0, {cfg.idcode}};
        case Command::CONFIG_STATUS: return {0, {cfg.configured ? 0u : 0x10000000u, 0, 0, 0, 0, 0}};
        case Command::QSPI_OPEN:
            if (!cfg.configured) return {code::NOT_CONFIGURED, {}};
            if (qspiOpen) return {code::DEVICE_BUSY, {}};
            qspiOpen = true;
            return {};
        case Command::QSPI_CLOSE:
            qspiOpen = false;
            chipSelect.reset();
            return {};
        default: break;
        }

        if (!qspiOpen) return {code::HW_NOT_RDY, {}};

        switch (c) {
        case Command::QSPI_SET_CS:
            if (!nargs(1)) return {code::INVALID_LEN, {}};
            chipSelect = a[0] >> 28;
            return {};
        case Command::QSPI_DIRECT: return {code::CMD_INVALID_ON_SRC, {}};
        case Command::QSPI_GET_DEVICE_INFO:  // 4 x {size (SFDP density form), erasesize}
            return {0, {cfg.flashBytes * 8 - 1, cfg.sdmEraseSize, 0, 0, 0, 0, 0, 0}};
        default: break;
        }

        if (!chipSelect) return {code::HW_NOT_RDY, {}};

        switch (c) {
        case Command::QSPI_READ_DEVICE_REG: {
            if (!nargs(2) || a[1] == 0 || a[1] > 8) return {code::INVALID_LEN, {}};
            std::vector<std::uint8_t> b(8, 0);
            if (a[0] == 0x9F) std::copy(std::begin(cfg.jedec), std::end(cfg.jedec), b.begin());
            else if (a[0] == 0x05) {
                b[0] = (wel ? 0x02 : 0x00) | (busy ? 0x01 : 0x00);
                if (busy) --busy;
            }
            std::vector<std::uint32_t> w((a[1] + 3) / 4);
            for (std::size_t i = 0; i < w.size(); ++i)
                w[i] = b[4 * i] | b[4 * i + 1] << 8 | b[4 * i + 2] << 16 | std::uint32_t(b[4 * i + 3]) << 24;
            return {0, w};
        }
        case Command::QSPI_WRITE_DEVICE_REG: {
            if (a.size() < 2 || a[1] > 8 || a.size() != 2 + (a[1] + 3) / 4) return {code::INVALID_LEN, {}};
            std::uint32_t size = eraseSizeForOpcode(a[0]);
            if (size && wel && !busy) {
                std::uint64_t addr = 0;
                for (std::uint32_t i = 0; i < a[1]; ++i) addr = addr << 8 | ((a[2 + i / 4] >> (8 * (i % 4))) & 0xFF);
                if (addr % size == 0 && addr + size <= flash.size()) {
                    std::fill_n(flash.begin() + addr, size, 0xFF);
                    ++directErases[size];
                    busy = cfg.busyPolls;
                }
            }
            wel = false;
            return {};
        }
        case Command::QSPI_SEND_DEVICE_OP:
            if (!nargs(1)) return {code::INVALID_LEN, {}};
            if (a[0] == 0x06) wel = true;
            if (a[0] == 0x04) wel = false;
            if ((a[0] == 0xC7 || a[0] == 0x60) && wel && !busy) {
                std::ranges::fill(flash, 0xFF);
                wel = false;
                busy = cfg.busyPolls * 10;
            }
            return {};
        case Command::QSPI_ERASE: {
            if (!nargs(2)) return {code::INVALID_LEN, {}};
            if (busy) return {code::DEVICE_BUSY, {}};
            std::uint64_t addr = a[0], bytes = std::uint64_t{a[1]} * 4;
            if (addr % 4096 || a[1] == 0 || a[1] % 0x400) return {code::INVALID_ADDR, {}};
            if (addr + bytes > flash.size()) return {cfg.pastEndCode, {}};
            std::fill_n(flash.begin() + addr, bytes, 0xFF);
            return {};
        }
        case Command::QSPI_WRITE: {
            if (a.size() < 2 || a.size() != 2 + std::size_t{a[1]}) return {code::INVALID_LEN, {}};
            if (a[1] == 0 || a[1] > cfg.maxRwWords) return {code::INVALID_LEN, {}};
            if (busy) return {code::DEVICE_BUSY, {}};
            std::uint64_t addr = a[0];
            if (addr % 4) return {code::INVALID_ADDR, {}};
            if (addr + std::uint64_t{a[1]} * 4 > flash.size()) return {cfg.pastEndCode, {}};
            for (std::uint32_t i = 0; i < a[1]; ++i)
                for (int b = 0; b < 4; ++b) flash[addr + 4 * i + b] &= std::uint8_t(a[2 + i] >> (8 * b));  // NOR: 1->0 only
            return {};
        }
        case Command::QSPI_READ: {
            if (!nargs(2)) return {code::INVALID_LEN, {}};
            if (a[1] == 0 || a[1] > cfg.maxRwWords) return {code::INVALID_LEN, {}};
            std::uint64_t addr = a[0];
            if (addr % 4) return {code::INVALID_ADDR, {}};
            if (addr + std::uint64_t{a[1]} * 4 > flash.size()) return {cfg.pastEndCode, {}};
            std::vector<std::uint32_t> w(a[1]);
            for (std::uint32_t i = 0; i < a[1]; ++i)
                for (int b = 0; b < 4; ++b) w[i] |= std::uint32_t(flash[addr + 4 * i + b]) << (8 * b);
            return {0, w};
        }
        default: return {code::INVALID_COMMAND, {}};
        }
    }
};

} // namespace sdm::testing
