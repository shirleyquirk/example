# SDM mailbox protocol: reference notes

This is a working reference for the Secure Device Manager (SDM) command protocol on
Stratix 10 and Agilex 7 devices, as far as it matters for QSPI flash programming over JTAG.

**Confidence tags** used below:
- **[src]**: read directly in open-source code (ATF, U-Boot) at the commit listed in *Sources*.
- **[doc]**: from Intel docs, seen only through search-engine excerpts. The sandbox that
  produced this file could not reach intel.com, altera.com or the manual mirrors.
- **[?]**: inferred or remembered but not confirmed. Measure it on hardware before relying on it.

## 1. Transport

| Path | Who uses it | Notes |
|---|---|---|
| HPS mailbox (MMIO @ `0xFFA30000`, `0x10A30000` on Agilex 5) | ATF, U-Boot | Circular buffers: CMD at `+0x40` (32 words), RESP at `+0xC0` (16 words); `CIN/COUT/RIN/ROUT` pointers; doorbells at `+0x400/+0x480`. **[src]** |
| Mailbox Client IP (Avalon-MM/ST in fabric) | User logic, or JTAG-to-Avalon bridge driven from System Console (`rsu1.tcl` design example) | Requires a user design containing the IP. **[doc]** |
| **JTAG → SDM directly ("packet service")** | System Console `packet` service, AN 936 *Executing SDM Commands via JTAG Interface* | No user IP needed. System Console turns packets into JTAG instructions. This goes through jtagd, the same as `quartus_pgm` and `quartus_jli`. **[doc]** |

Commands and responses use the same framing on every path. The sections below apply to all
of them.

## 2. Framing

### Command header (1 word, little-endian) **[src]**

```
 31    28 27    24 23 22            12 11  10                0
+--------+--------+--+----------------+---+-------------------+
| client | job id |0 |  length (words)| I |  command code     |
+--------+--------+--+----------------+---+-------------------+
```
- `client` [31:28]: client ID (ATF uses 1, U-Boot uses 1).
- `job id` [27:24]: echoed in the response, so you can match responses to requests.
- `length` [22:12]: number of argument words that follow the header (11 bits, so at most 2047).
- `I` [11]: indirect flag (arguments are a descriptor, not inline data). Use 0 for everything here.
- `cmd` [10:0]: command code.

### Response header (1 word) **[src]**

```
 31    28 27    24 23 22            12 11  10                0
+--------+--------+--+----------------+---+-------------------+
| client | job id |0 |  length (words)| 0 |   error code      |
+--------+--------+--+----------------+---+-------------------+
```
`length` response data words follow the header. An error code of 0 means OK.

### Error codes (response header [10:0]) **[src: U-Boot `mailbox_s10.h`]**

| Code | Name | Likely meaning for QSPI work **[?]** |
|---|---|---|
| 0x000 | STATOK | |
| 0x001 | INVALID_COMMAND | Unknown code, or a command that is not allowed from this source (JTAG vs HPS) |
| 0x002 | UNKNOWN_BR | |
| 0x003 | UNKNOWN | |
| 0x004 | INVALID_LEN | Wrong argument count; possibly also exceeding the maximum words per QSPI R/W |
| 0x005 | INVALID_INDIRECT_SETTING | |
| 0x006 | CMD_INVALID_ON_SRC | For example `QSPI_DIRECT` sent from JTAG |
| 0x008 | CLIENT_ID_NO_MATCH | Another client holds the QSPI (stale `QSPI_OPEN`?) |
| 0x009 | INVALID_ADDR | Misaligned address, or out of range (but see §5 KB note) |
| 0x00A | AUTH_FAIL | |
| 0x00B | TIMEOUT | |
| 0x00C | HW_NOT_RDY | QSPI not available: no helper image, or HPS owns it |
| 0x00F | FUNC_NOT_SUPPORTED | |
| 0x080–0x091 | PUF/attestation/crypto errors | Not relevant here |
| 0x100 | NOT_CONFIGURED | Device not in user mode (no helper design) |
| 0x1FF | DEVICE_BUSY | QSPI already opened by another client |
| 0x2FF | NO_VALID_RESP_AVAILABLE | |
| 0x3FF | ERROR | Generic error |

The ATF host-side codes (`-1..-5`, `-2047` timeout) belong to the host driver and are not
SDM codes. Do not mix them into this table.

## 3. Command catalogue

"Args" and "Resp" are word counts, excluding the header.

### 3.1 Generic / status

| Code | Name | Args | Resp | Src | Notes |
|---|---|---|---|---|---|
| 0x000 | NOOP | 0 | 0 | [src] | Use as the latency floor / keep-alive |
| 0x001 | SYNC | 0 | 0 | [src] | |
| 0x002 | RESTART | 0 | 0 | [src] | Resets the mailbox protocol state |
| 0x003 | CANCEL | 0 | 0 | [src] | Cancels an in-flight command |
| 0x004 | CONFIG_STATUS | 0 | 6–16 | [src] | Word 0 = state (`0x10000000` CONFIG, `0xF00000xx` errors, `…08` = QSPI_ERROR); word 1 low 24 bits = firmware version |
| 0x006 | RECONFIG | … | | [src] | |
| 0x007 | RECONFIG_MSEL | | | [src] | U-Boot only |
| 0x008 | RECONFIG_DATA | | | [src] | |
| 0x009 | RECONFIG_STATUS | 0 | 6 | [src] | Word 2 = pin status (bit 31 nSTATUS); word 3 = soft functions (CONF_DONE, INIT_DONE, SEU_ERROR) |
| 0x00B | VAB_SRC_CERT | | | [src] | |
| 0x010 | GET_IDCODE | 0 | 1 | [src] | JTAG IDCODE |
| 0x012 | GET_CHIPID | 0 | 2 | [src] | 64-bit chip ID |
| 0x013 | GET_USERCODE | 0 | 1 | [src] | |
| 0x018 | HWMON_READVOLT | 1 | 1 | [src] | Argument = channel bitmask |
| 0x019 | HWMON_READTEMP | 1 | 1+ | [src] | |
| 0x045 | FPGA_CONFIG_COMP | 0 | | [src] | |
| 0x047 | REBOOT_HPS | 0 | | [src] | |
| 0x1B0 | GET_ROM_PATCH_SHA384 | | | [src] | |
| 0x500 | GET_DEVICEID | | | [src] | ATF name; newer firmware only |

### 3.2 QSPI: the commands the programmer needs

| Code | Name | Args | Resp | Src | Argument layout / limits |
|---|---|---|---|---|---|
| 0x032 | **QSPI_OPEN** | 0 | 0 | [src] | Takes exclusive QSPI ownership for this client. Must come before any other QSPI command. |
| 0x033 | **QSPI_CLOSE** | 0 | 0 | [src] | Releases ownership. **Always** send it, including on error paths. |
| 0x034 | **QSPI_SET_CS** | 1 | 0 | [src] | `[31:28]` chip select; `[27]` external-decoder mode; `[26]` combined-address mode (ATF bit positions). Other bits 0. |
| 0x035 | QSPI_READ_DEVICE_REG | 2 | ⌈n/4⌉ | [doc] | `{opcode, nbytes≤8}`. For example `0x9F` gives JEDEC ID and `0x05` gives the status register. |
| 0x036 | QSPI_WRITE_DEVICE_REG | 2+⌈n/4⌉ | 0 | [doc] | `{opcode, nbytes≤8, data…}`. Address bytes go MSB first when used for an erase opcode. |
| 0x037 | QSPI_SEND_DEVICE_OP | 1 | 0 | [doc] | `{opcode}`: a bare opcode such as `0x06` WREN or `0x66/0x99` reset. |
| 0x038 | **QSPI_ERASE** | 2 | 0 | [src] | `{byte_addr, nwords}`. `byte_addr` must be 4 KiB aligned; `nwords` must be a multiple of 0x400 (4 KiB). |
| 0x039 | **QSPI_WRITE** | 2+n | 0 | [src] | `{byte_addr, nwords, data[nwords]}`. `byte_addr` must be word aligned. Max `nwords`: **ATF says 0x1000 (16 KiB); the IP UG excerpt says 1024 (4 KiB)**, so this has to be measured over JTAG. |
| 0x03A | **QSPI_READ** | 2 | n | [src] | `{byte_addr, nwords}`, same maximum as write. |
| 0x03B | QSPI_DIRECT | 0 | 1 | [src] | HPS only: hands the QSPI controller to HPS and returns the ref clock. Expect this to fail from JTAG. |
| 0x074 | **QSPI_GET_DEVICE_INFO** | 0 | 8 | [src] | Flash size and erase size. The 8-word layout is not documented in the sources read; decode it empirically. (ATF also names 0x74 `RSU_GET_DEVICE_INFO`.) |

### 3.3 RSU (useful for checking the result after programming)

| Code | Name | Src | Notes |
|---|---|---|---|
| 0x05A | GET_SUBPARTITION_TABLE | [src] | Returns the SPT flash offsets, so you can confirm that what you wrote is where firmware expects it |
| 0x05B | RSU_STATUS | [src] | Current image, failure info |
| 0x05C | RSU_UPDATE | [src] | Arg: flash offset to reconfigure from |
| 0x05D | HPS_STAGE_NOTIFY | [src] | |

### 3.4 SEU, crypto and attestation (out of scope for the programmer)

`0x3C SEU_ERR_READ`, `0x41 SAFE_INJECT_SEU_ERR`, `0x7B–0x8B FCS_*`, `0xA0–0xA9 FCS CS
session/key`, `0xD5 PSG_SIGMA_TEARDOWN`, `0x180–0x183 attestation`, `0x194 MCTP`. All **[src]**, ATF.

## 4. Minimal programming sequence

```
GET_IDCODE                 sanity check that the right device is on the chain
CONFIG_STATUS              state must be user mode (helper design loaded)
QSPI_OPEN
QSPI_SET_CS   (0 << 28)
QSPI_GET_DEVICE_INFO       size check against the plan
QSPI_READ_DEVICE_REG 0x9F,3 → JEDEC ID (optional, for logging)
for each 4 KiB-aligned erase span:   QSPI_ERASE addr, nwords
for each chunk ≤ MAX_WORDS:          QSPI_WRITE addr, n, data…   (skip all-0xFF chunks)
for each chunk ≤ MAX_WORDS:          QSPI_READ  addr, n → compare
QSPI_CLOSE                 always
```

## 5. Known quirks from the documentation

- **KB 343452 (Agilex 7):** QSPI commands whose address is past the end of the flash return
  an *incorrect* response code. Do not rely on the error code for range checks; check bounds
  on the host against `QSPI_GET_DEVICE_INFO`. **[doc]**
- **Quartus 20.3:** JIC programming of 128 Mb QSPI failed on Agilex 7, fixed in 20.4. This
  points at 3-byte versus 4-byte addressing handling in SDM firmware or the helper. Test a
  flash larger than 16 MiB across the 16 MiB boundary. **[doc]**
- The SDM rejects `QSPI_DIRECT` when QSPI ownership is not assigned to HPS. **[doc]**
- The SDM has one QSPI owner at a time. A crashed session that never sent `QSPI_CLOSE` may
  block the next `QSPI_OPEN` (0x1FF or 0x008?). Recovery could be `QSPI_CLOSE` first,
  `RESTART`, or a reconfiguration. **[?]** This is the first thing to characterise.

## Sources

- ATF `plat/intel/soc/common/include/socfpga_mailbox.h`, `soc/socfpga_mailbox.c`, `socfpga_sip_svc.c`,
  [github.com/ARM-software/arm-trusted-firmware](https://github.com/ARM-software/arm-trusted-firmware/blob/master/plat/intel/soc/common/include/socfpga_mailbox.h) (master, fetched 2026-09-26)
- U-Boot `arch/arm/mach-socfpga/include/mach/mailbox_s10.h`, `mailbox_s10.c`,
  [github.com/altera-fpga/u-boot-socfpga](https://github.com/altera-fpga/u-boot-socfpga/blob/socfpga_v2025.07/arch/arm/mach-socfpga/include/mach/mailbox_s10.h) (`socfpga_v2025.07`)
- Linux `include/linux/firmware/intel/stratix10-svc-client.h` (SMC-level, not raw codes)
- Intel AN 936 *Executing SDM Commands via JTAG Interface*: <https://www.intel.com/content/www/us/en/docs/programmable/683313/current.html> **(not readable from sandbox)**
- Mailbox Client Intel FPGA IP User Guide 683290: <https://www.intel.com/content/www/us/en/docs/programmable/683290/21-3-20-1-0/mailbox-client-fpga-ip-user-guide.html> **(excerpts only)**
- Agilex 7 Mailbox Client QSPI/RSU design example (`rsu1.tcl`): <https://www.intel.com/content/www/us/en/design-example/714805/intel-agilex-7-fpga-mailbox-client-with-qspi-flash-access-and-remote-system-update-design-example.html>
- KB 343452 (bad response code past flash end): <https://community.altera.com/kb/knowledge-base/why-do-qspi-commands-in-mailbox-client-fpga-ip-with-input-flash-address-beyond-t/343452>
- KB 343373 (128 Mb JIC failure, 20.3): <https://community.altera.com/kb/knowledge-base/why-does-jic-programming-fail-when-using-qspi-flash-devices-of-128mb-density-wit/343373>
