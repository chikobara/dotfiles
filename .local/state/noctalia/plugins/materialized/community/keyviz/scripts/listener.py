#!/usr/bin/env python3
"""
scripts/listener.py - Keyboard Event Listener for Noctalia Keyviz

Reads Linux /dev/input/event* devices using blocking I/O in reader threads,
tracks modifier states, formats Keyviz-style key combinations,
and emits JSON events to stdout for service.luau.
"""

import argparse
import glob
import json
import os
import signal
import struct
import sys
import threading
import time

# Handle termination signals cleanly
signal.signal(signal.SIGTERM, lambda _s, _f: sys.exit(0))
signal.signal(signal.SIGINT, lambda _s, _f: sys.exit(0))

EVENT_FORMAT = "qqHHi"
EVENT_SIZE = struct.calcsize(EVENT_FORMAT)
EV_KEY = 1

KEY_NAMES = {
    1: "Esc",
    2: "1",
    3: "2",
    4: "3",
    5: "4",
    6: "5",
    7: "6",
    8: "7",
    9: "8",
    10: "9",
    11: "0",
    12: "-",
    13: "=",
    14: "Backspace",
    15: "Tab",
    16: "Q",
    17: "W",
    18: "E",
    19: "R",
    20: "T",
    21: "Y",
    22: "U",
    23: "I",
    24: "O",
    25: "P",
    26: "[",
    27: "]",
    28: "Enter",
    29: "Ctrl",
    30: "A",
    31: "S",
    32: "D",
    33: "F",
    34: "G",
    35: "H",
    36: "J",
    37: "K",
    38: "L",
    39: ";",
    40: "'",
    41: "`",
    42: "Shift",
    43: "\\",
    44: "Z",
    45: "X",
    46: "C",
    47: "V",
    48: "B",
    49: "N",
    50: "M",
    51: ",",
    52: ".",
    53: "/",
    54: "Shift",
    55: "KP *",
    56: "Alt",
    57: "Space",
    58: "CapsLock",
    59: "F1",
    60: "F2",
    61: "F3",
    62: "F4",
    63: "F5",
    64: "F6",
    65: "F7",
    66: "F8",
    67: "F9",
    68: "F10",
    69: "NumLock",
    70: "ScrollLock",
    71: "KP 7",
    72: "KP 8",
    73: "KP 9",
    74: "KP -",
    75: "KP 4",
    76: "KP 5",
    77: "KP 6",
    78: "KP +",
    79: "KP 1",
    80: "KP 2",
    81: "KP 3",
    82: "KP 0",
    83: "KP .",
    87: "F11",
    88: "F12",
    96: "KP Enter",
    97: "Ctrl",
    98: "KP /",
    99: "Print",
    100: "Alt",
    102: "Home",
    103: "Up",
    104: "PageUp",
    105: "Left",
    106: "Right",
    107: "End",
    108: "Down",
    109: "PageDown",
    110: "Insert",
    111: "Delete",
    113: "Mute",
    114: "VolDown",
    115: "VolUp",
    116: "Power",
    117: "KP =",
    119: "Pause",
    125: "Super",
    126: "Super",
    127: "Menu",
    128: "Stop",
    183: "F13",
    184: "F14",
    185: "F15",
    186: "F16",
    187: "F17",
    188: "F18",
    189: "F19",
    190: "F20",
    191: "F21",
    192: "F22",
    193: "F23",
    194: "F24",
    210: "Print",
}

MODIFIER_CODES = {
    29: "Ctrl",
    97: "Ctrl",
    42: "Shift",
    54: "Shift",
    56: "Alt",
    100: "Alt",
    125: "Super",
    126: "Super",
}


def _read_ev_bits(dev_path):
    """Read EV capability bitmask from sysfs for a device path."""
    try:
        real = os.path.realpath(dev_path)
        event_name = os.path.basename(real)
        sysfs = f"/sys/class/input/{event_name}/device/capabilities/ev"
        with open(sysfs, "r") as f:
            return int(f.read().strip(), 16)
    except Exception:
        return None


def _is_real_keyboard(dev_path):
    """Return True only for devices that have both EV_KEY (1) and EV_REP (20) capabilities."""
    ev = _read_ev_bits(dev_path)
    if ev is None:
        return True
    EV_KEY_BIT = 1 << 1
    EV_REP_BIT = 1 << 20
    return bool(ev & EV_KEY_BIT) and bool(ev & EV_REP_BIT)


def find_keyboard_devices():
    """Discover real keyboard input event nodes (devices with EV_KEY + EV_REP)."""
    devices = []
    seen = set()

    if os.path.exists("/proc/bus/input/devices"):
        try:
            with open("/proc/bus/input/devices", "r") as f:
                content = f.read()
            for block in content.split("\n\n"):
                is_kbd = False
                event_name = None
                for line in block.splitlines():
                    if (
                        "sysrq" in line.lower()
                        or "kbd" in line.lower()
                        or "EV=120013" in line
                        or "EV=100013" in line
                        or "EV=12001f" in line
                    ):
                        is_kbd = True
                    if line.startswith("H: Handlers="):
                        for part in line.split():
                            if part.startswith("event"):
                                event_name = part
                if is_kbd and event_name:
                    dev_path = f"/dev/input/{event_name}"
                    if dev_path not in seen and _is_real_keyboard(dev_path):
                        devices.append(dev_path)
                        seen.add(dev_path)
        except Exception:
            pass

    for pattern in ["/dev/input/by-id/*kbd*", "/dev/input/by-path/*kbd*"]:
        for path in glob.glob(pattern):
            try:
                target = os.path.realpath(path)
                if target not in seen and _is_real_keyboard(target):
                    devices.append(target)
                    seen.add(target)
            except Exception:
                pass

    if not devices:
        for path in sorted(glob.glob("/dev/input/event*")):
            if path not in seen and _is_real_keyboard(path):
                devices.append(path)
                seen.add(path)

    return devices


def format_combination(modifiers, key_name):
    parts = []
    for mod in ["Super", "Ctrl", "Alt", "Shift"]:
        if mod != key_name and mod in set(modifiers):
            parts.append(mod)
    parts.append(key_name)
    return " + ".join(parts)


def read_device_blocking(fd, dev, q):
    try:
        while True:
            try:
                data = os.read(fd, EVENT_SIZE * 16)
            except OSError:
                break
            if not data:
                break
            q.put(("data", fd, dev, data))
    finally:
        q.put(("closed", fd, dev, b""))


def main():
    parser = argparse.ArgumentParser(description="Noctalia Keyviz Keyboard Listener")
    parser.add_argument("--test-devices", action="store_true", help="List discovered keyboard devices")
    args = parser.parse_args()

    if args.test_devices:
        all_devs = find_keyboard_devices()
        readable = [d for d in all_devs if os.access(d, os.R_OK)]
        print(f"Total discovered keyboard devices: {len(all_devs)}")
        for d in all_devs:
            status = "READABLE" if d in readable else "PERMISSION_DENIED"
            print(f"  {d} -> {status}")
        sys.exit(0)



    import queue

    last_error_time = 0

    while True:
        all_devs = find_keyboard_devices()
        readable_devs = [d for d in all_devs if os.access(d, os.R_OK)]

        if not readable_devs:
            now = time.time()
            if now - last_error_time > 5:
                error_payload = {
                    "type": "error",
                    "error": "permission_denied",
                    "message": "Input permission required: run `sudo usermod -aG input $USER` and re-login.",
                    "devices_found": all_devs,
                    "pid": os.getpid(),
                }
                print(json.dumps(error_payload), flush=True)
                last_error_time = now
            time.sleep(2)
            continue

        fds = {}
        for dev in readable_devs:
            try:
                fd = os.open(dev, os.O_RDONLY)
                fds[fd] = dev
            except Exception:
                pass

        if not fds:
            time.sleep(2)
            continue

        ready_payload = {
            "type": "ready",
            "device_count": len(fds),
            "devices": list(fds.values()),
            "pid": os.getpid(),
        }
        print(json.dumps(ready_payload), flush=True)

        active_modifiers = set()
        dev_queue = queue.SimpleQueue()

        for fd, dev in fds.items():
            t = threading.Thread(
                target=read_device_blocking,
                args=(fd, dev, dev_queue),
                daemon=True,
            )
            t.start()

        open_fds = set(fds.keys())

        try:
            while open_fds:
                try:
                    kind, fd, dev, data = dev_queue.get(timeout=2.0)
                except Exception:
                    continue

                if kind == "closed":
                    open_fds.discard(fd)
                    continue

                offset = 0
                while offset + EVENT_SIZE <= len(data):
                    chunk = data[offset : offset + EVENT_SIZE]
                    offset += EVENT_SIZE
                    tv_sec, tv_usec, ev_type, code, value = struct.unpack(EVENT_FORMAT, chunk)

                    if ev_type != EV_KEY:
                        continue

                    if code in MODIFIER_CODES:
                        mod_name = MODIFIER_CODES[code]
                        if value in (1, 2):
                            active_modifiers.add(mod_name)
                        elif value == 0:
                            active_modifiers.discard(mod_name)
                            out = {
                                "type": "release",
                                "key": mod_name,
                                "code": code,
                                "modifiers": list(active_modifiers),
                            }
                            print(json.dumps(out), flush=True)

                    if value == 1:  # Initial key press
                        key_name = KEY_NAMES.get(code, f"Key_{code}")
                        combo = format_combination(active_modifiers, key_name)
                        mods_list = list(active_modifiers)
                        out = {
                            "type": "press",
                            "key": key_name,
                            "combo": combo,
                            "code": code,
                            "is_modifier": code in MODIFIER_CODES,
                            "modifiers": mods_list,
                            "timestamp": int(time.time() * 1000),
                        }
                        print(json.dumps(out), flush=True)

        except Exception as exc:
            err_out = {
                "type": "error",
                "error": "listener_crashed",
                "message": str(exc) or "Listener loop crashed, restarting.",
            }
            print(json.dumps(err_out), flush=True)
        finally:
            for fd in list(fds.keys()):
                try:
                    os.close(fd)
                except Exception:
                    pass
            fds.clear()
            time.sleep(2)


if __name__ == "__main__":
    main()
