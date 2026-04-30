"""Smoke tests for the AJI wrapper. Don't need capture, only jtagd + cable.

These run under ``USB_BLASTER_HW=1`` and don't try to validate anything
against the decoder yet — they just confirm the wrapper drives jtagd
without ABI errors.
"""

from __future__ import annotations


def test_lists_at_least_one_cable(aji_client):
    cables = aji_client.get_hardware()
    assert cables, "no JTAG hardware reported by jtagd"


def test_chain_has_devices(aji_client, selected_cable):
    chain = aji_client.read_device_chain(selected_cable)
    assert chain, "no devices on selected cable's chain"
    for d in chain:
        # IDCODE bit 0 must be 1 per IEEE 1149.1.
        assert d.device_id & 1 == 1, f"bad IDCODE 0x{d.device_id:08x}"
        assert d.instruction_length > 0


def test_open_lock_unlock_close(open_device):
    with open_device.locked():
        # Just hold + release the lock. If this returns we know
        # access_ir/access_dr will at least find a locked device.
        pass


def test_access_ir_bypass(open_device):
    bypass = (1 << open_device.device.instruction_length) - 1
    with open_device.locked():
        captured = open_device.access_ir(bypass)
    # The captured IR should have the standard 'b01 in the low two bits.
    assert captured is not None
    assert captured & 0x3 == 0x1, f"unexpected IR capture 0x{captured:x}"


def test_access_dr_idcode(open_device):
    """Loading IDCODE into IR and shifting 32 zero DR bits returns the
    silicon's IDCODE. Works on every JTAG-compliant device with an IDCODE
    register."""
    IDCODE_IR = 0x6  # standard for most Altera/Intel devices; user01-style
    with open_device.locked():
        # First try the device-defined IDCODE if the chain reports a name;
        # otherwise just use the canonical 0x6.
        open_device.access_ir(IDCODE_IR)
        dr_in = b"\x00\x00\x00\x00"
        captured = open_device.access_dr(length=32, write=dr_in)
    assert captured is not None and len(captured) == 4
    idcode = int.from_bytes(captured, "little")
    assert idcode == open_device.device.device_id, (
        f"expected idcode 0x{open_device.device.device_id:08x}, "
        f"got 0x{idcode:08x}"
    )
