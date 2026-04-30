"""Python ctypes wrapper around libaji_client (via the aji_shim).

The shim handles C++ name-mangling and ABI; everything below speaks plain C.

Typical usage::

    from aji_pyclient import AjiClient, AjiClaim, ClaimType, PackStyle

    aji = AjiClient()
    cable = aji.select_cable()              # auto-pick if exactly 1
    device, tap_pos = aji.select_device(cable)  # auto-pick if exactly 1
    claims = [AjiClaim(ClaimType.IR_SHARED, 0)]
    with aji.open_device(cable, tap_pos, claims) as dev:
        with dev.locked():
            captured = dev.access_ir(0x06, 10)        # IR=BYPASS, length 10
            tdo = dev.access_dr(length=32, write=b"")  # read-only DR scan
"""

from .errors import AjiError, AjiErrorCode
from .client import AjiClient, AjiHardware, AjiDevice, OpenDevice
from .types import (
    AjiClaim,
    ClaimType,
    DrFlags,
    IrFlags,
    PackStyle,
    RtiFlags,
)

__all__ = [
    "AjiClient",
    "AjiClaim",
    "AjiDevice",
    "AjiError",
    "AjiErrorCode",
    "AjiHardware",
    "ClaimType",
    "DrFlags",
    "IrFlags",
    "OpenDevice",
    "PackStyle",
    "RtiFlags",
]
