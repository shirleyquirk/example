# Capture server — host-side setup

The decoder's hardware-backed tests need to capture USB traffic while
issuing AJI commands. Capturing usbmon needs root, but the test process
runs in a bwrap sandbox with no privileges. The pattern here is the same
one the rest of the tooling uses: a small server runs **outside** the
sandbox with NOPASSWD sudo for one specific command, and the test
process **inside** the sandbox talks to it over a unix socket.

The trust boundary lives at the wrapper script `usb-blaster-capture.sh`.
The server is a JSON dispatcher; the wrapper is the only thing that ever
runs as root and it accepts only validated arguments.

## One-time host setup

You'll do this on the lab box, once.

### 1. Pick the directories

```sh
sudo mkdir -p /var/lib/usb-blaster-decode   # pcaps land here
sudo mkdir -p /run/usb-blaster-decode       # the unix socket lives here
```

`/var/lib/usb-blaster-decode` should be world-readable (the bwrap config
will bind-mount it read-only into the sandbox). `/run/usb-blaster-decode`
needs to be writable by both the server's user and (read/write) the
sandbox.

### 2. Install the privileged wrapper

```sh
sudo install -m 0755 tools/capture-server/usb-blaster-capture.sh \
    /usr/local/bin/usb-blaster-capture.sh
```

Check the `PCAP_DIR` line at the top of the installed copy matches the
directory you created. The wrapper rejects any output path that doesn't
live under that directory.

### 3. Allow your user to run it without a password

In `/etc/sudoers.d/usb-blaster-capture` (use `visudo -f` so the syntax
gets validated):

```
youruser ALL=(root) NOPASSWD: /usr/local/bin/usb-blaster-capture.sh usbmon[0-9] /var/lib/usb-blaster-decode/*.pcap
youruser ALL=(root) NOPASSWD: /usr/local/bin/usb-blaster-capture.sh usbmon[0-9][0-9] /var/lib/usb-blaster-decode/*.pcap
```

Two lines because sudoers wildcards aren't full regexes; `usbmon[0-9]`
matches `usbmon0..9` and `usbmon[0-9][0-9]` matches `usbmon10..99`. If
you want to lock down further, replace with literal interface names, e.g.
`usbmon0`.

### 4. Make sure the usbmon kernel module is loaded

```sh
sudo modprobe usbmon
ls /sys/kernel/debug/usb/usbmon         # should list 0u, 0t, 1u, 1t, ...
```

The number after `usbmon` corresponds to the USB bus the blaster is on.
`lsusb -t` will tell you.

### 5. Start the server

```sh
tools/capture-server/capture-server.py \
    --socket /run/usb-blaster-decode/capture.sock \
    --pcap-dir /var/lib/usb-blaster-decode \
    --capture-cmd /usr/local/bin/usb-blaster-capture.sh \
    --iface usbmon0
```

You can repeat `--iface` to allowlist multiple buses. The server prints
its allowlist on startup so you can sanity-check.

A systemd unit for this is one obvious next step; for now, `tmux` or
`screen` is fine. The server is stateful only in the sense that it
remembers active captures, so if you restart it, in-flight captures lose
their stop endpoint (the tshark process keeps running and you'd have to
`pkill tshark` by hand).

## Bwrap mounts the test environment needs

When you spawn the bubble for testing, add:

```
--bind-try /run/usb-blaster-decode  /run/usb-blaster-decode
--ro-bind /var/lib/usb-blaster-decode /var/lib/usb-blaster-decode
```

Then inside the sandbox the tests look at the env vars set in
`tests/hw/conftest.py`:

```sh
export USB_BLASTER_HW=1
export USB_BLASTER_CABLE="USB-Blaster on local host"   # optional if only one
export USB_BLASTER_USBMON=usbmon0
export USB_BLASTER_CAPTURE_SOCK=/run/usb-blaster-decode/capture.sock
pytest tests/hw -x -v
```

`USB_BLASTER_HW=1` alone runs the wrapper smoke tests
(`tests/hw/test_aji_smoke.py`); add `USB_BLASTER_CAPTURE_SOCK` to also
run the round-trip tests (`tests/hw/test_round_trip.py`).

## Threat model / what the server can and can't do

- **Can:** start `tshark` capturing on a pre-allowlisted usbmon
  interface, writing to a path under the pre-allowlisted pcap directory.
  Nothing else.
- **Can't:** read, write, or delete arbitrary files; run arbitrary
  commands; bind a TCP port; capture on non-usbmon interfaces; pass
  arbitrary flags to tshark.
- **Trust:** the unix socket permission (0660 by default) decides who
  can talk to the server. If you put the socket somewhere group-writable
  and sandbox processes you don't trust into the same group, they can
  drive captures. Don't.

If you want to tighten further, replace the `usbmon[0-9]` patterns in
sudoers with literal interface names, and replace the `*.pcap` glob with
a fixed filename pattern that includes a process-specific salt the
server signs with HMAC. For our use that's overkill.
