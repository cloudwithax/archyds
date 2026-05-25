#!/usr/bin/env python3
"""
RG DS Button Mapper -- Guided Mode
====================================
Walks through each physical button one at a time and captures what evdev
event/code fires.  Produces a final mapping table at the end.

Run with:
    sudo python3 rgds-button-detective.py

No dependencies beyond Python 3 stdlib.
"""

import struct
import os
import select
import sys
import time
from pathlib import Path

# ---- event struct ----
INPUT_EVENT_FMT = 'llHHi'
INPUT_EVENT_SZ = struct.calcsize(INPUT_EVENT_FMT)
EV_KEY = 0x01
EV_ABS = 0x03

# ---- helpers ----

def get_device_name(devname):
    base = Path('/sys/class/input') / devname
    for p in [base / 'device' / 'name', base / 'name']:
        if p.exists():
            return p.read_text().strip()
    return None


def scan_devices():
    """Return {name: path} for gamepad & direct-keys devices."""
    found = {}
    for ev in sorted(Path('/dev/input').glob('event*')):
        name = get_device_name(ev.name)
        if name and ('ANBERNIC' in name or 'rk3568' in name or 'keys' in name):
            found[str(ev)] = name
    return found


def open_device(path):
    """Open device in non-blocking mode.  Returns fd or None."""
    try:
        return os.open(path, os.O_RDONLY | os.O_NONBLOCK)
    except PermissionError:
        print(f"  [!] Permission denied: {path}  (need root)")
        return None
    except OSError as e:
        print(f"  [!] Cannot open {path}: {e}")
        return None


# ---- guided capture ----

def wait_for_press(fds, timeout=60):
    """
    Poll across all fds for an EV_KEY press (value==1).
    Returns (event_path, code, raw_value) or None on timeout.
    Also captures ABS events in the background and returns them in a list.
    """
    poll = select.poll()
    for fd in fds:
        poll.register(fd, select.POLLIN)

    start = time.monotonic()
    abs_events = []

    while time.monotonic() - start < timeout:
        ready = poll.poll(200)
        if not ready:
            continue

        for fd, _ in ready:
            try:
                data = os.read(fd, INPUT_EVENT_SZ * 16)
            except OSError:
                continue

            for i in range(0, len(data), INPUT_EVENT_SZ):
                chunk = data[i:i + INPUT_EVENT_SZ]
                if len(chunk) < INPUT_EVENT_SZ:
                    break
                sec, usec, evtype, code, value = struct.unpack(INPUT_EVENT_FMT, chunk)

                if evtype == EV_KEY and value == 1:
                    path = fds[fd]
                    return path, code, value, abs_events

                if evtype == EV_ABS:
                    abs_events.append((evtype, code, value))

        # Also grab pending ABS from other fds
        for fd2 in fds:
            try:
                data2 = os.read(fd2, INPUT_EVENT_SZ * 4)
                for i in range(0, len(data2), INPUT_EVENT_SZ):
                    chunk = data2[i:i + INPUT_EVENT_SZ]
                    if len(chunk) < INPUT_EVENT_SZ:
                        break
                    sec, usec, evtype, code, value = struct.unpack(INPUT_EVENT_FMT, chunk)
                    if evtype == EV_ABS:
                        abs_events.append((evtype, code, value))
            except (OSError, BlockingIOError):
                pass

    return None, None, None, abs_events


def wait_for_release(fds, expected_code, timeout=10):
    """Wait for the same key to be released (value==0)."""
    poll = select.poll()
    for fd in fds:
        poll.register(fd, select.POLLIN)

    start = time.monotonic()
    while time.monotonic() - start < timeout:
        ready = poll.poll(200)
        if not ready:
            continue
        for fd, _ in ready:
            try:
                data = os.read(fd, INPUT_EVENT_SZ * 8)
            except OSError:
                continue
            for i in range(0, len(data), INPUT_EVENT_SZ):
                chunk = data[i:i + INPUT_EVENT_SZ]
                if len(chunk) < INPUT_EVENT_SZ:
                    break
                sec, usec, evtype, code, value = struct.unpack(INPUT_EVENT_FMT, chunk)
                if evtype == EV_KEY and code == expected_code and value == 0:
                    return True
    return False


# ---- Button definitions ----
# Each entry: (label, hints_for_display)
# We capture whatever code fires — we don't pre-guess the code.

GAMEPAD_BUTTONS = [
    ("A (south face, bottom)",
     "Press the physical A button (bottom face button)"),
    ("B (east face, right)",
     "Press the physical B button (right face button)"),
    ("Y (west face, left)",
     "Press the physical Y button (left face button)"),
    ("X (north face, top)",
     "Press the physical X button (top face button)"),
    ("L1 (left shoulder)",
     "Press the L1 / left shoulder button"),
    ("R1 (right shoulder)",
     "Press the R1 / right shoulder button"),
    ("L2 (left trigger)",
     "Press the L2 / left trigger"),
    ("R2 (right trigger)",
     "Press the R2 / right trigger"),
    ("Select / Minus",
     "Press the Select / Minus button"),
    ("Start / Plus",
     "Press the Start / Plus button"),
    ("Anbernic / Mode (center, left side)",
     "Press the Anbernic button (center-left, launches stock launcher)"),
    ("L3 (left stick click)",
     "Push down on the LEFT analog stick until it clicks"),
    ("R3 (right stick click)",
     "Push down on the RIGHT analog stick until it clicks"),
]

D_PAD_STEPS = [
    "Up",
    "Down",
    "Left",
    "Right",
]

STICK_TESTS = [
    # (label, prompt, all_axis_codes_for_this_stick)
    # Left stick: axis 2 (X), axis 3 (Y)
    ("Left Stick", "Move the LEFT stick: LEFT, then UP, then RIGHT, then DOWN — hold each for ~2s",
     [2, 3]),
    # Right stick: axis 4 (X), axis 5 (Y)
    ("Right Stick", "Move the RIGHT stick: LEFT, then UP, then RIGHT, then DOWN — hold each for ~2s",
     [4, 5]),
]

DIRECT_BUTTONS = [
    ("Home / Back", "Press the HOME / BACK button (short press = back, long press = home)"),
    ("Volume Up", "Press VOLUME UP"),
    ("Volume Down", "Press VOLUME DOWN"),
]

KEY_NAMES = {
    # Face buttons
    304: "BTN_SOUTH (A)",
    305: "BTN_EAST (B)",
    306: "BTN_C (Y)",
    307: "BTN_NORTH (X)",
    # Shoulders
    308: "BTN_WEST (L1)",
    309: "BTN_TR (R1)",
    # Select / Start
    310: "BTN_TL (Select)",
    311: "BTN_TR (Start)",
    # Mode (Anbernic launcher button, left side)
    312: "BTN_MODE (Anbernic)",
    # Triggers
    313: "BTN_THUMBL (L3)",
    314: "BTN_TL2 (L2)",
    315: "BTN_TR2 (R2)",
    316: "BTN_THUMBR (R3)",
    # D-Pad (EV_KEY, unused — D-Pad is ABS_HAT0X/Y)
    544: "BTN_DPAD_UP", 545: "BTN_DPAD_DOWN", 546: "BTN_DPAD_LEFT", 547: "BTN_DPAD_RIGHT",
    # Direct/function keys (adc-keys)
    114: "KEY_VOLUMEDOWN", 115: "KEY_VOLUMEUP", 116: "KEY_POWER",
    158: "KEY_BACK (Home/Back)",
    139: "KEY_MENU", 102: "KEY_HOME",
}

ABS_NAMES = {0: "ABS_X", 1: "ABS_Y", 2: "ABS_Z", 3: "ABS_RX",
             4: "ABS_RY", 5: "ABS_RZ",
             16: "ABS_HAT0X", 17: "ABS_HAT0Y"}


def run_step(step_num, total, label, prompt, fds, results):
    """Run a single guided button-press step."""
    print()
    print(f"  >>> Step {step_num}/{total}: {label}")
    print(f"      {prompt}")
    print(f"      (waiting for button press...)")

    path, code, value, abs_events = wait_for_press(fds)
    if path is None:
        print(f"  [!] Timed out waiting for press.  Skipping.")
        return

    dev_name = DEVICE_NAMES.get(path, path)
    key_name = KEY_NAMES.get(code, f"UNKNOWN_KEY_{code}")
    print(f"  [+] Captured!  {dev_name}:  code={code}  ({key_name})")
    print(f"      Now release the button.")

    results.append((label, dev_name, code, key_name))

    released = wait_for_release(fds, code)
    if released:
        print(f"  [+] Release detected.")
    else:
        print(f"  [-] Release not detected (timed out).  Continuing anyway.")


def run_stick_test(step_num, total, label, prompt, fds, stick_codes, results):
    """Capture ABS axis values for an entire stick in one step.

    Records all ABS events on the stick's axes for a fixed window, then
    reports the peak value per axis.  The user moves the stick to all 4
    directions during the window.
    """
    # Drain any stale events first
    for fd in fds:
        try:
            while True:
                d = os.read(fd, INPUT_EVENT_SZ * 4)
                if not d:
                    break
        except (OSError, BlockingIOError):
            pass

    print()
    print(f"  >>> Step {step_num}/{total}: {label}")
    print(f"      {prompt}")

    # Determine which device actually produces ABS events
    abs_dev_fd = None
    abs_dev_path = None
    for fd, path in fds.items():
        try:
            import fcntl
            buf = bytearray(24)
            EVIOCGABS0 = 0x80084540
            fcntl.ioctl(fd, EVIOCGABS0, buf)
            abs_dev_fd = fd
            abs_dev_path = path
            break
        except:
            pass

    if abs_dev_fd is None:
        abs_dev_fd = next(iter(fds))
        abs_dev_path = fds[abs_dev_fd]

    dev_name = DEVICE_NAMES.get(abs_dev_path, abs_dev_path)
    print(f"      Listening on {dev_name}...")

    STICK_THRESHOLD = 1500
    COLLECT_SEC = 10

    peak = {}  # code -> signed peak value

    print(f"      Move the stick through ALL 4 directions (you have {COLLECT_SEC}s)")
    start = time.monotonic()
    while time.monotonic() - start < COLLECT_SEC:
        try:
            data = os.read(abs_dev_fd, INPUT_EVENT_SZ * 32)
        except (OSError, BlockingIOError):
            time.sleep(0.05)
            continue
        for i in range(0, len(data), INPUT_EVENT_SZ):
            chunk = data[i:i + INPUT_EVENT_SZ]
            if len(chunk) < INPUT_EVENT_SZ:
                break
            sec, usec, evtype, code, value = struct.unpack(INPUT_EVENT_FMT, chunk)
            if evtype == EV_ABS and code in stick_codes:
                if code not in peak or abs(value) > abs(peak[code]):
                    peak[code] = value

    recorded = {c: v for c, v in peak.items() if abs(v) >= STICK_THRESHOLD}

    if recorded:
        for code, value in recorded.items():
            results.append((f"{label} ({ABS_NAMES.get(code, f'ABS_{code}')})",
                          dev_name,
                          code, f"{ABS_NAMES.get(code, f'ABS_{code}')} = {value}"))
        print(f"  [+] Captured: " + ", ".join(
            f"{ABS_NAMES.get(c, f'ABS_{c}')}={v}" for c, v in recorded.items()))
    else:
        print(f"  [!] No axis movement above threshold {STICK_THRESHOLD}.  Skipping.")


def run_dpad_step(step_num, total, direction_label, fds, results):
    """Capture D-Pad direction.  Watches both EV_KEY (BTN_DPAD_*) and
    EV_ABS (ABS_HAT0X/ABS_HAT0Y)."""
    print()
    print(f"  >>> Step {step_num}/{total}: D-Pad {direction_label}")
    print(f"      Press D-Pad {direction_label.upper()}")
    print(f"      (waiting for D-Pad input...)")

    poll = select.poll()
    for fd in fds:
        poll.register(fd, select.POLLIN)

    start = time.monotonic()
    while time.monotonic() - start < 30:
        ready = poll.poll(300)
        if not ready:
            continue
        for fd, _ in ready:
            try:
                data = os.read(fd, INPUT_EVENT_SZ * 8)
            except OSError:
                continue
            for i in range(0, len(data), INPUT_EVENT_SZ):
                chunk = data[i:i + INPUT_EVENT_SZ]
                if len(chunk) < INPUT_EVENT_SZ:
                    break
                sec, usec, evtype, code, value = struct.unpack(INPUT_EVENT_FMT, chunk)

                if evtype == EV_KEY and value == 1 and code in (544, 545, 546, 547):
                    path = fds[fd]
                    dev_name = DEVICE_NAMES.get(path, path)
                    kname = KEY_NAMES.get(code, f"BTN_DPAD_{code}")
                    print(f"  [+] Captured as EV_KEY:  {dev_name}:  code={code}  ({kname})")
                    results.append((f"D-Pad {direction_label}", dev_name, code, kname))
                    return

                if evtype == EV_ABS and code in (16, 17):
                    # ABS_HAT0X (16) = -1 left, +1 right
                    # ABS_HAT0Y (17) = -1 up, +1 down
                    dir_map = {16: { -1: "LEFT", 1: "RIGHT" },
                               17: { -1: "UP",   1: "DOWN"  }}
                    expected = dir_map.get(code, {}).get(value)
                    # direction_label is like "D-Pad Up"; extract just the direction word
                    dir_word = direction_label.split()[-1].upper()
                    if expected and expected.upper() == dir_word:
                        path = fds[fd]
                        dev_name = DEVICE_NAMES.get(path, path)
                        aname = ABS_NAMES.get(code, f"ABS_{code}")
                        print(f"  [+] Captured as EV_ABS:  {dev_name}:  code={code}  ({aname} = {value})")
                        results.append((f"D-Pad {direction_label}", dev_name, code, f"{aname} = {value}"))
                        return
                    # If value is non-zero but wrong direction, inform
                    if abs(value) > 0:
                        got = dir_map.get(code, {}).get(value, f"?")
                        if got:
                            print(f"      (got D-Pad {got} instead of {direction_label}.  Trying again...)")

    print(f"  [!] Timed out waiting for D-Pad {direction_label}.  Skipping.")


LOG_FILE = "/home/alarm/button-map.txt"


def print_summary(gamepad_results, dpad_results, stick_results, direct_results, devices):
    """Print the final mapping table and save to log file."""
    lines = []
    def out(s=""):
        print(s)
        lines.append(s)

    out()
    out("=" * 72)
    out("  RG DS BUTTON MAPPING SUMMARY")
    out("=" * 72)

    out()
    out("  Devices:")
    for path, name in sorted(devices.items(), key=lambda x: x[0]):
        out(f"    {path}  ->  {name}")
    out()

    if gamepad_results:
        out("  +== Gamepad ==+")
        out(f"  {'Button':30s}  {'Device':20s}  {'Code':6s}  {'Name'}")
        out("  " + "-" * 68)
        for label, dev, code, kname in gamepad_results:
            out(f"  {label:30s}  {dev:20s}  {code:3d}    {kname}")
        out()

    if dpad_results:
        out("  +== D-Pad ==+")
        out(f"  {'Direction':30s}  {'Device':20s}  {'Code':6s}  {'Name'}")
        out("  " + "-" * 68)
        for label, dev, code, kname in dpad_results:
            out(f"  {label:30s}  {dev:20s}  {code:3d}    {kname}")
        out()

    if stick_results:
        out("  +== Analog Sticks ==+")
        out(f"  {'Direction':30s}  {'Device':20s}  {'Code':6s}  {'Value'}")
        out("  " + "-" * 68)
        for label, dev, code, desc in stick_results:
            out(f"  {label:30s}  {dev:20s}  {code:3d}    {desc}")
        out()

    if direct_results:
        out("  +== System / Function Keys ==+")
        out(f"  {'Button':30s}  {'Device':20s}  {'Code':6s}  {'Name'}")
        out("  " + "-" * 68)
        for label, dev, code, kname in direct_results:
            out(f"  {label:30s}  {dev:20s}  {code:3d}    {kname}")
        out()

    out()
    out("  Done!  Use the codes above to configure rgds-padmouse.py.")
    out()

    # Write to log file
    try:
        with open(LOG_FILE, "w") as f:
            f.write("\n".join(lines))
        print(f"\n  [*] Summary saved to {LOG_FILE}")
    except OSError as e:
        print(f"\n  [!] Could not write log file: {e}")


# ---- main ----

if __name__ == "__main__":
    print()
    print("  ╔══════════════════════════════════════════════════════════╗")
    print("  ║       RG DS Button Mapper  —  Guided Mode               ║")
    print("  ╚══════════════════════════════════════════════════════════╝")
    print()

    devices = scan_devices()
    if not devices:
        print("  [!] No ANBERNIC-rk3568-keys or direct-keys devices found.")
        print("      Make sure you're running as root (sudo).")
        sys.exit(1)

    print("  Found devices:")
    for path, name in sorted(devices.items(), key=lambda x: x[0]):
        print(f"    {path}  →  {name}")
    print()

    # Open all target devices
    fds = {}  # fd -> path
    for path in sorted(devices.keys()):
        fd = open_device(path)
        if fd is not None:
            fds[fd] = path

    DEVICE_NAMES = devices

    if not fds:
        print("  [!] Could not open any input devices (need root).")
        sys.exit(1)

    total_steps = len(GAMEPAD_BUTTONS) + len(D_PAD_STEPS) + len(STICK_TESTS) + len(DIRECT_BUTTONS)
    step = 0

    gamepad_results = []
    dpad_results = []
    stick_results = []
    direct_results = []

    print("  ────────────────────────────────────────────────────────")
    print("  GAMEPAD BUTTONS")
    print("  ────────────────────────────────────────────────────────")
    print("  I'll ask you to press each button one at a time.")
    print("  Press the requested button when prompted.")
    print()

    for label, prompt in GAMEPAD_BUTTONS:
        step += 1
        run_step(step, total_steps, label, prompt, fds, gamepad_results)

    print()
    print("  ────────────────────────────────────────────────────────")
    print("  D-PAD")
    print("  ────────────────────────────────────────────────────────")
    print("  The D-Pad may use EV_KEY (BTN_DPAD_*) or EV_ABS (HAT axes).")
    print("  I'll watch for both.  Press the indicated direction.")
    print()

    for direction in D_PAD_STEPS:
        step += 1
        run_dpad_step(step, total_steps, direction, fds, dpad_results)

    print()
    print("  ────────────────────────────────────────────────────────")
    print("  ANALOG STICKS")
    print("  ────────────────────────────────────────────────────────")
    print("  Now I'll capture the stick axis codes.")
    print("  Move the stick in the requested direction and hold it.")
    print()

    for label, prompt, stick_codes in STICK_TESTS:
        step += 1
        run_stick_test(step, total_steps, label, prompt, fds,
                       stick_codes, stick_results)

    print()
    print("  ────────────────────────────────────────────────────────")
    print("  DIRECT / FUNCTION KEYS")
    print("  ────────────────────────────────────────────────────────")
    print("  These are the physical Home, Menu, Back, Volume, Power keys.")
    print()

    for label, prompt in DIRECT_BUTTONS:
        step += 1
        run_step(step, total_steps, label, prompt, fds, direct_results)

    # Close devices
    for fd in fds:
        os.close(fd)

    print_summary(gamepad_results, dpad_results, stick_results, direct_results, devices)

    input("\n  Press Enter to close this window...")
