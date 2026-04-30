"""Locate and bind the aji_shim shared library.

Resolution order:
    1. AJI_SHIM env var, if set, is taken as the absolute path.
    2. <repo_root>/build/aji_shim/libaji_shim.so (where the in-tree
       Makefile drops it).

We don't fall back to system paths — picking up a stray libaji_shim.so
would be more confusing than helpful.
"""

from __future__ import annotations

import ctypes
import os
import pathlib

from .types import _AjixDevice, _AjixHardware, _AjiClaimStruct


def _find_shim() -> pathlib.Path:
    env = os.environ.get("AJI_SHIM")
    if env:
        p = pathlib.Path(env)
        if not p.exists():
            raise FileNotFoundError(f"AJI_SHIM={env} does not exist")
        return p
    here = pathlib.Path(__file__).resolve()
    # src/aji_pyclient/_loader.py -> repo_root
    repo_root = here.parents[2]
    candidate = repo_root / "build" / "aji_shim" / "libaji_shim.so"
    if candidate.exists():
        return candidate
    raise FileNotFoundError(
        "Could not find libaji_shim.so. Build it with "
        "`make -C ext/aji_shim` or set AJI_SHIM."
    )


def load() -> ctypes.CDLL:
    lib = ctypes.CDLL(str(_find_shim()))
    _bind(lib)
    return lib


_AERR = ctypes.c_int     # AJI_ERROR
_DWORD = ctypes.c_uint32
_HANDLE = ctypes.c_void_p


def _bind(lib: ctypes.CDLL) -> None:
    lib.ajix_get_error_info.restype = ctypes.c_char_p
    lib.ajix_get_error_info.argtypes = []

    lib.ajix_get_hardware.restype = _AERR
    lib.ajix_get_hardware.argtypes = [
        ctypes.POINTER(_DWORD), ctypes.POINTER(_AjixHardware), _DWORD,
    ]

    lib.ajix_find_hardware_by_name.restype = _AERR
    lib.ajix_find_hardware_by_name.argtypes = [
        ctypes.c_char_p, ctypes.POINTER(_AjixHardware), _DWORD,
    ]

    lib.ajix_find_hardware_by_id.restype = _AERR
    lib.ajix_find_hardware_by_id.argtypes = [
        _DWORD, ctypes.POINTER(_AjixHardware), _DWORD,
    ]

    lib.ajix_read_device_chain.restype = _AERR
    lib.ajix_read_device_chain.argtypes = [
        _HANDLE, ctypes.POINTER(_DWORD), ctypes.POINTER(_AjixDevice),
    ]

    lib.ajix_open_device.restype = _AERR
    lib.ajix_open_device.argtypes = [
        _HANDLE, _DWORD, ctypes.POINTER(_HANDLE),
        ctypes.POINTER(_AjiClaimStruct), _DWORD, ctypes.c_char_p,
    ]

    lib.ajix_close_device.restype = _AERR
    lib.ajix_close_device.argtypes = [_HANDLE]

    lib.ajix_lock.restype = _AERR
    lib.ajix_lock.argtypes = [_HANDLE, _DWORD, ctypes.c_int]

    lib.ajix_unlock.restype = _AERR
    lib.ajix_unlock.argtypes = [_HANDLE]

    lib.ajix_lock_chain.restype = _AERR
    lib.ajix_lock_chain.argtypes = [_HANDLE, _DWORD]

    lib.ajix_unlock_chain.restype = _AERR
    lib.ajix_unlock_chain.argtypes = [_HANDLE]

    lib.ajix_unlock_lock.restype = _AERR
    lib.ajix_unlock_lock.argtypes = [_HANDLE, _HANDLE]

    lib.ajix_unlock_chain_lock.restype = _AERR
    lib.ajix_unlock_chain_lock.argtypes = [_HANDLE, _HANDLE, ctypes.c_int]

    lib.ajix_unlock_lock_chain.restype = _AERR
    lib.ajix_unlock_lock_chain.argtypes = [_HANDLE, _HANDLE]

    lib.ajix_flush.restype = _AERR
    lib.ajix_flush.argtypes = [_HANDLE]

    lib.ajix_access_ir_dword.restype = _AERR
    lib.ajix_access_ir_dword.argtypes = [
        _HANDLE, _DWORD, ctypes.POINTER(_DWORD), _DWORD,
    ]

    lib.ajix_access_ir_bits.restype = _AERR
    lib.ajix_access_ir_bits.argtypes = [
        _HANDLE, _DWORD, ctypes.c_char_p, ctypes.c_char_p, _DWORD,
    ]

    lib.ajix_access_dr.restype = _AERR
    lib.ajix_access_dr.argtypes = [
        _HANDLE, _DWORD, _DWORD,
        _DWORD, _DWORD, ctypes.c_char_p,
        _DWORD, _DWORD, ctypes.c_char_p,
    ]

    lib.ajix_access_dr_batch.restype = _AERR
    lib.ajix_access_dr_batch.argtypes = [
        _HANDLE, _DWORD, _DWORD,
        _DWORD, _DWORD, ctypes.c_char_p,
        _DWORD, _DWORD, ctypes.c_char_p,
        _DWORD,
    ]

    lib.ajix_run_test_idle.restype = _AERR
    lib.ajix_run_test_idle.argtypes = [_HANDLE, _DWORD]

    lib.ajix_run_test_idle_flags.restype = _AERR
    lib.ajix_run_test_idle_flags.argtypes = [_HANDLE, _DWORD, _DWORD]

    lib.ajix_test_logic_reset.restype = _AERR
    lib.ajix_test_logic_reset.argtypes = [_HANDLE]

    lib.ajix_delay.restype = _AERR
    lib.ajix_delay.argtypes = [_HANDLE, _DWORD]
