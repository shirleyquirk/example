"""Plain-data types and flag enums mirroring aji.h."""

from __future__ import annotations

import ctypes
from dataclasses import dataclass
from enum import IntEnum, IntFlag


class ClaimType(IntEnum):
    IR                 = 0x0000
    IR_SHARED          = 0x0100
    IR_SHARED_OVERLAY  = 0x0300
    IR_OVERLAID        = 0x0400
    IR_SHARED_OVERLAID = 0x0500
    IR_WEAK            = 0x0800
    OVERLAY            = 0x0001
    OVERLAY_SHARED     = 0x0101
    OVERLAY_WEAK       = 0x0801


class PackStyle(IntEnum):
    NEVER  = 0
    AUTO   = 1
    MANUAL = 2
    STREAM = 3


class DrFlags(IntFlag):
    NONE             = 0
    UNUSED_0         = 1
    UNUSED_0_OMIT    = 3
    UNUSED_X         = 15
    NO_SHORT         = 16
    END_PAUSE_DR     = 32
    START_PAUSE_DR   = 64
    NO_RESTORE       = 128


class IrFlags(IntFlag):
    NONE         = 0
    COULD_BREAK  = 2


class RtiFlags(IntFlag):
    NONE             = 0
    ACCURATE_CLOCK   = 1
    EXIT_RTI_STATE   = 2


@dataclass
class AjiClaim:
    type: ClaimType
    value: int


# These match the AjixHardware / AjixDevice POD structs in ext/aji_shim/aji_shim.cc.
class _AjixHardware(ctypes.Structure):
    _fields_ = [
        ("chain_id",      ctypes.c_void_p),
        ("persistent_id", ctypes.c_uint32),
        ("hw_name",       ctypes.c_char * 128),
        ("port",          ctypes.c_char * 64),
        ("device_name",   ctypes.c_char * 128),
        ("chain_type",    ctypes.c_int),
        ("server",        ctypes.c_char * 128),
        ("features",      ctypes.c_uint32),
    ]


class _AjixDevice(ctypes.Structure):
    _fields_ = [
        ("device_id",          ctypes.c_uint32),
        ("mask",               ctypes.c_uint32),
        ("instruction_length", ctypes.c_uint8),
        ("features",           ctypes.c_uint32),
        ("device_name",        ctypes.c_char * 128),
    ]


class _AjiClaimStruct(ctypes.Structure):
    _fields_ = [
        ("type",  ctypes.c_int),
        ("value", ctypes.c_uint32),
    ]
