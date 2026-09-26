#include "sdm/flash_plan.hpp"

#include <algorithm>
#include <charconv>
#include <format>
#include <fstream>
#include <iterator>

namespace sdm {

std::optional<std::uint32_t> placeholderOffsetParser(std::string_view filename)
{
    for (std::size_t pos = filename.find("0x"); pos != std::string_view::npos;
         pos = filename.find("0x", pos + 1)) {
        auto digits = filename.substr(pos + 2);
        std::uint32_t value = 0;
        auto [end, ec] = std::from_chars(digits.data(), digits.data() + digits.size(), value, 16);
        if (ec == std::errc{} && end != digits.data()) return value;
    }
    return std::nullopt;
}

std::vector<FileImage> loadDirectory(const std::filesystem::path& dir, const OffsetParser& parse)
{
    std::vector<FileImage> out;
    for (const auto& entry : std::filesystem::directory_iterator(dir)) {
        if (!entry.is_regular_file() || entry.path().extension() != ".bin") continue;
        auto name = entry.path().filename().string();
        auto offset = parse(name);
        if (!offset) throw PlanError(std::format("{}: no flash offset in filename", name));
        std::ifstream in(entry.path(), std::ios::binary);
        std::vector<char> raw((std::istreambuf_iterator<char>(in)), {});
        FileImage img{name, *offset, std::vector<std::byte>(raw.size())};
        std::ranges::transform(raw, img.data.begin(), [](char c) { return std::byte(c); });
        out.push_back(std::move(img));
    }
    return out;
}

namespace {

std::uint64_t alignDown(std::uint64_t x, std::uint64_t a) { return x / a * a; }
std::uint64_t alignUp(std::uint64_t x, std::uint64_t a) { return (x + a - 1) / a * a; }

bool allFF(std::span<const std::byte> s)
{
    return std::ranges::all_of(s, [](std::byte b) { return b == std::byte{0xFF}; });
}

} // namespace

FlashPlan makePlan(std::vector<FileImage> files, const PlanOptions& o)
{
    if (o.eraseBlock == 0 || o.eraseBlock % 4096)
        throw PlanError(std::format("eraseBlock {} is not a multiple of 4 KiB", o.eraseBlock));
    if (o.maxEraseBytesPerCmd % o.eraseBlock)
        throw PlanError("maxEraseBytesPerCmd must be a multiple of eraseBlock");
    if (o.writeChunk == 0 || o.writeChunk % 4)
        throw PlanError("writeChunk must be a non-zero multiple of 4");

    FlashPlan plan;
    std::ranges::sort(files, {}, &FileImage::offset);

    // Validate files and their (word-padded) extents.
    for (std::size_t i = 0; i < files.size(); ++i) {
        const auto& f = files[i];
        if (f.data.empty()) throw PlanError(std::format("{}: empty file", f.name));
        if (f.offset % 4)
            throw PlanError(std::format("{}: offset 0x{:08x} not word aligned", f.name, f.offset));
        std::uint64_t end = f.offset + alignUp(f.data.size(), 4);
        if (end > (std::uint64_t{1} << 32))
            throw PlanError(std::format("{}: extends past 4 GiB", f.name));
        if (o.flashSize && end > *o.flashSize)
            throw PlanError(std::format("{}: ends at 0x{:x}, flash is 0x{:x} bytes", f.name, end, *o.flashSize));
        if (i + 1 < files.size() && end > files[i + 1].offset)
            throw PlanError(std::format("{} [0x{:08x},0x{:08x}) overlaps {} at 0x{:08x}", f.name,
                                        f.offset, end, files[i + 1].name, files[i + 1].offset));
    }

    // Merge erase-aligned extents into spans, so two files sharing an erase block get one erase.
    for (std::size_t i = 0; i < files.size(); ++i) {
        const auto& f = files[i];
        auto b = static_cast<std::uint32_t>(alignDown(f.offset, o.eraseBlock));
        auto e = alignUp(f.offset + f.data.size(), o.eraseBlock);
        if (!plan.spans.empty() && b <= plan.spans.back().end)
            plan.spans.back().end = static_cast<std::uint32_t>(std::max<std::uint64_t>(plan.spans.back().end, e));
        else
            plan.spans.push_back({b, static_cast<std::uint32_t>(e), {}, {}});

        // Writes, aligned to absolute multiples of writeChunk.
        std::uint64_t pos = f.offset;
        std::uint64_t fend = f.offset + f.data.size();
        while (pos < fend) {
            std::uint64_t next = std::min(fend, alignDown(pos, o.writeChunk) + o.writeChunk);
            std::size_t off = pos - f.offset;
            std::span<const std::byte> chunk(f.data.data() + off, next - pos);
            if (o.skipBlankChunks && allFF(chunk))
                plan.skippedBytes += chunk.size();
            else
                plan.spans.back().writes.push_back(
                    {static_cast<std::uint32_t>(pos), i, off, {chunk.begin(), chunk.end()}});
            pos = next;
        }
    }

    // Split spans into erase commands, and flag bytes erased that belong to no file.
    for (auto& s : plan.spans) {
        std::uint32_t step = o.maxEraseBytesPerCmd ? o.maxEraseBytesPerCmd : s.end - s.begin;
        for (std::uint64_t a = s.begin; a < s.end; a += step)
            s.erases.push_back({static_cast<std::uint32_t>(a),
                                static_cast<std::uint32_t>(std::min<std::uint64_t>(step, s.end - a))});
    }
    // Bytes a span erases that no file rewrites: previous flash contents there are lost.
    for (const auto& s : plan.spans) {
        std::uint64_t cursor = s.begin;
        auto gap = [&](std::uint64_t upTo) {
            if (upTo > cursor)
                plan.warnings.push_back(std::format("erase clears [0x{:08x}, 0x{:08x}) which no file covers",
                                                    cursor, upTo));
        };
        for (const auto& f : files) {
            if (f.offset >= s.end || f.offset + f.data.size() <= s.begin) continue;
            gap(f.offset);
            cursor = f.offset + f.data.size();
        }
        gap(s.end);
    }

    plan.files = std::move(files);
    return plan;
}

std::uint64_t FlashPlan::eraseBytes() const
{
    std::uint64_t n = 0;
    for (const auto& s : spans) n += s.end - s.begin;
    return n;
}

std::uint64_t FlashPlan::writeBytes() const
{
    std::uint64_t n = 0;
    for (const auto& s : spans)
        for (const auto& w : s.writes) n += w.data.size();
    return n;
}

std::string FlashPlan::describe() const
{
    std::string out;
    for (const auto& f : files)
        out += std::format("  file  0x{:08x} +0x{:08x}  {}\n", f.offset, f.data.size(), f.name);
    for (const auto& s : spans)
        out += std::format("  span  [0x{:08x}, 0x{:08x})  {} erase cmd(s), {} write cmd(s)\n", s.begin,
                           s.end, s.erases.size(), s.writes.size());
    out += std::format("  total erase 0x{:x} B, write 0x{:x} B, skipped (0xFF) 0x{:x} B\n", eraseBytes(),
                       writeBytes(), skippedBytes);
    for (const auto& w : warnings) out += "  warning: " + w + "\n";
    return out;
}

} // namespace sdm
