# RG DS Linux Firmware Dissection (RGDS-LINUX-V1.0-260513)

## 1) Image / Partition Layout

Source image:
- `RGDS-LINUX-V1.0-260513.img.gz` (contains `rgds_sdcard_20260514.img`)
- Uncompressed image size: `12,599,689,216` bytes (`~11.73 GiB`)

Important GPT quirk:
- Primary GPT exists and partition entries are valid.
- Header fields claim a huge backup LBA (`0xFFFFFFFE`), so tools like `parted`/`fdisk` mis-detect it.
- Primary entry table at LBA2 is still usable and defines all real partitions.

Parsed partitions:

| # | Name | Start LBA | End LBA | Size |
|---|---|---:|---:|---:|
| 1 | `uboot` | 16384 | 24575 | 4 MiB |
| 2 | `misc` | 24576 | 32767 | 4 MiB |
| 3 | `boot` | 32768 | 163839 | 64 MiB |
| 4 | `recovery` | 163840 | 425983 | 128 MiB |
| 5 | `backup` | 425984 | 491519 | 32 MiB |
| 6 | `rootfs` | 491520 | 10977279 | 5120 MiB |
| 7 | `ports` | 10977280 | 15171583 | 2048 MiB |
| 8 | `vendor` | 15171584 | 16220159 | 512 MiB |
| 9 | `oem` | 16220160 | 22511615 | 3072 MiB |
| 10 | `userdata` | 22511616 | 24608767 | 1024 MiB |

Filesystem labels/types:
- `rootfs`, `ports`, `vendor`, `oem`, `userdata` are ext4.
- `misc` and `backup` are currently zeroed data partitions.

Notable ext4 sizing behavior:
- Several partitions are larger than their current ext4 filesystem size (e.g. `rootfs` partition 5 GiB, ext4 currently ~1.0 GiB). This leaves grow room.

## 2) Boot Chain

`uboot` partition:
- FIT image with ATF + OP-TEE + U-Boot.
- Contains duplicated payload blocks (at 0 and +2 MiB), likely redundancy.

`boot` partition:
- FIT image containing:
  - kernel
  - FDT
  - resource blob
- No recovery ramdisk here.

`recovery` partition:
- FIT image containing:
  - kernel
  - FDT
  - ramdisk (`cpio.gz`)
  - resource blob

Kernel cmdline (from boot/recovery DTB):
- `root=PARTUUID=614e0000-0000 rw rootwait`
- This matches the rootfs partition UUID prefix.

U-Boot env (from extracted `u-boot-nodtb.bin` strings):
- `bootcmd=boot_android ...;boot_fit;bootrkp;run distro_bootcmd;`
- `boot_targets=mmc1 mmc0 mtd2 mtd1 mtd0 usb0 pxe dhcp`
- Android-style boot/recovery paths and fastboot commands are compiled in.

## 3) Userland Startup Flow (What Actually Makes It Tick)

Init chain:
1. BusyBox init from rootfs inittab
2. Runs `/etc/init.d/rcS`
3. Starts Weston (`S49weston`)
4. Starts launch orchestration (`S50launch`)

Critical scripts:
- Root init: `/etc/inittab`
- Launcher orchestrator: `/etc/init.d/S50launch`
- App launcher: `/mnt/vendor/ctrl/loadapp.sh`
- Frontend dispatch shim: `/mnt/vendor/ctrl/dmenu_ln`

Flow details:
- `S50launch` mounts/validates `userdata`, mounts ROM volume, may create ROMS partition when missing, and configures hidden GPT attributes on SD boot.
- Then it runs `loadapp.sh`.
- `loadapp.sh` waits for Weston socket, sets power/battery knobs under `/sys/class/anbernic_misc/*`, mounts SD card (`mmc_new.sh add`), and loops the frontend launcher.
- `dmenu_ln` selects one of:
  - `dmenu.bin`
  - `muos2.bin` (active when `res2.ini` exists)
  - `muos3.bin` (if `res3.ini` exists)

Current stock indicates `res2.ini` exists, so frontend path is effectively `muos2.bin`.

## 4) Built-In Mod Hooks (Best News)

Stock firmware already contains explicit mod extension points:

- `/mnt/mod/ctrl/autostart`
  - Called by `loadapp.sh` during boot if present.
- `/mnt/mod/ctrl/pwr_new.sh`
  - Called by vendor power script if present.
- `/mnt/mod/ctrl/RA_launch.sh`
  - Referenced inside `muos2.bin`/`dmenu.bin` for RetroArch launch path.

This means you can inject behavior without replacing kernel/bootloader.

## 5) Recovery / Update Path

Recovery ramdisk service:
- `/etc/init.d/S40recovery` starts `/usr/bin/recovery`.

Recovery binary behaviors (from strings):
- Reads commands from `/userdata/recovery/command`
- Uses misc block: `/dev/block/by-name/misc`
- Supports update package paths like:
  - `/userdata/update.img`
  - `/udisk/update.img`
  - `/sdupdate.img`
- Menu includes:
  - apply update from sdcard
  - apply update from local userdata
  - apply update from udisk
  - wipe data/factory reset

Rootfs also ships `/usr/bin/update` helper:
- Writes `boot-recovery` and command payload to misc/command files, then reboots to recovery.

## 6) Existing Mod Pack (`mod_20260508.zip`) Findings

The bundled mod pack is consistent with stock hooks:
- Installs `/mnt/mod/ctrl/*`
- Uses `autostart` hook
- Provides `RA_launch.sh`, shader/bezel/core automation
- Patches `/mnt/vendor/ctrl/setRA.sh` to call `/mnt/mod/ctrl/sw` on language changes

So current community mod strategy is non-invasive userspace hijacking via `/mnt/mod` + RA wrapper, not bootloader patching.

## 7) Practical Mod Strategy (Recommended)

Safest high-leverage path:
1. Keep bootloader/kernel/recovery stock.
2. Add/maintain your own `/mnt/mod/ctrl/` scripts:
   - `autostart`
   - `RA_launch.sh`
   - optional power/input hooks
3. Patch only vendor/oem userspace assets when needed.
4. Use recovery update path only for full-image rollouts.

Higher risk paths:
- Repacking `boot` / `recovery` / `uboot` (signature/boot-chain sensitivity).
- GPT edits on-device during runtime scripts (`sgdisk` logic in `S50launch`).

## 8) Key Files

- `/home/clxud/rgds-stock-mod/analysis/extracted/rootfs/etc/init.d/S50launch`
- `/home/clxud/rgds-stock-mod/analysis/extracted/vendor/ctrl/loadapp.sh`
- `/home/clxud/rgds-stock-mod/analysis/extracted/vendor/ctrl/dmenu_ln`
- `/home/clxud/rgds-stock-mod/analysis/reports/boot_fdt.dts`
- `/home/clxud/rgds-stock-mod/analysis/extracted/recovery_ramdisk/etc/init.d/S40recovery`
- `/home/clxud/rgds-stock-mod/analysis/extracted/rootfs/info/rockchip_config`
- `/home/clxud/rgds-stock-mod/analysis/extracted/mod_mnt/mnt/mod/ctrl/RA_launch.sh`

