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

## What this is

A real Linux desktop on the RG DS without touching the stock boot chain. The vendor U-Boot, kernel, and DTB are particular about this hardware (the panels and touch IC especially), so this build leaves all of that alone and only rewrites the rootfs partition. Arch Linux ARM goes on top, KDE Plasma runs against the stock kernel, and a first-boot script does the unattended setup.

Not a polished distro. A mod pipeline that produces a bootable SD card.

## Features

- Stock boot chain is untouched. Only `rootfs` gets rewritten.
- Full Arch Linux ARM aarch64 userland, pacman included.
- KDE Plasma 6.7 on Wayland. SDDM is forced to Wayland because the RK3568 has no X.org driver.
- Optional Plasma 6.7 beta modules built from KDE unstable tarballs at first boot.
- Optional `plasma-bigscreen` + `union` for a TV-style frontend.
- Dual-screen aware. DSI-2 (bottom) is the primary display, DSI-1 (top) sits above it.
- Touch works on the bottom screen via Goodix `gt9xx-0`, bound to DSI-2 through a libinput quirk.
- Padmouse service so the analog stick can drive the cursor when touch is awkward.
- Stock WiFi and Bluetooth via the Realtek RTL8821CS modules and the vendor helper scripts.
- First boot runs `rgds-firstboot.service` and handles package install, autologin, services, and beta builds with no babysitting.

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

## Partition layout

The stock boot chain is preserved. `rootfs` is rewritten and grown to absorb the unused vendor partitions:

| # | Name | Size | Modified |
|---|------|-----:|:--------:|
| 1 | uboot | 4 MiB | — |
| 2 | misc | 4 MiB | — |
| 3 | boot | 64 MiB | — |
| 4 | recovery | 128 MiB | — |
| 5 | backup | 32 MiB | — |
| 6 | **rootfs** | **~11.5 GiB** | **✓ grown** |
| ~~7~~ | ~~ports~~ | — | absorbed |
| ~~8~~ | ~~vendor~~ | — | absorbed |
| ~~9~~ | ~~oem~~ | — | absorbed |
| ~~10~~ | ~~userdata~~ | — | absorbed |

Partitions 7–10 hold the stock Anbernic frontend and the ROM/save assets. Nothing in Arch uses them, so by default they get absorbed into rootfs. To dual-boot with the stock OS, pass `--grow-rootfs 0` and they stay in place.

## Building

### Prerequisites

- A Linux host with root, for loop-mounting and chroot.
- `qemu-user-static` with `binfmt_misc` registered, so the build can chroot into aarch64 from x86_64.
- `arch-install-scripts`, `parted`, `dosfstools`, `e2fsprogs`.
- A copy of the stock RG DS firmware: `rgds_sdcard_20260514.img`. Extract it from the `RGDS-LINUX-V1.0-260513.img.gz` archive Anbernic ships.

### Build the image

```bash
sudo ./scripts/build-rgds-arch-plasma67-image.sh \
  --stock-img ./analysis/rgds_sdcard_20260514.img \
  --output-img ./out/rgds-arch-plasma67.img \
  --enable-kde-beta 1 \
  --enable-bigscreen 1 \
  --enable-union 1
```

The image lands at `./out/rgds-arch-plasma67.img`.

## Flashing

```bash
sudo dd if=./out/rgds-arch-plasma67.img of=/dev/sdX bs=4M conv=fsync status=progress
sync
```

`/dev/sdX` is the whole card, not a partition. Don't pass `/dev/sdX1`.

To restore just the stock boot partition (after experimentation):

```bash
sudo dd if=touchfix/boot_orig.img of=/dev/sdX3 bs=1M conv=fsync status=progress
```

## First boot

First power-on runs `rgds-firstboot.service`. It takes a while, especially with the Plasma beta builds turned on. Watch it over SSH or serial:

```bash
journalctl -u rgds-firstboot -f
# or
tail -f /var/log/rgds-firstboot.log
```

When `/var/lib/rgds-firstboot.done` exists, the bootstrap is done and the system reboots into an autologged-in Plasma session.

Default user is `alarm`, passwordless sudo, in every system group it needs.

## Configuration

Edit `/etc/rgds-plasma-bootstrap.conf` on the rootfs before first boot to change behavior:

| Key | Default | Meaning |
|-----|---------|---------|
| `RGDS_ENABLE_KDE_BETA` | `1` | Build Plasma 6.7 beta modules from source |
| `RGDS_ENABLE_BIGSCREEN` | `1` | Build and install `plasma-bigscreen` |
| `RGDS_ENABLE_UNION` | `1` | Build and install `union` |
| `RGDS_PLASMA_BETA_VERSION` | `6.6.90` | KDE unstable tag to fetch |
| `RGDS_REBOOT_AFTER_BOOTSTRAP` | `1` | Reboot once bootstrap completes |
| `RGDS_AUTOLOGIN_USER` | `alarm` | SDDM autologin user |

If a beta build fails (upstream module renames happen), set `RGDS_ENABLE_KDE_BETA=0`. The stable Plasma 6.6.5 from the Arch Linux ARM repos is still there and the system boots fine.

## Repository layout

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

## Caveats

- The beta build pulls from KDE unstable tarballs. When upstream renames or removes a module mid-release, the build will fail and the stable fallback is what you get.
- The kernel is vendor-pinned at 6.1.141. The panel, touch, and audio drivers are out-of-tree against that exact version, so swapping kernels is not a small project.
- Battery reporting works. Suspend is not wired up — the panels' standby behavior is fragile enough that a clean shutdown is the safer default.
- No mainlining work is included. This targets the vendor BSP as-is.

## Credits

- [Arch Linux ARM](https://archlinuxarm.org/) for the base userland.
- [KDE](https://kde.org/) for Plasma 6.7.
- Anbernic for shipping a handheld with an unsigned bootloader.
- [plasma-bigscreen](https://invent.kde.org/plasma/plasma-bigscreen) for the TV-style shell.

## License

MIT. See [LICENSE](LICENSE).
