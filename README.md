<h1 align="center">archyds</h1>

<p align="center">
  <b>Arch Linux ARM + KDE Plasma 6.7 for the Anbernic RG DS dual-screen handheld</b>
</p>

<p align="center">
  <a href="https://github.com/cloudwithax/archyds/blob/main/LICENSE">
    <img src="https://img.shields.io/github/license/cloudwithax/archyds?style=flat-square" alt="License">
  </a>
  <img src="https://img.shields.io/badge/device-Anbernic%20RG%20DS-red?style=flat-square" alt="RG DS">
  <img src="https://img.shields.io/badge/SoC-Rockchip%20RK3568-blue?style=flat-square" alt="RK3568">
  <img src="https://img.shields.io/badge/arch-aarch64-ff69b4?style=flat-square" alt="aarch64">
  <img src="https://img.shields.io/badge/desktop-KDE%20Plasma%206.7-1d99f3?logo=kde&logoColor=white&style=flat-square" alt="Plasma 6.7">
</p>

<p align="center">
  <a href="#features">Features</a> •
  <a href="#hardware">Hardware</a> •
  <a href="#building">Building</a> •
  <a href="#flashing">Flashing</a> •
  <a href="#first-boot">First Boot</a> •
  <a href="#configuration">Configuration</a>
</p>

---

## Features

- **Stock boot chain preserved** — only the `rootfs` partition is replaced; U-Boot, kernel, and DTB stay untouched
- **Full Arch Linux ARM aarch64** userland with pacman
- **KDE Plasma 6.7** desktop with Wayland (forced via SDDM config — RK3568 has no X.org driver)
- **Optional Plasma 6.7 beta modules** built from KDE unstable tarballs on first boot
- **Optional `plasma-bigscreen`** + `union` for a TV-style frontend
- **Dual-screen aware** — DSI-2 (bottom) is primary, DSI-1 (top) is secondary, stacked vertically
- **Touch on bottom screen** via Goodix gt9xx-0, bound to DSI-2 with libinput quirks
- **Padmouse service** — control the desktop with the gamepad / analog stick
- **Stock WiFi & Bluetooth** — Realtek RTL8821CS modules + helper scripts ported from vendor firmware
- **First-boot bootstrap** — package install, autologin, services, and beta builds run unattended on first power-on

## Hardware

| Component | Detail |
|-----------|--------|
| SoC | Rockchip RK3568 (quad-core Cortex-A55, Mali-G52) |
| Screens | 2× 640×480 DSI panels (DSI-1 top, DSI-2 bottom) |
| Touch | Goodix GT911 on i2c-5 @ 0x14 (`gt9xx-0`, bottom only) |
| Input | Gamepad, analog stick, d-pad, ABXY, volume rocker, power |
| WiFi/BT | Realtek RTL8821CS (SDIO + USB) |
| Boot media | microSD |
| Stock OS | Anbernic vendor Linux 6.1.141 |

## Partition Layout

The stock SD layout is preserved. Only `rootfs` is rewritten:

| # | Name | Size | Modified |
|---|------|-----:|:--------:|
| 1 | uboot | 4 MiB | — |
| 2 | misc | 4 MiB | — |
| 3 | boot | 64 MiB | — |
| 4 | recovery | 128 MiB | — |
| 5 | backup | 32 MiB | — |
| 6 | **rootfs** | **5 GiB** | **✓** |
| 7 | ports | 2 GiB | — |
| 8 | vendor | 512 MiB | — |
| 9 | oem | 3 GiB | — |
| 10 | userdata | 1 GiB | — |

## Building

### Prerequisites

- A Linux host with root (for loop-mounting and chroot)
- `qemu-user-static` with `binfmt_misc` registered (for aarch64 chroot from x86_64)
- `arch-install-scripts`, `parted`, `dosfstools`, `e2fsprogs`
- A copy of the stock RG DS firmware image: `rgds_sdcard_20260514.img`
  (Extract from `RGDS-LINUX-V1.0-260513.img.gz` shipped by Anbernic.)

### Build the image

```bash
sudo ./scripts/build-rgds-arch-plasma67-image.sh \
  --stock-img ./analysis/rgds_sdcard_20260514.img \
  --output-img ./out/rgds-arch-plasma67.img \
  --enable-kde-beta 1 \
  --enable-bigscreen 1 \
  --enable-union 1
```

Build output lands at `./out/rgds-arch-plasma67.img`.

## Flashing

```bash
sudo dd if=./out/rgds-arch-plasma67.img of=/dev/sdX bs=4M conv=fsync status=progress
sync
```

Replace `/dev/sdX` with your SD card device (**not** a partition like `/dev/sdX1`).

If you need to restore just the stock boot partition (e.g. after experimentation):

```bash
sudo dd if=touchfix/boot_orig.img of=/dev/sdX3 bs=1M conv=fsync status=progress
```

## First Boot

The first power-on runs `rgds-firstboot.service`. It can take a long time, especially if you enabled the Plasma beta source builds.

Watch the progress over SSH or serial:

```bash
journalctl -u rgds-firstboot -f
# or
tail -f /var/log/rgds-firstboot.log
```

When the marker file `/var/lib/rgds-firstboot.done` appears, the bootstrap is finished and the system reboots into the autologged-in Plasma session.

Default user: **`alarm`** (passwordless sudo, in all system groups).

## Configuration

Edit `/etc/rgds-plasma-bootstrap.conf` on the SD card's rootfs before first boot to tweak behavior:

| Key | Default | Meaning |
|-----|---------|---------|
| `RGDS_ENABLE_KDE_BETA` | `1` | Build Plasma 6.7 beta modules from source |
| `RGDS_ENABLE_BIGSCREEN` | `1` | Build & install `plasma-bigscreen` |
| `RGDS_ENABLE_UNION` | `1` | Build & install `union` |
| `RGDS_PLASMA_BETA_VERSION` | `6.6.90` | KDE unstable tag to fetch |
| `RGDS_REBOOT_AFTER_BOOTSTRAP` | `1` | Reboot once bootstrap completes |
| `RGDS_AUTOLOGIN_USER` | `alarm` | SDDM autologin user |

If the beta build fails (upstream ABI drift), set `RGDS_ENABLE_KDE_BETA=0` and you'll still get a working stable Plasma 6.6.5 from Arch Linux ARM's repos.

## Repository Layout

```
scripts/
├── build-rgds-arch-plasma67-image.sh    Image builder (host-side)
└── overlay/                              Files dropped into rootfs
    ├── etc/sddm.conf.d/                  SDDM (forced Wayland)
    ├── etc/libinput/                     Touch → DSI-2 binding quirks
    ├── etc/skel/.config/                 Default KWin / Plasma config
    ├── etc/systemd/system/               First-boot, padmouse, wifi/bt services
    └── usr/local/sbin/                   Bootstrap & helper scripts
analysis/
├── RGDS_DISSECTION.md                    Stock firmware analysis notes
├── partition_map.tsv                     GPT layout
└── reports/                              DTS dumps, binwalk output
touchfix/                                 DTS sources for boot partition (reference)
CLAUDE.md                                 Detailed dev notes & lessons learned
```

## Reality Check

This is a practical mod pipeline, not a polished distro release. Things to expect:

- First-boot beta builds depend on KDE unstable tarball availability and can break when upstream APIs drift.
- The stock kernel is vendor-pinned at 6.1.141; you cannot trivially swap kernels without breaking the panel/touch/audio stack.
- Power management is rudimentary — battery reporting works but suspend is not wired up.
- No mainline upstreaming work is included here; this targets the existing vendor BSP.

## Credits

- [Arch Linux ARM](https://archlinuxarm.org/) — base userland
- [KDE](https://kde.org/) — Plasma 6.7 desktop
- Anbernic — for shipping a hackable handheld with an unsigned bootloader
- [plasma-bigscreen](https://invent.kde.org/plasma/plasma-bigscreen) — TV-style Plasma shell

## License

MIT — see [LICENSE](LICENSE).
