#!/usr/bin/env python3
"""
RGDS gamepad-to-pointer daemon.

Translates events from /dev/input/event4 (ANBERNIC-rk3568-keys) and
/dev/input/event3 (adc-keys) into a virtual mouse + keyboard via /dev/uinput.

Verified button mapping (2026-05-25):
  Face buttons (ANBERNIC event4):
    A (south)       304  BTN_SOUTH   → BTN_LEFT (left click)
    B (east)        305  BTN_EAST    → BTN_RIGHT (right click)
    Y (west)        306  BTN_C       → KEY_BACKSPACE
    X (north)       307  BTN_NORTH   → KEY_ENTER
    L1              308  BTN_WEST    → KEY_PAGEUP
    R1              309  BTN_TR      → KEY_PAGEDOWN
    Select          310  BTN_TL      → KEY_ESC
    Start           311  BTN_TR      → KEY_LEFTMETA (Super / KRunner)
    Anbernic/Mode   312  BTN_MODE    → KEY_LEFTCTRL
    L3 (stick click) 313 BTN_THUMBL  → BTN_RIGHT (right click)
    L2              314  BTN_TL2     → KEY_LEFTALT
    R2              315  BTN_TR2     → KEY_TAB
    R3 (stick click) 316 BTN_THUMBR  → BTN_LEFT (left click)

  D-Pad (ANBERNIC event4, ABS_HAT0X/Y):
    → arrow keys (UP/DOWN/LEFT/RIGHT)

  Left analog stick (ANBERNIC event4):
    ABS_Z  (code 2) → mouse REL_X
    ABS_RX (code 3) → mouse REL_Y

  Right analog stick (ANBERNIC event4):
    ABS_RY (code 4) → REL_WHEEL (vertical scroll)
    ABS_RZ (code 5) → REL_HWHEEL (horizontal scroll)

  System keys (adc-keys event3):
    Home/Back  158  → KEY_BACK (short) / KEY_HOME (long — handled by OS)
    Volume Up  115  → passthrough
    Volume Down 114 → passthrough
"""

from __future__ import annotations

import ctypes
import errno
import fcntl
import os
import select
import struct
import sys
import time

GAMEPAD_DEV = "/dev/input/event4"
ADC_KEYS_DEV = "/dev/input/event3"
UINPUT_DEV = "/dev/uinput"
TICK_HZ = 60
LOG_PATH = "/var/log/rgds-padmouse.log"

EV_STRUCT = struct.Struct("@llHHi")
assert EV_STRUCT.size == 24

EV_SYN = 0x00
EV_KEY = 0x01
EV_REL = 0x02
EV_ABS = 0x03

REL_X = 0x00
REL_Y = 0x01
REL_HWHEEL = 0x06
REL_WHEEL = 0x08

BTN_LEFT = 0x110
BTN_RIGHT = 0x111
KEY_ESC = 1
KEY_TAB = 15
KEY_ENTER = 28
KEY_LEFTCTRL = 29
KEY_LEFTALT = 56
KEY_LEFTMETA = 125
KEY_BACKSPACE = 14
KEY_UP = 103
KEY_LEFT = 105
KEY_RIGHT = 106
KEY_DOWN = 108
KEY_HOME = 102
KEY_PAGEUP = 104
KEY_PAGEDOWN = 109
KEY_VOLUMEUP = 115
KEY_VOLUMEDOWN = 114
KEY_BACK = 158  # Home/Back button on adc-keys

# ABS axis codes (verified on device)
ABS_Z = 0x02      # Left stick X
ABS_RX = 0x03     # Left stick Y
ABS_RY = 0x04     # Right stick X
ABS_RZ = 0x05     # Right stick Y
ABS_HAT0X = 0x10
ABS_HAT0Y = 0x11

# Source button codes from ANBERNIC (verified)
SRC_A = 0x130         # BTN_SOUTH
SRC_B = 0x131         # BTN_EAST
SRC_Y = 0x132         # BTN_C
SRC_X = 0x133         # BTN_NORTH
SRC_L1 = 0x134        # BTN_WEST
SRC_R1 = 0x135        # BTN_TR (second, shared with Start)
SRC_SELECT = 0x13a    # BTN_TL
SRC_START = 0x13b     # BTN_TR
SRC_MODE = 0x13c      # BTN_MODE (Anbernic button)
SRC_L3 = 0x13d        # BTN_THUMBL — wait, 313 = 0x139
# Let me use decimal to avoid hex confusion:
# 304=0x130  305=0x131  306=0x132  307=0x133
# 308=0x134  309=0x135  310=0x136  311=0x137
# 312=0x138  313=0x139  314=0x13a  315=0x13b  316=0x13c

# Mapping: source code -> (output_type, output_code)
# type 'k' = keyboard key, 'm' = mouse button
KEY_MAP = {
    304: ("m", BTN_LEFT),        # A → left click
    305: ("m", BTN_RIGHT),       # B → right click
    306: ("k", KEY_BACKSPACE),   # Y → backspace
    307: ("k", KEY_ENTER),       # X → enter
    308: ("k", KEY_PAGEUP),      # L1 → pageup
    309: ("k", KEY_PAGEDOWN),    # R1 → pagedown
    310: ("k", KEY_ESC),         # Select → esc
    311: ("k", KEY_LEFTMETA),    # Start → super/krunner
    312: ("k", KEY_LEFTCTRL),    # Anbernic → left ctrl
    313: ("m", BTN_RIGHT),       # L3 → right click
    314: ("k", KEY_LEFTALT),     # L2 → alt
    315: ("k", KEY_TAB),         # R2 → tab
    316: ("m", BTN_LEFT),        # R3 → left click
    # adc-keys passthrough
    114: ("k", KEY_VOLUMEDOWN),
    115: ("k", KEY_VOLUMEUP),
    158: ("k", KEY_BACK),         # Home/Back
}

ABS_MAX = 4096
DEADBAND = 384
POINTER_MAX_PX = 18
SCROLL_MAX = 1


# --- uinput setup ---------------------------------------------------------

UINPUT_MAX_NAME_SIZE = 80
ABS_CNT = 0x40


class _input_id(ctypes.Structure):
    _fields_ = [
        ("bustype", ctypes.c_uint16),
        ("vendor", ctypes.c_uint16),
        ("product", ctypes.c_uint16),
        ("version", ctypes.c_uint16),
    ]


class _uinput_user_dev(ctypes.Structure):
    _fields_ = [
        ("name", ctypes.c_char * UINPUT_MAX_NAME_SIZE),
        ("id", _input_id),
        ("ff_effects_max", ctypes.c_uint32),
        ("absmax", ctypes.c_int32 * ABS_CNT),
        ("absmin", ctypes.c_int32 * ABS_CNT),
        ("absfuzz", ctypes.c_int32 * ABS_CNT),
        ("absflat", ctypes.c_int32 * ABS_CNT),
    ]


def _IO(t, nr):
    return (0 << 30) | (ord(t) << 8) | nr


def _IOW(t, nr, size):
    return (1 << 30) | (size << 16) | (ord(t) << 8) | nr


UI_SET_EVBIT = _IOW("U", 100, 4)
UI_SET_KEYBIT = _IOW("U", 101, 4)
UI_SET_RELBIT = _IOW("U", 102, 4)
UI_SET_ABSBIT = _IOW("U", 103, 4)
UI_DEV_CREATE = _IO("U", 1)
UI_DEV_DESTROY = _IO("U", 2)


def make_uinput():
    fd = os.open(UINPUT_DEV, os.O_WRONLY | os.O_NONBLOCK)
    for ev in (EV_KEY, EV_REL, EV_SYN):
        fcntl.ioctl(fd, UI_SET_EVBIT, ev)
    keys_to_enable = {
        BTN_LEFT, BTN_RIGHT,
        KEY_ESC, KEY_TAB, KEY_ENTER, KEY_LEFTCTRL,
        KEY_LEFTALT, KEY_LEFTMETA, KEY_BACKSPACE,
        KEY_UP, KEY_DOWN, KEY_LEFT, KEY_RIGHT,
        KEY_HOME, KEY_PAGEUP, KEY_PAGEDOWN,
        KEY_VOLUMEUP, KEY_VOLUMEDOWN, KEY_BACK, KEY_BACK,
    }
    for k in keys_to_enable:
        fcntl.ioctl(fd, UI_SET_KEYBIT, k)
    for r in (REL_X, REL_Y, REL_WHEEL, REL_HWHEEL):
        fcntl.ioctl(fd, UI_SET_RELBIT, r)

    udev = _uinput_user_dev()
    udev.name = b"RGDS Virtual Pad Pointer"
    udev.id.bustype = 0x03
    udev.id.vendor = 0x1d6b
    udev.id.product = 0xface
    udev.id.version = 1
    os.write(fd, bytes(udev))
    fcntl.ioctl(fd, UI_DEV_CREATE)
    return fd


def emit(fd, ev_type, code, value):
    pkt = EV_STRUCT.pack(0, 0, ev_type, code, value)
    os.write(fd, pkt)


def emit_syn(fd):
    emit(fd, EV_SYN, 0, 0)


# --- stick normalization --------------------------------------------------

def normalize(v, max_out, deadband=DEADBAND, abs_max=ABS_MAX):
    if -deadband <= v <= deadband:
        return 0.0
    sign = -1.0 if v < 0 else 1.0
    mag = (abs(v) - deadband) / (abs_max - deadband)
    if mag > 1.0:
        mag = 1.0
    return sign * mag * mag * max_out


# --- main loop ------------------------------------------------------------

class State:
    def __init__(self):
        # Left stick → mouse motion
        self.lx = 0   # ABS_Z (code 2)
        self.ly = 0   # ABS_RX (code 3)
        # Right stick → scroll
        self.rx = 0   # ABS_RY (code 4) → vertical scroll
        self.ry = 0   # ABS_RZ (code 5) → horizontal scroll
        # Sub-pixel accumulation
        self.fx = 0.0
        self.fy = 0.0
        self.fw = 0.0
        self.fh = 0.0
        # D-pad state
        self.hat_key_x = 0
        self.hat_key_y = 0
        # Track output key/btn state for shared mappings
        # (multiple physical buttons can map to the same output code)
        self.out_state = {}  # output_code -> current value (0 or 1)


def hat_to_key(state, axis, value, uin):
    if axis == "x":
        prev = state.hat_key_x
        cur = -1 if value < 0 else (1 if value > 0 else 0)
        if cur == prev:
            return
        if prev == -1:
            emit(uin, EV_KEY, KEY_LEFT, 0)
        elif prev == 1:
            emit(uin, EV_KEY, KEY_RIGHT, 0)
        if cur == -1:
            emit(uin, EV_KEY, KEY_LEFT, 1)
        elif cur == 1:
            emit(uin, EV_KEY, KEY_RIGHT, 1)
        state.hat_key_x = cur
    else:
        prev = state.hat_key_y
        cur = -1 if value < 0 else (1 if value > 0 else 0)
        if cur == prev:
            return
        if prev == -1:
            emit(uin, EV_KEY, KEY_UP, 0)
        elif prev == 1:
            emit(uin, EV_KEY, KEY_DOWN, 0)
        if cur == -1:
            emit(uin, EV_KEY, KEY_UP, 1)
        elif cur == 1:
            emit(uin, EV_KEY, KEY_DOWN, 1)
        state.hat_key_y = cur
    emit_syn(uin)


def main():
    os.makedirs("/var/log", exist_ok=True)
    logf = open(LOG_PATH, "a", buffering=1)

    def log(msg):
        logf.write(f"[{time.strftime('%FT%T')}] {msg}\n")

    log(f"starting; opening {GAMEPAD_DEV} and {ADC_KEYS_DEV}")

    for _ in range(60):
        if os.path.exists(GAMEPAD_DEV):
            break
        time.sleep(0.5)
    else:
        log(f"gamepad device {GAMEPAD_DEV} never appeared; exiting")
        return 1

    src_fd = os.open(GAMEPAD_DEV, os.O_RDONLY | os.O_NONBLOCK)
    adc_fd = None
    try:
        adc_fd = os.open(ADC_KEYS_DEV, os.O_RDONLY | os.O_NONBLOCK)
    except OSError:
        log(f"warning: could not open {ADC_KEYS_DEV}")

    try:
        uin = make_uinput()
    except OSError as exc:
        log(f"failed to open/create uinput: {exc}")
        os.close(src_fd)
        if adc_fd:
            os.close(adc_fd)
        return 1
    log("uinput device created")
    time.sleep(0.5)

    state = State()
    tick_dt = 1.0 / TICK_HZ
    next_tick = time.monotonic() + tick_dt
    poller = select.poll()
    poller.register(src_fd, select.POLLIN)
    if adc_fd:
        poller.register(adc_fd, select.POLLIN)

    while True:
        now = time.monotonic()
        timeout_ms = max(0, int((next_tick - now) * 1000))
        for fd, ev in poller.poll(timeout_ms):
            try:
                data = os.read(fd, EV_STRUCT.size * 32)
            except OSError as exc:
                if exc.errno not in (errno.EAGAIN, errno.EWOULDBLOCK):
                    log(f"read error {exc}; reopening")
                    if fd == src_fd:
                        os.close(src_fd)
                        time.sleep(1.0)
                        src_fd = os.open(GAMEPAD_DEV, os.O_RDONLY | os.O_NONBLOCK)
                        poller.register(src_fd, select.POLLIN)
                    elif fd == adc_fd:
                        try:
                            os.close(adc_fd)
                        except:
                            pass
                        try:
                            adc_fd = os.open(ADC_KEYS_DEV, os.O_RDONLY | os.O_NONBLOCK)
                            poller.register(adc_fd, select.POLLIN)
                        except OSError:
                            adc_fd = None
                continue
            for off in range(0, len(data), EV_STRUCT.size):
                chunk = data[off : off + EV_STRUCT.size]
                if len(chunk) < EV_STRUCT.size:
                    break
                _s, _u, t, c, v = EV_STRUCT.unpack(chunk)
                if t == EV_KEY:
                    mapping = KEY_MAP.get(c)
                    if not mapping:
                        continue
                    out_kind, out_code = mapping
                    # Only emit on state change to handle shared output codes
                    # (e.g. A and R3 both → BTN_LEFT)
                    prev = state.out_state.get(out_code, 0)
                    if v != prev:
                        emit(uin, EV_KEY, out_code, v)
                        state.out_state[out_code] = v
                    emit_syn(uin)
                elif t == EV_ABS:
                    if c == ABS_Z:     # Left stick X → mouse X
                        state.lx = v
                    elif c == ABS_RX:  # Left stick Y → mouse Y
                        state.ly = v
                    elif c == ABS_RY:  # Right stick X → vertical scroll
                        state.rx = v
                    elif c == ABS_RZ:  # Right stick Y → horizontal scroll
                        state.ry = v
                    elif c == ABS_HAT0X:
                        hat_to_key(state, "x", v, uin)
                    elif c == ABS_HAT0Y:
                        hat_to_key(state, "y", v, uin)

        now = time.monotonic()
        if now >= next_tick:
            dx = normalize(state.lx, POINTER_MAX_PX)
            dy = normalize(state.ly, POINTER_MAX_PX)
            dw = normalize(state.rx, SCROLL_MAX)   # right stick X → vscroll
            dh = normalize(state.ry, SCROLL_MAX)   # right stick Y → hscroll
            state.fx += dx
            state.fy += dy
            state.fw += dw
            state.fh += dh
            ix = int(state.fx)
            iy = int(state.fy)
            iw = int(state.fw)
            ih = int(state.fh)
            state.fx -= ix
            state.fy -= iy
            state.fw -= iw
            state.fh -= ih
            need_syn = False
            if ix:
                emit(uin, EV_REL, REL_X, ix)
                need_syn = True
            if iy:
                emit(uin, EV_REL, REL_Y, iy)
                need_syn = True
            if iw:
                emit(uin, EV_REL, REL_WHEEL, -iw)
                need_syn = True
            if ih:
                emit(uin, EV_REL, REL_HWHEEL, ih)
                need_syn = True
            if need_syn:
                emit_syn(uin)
            next_tick = now + tick_dt


if __name__ == "__main__":
    try:
        sys.exit(main() or 0)
    except KeyboardInterrupt:
        pass
    except Exception:
        import traceback
        with open(LOG_PATH, "a") as f:
            f.write("\nFATAL:\n")
            f.write(traceback.format_exc())
        sys.exit(1)
