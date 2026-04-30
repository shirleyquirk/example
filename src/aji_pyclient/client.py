"""High-level Python API over the aji_shim.

Goals:
    - Idiomatic Python: bytes in, bytes out; exceptions on errors.
    - Match the user's discovery flow: auto-pick a single cable / device,
      otherwise require an explicit selector.
    - Don't hide AJI semantics — locks are explicit (context managers),
      claims are explicit, flags are explicit. The decoder validation is
      our point; we don't want the wrapper papering over server behaviour.
"""

from __future__ import annotations

import ctypes
from contextlib import contextmanager
from dataclasses import dataclass
from typing import Iterator, Optional, Sequence, Union

from . import _loader
from .errors import AjiErrorCode, check
from .types import (
    AjiClaim,
    DrFlags,
    IrFlags,
    PackStyle,
    RtiFlags,
    _AjiClaimStruct,
    _AjixDevice,
    _AjixHardware,
)


_DEFAULT_TIMEOUT_MS = 5000


def _bits_to_bytes(nbits: int) -> int:
    return (nbits + 7) // 8


@dataclass(frozen=True)
class AjiHardware:
    chain_id: int           # opaque AJI_CHAIN_ID
    persistent_id: int
    hw_name: str
    port: str
    device_name: str
    server: str
    features: int


@dataclass(frozen=True)
class AjiDevice:
    tap_position: int
    device_id: int           # IDCODE
    mask: int
    instruction_length: int
    features: int
    device_name: str


class AjiClient:
    """Top-level wrapper. One per process is fine; the underlying lib is
    process-global state."""

    def __init__(self) -> None:
        self._lib = _loader.load()

    # ---- discovery -------------------------------------------------------

    def get_hardware(self, timeout_ms: int = _DEFAULT_TIMEOUT_MS) -> list[AjiHardware]:
        # Two-pass: first call with count=0 to learn the size, then call again.
        count = ctypes.c_uint32(0)
        e = self._lib.ajix_get_hardware(ctypes.byref(count), None, timeout_ms)
        # The first call may return AJI_NO_ERROR with count set, or it may
        # need a non-null buffer to succeed. Try the latter form too.
        if e != AjiErrorCode.NO_ERROR or count.value == 0:
            count = ctypes.c_uint32(16)
            buf = (_AjixHardware * count.value)()
            e = self._lib.ajix_get_hardware(ctypes.byref(count), buf, timeout_ms)
            check(e, call="aji_get_hardware", get_info=self._lib.ajix_get_error_info)
            if count.value > 16:
                # Library wanted more than we asked for; redo with the right size.
                buf = (_AjixHardware * count.value)()
                e = self._lib.ajix_get_hardware(ctypes.byref(count), buf, timeout_ms)
                check(e, call="aji_get_hardware", get_info=self._lib.ajix_get_error_info)
        else:
            buf = (_AjixHardware * count.value)()
            e = self._lib.ajix_get_hardware(ctypes.byref(count), buf, timeout_ms)
            check(e, call="aji_get_hardware", get_info=self._lib.ajix_get_error_info)
        return [
            AjiHardware(
                chain_id=int(buf[i].chain_id or 0),
                persistent_id=buf[i].persistent_id,
                hw_name=buf[i].hw_name.decode("utf-8", "replace"),
                port=buf[i].port.decode("utf-8", "replace"),
                device_name=buf[i].device_name.decode("utf-8", "replace"),
                server=buf[i].server.decode("utf-8", "replace"),
                features=buf[i].features,
            )
            for i in range(count.value)
        ]

    def find_hardware(
        self,
        *,
        hw_name: Optional[str] = None,
        persistent_id: Optional[int] = None,
        timeout_ms: int = _DEFAULT_TIMEOUT_MS,
    ) -> AjiHardware:
        if (hw_name is None) == (persistent_id is None):
            raise ValueError("provide exactly one of hw_name, persistent_id")
        out = _AjixHardware()
        if hw_name is not None:
            e = self._lib.ajix_find_hardware_by_name(
                hw_name.encode("utf-8"), ctypes.byref(out), timeout_ms
            )
            call = "aji_find_hardware(name)"
        else:
            e = self._lib.ajix_find_hardware_by_id(
                persistent_id, ctypes.byref(out), timeout_ms
            )
            call = "aji_find_hardware(id)"
        check(e, call=call, get_info=self._lib.ajix_get_error_info)
        return AjiHardware(
            chain_id=int(out.chain_id or 0),
            persistent_id=out.persistent_id,
            hw_name=out.hw_name.decode("utf-8", "replace"),
            port=out.port.decode("utf-8", "replace"),
            device_name=out.device_name.decode("utf-8", "replace"),
            server=out.server.decode("utf-8", "replace"),
            features=out.features,
        )

    def select_cable(self, *, cable: Optional[str] = None) -> AjiHardware:
        """Match user's hand-typed flow: auto-pick if one cable, else require selector."""
        cables = self.get_hardware()
        if cable is not None:
            for h in cables:
                if h.hw_name == cable or str(h.persistent_id) == cable:
                    return h
            raise ValueError(
                f"No cable matched {cable!r}. Available: "
                + ", ".join(f"{h.hw_name} (pid={h.persistent_id})" for h in cables)
            )
        if len(cables) == 1:
            return cables[0]
        if not cables:
            raise RuntimeError("No JTAG hardware found by jtagd")
        raise RuntimeError(
            "Multiple cables present, pass cable=<hw_name|persistent_id>: "
            + ", ".join(f"{h.hw_name} (pid={h.persistent_id})" for h in cables)
        )

    def read_device_chain(self, hw: AjiHardware) -> list[AjiDevice]:
        count = ctypes.c_uint32(16)
        buf = (_AjixDevice * count.value)()
        e = self._lib.ajix_read_device_chain(hw.chain_id, ctypes.byref(count), buf)
        if count.value > 16:
            buf = (_AjixDevice * count.value)()
            e = self._lib.ajix_read_device_chain(hw.chain_id, ctypes.byref(count), buf)
        check(e, call="aji_read_device_chain", get_info=self._lib.ajix_get_error_info)
        return [
            AjiDevice(
                tap_position=i,
                device_id=buf[i].device_id,
                mask=buf[i].mask,
                instruction_length=buf[i].instruction_length,
                features=buf[i].features,
                device_name=buf[i].device_name.decode("utf-8", "replace"),
            )
            for i in range(count.value)
        ]

    def select_device(
        self,
        hw: AjiHardware,
        *,
        device: Optional[Union[int, str]] = None,
    ) -> AjiDevice:
        """If exactly one device on the chain, use it; else require selector
        (matched against tap_position, IDCODE, or device_name)."""
        chain = self.read_device_chain(hw)
        if device is not None:
            for d in chain:
                if (
                    d.tap_position == device
                    or d.device_id == device
                    or d.device_name == device
                    or (isinstance(device, str) and f"0x{d.device_id:08x}" == device.lower())
                ):
                    return d
            raise ValueError(
                f"No device matched {device!r}. Available: "
                + ", ".join(
                    f"tap{d.tap_position} idcode=0x{d.device_id:08x} {d.device_name!r}"
                    for d in chain
                )
            )
        if len(chain) == 1:
            return chain[0]
        if not chain:
            raise RuntimeError("No devices on chain")
        raise RuntimeError(
            "Multiple devices on chain, pass device=<tap_position|idcode|name>: "
            + ", ".join(
                f"tap{d.tap_position} idcode=0x{d.device_id:08x} {d.device_name!r}"
                for d in chain
            )
        )

    # ---- open ------------------------------------------------------------

    def open_device(
        self,
        hw: AjiHardware,
        device: AjiDevice,
        claims: Sequence[AjiClaim],
        *,
        application_name: str = "usb_blaster_decode_test",
    ) -> "OpenDevice":
        claim_arr = (_AjiClaimStruct * len(claims))()
        for i, c in enumerate(claims):
            claim_arr[i].type = int(c.type)
            claim_arr[i].value = c.value
        open_id = ctypes.c_void_p()
        e = self._lib.ajix_open_device(
            hw.chain_id,
            device.tap_position,
            ctypes.byref(open_id),
            claim_arr if claims else None,
            len(claims),
            application_name.encode("utf-8"),
        )
        check(e, call="aji_open_device", get_info=self._lib.ajix_get_error_info)
        return OpenDevice(
            self._lib,
            chain_id=hw.chain_id,
            open_id=int(open_id.value or 0),
            device=device,
        )

    # ---- chain-level locking --------------------------------------------

    @contextmanager
    def lock_chain(self, hw: AjiHardware, timeout_ms: int = _DEFAULT_TIMEOUT_MS) -> Iterator[None]:
        e = self._lib.ajix_lock_chain(hw.chain_id, timeout_ms)
        check(e, call="aji_lock_chain", get_info=self._lib.ajix_get_error_info)
        try:
            yield
        finally:
            self._lib.ajix_unlock_chain(hw.chain_id)


class OpenDevice:
    """Wraps an AJI_OPEN_ID. Use ``with dev.locked():`` around a sequence
    of access_ir / access_dr calls."""

    def __init__(self, lib, *, chain_id: int, open_id: int, device: AjiDevice) -> None:
        self._lib = lib
        self._chain_id = chain_id
        self._open_id = open_id
        self.device = device
        self._closed = False

    @property
    def chain_id(self) -> int:
        return self._chain_id

    @property
    def open_id(self) -> int:
        return self._open_id

    def close(self) -> None:
        if self._closed:
            return
        self._lib.ajix_close_device(self._open_id)
        self._closed = True

    def __enter__(self) -> "OpenDevice":
        return self

    def __exit__(self, *exc) -> None:
        self.close()

    # ---- locking -----------------------------------------------------

    @contextmanager
    def locked(
        self,
        *,
        timeout_ms: int = _DEFAULT_TIMEOUT_MS,
        pack_style: PackStyle = PackStyle.NEVER,
    ) -> Iterator[None]:
        e = self._lib.ajix_lock(self._open_id, timeout_ms, int(pack_style))
        check(e, call="aji_lock", get_info=self._lib.ajix_get_error_info)
        try:
            yield
        finally:
            self._lib.ajix_unlock(self._open_id)

    def acquire_from_chain_lock(
        self,
        chain_id: int,
        *,
        pack_style: PackStyle = PackStyle.NEVER,
    ) -> None:
        """``aji_unlock_chain_lock``: release the chain lock and grab device lock atomically."""
        e = self._lib.ajix_unlock_chain_lock(chain_id, self._open_id, int(pack_style))
        check(e, call="aji_unlock_chain_lock", get_info=self._lib.ajix_get_error_info)

    def release_to_chain_lock(self, chain_id: int) -> None:
        """``aji_unlock_lock_chain``: release device lock and acquire chain lock."""
        e = self._lib.ajix_unlock_lock_chain(self._open_id, chain_id)
        check(e, call="aji_unlock_lock_chain", get_info=self._lib.ajix_get_error_info)

    def flush(self) -> None:
        e = self._lib.ajix_flush(self._open_id)
        check(e, call="aji_flush", get_info=self._lib.ajix_get_error_info)

    # ---- IR / DR -----------------------------------------------------

    def access_ir(
        self,
        instruction: int,
        *,
        capture: bool = True,
        flags: IrFlags = IrFlags.NONE,
    ) -> Optional[int]:
        """DWORD-form aji_access_ir. Returns the captured IR (LSB-first DWORD)
        or None if ``capture=False`` (lets the server pack the call)."""
        captured = ctypes.c_uint32(0)
        e = self._lib.ajix_access_ir_dword(
            self._open_id,
            instruction,
            ctypes.byref(captured) if capture else None,
            int(flags),
        )
        check(e, call="aji_access_ir(dword)", get_info=self._lib.ajix_get_error_info)
        return captured.value if capture else None

    def access_ir_bits(
        self,
        write: bytes,
        *,
        length: int,
        capture: bool = True,
        flags: IrFlags = IrFlags.NONE,
    ) -> Optional[bytes]:
        """Bit-vector form. ``length`` is the IR length in bits;
        ``write`` is LSB-first packed bytes (length must be ceil(length/8))."""
        nbytes = _bits_to_bytes(length)
        if len(write) != nbytes:
            raise ValueError(
                f"write length {len(write)} != ceil({length}/8) = {nbytes}"
            )
        read_buf = ctypes.create_string_buffer(nbytes) if capture else None
        e = self._lib.ajix_access_ir_bits(
            self._open_id,
            length,
            write,
            read_buf if capture else None,
            int(flags),
        )
        check(e, call="aji_access_ir(bits)", get_info=self._lib.ajix_get_error_info)
        return bytes(read_buf.raw[:nbytes]) if capture else None

    def access_dr(
        self,
        *,
        length: int,
        flags: DrFlags = DrFlags.NONE,
        write: bytes = b"",
        write_offset: int = 0,
        write_length: Optional[int] = None,
        read_offset: int = 0,
        read_length: Optional[int] = None,
        capture: bool = True,
    ) -> Optional[bytes]:
        """``aji_access_dr``. Writes ``write_length`` bits starting at
        ``write_offset`` (default: write all bits in ``write``); reads
        ``read_length`` bits starting at ``read_offset`` (default: read all
        bits if ``capture`` else nothing)."""
        wl = write_length if write_length is not None else len(write) * 8
        rl = read_length if read_length is not None else (length if capture else 0)
        if write and len(write) < _bits_to_bytes(wl):
            raise ValueError(f"write buffer too small for write_length={wl}")
        read_buf = (
            ctypes.create_string_buffer(_bits_to_bytes(rl)) if rl > 0 else None
        )
        e = self._lib.ajix_access_dr(
            self._open_id,
            length,
            int(flags),
            write_offset,
            wl,
            write if write else None,
            read_offset,
            rl,
            read_buf,
        )
        check(e, call="aji_access_dr", get_info=self._lib.ajix_get_error_info)
        if read_buf is None:
            return None
        return bytes(read_buf.raw[: _bits_to_bytes(rl)])

    def access_dr_batch(
        self,
        *,
        length: int,
        batch: int,
        flags: DrFlags = DrFlags.NONE,
        write: bytes = b"",
        write_length: int,
        write_offset: int = 0,
        read_length: int = 0,
        read_offset: int = 0,
    ) -> Optional[bytes]:
        """Repeated DR scan. Each iteration consumes
        ``ceil(write_length/8)`` bytes of write and produces
        ``ceil(read_length/8)`` bytes of read (per the aji.h doc)."""
        per_w = _bits_to_bytes(write_length)
        per_r = _bits_to_bytes(read_length)
        if write and len(write) < per_w * batch:
            raise ValueError(
                f"write buffer too small: need {per_w * batch}, got {len(write)}"
            )
        read_buf = (
            ctypes.create_string_buffer(per_r * batch) if read_length else None
        )
        e = self._lib.ajix_access_dr_batch(
            self._open_id,
            length,
            int(flags),
            write_offset,
            write_length,
            write if write else None,
            read_offset,
            read_length,
            read_buf,
            batch,
        )
        check(e, call="aji_access_dr(batch)", get_info=self._lib.ajix_get_error_info)
        return bytes(read_buf.raw) if read_buf is not None else None

    # ---- TAP control -------------------------------------------------

    def run_test_idle(self, num_clocks: int, *, flags: Optional[RtiFlags] = None) -> None:
        if flags is None:
            e = self._lib.ajix_run_test_idle(self._open_id, num_clocks)
            call = "aji_run_test_idle"
        else:
            e = self._lib.ajix_run_test_idle_flags(self._open_id, num_clocks, int(flags))
            call = "aji_run_test_idle(flags)"
        check(e, call=call, get_info=self._lib.ajix_get_error_info)

    def test_logic_reset(self) -> None:
        e = self._lib.ajix_test_logic_reset(self._open_id)
        check(e, call="aji_test_logic_reset", get_info=self._lib.ajix_get_error_info)

    def delay(self, microseconds: int) -> None:
        e = self._lib.ajix_delay(self._open_id, microseconds)
        check(e, call="aji_delay", get_info=self._lib.ajix_get_error_info)
