#include "sdm/flash_plan.hpp"

#include <doctest/doctest.h>

#include <fstream>

using namespace sdm;

namespace {
FileImage img(std::string name, std::uint32_t off, std::size_t n, std::uint8_t fill = 0x5A)
{
    return {std::move(name), off, std::vector<std::byte>(n, std::byte{fill})};
}
} // namespace

TEST_CASE("placeholder offset parser")
{
    CHECK(placeholderOffsetParser("fw_0x00200000.bin") == 0x200000u);
    CHECK(placeholderOffsetParser("0x1000_boot.bin") == 0x1000u);
    CHECK(placeholderOffsetParser("0xnothing_0x40.bin") == 0x40u);
    CHECK_FALSE(placeholderOffsetParser("boot.bin").has_value());
}

TEST_CASE("loadDirectory reads *.bin files and their offsets")
{
    auto dir = std::filesystem::temp_directory_path() / "sdm_plan_test";
    std::filesystem::remove_all(dir);
    std::filesystem::create_directories(dir);
    std::ofstream(dir / "a_0x1000.bin", std::ios::binary) << "hello";
    std::ofstream(dir / "readme.txt") << "ignored";
    auto files = loadDirectory(dir);
    REQUIRE(files.size() == 1);
    CHECK(files[0].offset == 0x1000);
    CHECK(files[0].data.size() == 5);
    std::ofstream(dir / "nooffset.bin") << "x";
    CHECK_THROWS_AS(loadDirectory(dir), PlanError);
    std::filesystem::remove_all(dir);
}

TEST_CASE("validation")
{
    CHECK_THROWS_AS(makePlan({img("a", 0x1002, 16)}), PlanError);                       // unaligned
    CHECK_THROWS_AS(makePlan({img("a", 0x1000, 0)}), PlanError);                        // empty
    CHECK_THROWS_AS(makePlan({img("a", 0x1000, 0x100), img("b", 0x10FC, 4)}), PlanError);  // overlap
    CHECK_THROWS_AS(makePlan({img("a", 0x1000, 0x101), img("b", 0x1100, 4)}), PlanError);  // overlap via word padding
    CHECK_THROWS_AS(makePlan({img("a", 0xFFF000, 0x2000)}, {.flashSize = 16u << 20}), PlanError);
    CHECK_THROWS_AS(makePlan({img("a", 0, 4)}, {.eraseBlock = 1000}), PlanError);
}

TEST_CASE("files sharing an erase block merge into one span, erased once")
{
    auto p = makePlan({img("b", 0x1800, 0x100), img("a", 0x1000, 0x100)});
    REQUIRE(p.spans.size() == 1);
    CHECK(p.spans[0].begin == 0x1000);
    CHECK(p.spans[0].end == 0x2000);
    REQUIRE(p.spans[0].erases.size() == 1);
    CHECK(p.files[0].name == "a");  // sorted by offset
    CHECK(p.spans[0].writes.size() == 2);
}

TEST_CASE("erase block size is a knob")
{
    auto files = std::vector{img("a", 0x1000, 0x100), img("b", 0x9000, 0x100)};
    auto p4 = makePlan(files, {.eraseBlock = 4096});
    auto p64 = makePlan(files, {.eraseBlock = 65536});
    CHECK(p4.spans.size() == 2);
    CHECK(p4.eraseBytes() == 0x2000);
    REQUIRE(p64.spans.size() == 1);
    CHECK(p64.eraseBytes() == 0x10000);
}

TEST_CASE("maxEraseBytesPerCmd splits a span into several QSPI_ERASE commands")
{
    auto p = makePlan({img("a", 0, 0x30000)}, {.eraseBlock = 4096, .maxEraseBytesPerCmd = 0x10000});
    REQUIRE(p.spans.size() == 1);
    REQUIRE(p.spans[0].erases.size() == 3);
    CHECK(p.spans[0].erases[2].addr == 0x20000);
    CHECK(p.spans[0].erases[2].bytes == 0x10000);
}

TEST_CASE("write chunks are aligned to absolute chunk boundaries")
{
    auto p = makePlan({img("a", 0x0F00, 0x1200)}, {.writeChunk = 0x1000});
    auto& w = p.spans[0].writes;
    REQUIRE(w.size() == 3);  // [0x0F00,0x1000) [0x1000,0x2000) [0x2000,0x2100)
    CHECK(w[0].addr == 0x0F00);
    CHECK(w[0].data.size() == 0x100);
    CHECK(w[1].addr == 0x1000);
    CHECK(w[1].data.size() == 0x1000);
    CHECK(w[2].addr == 0x2000);
    CHECK(w[2].data.size() == 0x100);
}

TEST_CASE("all-0xFF chunks are skipped")
{
    auto f = img("a", 0, 0x3000, 0xFF);
    f.data[0x1500] = std::byte{0};
    auto p = makePlan({f});
    REQUIRE(p.spans[0].writes.size() == 1);
    CHECK(p.spans[0].writes[0].addr == 0x1000);
    CHECK(p.skippedBytes == 0x2000);
    CHECK(makePlan({f}, {.skipBlankChunks = false}).spans[0].writes.size() == 3);
}

TEST_CASE("warns about erased bytes no file covers")
{
    auto p = makePlan({img("a", 0x1100, 0x100), img("b", 0x1400, 0x100)});
    REQUIRE(p.warnings.size() == 3);
    CHECK(p.warnings[0].find("[0x00001000, 0x00001100)") != std::string::npos);
    CHECK(p.warnings[1].find("[0x00001200, 0x00001400)") != std::string::npos);
    CHECK(p.warnings[2].find("[0x00001500, 0x00002000)") != std::string::npos);
    CHECK(makePlan({img("a", 0, 0x1000)}).warnings.empty());
}
