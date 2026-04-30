#!/bin/sh
# Privileged wrapper. The capture-server execs this via NOPASSWD sudo.
# Validates inputs strictly so that even if the server is compromised, the
# only thing the attacker can cause is a tshark capture into a fixed
# directory.
#
# Args:
#   $1 - usbmon interface name (must match usbmon[0-9]{1,2})
#   $2 - output pcap path      (must be absolute, end with .pcap, and live
#                               under PCAP_DIR)
#
# PCAP_DIR is set at install time when you bake this script for your host.
# If you adjust it, also update the sudoers entry to match.

set -eu

PCAP_DIR=/var/lib/usb-blaster-decode
TSHARK=/usr/bin/tshark

iface="$1"
out="$2"

case "$iface" in
    usbmon[0-9]|usbmon[0-9][0-9]) ;;
    *) echo "bad iface: $iface" >&2; exit 2;;
esac

case "$out" in
    "$PCAP_DIR"/*.pcap) ;;
    *) echo "bad output path: $out" >&2; exit 3;;
esac

# tshark itself doesn't traverse the path so a relative '..' would have to
# survive Popen; still, defence in depth.
case "$out" in
    *..*) echo "path traversal blocked" >&2; exit 4;;
esac

exec "$TSHARK" -i "$iface" -w "$out"
