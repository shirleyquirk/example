#include "fake_sdm.hpp"
#include "sdm/flash_writer.hpp"
#include "sdm/jtag_clock.hpp"

#include <doctest/doctest.h>

using namespace sdm;
using sdm::testing::FakeSdm;

TEST_CASE("QSPI_GET_DEVICE_INFO decode (SFDP density encoding)")
{
    CHECK(FlashDeviceInfo{0x0FFFFFFF, 0x10000}.sizeBytes() == 32u << 20);  // 256 Mb, count-1 form
    CHECK(FlashDeviceInfo{0x10000000, 0x10000}.sizeBytes() == 32u << 20);  // 256 Mb, U-Boot's reading
    CHECK(FlashDeviceInfo{0x80000021, 0x10000}.sizeBytes() == 1ull << 30); // 2^33 bits = 8 Gb
    CHECK_FALSE(FlashDeviceInfo{0, 0}.present());
    std::array<std::uint32_t, 8> w{0x07FFFFFF, 0x1000, 0, 0, 0, 0, 0, 0};
    auto d = decodeDeviceInfo(w);
    CHECK(d[0].sizeBytes() == 16u << 20);
    CHECK(d[0].eraseSize == 0x1000);
    CHECK_FALSE(d[1].present());

    FakeSdm sdm;
    QspiSession q(sdm);
    CHECK(q.deviceInfo()[0].sizeBytes() == sdm.cfg.flashBytes);
}

TEST_CASE("direct erase: WREN + opcode with MSB-first address, then WIP polling")
{
    FakeSdm sdm;
    QspiSession q(sdm);
    q.erase(0x20000, 0x10000);
    q.write(0x2F000, std::vector<std::byte>(16, std::byte{0}));
    auto polls = q.eraseDirect(0x20000, 0x10000, /*fourByteAddr=*/true);
    CHECK(polls == sdm.cfg.busyPolls + 1);
    CHECK(sdm.directErases[0x10000] == 1);
    CHECK(q.read(0x2F000, 16) == std::vector<std::byte>(16, std::byte{0xFF}));

    q.eraseDirect(0x3000, 0x1000, /*fourByteAddr=*/false);  // 3-byte address form
    CHECK(sdm.directErases[0x1000] == 1);

    CHECK_THROWS_AS(q.eraseDirect(0x1000, 0x10000, true), UsageError);  // misaligned for 64K
    CHECK_THROWS_AS(q.eraseDirect(0x0, 0x2000, true), UsageError);      // no 8K opcode
}

TEST_CASE("waitReady times out on a stuck flash")
{
    FakeSdm sdm(FakeSdm::Config{.busyPolls = 1'000'000});
    QspiSession q(sdm);
    CHECK_THROWS_AS(q.eraseDirect(0, 4096, true, std::chrono::milliseconds(20)), FlashBusyTimeout);
    sdm.busy = 0;
}

TEST_CASE("greedy mixed-size erase decomposition")
{
    FileImage f{"a", 0x1000, std::vector<std::byte>(0x2F000, std::byte{1})};
    auto p = makePlan({f}, {.eraseOpSizes = {4096, 65536, 32768}});
    REQUIRE(p.spans.size() == 1);
    std::map<std::uint32_t, int> n;
    for (auto& e : p.spans[0].erases) ++n[e.bytes];
    CHECK(n[4096] == 7);     // 0x1000..0x8000
    CHECK(n[32768] == 1);    // 0x8000..0x10000
    CHECK(n[65536] == 2);    // 0x10000..0x30000
    CHECK(p.eraseBytes() == 0x2F000);
    CHECK_THROWS_AS(makePlan({f}, {.eraseOpSizes = {12288}}), PlanError);
    CHECK_THROWS_AS(makePlan({f}, {.eraseBlock = 4096, .eraseOpSizes = {65536}}), PlanError);
}

namespace {
std::vector<FileImage> twoFiles()
{
    std::vector<FileImage> v{{"a", 0x0, std::vector<std::byte>(0x23456)}, {"b", 0x100000, std::vector<std::byte>(0x8000)}};
    for (auto& f : v)
        for (std::size_t i = 0; i < f.data.size(); ++i) f.data[i] = std::byte(i * 13 + f.offset);
    return v;
}

bool flashMatches(const FakeSdm& sdm, const FlashPlan& p)
{
    return std::ranges::all_of(p.files, [&](const FileImage& f) {
        return std::equal(f.data.begin(), f.data.end(), sdm.flash.begin() + f.offset,
                          [](std::byte a, std::uint8_t b) { return a == std::byte(b); });
    });
}
} // namespace

TEST_CASE("writer: direct erase method")
{
    FakeSdm sdm;
    auto plan = makePlan(twoFiles(), {.eraseOpSizes = {65536, 32768, 4096}});
    auto rep = writeFlash(sdm, plan, {.eraseMethod = EraseMethod::Direct, .log = nullptr});
    CHECK(flashMatches(sdm, plan));
    CHECK(sdm.counts[Command::QSPI_ERASE] == 0);
    CHECK(sdm.directErases[65536] == 2);
    CHECK(rep.busyPolls > 0);

    auto coarse = makePlan(twoFiles());  // one QSPI_ERASE per span: not expressible as opcodes
    CHECK_THROWS_AS(writeFlash(sdm, coarse, {.eraseMethod = EraseMethod::Direct, .log = nullptr}), UsageError);
}

TEST_CASE("writer: write-first skips erase on blank flash and repairs dirty spans")
{
    SUBCASE("factory-blank flash: no erase at all")
    {
        FakeSdm sdm(FakeSdm::Config{.initialFill = 0xFF});
        auto plan = makePlan(twoFiles());
        auto rep = writeFlash(sdm, plan, {.writeFirst = true, .log = nullptr});
        CHECK(flashMatches(sdm, plan));
        CHECK(rep.erasedBytes == 0);
        CHECK(rep.spansRepaired == 0);
        CHECK(sdm.counts[Command::QSPI_ERASE] == 0);
    }
    SUBCASE("dirty flash: every span erased and rewritten")
    {
        FakeSdm sdm;  // initialFill 0x00
        auto plan = makePlan(twoFiles());
        auto rep = writeFlash(sdm, plan, {.writeFirst = true, .log = nullptr});
        CHECK(flashMatches(sdm, plan));
        CHECK(rep.spansRepaired == plan.spans.size());
    }
    SUBCASE("needs verify")
    {
        FakeSdm sdm;
        CHECK_THROWS_AS(writeFlash(sdm, makePlan(twoFiles()), {.writeFirst = true, .verify = false, .log = nullptr}),
                        UsageError);
    }
}

TEST_CASE("JTAG clock helpers")
{
    using namespace sdm::jtag;
    CHECK(parseFrequency("16M") == 16'000'000u);
    CHECK(parseFrequency("16MHz") == 16'000'000u);
    CHECK(parseFrequency("400k") == 400'000u);
    CHECK(parseFrequency("6000000") == 6'000'000u);
    CHECK_FALSE(parseFrequency("fast").has_value());
    CHECK_FALSE(parseFrequency("16G").has_value());
    CHECK_FALSE(parseFrequency("0").has_value());
    CHECK(formatFrequency(24'000'000) == "24M");
    CHECK(formatFrequency(400'000) == "400k");
    CHECK(jtagconfigSetClockCommand("USB-BlasterII [1-3]", 16'000'000) ==
          "jtagconfig --setparam 'USB-BlasterII [1-3]' JtagClock 16M");
    CHECK(shellQuote("a'b") == "'a'\\''b'");
}
