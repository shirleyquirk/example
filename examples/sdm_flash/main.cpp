// sdm-flash: write a folder of .bin files to QSPI through the SDM.
//
//   sdm-flash [options] <dir>
//     --dry-run              print the plan and exit
//     --fake                 run against the in-memory FakeSdm (no hardware)
//     --cs N                 QSPI chip select (default 0)
//     --erase-block N        erase alignment in bytes, multiple of 4096 (default 4096)
//     --erase-cmd-max N      max bytes per QSPI_ERASE command, 0 = whole span (default 0)
//     --max-rw-words N       max words per QSPI_WRITE/READ command (default 1024)
//     --no-verify            skip read-back verification
//     --no-skip-blank        also write all-0xFF chunks
//
// Numbers accept 0x prefixes. Offsets come from filenames (see placeholderOffsetParser).
#include "fake_sdm.hpp"
#include "sdm/flash_plan.hpp"
#include "sdm/flash_writer.hpp"

#include <cstdlib>
#include <iostream>
#include <string>
#include <string_view>

namespace {

struct Options {
    std::string dir;
    bool dryRun = false, fake = false;
    sdm::PlanOptions plan;
    sdm::WriteOptions write;
};

[[noreturn]] void usage(const char* msg)
{
    std::cerr << "sdm-flash: " << msg << "\nusage: sdm-flash [--dry-run] [--fake] [--cs N] [--erase-block N] "
                 "[--erase-cmd-max N] [--max-rw-words N] [--no-verify] [--no-skip-blank] <dir>\n";
    std::exit(2);
}

Options parse(int argc, char** argv)
{
    Options o;
    for (int i = 1; i < argc; ++i) {
        std::string_view a = argv[i];
        auto num = [&]() -> std::uint32_t {
            if (++i >= argc) usage("missing value");
            return static_cast<std::uint32_t>(std::stoul(argv[i], nullptr, 0));
        };
        if (a == "--dry-run") o.dryRun = true;
        else if (a == "--fake") o.fake = true;
        else if (a == "--cs") o.write.chipSelect = num();
        else if (a == "--erase-block") o.plan.eraseBlock = num();
        else if (a == "--erase-cmd-max") o.plan.maxEraseBytesPerCmd = num();
        else if (a == "--max-rw-words") o.write.limits.maxRwWords = num();
        else if (a == "--no-verify") o.write.verify = false;
        else if (a == "--no-skip-blank") o.plan.skipBlankChunks = false;
        else if (a.starts_with("--")) usage("unknown option");
        else if (o.dir.empty()) o.dir = a;
        else usage("more than one directory");
    }
    if (o.dir.empty()) usage("no directory");
    o.plan.writeChunk = o.write.limits.maxRwWords * 4;
    return o;
}

template <sdm::SdmServiceLike Sdm>
int run(Sdm& sdm, const sdm::FlashPlan& plan, const Options& o)
{
    auto rep = sdm::writeFlash(sdm, plan, o.write);
    auto mbps = [](std::uint64_t b, double s) { return s > 0 ? b / 1e6 / s : 0.0; };
    std::cout << std::format("erase  {:>10} B  {:8.3f} s\n", rep.erasedBytes, rep.eraseSeconds)
              << std::format("write  {:>10} B  {:8.3f} s  {:6.2f} MB/s\n", rep.writtenBytes, rep.writeSeconds,
                             mbps(rep.writtenBytes, rep.writeSeconds))
              << std::format("verify {:>10} B  {:8.3f} s  {:6.2f} MB/s\n", rep.verifiedBytes, rep.verifySeconds,
                             mbps(rep.verifiedBytes, rep.verifySeconds))
              << std::format("total  {:8.3f} s\n\n", rep.totalSeconds) << rep.stats.summary();
    return 0;
}

} // namespace

int main(int argc, char** argv)
{
    auto o = parse(argc, argv);
    try {
        auto plan = sdm::makePlan(sdm::loadDirectory(o.dir), o.plan);
        std::cout << "plan:\n" << plan.describe() << '\n';
        if (o.dryRun) return 0;

        if (o.fake) {
            sdm::testing::FakeSdm sdm(sdm::testing::FakeSdm::Config{.flashBytes = 256u << 20,
                                                                    .jedec = {0x20, 0xBB, 0x22}});
            return run(sdm, plan, o);
        }
        // Real hardware: construct the jtagd-backed SdmService here and call run(sdm, plan, o).
        std::cerr << "sdm-flash: no hardware backend linked in this build; use --fake or --dry-run\n";
        return 2;
    } catch (const std::exception& e) {
        std::cerr << "sdm-flash: " << e.what() << '\n';
        return 1;
    }
}
