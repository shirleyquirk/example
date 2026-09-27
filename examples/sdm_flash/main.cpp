// sdm-flash: write a folder of .bin files to QSPI through the SDM.
//
//   sdm-flash [options] <dir>
//     --dry-run              print the plan and exit
//     --fake                 run against the in-memory FakeSdm (no hardware)
//     --cs N                 QSPI chip select (default 0)
//     --erase-block N        erase alignment in bytes, multiple of 4096 (default 4096)
//     --erase-cmd-max N      max bytes per QSPI_ERASE command, 0 = whole span (default 0)
//     --erase-sizes L        greedy mixed-size erase ops, e.g. 64K,32K,4K (overrides --erase-cmd-max)
//     --erase-method M       sdm (QSPI_ERASE, default) | direct (flash opcodes + WIP polling)
//     --write-first          program without erasing; erase + rewrite only spans that fail verify
//     --jtag-clock F         set TCK first via jtagconfig, e.g. 16M (needs --cable)
//     --cable NAME           jtagconfig cable name or index, e.g. 1 or "USB-BlasterII [1-3]"
//     --max-rw-words N       max words per QSPI_WRITE/READ command (default 1024)
//     --no-verify            skip read-back verification
//     --no-skip-blank        also write all-0xFF chunks
//
// Numbers accept 0x prefixes. Offsets come from filenames (see placeholderOffsetParser).
#include "fake_sdm.hpp"
#include "sdm/flash_plan.hpp"
#include "sdm/flash_writer.hpp"
#include "sdm/jtag_clock.hpp"

#include <cstdlib>
#include <iostream>
#include <ranges>
#include <string>
#include <string_view>

namespace {

struct Options {
    std::string dir, cable;
    std::optional<std::uint32_t> jtagClock;
    bool dryRun = false, fake = false;
    sdm::PlanOptions plan;
    sdm::WriteOptions write;
};

[[noreturn]] void usage(const char* msg)
{
    std::cerr << "sdm-flash: " << msg << "\nusage: sdm-flash [--dry-run] [--fake] [--cs N] [--erase-block N] "
                 "[--erase-cmd-max N] [--erase-sizes 64K,32K,4K] [--erase-method sdm|direct] [--write-first] "
                 "[--jtag-clock 16M --cable NAME] [--max-rw-words N] [--no-verify] [--no-skip-blank] <dir>\n";
    std::exit(2);
}

// "64K" -> 65536, "1M" -> 1048576, "0x1000" -> 4096.
std::uint32_t parseSize(std::string_view v)
{
    std::size_t end = 0;
    std::string str(v);
    auto n = std::stoul(str, &end, 0);
    auto suffix = v.substr(end);
    if (suffix == "K" || suffix == "k") n <<= 10;
    else if (suffix == "M" || suffix == "m") n <<= 20;
    else if (!suffix.empty()) usage("bad size suffix");
    return static_cast<std::uint32_t>(n);
}

Options parse(int argc, char** argv)
{
    Options o;
    for (int i = 1; i < argc; ++i) {
        std::string_view a = argv[i];
        auto str = [&]() -> std::string_view {
            if (++i >= argc) usage("missing value");
            return argv[i];
        };
        auto num = [&] { return parseSize(str()); };
        if (a == "--dry-run") o.dryRun = true;
        else if (a == "--fake") o.fake = true;
        else if (a == "--cs") o.write.chipSelect = num();
        else if (a == "--erase-block") o.plan.eraseBlock = num();
        else if (a == "--erase-cmd-max") o.plan.maxEraseBytesPerCmd = num();
        else if (a == "--max-rw-words") o.write.limits.maxRwWords = num();
        else if (a == "--erase-sizes") {
            for (auto part : std::views::split(str(), ','))
                o.plan.eraseOpSizes.push_back(parseSize(std::string_view(part.begin(), part.end())));
        }
        else if (a == "--erase-method") {
            auto m = str();
            if (m == "sdm") o.write.eraseMethod = sdm::EraseMethod::Sdm;
            else if (m == "direct") o.write.eraseMethod = sdm::EraseMethod::Direct;
            else usage("--erase-method must be sdm or direct");
        }
        else if (a == "--write-first") o.write.writeFirst = true;
        else if (a == "--jtag-clock") {
            o.jtagClock = sdm::jtag::parseFrequency(str());
            if (!o.jtagClock) usage("bad --jtag-clock value (e.g. 16M)");
        }
        else if (a == "--cable") o.cable = str();
        else if (a == "--no-verify") o.write.verify = false;
        else if (a == "--no-skip-blank") o.plan.skipBlankChunks = false;
        else if (a.starts_with("--")) usage("unknown option");
        else if (o.dir.empty()) o.dir = a;
        else usage("more than one directory");
    }
    if (o.dir.empty()) usage("no directory");
    if (o.jtagClock && o.cable.empty()) usage("--jtag-clock needs --cable");
    if (o.write.eraseMethod == sdm::EraseMethod::Direct && o.plan.eraseOpSizes.empty())
        o.plan.eraseOpSizes = {65536, 32768, 4096};
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
              << std::format("total  {:8.3f} s   spans repaired {}   WIP polls {}\n\n", rep.totalSeconds,
                             rep.spansRepaired, rep.busyPolls)
              << rep.stats.summary();
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

        if (o.jtagClock && !o.fake) {
            // Swap for sdm::jtag::setJtagClock(chain, hz) once SdmService exposes its AJI chain.
            auto cmd = sdm::jtag::jtagconfigSetClockCommand(o.cable, *o.jtagClock);
            std::cerr << "sdm-flash: " << cmd << '\n';
            if (int rc = sdm::jtag::setJtagClockViaJtagconfig(o.cable, *o.jtagClock); rc != 0) {
                std::cerr << "sdm-flash: jtagconfig failed (" << rc << ")\n";
                return 1;
            }
        }

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
