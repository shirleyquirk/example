#pragma once
// Host-only planning: turn a set of (offset, bytes) images into erase and write operations.
// No SDM here, so all of it is unit-testable.
#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <functional>
#include <optional>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

namespace sdm {

struct FileImage {
    std::string name;  // for logs and errors
    std::uint32_t offset = 0;
    std::vector<std::byte> data;
};

// PLACEHOLDER: the real manufacturing filename convention is still to be confirmed.
// Currently takes the first "0x<hex>" token in the filename, e.g. "fw_0x00200000.bin".
using OffsetParser = std::function<std::optional<std::uint32_t>(std::string_view filename)>;
std::optional<std::uint32_t> placeholderOffsetParser(std::string_view filename);

// Loads every regular *.bin file in `dir`. Throws PlanError if a filename has no offset.
std::vector<FileImage> loadDirectory(const std::filesystem::path& dir,
                                     const OffsetParser& parse = placeholderOffsetParser);

struct PlanOptions {
    // Granularity erase spans are rounded to. Must be a multiple of 4 KiB. Configurable because
    // the best value (4K subsector vs 32K/64K sector) is something to measure, not assume.
    std::uint32_t eraseBlock = 4096;
    // Max bytes per QSPI_ERASE command (multiple of eraseBlock). 0 = one command per merged span.
    std::uint32_t maxEraseBytesPerCmd = 0;
    // Write chunk size in bytes; chunks are aligned to absolute multiples of this.
    std::uint32_t writeChunk = 4096;
    // Don't send chunks that are entirely 0xFF: erase already left them that way.
    bool skipBlankChunks = true;
    // Optional flash size; if set, the plan is rejected if it doesn't fit.
    std::optional<std::uint64_t> flashSize;
};

struct EraseOp {
    std::uint32_t addr, bytes;
};

struct WriteOp {
    std::uint32_t addr;
    std::size_t file;          // index into FlashPlan::files
    std::size_t fileOffset;    // offset within that file
    std::vector<std::byte> data;
};

// One merged, erase-aligned region: erase it, then write everything inside it.
struct Span {
    std::uint32_t begin, end;  // erase-aligned, end exclusive
    std::vector<EraseOp> erases;
    std::vector<WriteOp> writes;
};

struct FlashPlan {
    std::vector<FileImage> files;
    std::vector<Span> spans;
    std::vector<std::string> warnings;

    std::uint64_t eraseBytes() const;
    std::uint64_t writeBytes() const;
    std::uint64_t skippedBytes = 0;
    std::string describe() const;
};

class PlanError : public std::runtime_error {
    using std::runtime_error::runtime_error;
};

FlashPlan makePlan(std::vector<FileImage> files, const PlanOptions& opts = {});

} // namespace sdm
