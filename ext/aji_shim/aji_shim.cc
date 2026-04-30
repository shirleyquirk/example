// C-callable shim around libaji_client.
//
// libaji_client exposes overloaded C++ functions and a couple of structs
// that pass back library-owned strings. ctypes can't dispatch to a C++
// overload (the symbol is mangled) and library-owned strings can be
// invalidated by the next call. This shim:
//
//   1. Picks a single overload per AJI entry point and re-exports it
//      under an unmangled name (`ajix_*`).
//   2. Copies AJI_HARDWARE strings into a caller-owned buffer so the
//      Python side can hold onto them.
//   3. Returns AJI_ERROR codes verbatim; the caller is expected to map
//      them to exceptions.
//
// We deliberately do not do any allocation here that the caller has to
// free — the Python wrapper is keeping the memory model simple by
// pre-allocating buffers and asking the shim to fill them.

#include "aji.h"

#include <cstring>
#include <cstdint>

extern "C" {

// ---- error info -----------------------------------------------------------

const char* ajix_get_error_info(void) {
    return aji_get_error_info();
}

// ---- hardware enumeration -------------------------------------------------

// Caller-owned mirror of AJI_HARDWARE that owns its strings. Simpler for
// ctypes than tracking lifetimes of library-internal pointers.
struct AjixHardware {
    AJI_CHAIN_ID chain_id;
    DWORD persistent_id;
    char hw_name[128];
    char port[64];
    char device_name[128];
    int  chain_type;        // AJI_CHAIN_TYPE
    char server[128];
    DWORD features;
};

static void copy_str(char* dst, std::size_t dst_n, const char* src) {
    if (!src) { dst[0] = 0; return; }
    std::strncpy(dst, src, dst_n - 1);
    dst[dst_n - 1] = 0;
}

// Fill `out` with up to *count entries; on return *count holds the number
// of hardware entries the library knew about (may be larger than the
// caller-supplied buffer — caller can grow and retry).
AJI_ERROR ajix_get_hardware(DWORD* count, AjixHardware* out, DWORD timeout_ms) {
    DWORD n = *count;
    AJI_HARDWARE* tmp = nullptr;
    if (n > 0) {
        tmp = new AJI_HARDWARE[n];
    }
    AJI_ERROR e = aji_get_hardware(&n, tmp, timeout_ms);
    if (e == AJI_NO_ERROR && out != nullptr) {
        DWORD m = (n < *count) ? n : *count;
        for (DWORD i = 0; i < m; ++i) {
            out[i].chain_id      = tmp[i].chain_id;
            out[i].persistent_id = tmp[i].persistent_id;
            copy_str(out[i].hw_name,     sizeof out[i].hw_name,     tmp[i].hw_name);
            copy_str(out[i].port,        sizeof out[i].port,        tmp[i].port);
            copy_str(out[i].device_name, sizeof out[i].device_name, tmp[i].device_name);
            out[i].chain_type    = static_cast<int>(tmp[i].chain_type);
            copy_str(out[i].server,      sizeof out[i].server,      tmp[i].server);
            out[i].features     = tmp[i].features;
        }
    }
    *count = n;
    delete[] tmp;
    return e;
}

AJI_ERROR ajix_find_hardware_by_name(const char* hw_name, AjixHardware* out, DWORD timeout_ms) {
    AJI_HARDWARE tmp = {};
    AJI_ERROR e = aji_find_hardware(hw_name, &tmp, timeout_ms);
    if (e == AJI_NO_ERROR && out != nullptr) {
        out->chain_id      = tmp.chain_id;
        out->persistent_id = tmp.persistent_id;
        copy_str(out->hw_name,     sizeof out->hw_name,     tmp.hw_name);
        copy_str(out->port,        sizeof out->port,        tmp.port);
        copy_str(out->device_name, sizeof out->device_name, tmp.device_name);
        out->chain_type    = static_cast<int>(tmp.chain_type);
        copy_str(out->server,      sizeof out->server,      tmp.server);
        out->features     = tmp.features;
    }
    return e;
}

AJI_ERROR ajix_find_hardware_by_id(DWORD persistent_id, AjixHardware* out, DWORD timeout_ms) {
    AJI_HARDWARE tmp = {};
    AJI_ERROR e = aji_find_hardware(persistent_id, &tmp, timeout_ms);
    if (e == AJI_NO_ERROR && out != nullptr) {
        out->chain_id      = tmp.chain_id;
        out->persistent_id = tmp.persistent_id;
        copy_str(out->hw_name,     sizeof out->hw_name,     tmp.hw_name);
        copy_str(out->port,        sizeof out->port,        tmp.port);
        copy_str(out->device_name, sizeof out->device_name, tmp.device_name);
        out->chain_type    = static_cast<int>(tmp.chain_type);
        copy_str(out->server,      sizeof out->server,      tmp.server);
        out->features     = tmp.features;
    }
    return e;
}

// ---- chain content --------------------------------------------------------

struct AjixDevice {
    DWORD device_id;
    DWORD mask;
    BYTE  instruction_length;
    DWORD features;
    char  device_name[128];
};

AJI_ERROR ajix_read_device_chain(AJI_CHAIN_ID chain_id, DWORD* count, AjixDevice* out) {
    DWORD n = *count;
    AJI_DEVICE* tmp = nullptr;
    if (n > 0) tmp = new AJI_DEVICE[n];
    AJI_ERROR e = aji_read_device_chain(chain_id, &n, tmp, true);
    if (e == AJI_NO_ERROR && out != nullptr) {
        DWORD m = (n < *count) ? n : *count;
        for (DWORD i = 0; i < m; ++i) {
            out[i].device_id          = tmp[i].device_id;
            out[i].mask               = tmp[i].mask;
            out[i].instruction_length = tmp[i].instruction_length;
            out[i].features           = tmp[i].features;
            copy_str(out[i].device_name, sizeof out[i].device_name, tmp[i].device_name);
        }
    }
    *count = n;
    delete[] tmp;
    return e;
}

// ---- open / close ---------------------------------------------------------

AJI_ERROR ajix_open_device(
        AJI_CHAIN_ID chain_id, DWORD tap_position, AJI_OPEN_ID* open_id,
        const AJI_CLAIM* claims, DWORD claim_n, const char* application_name) {
    return aji_open_device(chain_id, tap_position, open_id, claims, claim_n, application_name);
}

AJI_ERROR ajix_close_device(AJI_OPEN_ID open_id) {
    return aji_close_device(open_id);
}

// ---- locking --------------------------------------------------------------

AJI_ERROR ajix_lock(AJI_OPEN_ID open_id, DWORD timeout_ms, int pack_style) {
    return aji_lock(open_id, timeout_ms, static_cast<AJI_PACK_STYLE>(pack_style));
}

AJI_ERROR ajix_unlock(AJI_OPEN_ID open_id) {
    return aji_unlock(open_id);
}

AJI_ERROR ajix_lock_chain(AJI_CHAIN_ID chain_id, DWORD timeout_ms) {
    return aji_lock_chain(chain_id, timeout_ms);
}

AJI_ERROR ajix_unlock_chain(AJI_CHAIN_ID chain_id) {
    return aji_unlock_chain(chain_id);
}

AJI_ERROR ajix_unlock_lock(AJI_OPEN_ID unlock_id, AJI_OPEN_ID lock_id) {
    return aji_unlock_lock(unlock_id, lock_id);
}

AJI_ERROR ajix_unlock_chain_lock(AJI_CHAIN_ID unlock_id, AJI_OPEN_ID lock_id, int pack_style) {
    return aji_unlock_chain_lock(unlock_id, lock_id, static_cast<AJI_PACK_STYLE>(pack_style));
}

AJI_ERROR ajix_unlock_lock_chain(AJI_OPEN_ID unlock_id, AJI_CHAIN_ID lock_id) {
    return aji_unlock_lock_chain(unlock_id, lock_id);
}

AJI_ERROR ajix_flush(AJI_OPEN_ID open_id) {
    return aji_flush(open_id);
}

// ---- IR / DR access -------------------------------------------------------

AJI_ERROR ajix_access_ir_dword(AJI_OPEN_ID open_id, DWORD instruction, DWORD* captured_ir, DWORD flags) {
    return aji_access_ir(open_id, instruction, captured_ir, flags);
}

AJI_ERROR ajix_access_ir_bits(
        AJI_OPEN_ID open_id, DWORD length_ir,
        const BYTE* write_bits, BYTE* read_bits, DWORD flags) {
    return aji_access_ir(open_id, length_ir, write_bits, read_bits, flags);
}

AJI_ERROR ajix_access_dr(
        AJI_OPEN_ID open_id, DWORD length_dr, DWORD flags,
        DWORD write_offset, DWORD write_length, const BYTE* write_bits,
        DWORD read_offset, DWORD read_length, BYTE* read_bits) {
    return aji_access_dr(open_id, length_dr, flags,
                         write_offset, write_length, write_bits,
                         read_offset, read_length, read_bits);
}

AJI_ERROR ajix_access_dr_batch(
        AJI_OPEN_ID open_id, DWORD length_dr, DWORD flags,
        DWORD write_offset, DWORD write_length, const BYTE* write_bits,
        DWORD read_offset, DWORD read_length, BYTE* read_bits, DWORD batch) {
    return aji_access_dr(open_id, length_dr, flags,
                         write_offset, write_length, write_bits,
                         read_offset, read_length, read_bits, batch);
}

// ---- TAP control ----------------------------------------------------------

AJI_ERROR ajix_run_test_idle(AJI_OPEN_ID open_id, DWORD num_clocks) {
    return aji_run_test_idle(open_id, num_clocks);
}

AJI_ERROR ajix_run_test_idle_flags(AJI_OPEN_ID open_id, DWORD num_clocks, DWORD flags) {
    return aji_run_test_idle(open_id, num_clocks, flags);
}

AJI_ERROR ajix_test_logic_reset(AJI_OPEN_ID open_id) {
    return aji_test_logic_reset(open_id);
}

AJI_ERROR ajix_delay(AJI_OPEN_ID open_id, DWORD timeout_microseconds) {
    return aji_delay(open_id, timeout_microseconds);
}

}  // extern "C"
