// Compiled only when SDM_AJI_INCLUDE_DIR is set: proves jtag_clock.hpp's AJI path type-checks.
#include "sdm/jtag_clock.hpp"

#if !__has_include(<aji.h>)
#error "aji.h not found; set SDM_AJI_INCLUDE_DIR"
#endif

auto* const sdm_aji_check_instantiate = &sdm::jtag::setJtagClock;
