"""Layer 1: pull blaster OUT/IN byte streams out of a USB pcap file.

This module parses the pcap container format directly (no scapy/pyshark
dependency) and the Linux usbmon header for each record. usbmon has two
encodings on the wire:

    DLT_USB_LINUX           = 220   (48-byte header)
    DLT_USB_LINUX_MMAPPED   = 220 + handled identically below for our
                              purposes; the extra fields we don't read are
                              past the offset we already know

Reference: https://www.kernel.org/doc/Documentation/usb/usbmon.txt and the
libpcap man page for usbmon link types.

Only bulk transfers on the targeted (bus, device) endpoints are aggregated.
Control transfers (FTDI setup) are skipped. The FTDI 2-byte modem-status
header that prefixes every bulk-IN packet is stripped here so layer 2
sees clean blaster bytes.

CAVEAT: This layer has not been validated against a real-hardware capture
yet. The struct offsets are well documented but quirks (URB coalescing,
reorder vs. wall-clock timestamps, isochronous fragments) need to be
checked once we have a `jtagd` trace. Layers 2-4 are validated end-to-end
by the synthesised fixture path; this layer is on its own.
"""

from __future__ import annotations

import struct
from dataclasses import dataclass
from typing import BinaryIO, Iterator, Optional

PCAP_MAGIC_LE = 0xA1B2C3D4
PCAP_MAGIC_BE = 0xD4C3B2A1
PCAP_MAGIC_NS_LE = 0xA1B23C4D  # nanosecond resolution

LINKTYPE_USB_LINUX = 220
LINKTYPE_USB_LINUX_MMAPPED = 220  # historically distinct (189), modern usbmon
                                  # uses 220 with the 64-byte header; we
                                  # autodetect by header length.

# usbmon URB types (urb_type field).
URB_SUBMIT = ord("S")
URB_COMPLETE = ord("C")
URB_ERROR = ord("E")

# Transfer types
XFER_ISO = 0
XFER_INT = 1
XFER_CTRL = 2
XFER_BULK = 3


@dataclass
class UrbRecord:
    ts_sec: int
    ts_usec: int
    urb_type: int      # 'S', 'C', 'E'
    xfer_type: int     # XFER_*
    epnum: int         # endpoint number with direction bit (bit7 = 1 means IN)
    devnum: int
    busnum: int
    data: bytes        # payload bytes captured

    @property
    def is_in(self) -> bool:
        return bool(self.epnum & 0x80)

    @property
    def endpoint(self) -> int:
        return self.epnum & 0x7F


def _read_pcap_header(f: BinaryIO) -> tuple[str, int]:
    """Return (endian, linktype). Raise on bad magic."""
    magic_bytes = f.read(4)
    if len(magic_bytes) != 4:
        raise ValueError("pcap: file too short for global header")
    (magic,) = struct.unpack("<I", magic_bytes)
    if magic == PCAP_MAGIC_LE or magic == PCAP_MAGIC_NS_LE:
        endian = "<"
    elif magic == PCAP_MAGIC_BE:
        endian = ">"
    else:
        raise ValueError(f"pcap: unrecognised magic 0x{magic:08x}")
    rest = f.read(20)
    if len(rest) != 20:
        raise ValueError("pcap: truncated global header")
    _vmaj, _vmin, _thiszone, _sigfigs, _snaplen, linktype = struct.unpack(
        endian + "HHiIII", rest
    )
    return endian, linktype


def _iter_records(
    f: BinaryIO, endian: str
) -> Iterator[tuple[int, int, bytes]]:
    """Yield (ts_sec, ts_usec, payload) per record."""
    rec_hdr = struct.Struct(endian + "IIII")
    while True:
        hdr = f.read(rec_hdr.size)
        if not hdr:
            return
        if len(hdr) != rec_hdr.size:
            raise ValueError("pcap: truncated record header")
        ts_sec, ts_usec, incl_len, _orig_len = rec_hdr.unpack(hdr)
        payload = f.read(incl_len)
        if len(payload) != incl_len:
            raise ValueError("pcap: truncated record body")
        yield ts_sec, ts_usec, payload


# usbmon "s" header (legacy 48-byte):
#   q  id
#   B  urb_type
#   B  xfer_type
#   B  epnum
#   B  devnum
#   H  busnum
#   B  flag_setup
#   B  flag_data
#   q  ts_sec
#   i  ts_usec
#   i  status
#   I  length             (length of urb data, may be > captured)
#   I  len_cap            (captured data length)
#   8s setup or iso
# 64-byte mmapped header adds: interval, start_frame, xfer_flags, ndesc.
_USBMON_HDR_S = struct.Struct("<QBBBBHBBQiiII8s")
_USBMON_HDR_MMAP_TAIL = struct.Struct("<iiII")


def _parse_usbmon(payload: bytes) -> Optional[UrbRecord]:
    if len(payload) < _USBMON_HDR_S.size:
        return None
    (
        _id,
        urb_type,
        xfer_type,
        epnum,
        devnum,
        busnum,
        _flag_setup,
        _flag_data,
        _ts_sec,
        _ts_usec,
        _status,
        _length,
        len_cap,
        _setup,
    ) = _USBMON_HDR_S.unpack_from(payload, 0)
    body_off = _USBMON_HDR_S.size
    # The mmapped variant tacks 16 more bytes on; if we appear to have
    # them and len_cap fits the remaining body, prefer that interpretation.
    if len(payload) >= body_off + _USBMON_HDR_MMAP_TAIL.size + len_cap:
        if len(payload) - (body_off + _USBMON_HDR_MMAP_TAIL.size) >= len_cap:
            body_off += _USBMON_HDR_MMAP_TAIL.size
    body = payload[body_off : body_off + len_cap]
    return UrbRecord(
        ts_sec=_ts_sec,
        ts_usec=_ts_usec,
        urb_type=urb_type,
        xfer_type=xfer_type,
        epnum=epnum,
        devnum=devnum,
        busnum=busnum,
        data=body,
    )


def _strip_ftdi_status(chunk: bytes, *, max_packet: int = 64) -> bytes:
    """Drop the 2-byte FT245 modem-status header from each USB packet slice."""
    out = bytearray()
    for i in range(0, len(chunk), max_packet):
        slice_ = chunk[i : i + max_packet]
        if len(slice_) >= 2:
            out += slice_[2:]
    return bytes(out)


@dataclass
class ExtractedStreams:
    out_bytes: bytes
    in_bytes: bytes
    bus: int
    device: int
    out_endpoint: int
    in_endpoint: int


def extract_streams(
    path: str,
    *,
    bus: Optional[int] = None,
    device: Optional[int] = None,
    out_endpoint: Optional[int] = None,
    in_endpoint: Optional[int] = None,
    ftdi_max_packet: int = 64,
) -> ExtractedStreams:
    """Read ``path`` and return concatenated OUT and IN byte streams.

    If ``bus``/``device`` are not specified, the first bulk endpoint
    address seen wins and subsequent packets to other devices are ignored;
    this is enough for traces with a single blaster on the bus.
    """
    out_chunks: list[bytes] = []
    in_chunks: list[bytes] = []
    chosen_bus = bus
    chosen_dev = device
    chosen_out_ep = out_endpoint
    chosen_in_ep = in_endpoint

    with open(path, "rb") as f:
        endian, linktype = _read_pcap_header(f)
        if linktype not in (LINKTYPE_USB_LINUX, LINKTYPE_USB_LINUX_MMAPPED):
            raise ValueError(
                f"pcap linktype {linktype} not supported; need usbmon (220)"
            )
        for _ts_s, _ts_us, payload in _iter_records(f, endian):
            urb = _parse_usbmon(payload)
            if urb is None or urb.xfer_type != XFER_BULK:
                continue
            if urb.urb_type == URB_ERROR:
                continue
            if chosen_bus is None:
                chosen_bus = urb.busnum
            if chosen_dev is None:
                chosen_dev = urb.devnum
            if urb.busnum != chosen_bus or urb.devnum != chosen_dev:
                continue
            ep = urb.endpoint
            if urb.is_in:
                # IN data arrives on the COMPLETE record (urb_type == 'C').
                if urb.urb_type != URB_COMPLETE or not urb.data:
                    continue
                if chosen_in_ep is None:
                    chosen_in_ep = ep
                if ep != chosen_in_ep:
                    continue
                in_chunks.append(
                    _strip_ftdi_status(urb.data, max_packet=ftdi_max_packet)
                )
            else:
                # OUT data is in the SUBMIT record.
                if urb.urb_type != URB_SUBMIT or not urb.data:
                    continue
                if chosen_out_ep is None:
                    chosen_out_ep = ep
                if ep != chosen_out_ep:
                    continue
                out_chunks.append(urb.data)
    return ExtractedStreams(
        out_bytes=b"".join(out_chunks),
        in_bytes=b"".join(in_chunks),
        bus=chosen_bus or 0,
        device=chosen_dev or 0,
        out_endpoint=chosen_out_ep or 0,
        in_endpoint=chosen_in_ep or 0,
    )
