"""AJI error code → Python exception."""

from __future__ import annotations

from enum import IntEnum


class AjiErrorCode(IntEnum):
    NO_ERROR = 0
    FAILURE = 1
    TIMEOUT = 2

    UNKNOWN_HARDWARE = 32
    INVALID_CHAIN_ID = 33
    LOCKED = 34
    NOT_LOCKED = 35
    CHAIN_IN_USE = 36
    NO_DEVICES = 37
    CHAIN_NOT_CONFIGURED = 38
    BAD_TAP_POSITION = 39
    DEVICE_DOESNT_MATCH = 40
    IR_LENGTH_ERROR = 41
    DEVICE_NOT_CONFIGURED = 42
    CHAINS_CLAIMED = 43

    INVALID_OPEN_ID = 44
    INVALID_PARAMETER = 45
    BAD_TAP_STATE = 46
    TOO_MANY_DEVICES = 47
    IR_MULTIPLE = 48
    BAD_SEQUENCE = 49
    INSTRUCTION_CLAIMED = 50
    MODE_NOT_AVAILABLE = 51
    INVALID_DUMMY_BITS = 52

    FILE_ERROR = 80
    NET_DOWN = 81
    SERVER_ERROR = 82
    NO_MEMORY = 83
    BAD_PORT = 84
    PORT_IN_USE = 85
    BAD_HARDWARE = 86
    BAD_JTAG_CHAIN = 87
    SERVER_ACTIVE = 88
    NOT_PERMITTED = 89
    HARDWARE_DISABLED = 90

    HIERARCHICAL_HUB_NOT_SUPPORTED = 125
    UNIMPLEMENTED = 126
    INTERNAL_ERROR = 127

    NO_HUBS = 256
    TOO_MANY_HUBS = 257
    NO_MATCHING_NODES = 258
    TOO_MANY_MATCHING_NODES = 259
    TOO_MANY_HIERARCHIES = 260


class AjiError(RuntimeError):
    """An AJI call returned a non-zero AJI_ERROR. ``code`` is the enum, ``info``
    is the latest server message from ``aji_get_error_info``."""

    def __init__(self, code: int, info: str = "", call: str = "") -> None:
        try:
            self.code = AjiErrorCode(code)
            name = self.code.name
        except ValueError:
            self.code = code  # type: ignore[assignment]
            name = f"AJI_ERROR({code})"
        self.info = info
        self.call = call
        msg = f"{call}: {name}" if call else name
        if info:
            msg = f"{msg}: {info}"
        super().__init__(msg)


def check(code: int, *, call: str, get_info) -> None:
    if code == AjiErrorCode.NO_ERROR:
        return
    info = ""
    try:
        raw = get_info()
        if raw:
            info = raw.decode("utf-8", "replace")
    except Exception:  # pragma: no cover - error_info is best-effort
        pass
    raise AjiError(code, info=info, call=call)
