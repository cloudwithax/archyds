#!/usr/bin/env python3
"""
RGDS gamepad-to-pointer daemon.

Translates events from /dev/input/event4 (ANBERNIC-rk3568-keys) into a virtual
mouse + keyboard via /dev/uinput, so the device can be used as a desktop input
device without external peripherals.

Mapping (after on-device validation):
  D-pad / HAT0X HAT0Y     → arrow keys (UP/DOWN/LEFT/RIGHT)
  Left analog stick       → mouse motion (ABS_RY = X, ABS_RZ = Y)
  Right analog stick      → mouse wheel  (ABS_RX = horiz, ABS_Z = vert)
  BTN_GAMEPAD (A)         → BTN_LEFT  (left mouse click)
  BTN_EAST    (B)         → BTN_RIGHT (right mouse click)
  BTN_NORTH   (X)         → KEY_ENTER
  BTN_C       (Y)         → KEY_BACKSPACE
  BTN_TL  (L1)            → KEY_PAGEUP
  BTN_TR  (R1)            → KEY_PAGEDOWN
  BTN_TL2 (L2)            → KEY_LEFTALT (hold)
  BTN_TR2 (R2)            → KEY_TAB
  BTN_SELECT              → KEY_ESC
  BTN_START               → KEY_LEFTMETA (Super — opens KRunner)
  BTN_MODE                → KEY_LEFTCTRL
  KEY_GOTO  (extra)       → KEY_HOME
  KEY_VOLUMEUP/DOWN       → passthrough

Stick motion is integrated each tick (default 60 Hz) into REL_X/REL_Y.
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
UINPUT_DEV = "/dev/uinput"
TICK_HZ = 60
LOG_PATH = "/var/log/rgds-padmouse.log"

# input_event struct (24 bytes on 64-bit)
EV_STRUCT = struct.Struct("@llHHi")
assert EV_STRUCT.size == 24

EV_SYN = 0x00
EV_KEY = 0x01
EV_REL = 0x02
EV_ABS = 0x03

# REL codes
REL_X = 0x00
REL_Y = 0x01
REL_HWHEEL = 0x06
REL_WHEEL = 0x08

# KEY/BTN codes used here
BTN_LEFT = 0x110
BTN_RIGHT = 0x111
BTN_MIDDLE = 0x112
KEY_ESC = 1
KEY_TAB = 15
KEY_ENTER = 28
KEY_LEFTCTRL = 29
KEY_LEFTSHIFT = 42
KEY_LEFTALT = 56
KEY_LEFTMETA = 125
KEY_BACKSPACE = 14
KEY_UP = 103
KEY_LEFT = 105
KEY_RIGHT = 106
KEY_DOWN = 108
KEY_HOME = 102
KEY_END = 107
KEY_PAGEUP = 104
KEY_PAGEDOWN = 109
KEY_VOLUMEUP = 115
KEY_VOLUMEDOWN = 114

# ABS event codes
ABS_Z = 0x02
ABS_RX = 0x03
ABS_RY = 0x04
ABS_RZ = 0x05
ABS_HAT0X = 0x10
ABS_HAT0Y = 0x11

# Incoming KEY codes from event4
SRC_BTN_GAMEPAD = 0x130
SRC_BTN_EAST = 0x131
SRC_BTN_C = 0x132
SRC_BTN_NORTH = 0x133
SRC_BTN_WEST = 0x134
SRC_BTN_Z = 0x135
SRC_BTN_TL = 0x136
SRC_BTN_TR = 0x137
SRC_BTN_TL2 = 0x138
SRC_BTN_TR2 = 0x139
SRC_BTN_SELECT = 0x13a
SRC_BTN_START = 0x13b
SRC_BTN_MODE = 0x13c
SRC_KEY_GOTO = 0x1A2

# Mapping: source button code -> (output type, output code).
# type 'k' = key/btn passthrough press, 'm' = mouse button
# Confirmed on device: A=BTN_GAMEPAD, B=BTN_EAST, X=BTN_NORTH, Y=BTN_C
KEY_MAP = {
    SRC_BTN_GAMEPAD: ("m", BTN_LEFT),   # A
    SRC_BTN_EAST: ("m", BTN_RIGHT),     # B
    SRC_BTN_NORTH: ("k", KEY_ENTER),    # X
    SRC_BTN_C: ("k", KEY_BACKSPACE),    # Y
    SRC_BTN_TL: ("k", KEY_PAGEUP),
    SRC_BTN_TR: ("k", KEY_PAGEDOWN),
    SRC_BTN_TL2: ("k", KEY_LEFTALT),
    SRC_BTN_TR2: ("k", KEY_TAB),
    SRC_BTN_SELECT: ("k", KEY_ESC),
    SRC_BTN_START: ("k", KEY_LEFTMETA),
    SRC_BTN_MODE: ("k", KEY_LEFTCTRL),
    SRC_KEY_GOTO: ("k", KEY_HOME),
    0x73: ("k", KEY_VOLUMEUP),    # KEY_VOLUMEUP passthrough
    0x72: ("k", KEY_VOLUMEDOWN),  # KEY_VOLUMEDOWN
    1: ("k", KEY_ESC),            # KEY_ESC (mapped from somewhere)
}

# Stick parameters: ABS axis full range is +/- 4096, with flat=32 deadband.
ABS_MAX = 4096
DEADBAND = 384
POINTER_MAX_PX = 18  # max pixels per tick at full deflection (~1080 px/sec @ 60Hz)
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


# ioctl numbers for uinput
def _IO(t, nr):
    return (0 << 30) | (ord(t) << 8) | nr


def _IOW(t, nr, size):
    return (1 << 30) | (size << 16) | (ord(t) << 8) | nr


UI_SET_EVBIT = _IOW("U", 100, 4)
UI_SET_KEYBIT = _IOW("U", 101, 4)
UI_SET_RELBIT = _IOW("U", 102, 4)
UI_SET_ABSBIT = _IOW("U", 103, 4)
UI_SET_PROPBIT = _IOW("U", 110, 4)
UI_DEV_CREATE = _IO("U", 1)
UI_DEV_DESTROY = _IO("U", 2)


def make_uinput():
    fd = os.open(UINPUT_DEV, os.O_WRONLY | os.O_NONBLOCK)
    # Enable types
    for ev in (EV_KEY, EV_REL, EV_SYN):
        fcntl.ioctl(fd, UI_SET_EVBIT, ev)
    # Enable key codes — both mouse buttons and keyboard keys we'll emit
    keys_to_enable = {
        BTN_LEFT, BTN_RIGHT, BTN_MIDDLE,
        KEY_ESC, KEY_TAB, KEY_ENTER, KEY_LEFTCTRL, KEY_LEFTSHIFT,
        KEY_LEFTALT, KEY_LEFTMETA, KEY_BACKSPACE,
        KEY_UP, KEY_DOWN, KEY_LEFT, KEY_RIGHT,
        KEY_HOME, KEY_END, KEY_PAGEUP, KEY_PAGEDOWN,
        KEY_VOLUMEUP, KEY_VOLUMEDOWN,
    }
    for k in keys_to_enable:
        fcntl.ioctl(fd, UI_SET_KEYBIT, k)
    # Enable rel codes
    for r in (REL_X, REL_Y, REL_WHEEL, REL_HWHEEL):
        fcntl.ioctl(fd, UI_SET_RELBIT, r)
    # INPUT_PROP_POINTER = 0x00 (this is a pointer, not absolute)
    # Don't set this — it confuses some compositors. Default behavior is fine.

    udev = _uinput_user_dev()
    udev.name = b"RGDS Virtual Pad Pointer"
    udev.id.bustype = 0x03  # BUS_USB so libinput accepts as a normal device
    udev.id.vendor = 0x1d6b
    udev.id.product = 0xface
    udev.id.version = 1
    os.write(fd, bytes(udev))
    fcntl.ioctl(fd, UI_DEV_CREATE)
    return fd


def emit(fd, ev_type, code, value):
    # No leading timestamp needed when writing to uinput.
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
    # Square the magnitude for finer control at low deflection
    return sign * mag * mag * max_out


# --- main loop ------------------------------------------------------------

class State:
    def __init__(self):
        # current stick values
        self.lx = 0  # fed from ABS_RY on this hw (horizontal axis)
        self.ly = 0  # fed from ABS_RZ on this hw (vertical axis)
        self.rx = 0  # ABS_RX (right X) -> hwheel
        self.ry = 0  # ABS_Z  (right Y) -> wheel
        # remainder for sub-pixel accumulation
        self.fx = 0.0
        self.fy = 0.0
        self.fw = 0.0
        self.fh = 0.0
        # dpad current state for arrow-key edge detection
        self.hat_x = 0
        self.hat_y = 0
        self.hat_key_x = 0  # 0 / -1 / +1
        self.hat_key_y = 0


def hat_to_key(state, axis, value, uin):
    if axis == "x":
        prev = state.hat_key_x
        cur = -1 if value < 0 else (1 if value > 0 else 0)
        if cur == prev:
            return
        # release previous
        if prev == -1:
            emit(uin, EV_KEY, KEY_LEFT, 0)
        elif prev == 1:
            emit(uin, EV_KEY, KEY_RIGHT, 0)
        # press new
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

    log(f"starting; opening {GAMEPAD_DEV} and {UINPUT_DEV}")

    # Wait for device to appear (may not exist at very early boot)
    for _ in range(60):
        if os.path.exists(GAMEPAD_DEV):
            break
        time.sleep(0.5)
    else:
        log(f"gamepad device {GAMEPAD_DEV} never appeared; exiting")
        return 1

    src_fd = os.open(GAMEPAD_DEV, os.O_RDONLY | os.O_NONBLOCK)
    try:
        uin = make_uinput()
    except OSError as exc:
        log(f"failed to open/create uinput: {exc}")
        os.close(src_fd)
        return 1
    log("uinput device created")

    # Slight delay to let udev publish the new device
    time.sleep(0.5)

    state = State()
    tick_dt = 1.0 / TICK_HZ
    next_tick = time.monotonic() + tick_dt
    poller = select.poll()
    poller.register(src_fd, select.POLLIN)

    while True:
        now = time.monotonic()
        timeout_ms = max(0, int((next_tick - now) * 1000))
        for fd, ev in poller.poll(timeout_ms):
            try:
                data = os.read(fd, EV_STRUCT.size * 32)
            except OSError as exc:
                if exc.errno not in (errno.EAGAIN, errno.EWOULDBLOCK):
                    log(f"read error {exc}; reopening")
                    os.close(src_fd)
                    time.sleep(1.0)
                    src_fd = os.open(GAMEPAD_DEV, os.O_RDONLY | os.O_NONBLOCK)
                    poller.register(src_fd, select.POLLIN)
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
                    emit(uin, EV_KEY, out_code, v)
                    emit_syn(uin)
                elif t == EV_ABS:
                    # Validated on device 2026-05-15: left stick reports
                    # vertical motion on ABS_RZ and horizontal motion on
                    # ABS_RY (axes physically rotated 90° vs Linux defaults).
                    if c == ABS_RY:
                        state.lx = v
                    elif c == ABS_RZ:
                        state.ly = v
                    elif c == ABS_RX:
                        state.rx = v
                    elif c == ABS_Z:
                        state.ry = v
                    elif c == ABS_HAT0X:
                        state.hat_x = v
                        hat_to_key(state, "x", v, uin)
                    elif c == ABS_HAT0Y:
                        state.hat_y = v
                        hat_to_key(state, "y", v, uin)

        # Tick: integrate stick into mouse motion + wheel
        now = time.monotonic()
        if now >= next_tick:
            dx = normalize(state.lx, POINTER_MAX_PX)
            dy = normalize(state.ly, POINTER_MAX_PX)
            dw = normalize(state.ry, SCROLL_MAX)  # vertical scroll
            dh = normalize(state.rx, SCROLL_MAX)  # horizontal scroll
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
                emit(uin, EV_REL, REL_WHEEL, -iw if iw else 0)
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
