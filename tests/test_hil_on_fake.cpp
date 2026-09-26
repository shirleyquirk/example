// Runs the hardware suite against the fake so it can't rot between bench sessions.
#include "fake_sdm.hpp"
#include "hil_suite.hpp"

#include <doctest/doctest.h>

#include <sstream>

using sdm::testing::FakeSdm;

TEST_CASE("HIL assertions pass on the fake")
{
    FakeSdm sdm;
    for (const auto& r : sdm::hil::runAssertions(sdm, {})) {
        INFO(r.name << ": " << r.detail);
        CHECK(r.pass);
    }
    CHECK_FALSE(sdm.qspiOpen);
}

TEST_CASE("characterisation emits one JSON line per probe and closes the session")
{
    FakeSdm sdm;
    std::ostringstream out;
    sdm::hil::characterise(sdm, {}, out);
    auto s = out.str();
    CHECK(s.find("\"probe\":\"max_words_read\",\"max\":1024") != std::string::npos);
    CHECK(s.find("\"probe\":\"erase_sweep\",\"block\":65536") != std::string::npos);
    CHECK(s.find("\"probe\":\"write_unerased\",\"code\":\"0x000\",\"readback\":\"0x0f000f00\"") != std::string::npos);
    CHECK(s.find("\"probe\":\"err_no_open\",\"code\":\"0x00c\"") != std::string::npos);
    CHECK_FALSE(sdm.qspiOpen);
}
