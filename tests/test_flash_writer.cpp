#include "fake_sdm.hpp"
#include "sdm/flash_writer.hpp"

#include <doctest/doctest.h>

#include <sstream>

using namespace sdm;
using sdm::testing::FakeSdm;

namespace {
std::vector<FileImage> images()
{
    std::vector<FileImage> v;
    for (auto [off, n, seed] : {std::tuple{0x0u, 0x2345u, 1}, {0x100000u, 0x40000u, 2}, {0x3000u, 0x10u, 3}}) {
        FileImage f{std::format("f{}", seed), off, std::vector<std::byte>(n)};
        for (std::size_t i = 0; i < n; ++i) f.data[i] = std::byte((i * 31 + seed) & 0xFF);
        v.push_back(std::move(f));
    }
    return v;
}
} // namespace

TEST_CASE("end to end: flash contents match the files, session closed")
{
    FakeSdm sdm;
    std::ostringstream log;
    auto plan = makePlan(images(), {.eraseBlock = 65536});
    auto rep = writeFlash(sdm, plan, {.log = &log});
    for (const auto& f : plan.files) {
        INFO(f.name);
        CHECK(std::equal(f.data.begin(), f.data.end(), sdm.flash.begin() + f.offset,
                         [](std::byte a, std::uint8_t b) { return a == std::byte(b); }));
    }
    CHECK_FALSE(sdm.qspiOpen);
    CHECK(rep.idcode == sdm.cfg.idcode);
    CHECK(rep.verifiedBytes == 0x2345 + 0x40000 + 0x10);
    CHECK(log.str().find("verified") != std::string::npos);
}

TEST_CASE("a failing write stops the run, names the suspect range, still closes")
{
    FakeSdm sdm;
    auto plan = makePlan(images());
    int writes = 0;
    sdm.fault = [&](Command c, auto, auto) -> std::optional<std::uint32_t> {
        if (c == Command::QSPI_WRITE && ++writes == 5) return code::TIMEOUT;
        return std::nullopt;
    };
    try {
        writeFlash(sdm, plan, {.log = nullptr});
        FAIL("expected throw");
    } catch (const FlashWriteError& e) {
        CHECK(e.phase == "write");
        CHECK(e.file == "f2");
        CHECK(e.suspectBegin == 0x100000);
        CHECK(e.suspectEnd == 0x140000);
        CHECK(std::string(e.what()).find("TIMEOUT") != std::string::npos);
    }
    CHECK_FALSE(sdm.qspiOpen);
    CHECK(sdm.log.back() == Command::QSPI_CLOSE);
}

TEST_CASE("verify catches a silently dropped write")
{
    FakeSdm sdm;
    auto plan = makePlan(images());
    int writes = 0;
    // Swallow the 3rd write: SDM says OK but nothing reaches the flash.
    sdm.fault = [&](Command c, auto, auto) -> std::optional<std::uint32_t> {
        if (c == Command::QSPI_WRITE && ++writes == 3) return code::OK;
        return std::nullopt;
    };
    CHECK_THROWS_AS(writeFlash(sdm, plan, {.log = nullptr}), FlashWriteError);
    CHECK_FALSE(sdm.qspiOpen);
}

TEST_CASE("plan larger than the flash (per JEDEC) is refused before any erase")
{
    FakeSdm sdm;  // 16 MiB part
    auto plan = makePlan({FileImage{"big", 0x00FF0000, std::vector<std::byte>(0x20000)}});
    CHECK_THROWS_AS(writeFlash(sdm, plan, {.log = nullptr}), FlashWriteError);
    CHECK(sdm.counts[Command::QSPI_ERASE] == 0);
    CHECK_FALSE(sdm.qspiOpen);
}
