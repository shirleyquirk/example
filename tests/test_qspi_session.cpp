#include "fake_sdm.hpp"
#include "sdm/qspi.hpp"

#include <doctest/doctest.h>

using namespace sdm;
using sdm::testing::FakeSdm;

static_assert(SdmServiceLike<FakeSdm>);

TEST_CASE("session sends OPEN, SET_CS and CLOSE in order")
{
    FakeSdm sdm;
    { QspiSession q(sdm, 1); CHECK(sdm.qspiOpen); CHECK(sdm.chipSelect == 1u); }
    CHECK_FALSE(sdm.qspiOpen);
    CHECK(sdm.log == std::vector{Command::QSPI_OPEN, Command::QSPI_SET_CS, Command::QSPI_CLOSE});
}

TEST_CASE("CLOSE is sent when SET_CS fails and when the scope unwinds")
{
    FakeSdm sdm;
    sdm.fault = [](Command c, auto, auto) -> std::optional<std::uint32_t> {
        if (c == Command::QSPI_SET_CS) return code::INVALID_LEN;
        return std::nullopt;
    };
    CHECK_THROWS_AS(QspiSession<FakeSdm>{sdm}, SdmError);
    CHECK_FALSE(sdm.qspiOpen);

    sdm.fault = nullptr;
    try {
        QspiSession q(sdm);
        throw std::runtime_error("boom");
    } catch (const std::runtime_error&) {
    }
    CHECK_FALSE(sdm.qspiOpen);
}

TEST_CASE("OPEN failure surfaces the SDM code")
{
    FakeSdm sdm(FakeSdm::Config{.configured = false});
    try {
        QspiSession q(sdm);
        FAIL("expected throw");
    } catch (const SdmError& e) {
        CHECK(e.command == Command::QSPI_OPEN);
        CHECK(e.sdmCode == code::NOT_CONFIGURED);
    }
}

TEST_CASE("host-side argument checks reject before anything is sent")
{
    FakeSdm sdm;
    QspiSession q(sdm);
    auto sent = sdm.log.size();
    CHECK_THROWS_AS(q.erase(0x1000 + 4, 4096), UsageError);
    CHECK_THROWS_AS(q.erase(0x1000, 100), UsageError);
    CHECK_THROWS_AS(q.erase(0x1000, 0), UsageError);
    std::vector<std::byte> d(8);
    CHECK_THROWS_AS(q.write(2, d), UsageError);
    CHECK_THROWS_AS(q.read(3, 4), UsageError);
    CHECK_THROWS_AS(q.readDeviceReg(0x9F, 9), UsageError);
    CHECK_THROWS_AS(q.writeDeviceReg(0x01, std::vector<std::byte>(9)), UsageError);
    CHECK(sdm.log.size() == sent);
}

TEST_CASE("write and read split into maxRwWords commands and round-trip")
{
    FakeSdm sdm;
    CommandStats stats;
    QspiSession q(sdm, 0, QspiLimits{.maxRwWords = 256}, &stats);
    std::vector<std::byte> data(10000);
    for (std::size_t i = 0; i < data.size(); ++i) data[i] = std::byte(i * 7);
    q.erase(0x10000, 16384);
    q.write(0x10000, data);
    CHECK(sdm.counts[Command::QSPI_WRITE] == 10);  // ceil(2500 words / 256)
    CHECK(q.read(0x10000, 10000) == data);
    CHECK(sdm.counts[Command::QSPI_READ] == 10);
    CHECK(stats.summary().find("QSPI_WRITE") != std::string::npos);
}

TEST_CASE("NOR semantics in the fake: writing without erase ANDs")
{
    FakeSdm sdm;  // initialFill 0x00
    QspiSession q(sdm);
    std::vector<std::byte> d(4, std::byte{0xAB});
    q.write(0, d);
    CHECK(q.read(0, 4) == std::vector<std::byte>(4, std::byte{0x00}));
}

TEST_CASE("device register helpers")
{
    FakeSdm sdm;
    QspiSession q(sdm);
    auto id = q.jedecId();
    CHECK(id.manufacturer == 0x20);
    CHECK(id.capacity() == 16u << 20);
    q.sendDeviceOp(0x06);
    CHECK((std::to_integer<int>(q.readDeviceReg(0x05, 1)[0]) & 0x02));
    q.writeDeviceReg(0x01, std::vector<std::byte>{std::byte{0x00}});
    CHECK_FALSE((std::to_integer<int>(q.readDeviceReg(0x05, 1)[0]) & 0x02));
}
