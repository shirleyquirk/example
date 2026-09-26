#include "sdm/error.hpp"
#include "sdm/qspi.hpp"

#include <doctest/doctest.h>

using namespace sdm;

TEST_CASE("QSPI_SET_CS argument layout (ATF bit positions)")
{
    CHECK(setCsArg(0) == 0x00000000);
    CHECK(setCsArg(1) == 0x10000000);
    CHECK(setCsArg(0xF) == 0xF0000000);
    CHECK(setCsArg(0, true) == 0x08000000);
    CHECK(setCsArg(0, false, true) == 0x04000000);
}

TEST_CASE("byte <-> word packing is little-endian with 0xFF tail padding")
{
    std::vector<std::byte> b{std::byte{0x11}, std::byte{0x22}, std::byte{0x33}, std::byte{0x44}, std::byte{0x55}};
    auto w = packWords(b);
    REQUIRE(w.size() == 2);
    CHECK(w[0] == 0x44332211);
    CHECK(w[1] == 0xFFFFFF55);
    CHECK(unpackWords(w, 5) == b);
}

TEST_CASE("JEDEC density decode")
{
    CHECK(jedecCapacityBytes(0x18) == 16u << 20);          // 128 Mb
    CHECK(jedecCapacityBytes(0x19) == 32u << 20);          // 256 Mb
    CHECK(jedecCapacityBytes(0x20) == 64u << 20);          // Micron 512 Mb
    CHECK(jedecCapacityBytes(0x22) == 256u << 20);         // Micron 2 Gb
    CHECK(jedecCapacityBytes(0x1C) == 256u << 20);         // Macronix 2 Gb
    CHECK_FALSE(jedecCapacityBytes(0x00).has_value());
}

TEST_CASE("error and command names")
{
    CHECK(errorName(0x1FF) == "DEVICE_BUSY");
    CHECK(errorName(0x085) == "SECURITY/PUF (0x80-0xFF)");
    CHECK(errorName(0x7AB) == "UNDOCUMENTED");
    CHECK(name(Command::QSPI_WRITE) == "QSPI_WRITE");
    CHECK(static_cast<int>(Command::QSPI_GET_DEVICE_INFO) == 0x74);
    SdmError e(Command::QSPI_ERASE, 0x009, "addr=0x00001000");
    CHECK(std::string(e.what()) == "QSPI_ERASE failed: 0x009 INVALID_ADDR | addr=0x00001000");
}
