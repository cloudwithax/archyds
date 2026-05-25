# RG DS Arch Image (Plasma 6.7 Beta + Bigscreen)

This repository now includes a builder that keeps the **stock RG DS boot chain** and replaces only the `rootfs` partition with Arch Linux ARM.

## What This Builder Does

1. Copies the stock SD image.
2. Re-formats only the `rootfs` partition.
3. Extracts `ArchLinuxARM-aarch64-latest.tar.gz` into `rootfs`.
4. Imports stock WiFi/BT compatibility blobs (`RTL8821CS.ko`, `rtk_btusb.ko`, helper scripts).
5. Installs first-boot systemd services that:
   - install a Plasma stack from Arch Linux ARM repos
   - optionally compile/install selected Plasma 6.7 beta modules from KDE unstable tarballs
   - optionally compile/install `plasma-bigscreen` and `union`

The raw `boot` partition is preserved, so the stock U-Boot/kernel/device tree remain in control.

## Why First-Boot Build Is Used

As of **May 15, 2026**, Arch Linux ARM has Plasma `6.6.5` binaries but does **not** ship `plasma-bigscreen` for `aarch64` in its standard repo.  
So this setup builds beta modules from source on the device itself.

## Files

- Builder: `scripts/build-rgds-arch-plasma67-image.sh`
- First-boot bootstrap: `scripts/overlay/usr/local/sbin/rgds-firstboot.sh`
- WiFi/BT service wrapper: `scripts/overlay/usr/local/sbin/rgds-wifibt-init.sh`

## Build

```bash
sudo ./scripts/build-rgds-arch-plasma67-image.sh \
  --stock-img ./analysis/rgds_sdcard_20260514.img \
  --output-img ./out/rgds-arch-plasma67.img \
  --enable-kde-beta 1 \
  --enable-bigscreen 1 \
  --enable-union 1
```

Then flash `./out/rgds-arch-plasma67.img` to SD.

## First Boot Behavior

On first boot, `rgds-firstboot.service` runs automatically and can take a long time (especially beta source builds).

Logs:

```bash
journalctl -u rgds-firstboot -f
cat /var/log/rgds-firstboot.log
```

Completion marker:

```bash
/var/lib/rgds-firstboot.done
```

## Config Knobs

`/etc/rgds-plasma-bootstrap.conf` inside the image controls:

- `RGDS_ENABLE_KDE_BETA` (`0|1`)
- `RGDS_ENABLE_BIGSCREEN` (`0|1`)
- `RGDS_ENABLE_UNION` (`0|1`)
- `RGDS_PLASMA_BETA_VERSION` (default `6.6.90`)
- `RGDS_REBOOT_AFTER_BOOTSTRAP` (`0|1`)

## Reality Check

- This is a practical mod pipeline, not a polished distro release process.
- Full Plasma beta stack source builds can fail if upstream module ABI/deps drift.
- If beta build fails, set `RGDS_ENABLE_KDE_BETA=0` and keep stable Arch Linux ARM Plasma.
