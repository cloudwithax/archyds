#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Build an RG DS image that keeps the stock boot chain but swaps rootfs to Arch Linux ARM.

Usage:
  sudo ./scripts/build-rgds-arch-plasma67-image.sh [options]

Options:
  --stock-img PATH            Stock unpacked .img (default: ./analysis/rgds_sdcard_20260514.img)
  --stock-rootfs PATH         Extracted stock rootfs dir (default: ./analysis/extracted/rootfs)
  --output-img PATH           Output image path (default: ./out/rgds-arch-plasma67.img)
  --arch-rootfs-url URL       Arch ARM aarch64 rootfs tarball
  --rootfs-start-sector N     Rootfs start sector override (default: from analysis/partition_map.tsv)
  --rootfs-size-sectors N     Rootfs size in sectors override (default: from analysis/partition_map.tsv)
  --grow-rootfs 0|1           Absorb ports/vendor/oem/userdata into rootfs (default: 1, ~11.5 GiB)
  --hostname NAME             Hostname for the image (default: rgds-arch)
  --root-pass PASS            Root password in image (default: root)
  --alarm-pass PASS           alarm user password in image (default: alarm)
  --beta-version VER          Plasma beta version (default: 6.6.90 -> Plasma 6.7 beta)
  --enable-kde-beta 0|1       Build selected Plasma beta modules on first boot (default: 1)
  --enable-bigscreen 0|1      Build/install plasma-bigscreen on first boot (default: 1)
  --enable-union 0|1          Build/install union on first boot (default: 1)
  --reboot-after-bootstrap 0|1 Reboot automatically after first-boot bootstrap (default: 1)
  --wifi-ssid SSID            Pre-configure WiFi SSID for first boot
  --wifi-psk PSK              Pre-configure WiFi PSK for first boot
  --skip-package-install      Skip QEMU-based package pre-installation (firstboot will handle it)
  --safe-firstboot 0|1        Boot first to multi-user + autologin tty1, disable Plasma firstboot (default: 1).
                              Run /root/rgds-enable-graphical.sh on device to switch to graphical + Plasma firstboot.
  --help                      Show this help
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OVERLAY_DIR="$SCRIPT_DIR/overlay"

STOCK_IMG="${REPO_DIR}/analysis/rgds_sdcard_20260514.img"
STOCK_ROOTFS="${REPO_DIR}/analysis/extracted/rootfs"
OUTPUT_IMG="${REPO_DIR}/out/rgds-arch-plasma67.img"
ARCH_ROOTFS_URL="http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz"
ROOTFS_START_SECTOR=""
ROOTFS_SIZE_SECTORS=""
GROW_ROOTFS="1"
HOSTNAME="rgds-arch"
ROOT_PASS="root"
ALARM_PASS="alarm"
BETA_VERSION="6.6.90"
ENABLE_KDE_BETA="1"
ENABLE_BIGSCREEN="1"
ENABLE_UNION="1"
REBOOT_AFTER_BOOTSTRAP="1"
WIFI_SSID=""
WIFI_PSK=""
SKIP_PACKAGE_INSTALL="0"
SAFE_FIRSTBOOT="1"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stock-img) STOCK_IMG="$2"; shift 2 ;;
    --stock-rootfs) STOCK_ROOTFS="$2"; shift 2 ;;
    --output-img) OUTPUT_IMG="$2"; shift 2 ;;
    --arch-rootfs-url) ARCH_ROOTFS_URL="$2"; shift 2 ;;
    --rootfs-start-sector) ROOTFS_START_SECTOR="$2"; shift 2 ;;
    --rootfs-size-sectors) ROOTFS_SIZE_SECTORS="$2"; shift 2 ;;
    --grow-rootfs) GROW_ROOTFS="$2"; shift 2 ;;
    --hostname) HOSTNAME="$2"; shift 2 ;;
    --root-pass) ROOT_PASS="$2"; shift 2 ;;
    --alarm-pass) ALARM_PASS="$2"; shift 2 ;;
    --beta-version) BETA_VERSION="$2"; shift 2 ;;
    --enable-kde-beta) ENABLE_KDE_BETA="$2"; shift 2 ;;
    --enable-bigscreen) ENABLE_BIGSCREEN="$2"; shift 2 ;;
    --enable-union) ENABLE_UNION="$2"; shift 2 ;;
    --reboot-after-bootstrap) REBOOT_AFTER_BOOTSTRAP="$2"; shift 2 ;;
    --wifi-ssid) WIFI_SSID="$2"; shift 2 ;;
    --wifi-psk) WIFI_PSK="$2"; shift 2 ;;
    --skip-package-install) SKIP_PACKAGE_INSTALL="1"; shift ;;
    --safe-firstboot) SAFE_FIRSTBOOT="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ "$ENABLE_KDE_BETA" =~ ^[01]$ ]] || die "--enable-kde-beta must be 0 or 1"
[[ "$ENABLE_BIGSCREEN" =~ ^[01]$ ]] || die "--enable-bigscreen must be 0 or 1"
[[ "$ENABLE_UNION" =~ ^[01]$ ]] || die "--enable-union must be 0 or 1"
[[ "$REBOOT_AFTER_BOOTSTRAP" =~ ^[01]$ ]] || die "--reboot-after-bootstrap must be 0 or 1"
[[ "$SAFE_FIRSTBOOT" =~ ^[01]$ ]] || die "--safe-firstboot must be 0 or 1"
[[ "$GROW_ROOTFS" =~ ^[01]$ ]] || die "--grow-rootfs must be 0 or 1"
[[ -z "$ROOTFS_START_SECTOR" || "$ROOTFS_START_SECTOR" =~ ^[0-9]+$ ]] || die "--rootfs-start-sector must be an integer"
[[ -z "$ROOTFS_SIZE_SECTORS" || "$ROOTFS_SIZE_SECTORS" =~ ^[0-9]+$ ]] || die "--rootfs-size-sectors must be an integer"
[[ $EUID -eq 0 ]] || die "Run as root (or via sudo)."

for c in awk blkid bsdtar cp curl install losetup lsblk mkfs.ext4 mount openssl rsync sed sgdisk truncate umount uuidgen; do
  need_cmd "$c"
done

# QEMU aarch64 emulation is required for package pre-installation
NEED_QEMU_CMDS="0"
if [[ "$SKIP_PACKAGE_INSTALL" != "1" ]]; then
  NEED_QEMU_CMDS="1"
fi
if [[ -n "$WIFI_SSID" && -n "$WIFI_PSK" ]]; then
  NEED_QEMU_CMDS="1"
fi
if [[ "$NEED_QEMU_CMDS" == "1" ]]; then
  for c in arch-chroot qemu-aarch64-static; do
    need_cmd "$c"
  done
fi

[[ -f "$STOCK_IMG" ]] || die "Stock image not found: $STOCK_IMG"
[[ -d "$OVERLAY_DIR" ]] || die "Overlay directory missing: $OVERLAY_DIR"

mkdir -p "$(dirname "$OUTPUT_IMG")"

WORK_DIR="$(mktemp -d /tmp/rgds-arch-build.XXXXXX)"
MNT_DIR="$WORK_DIR/mnt"
TARBALL="$WORK_DIR/ArchLinuxARM-aarch64-latest.tar.gz"
LOOP_DEV=""
ROOT_LOOP_DEV=""

PARTITION_MAP="${REPO_DIR}/analysis/partition_map.tsv"
if [[ -z "$ROOTFS_START_SECTOR" || -z "$ROOTFS_SIZE_SECTORS" ]]; then
  if [[ -f "$PARTITION_MAP" ]]; then
    map_vals="$(awk -F'\t' '$1=="rootfs"{print $2 " " $3}' "$PARTITION_MAP")"
    if [[ -n "$map_vals" ]]; then
      map_start="$(awk '{print $1}' <<<"$map_vals")"
      map_end="$(awk '{print $2}' <<<"$map_vals")"
      [[ -n "$ROOTFS_START_SECTOR" ]] || ROOTFS_START_SECTOR="$map_start"
      if [[ -z "$ROOTFS_SIZE_SECTORS" ]]; then
        ROOTFS_SIZE_SECTORS="$((map_end - map_start + 1))"
      fi
    fi
  fi
fi

ROOTFS_START_SECTOR="${ROOTFS_START_SECTOR:-491520}"
ROOTFS_SIZE_SECTORS="${ROOTFS_SIZE_SECTORS:-14680064}"

cleanup() {
  set +e
  mountpoint -q "$MNT_DIR" && umount -R "$MNT_DIR"
  [[ -n "$ROOT_LOOP_DEV" ]] && losetup -d "$ROOT_LOOP_DEV"
  [[ -n "$LOOP_DEV" ]] && losetup -d "$LOOP_DEV"
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

echo "[1/8] Copying stock image to $OUTPUT_IMG"
cp --reflink=auto "$STOCK_IMG" "$OUTPUT_IMG"

# The stock image ships with a deliberately stale backup GPT location. Clean it
# in the generated image so flashing does not require a manual `sgdisk -e`.
# The last stock partition ends on the final image sector, so append the 33
# sectors GPT needs for the backup entry table plus backup header.
echo "[1b/8] GPT: relocate backup header to image end"
truncate -s +16896 "$OUTPUT_IMG"
sgdisk -e "$OUTPUT_IMG" >/dev/null

# Optional: grow rootfs to reclaim adjacent 'ports' space. Keep this disabled by
# default while debugging boot, because deleting a stock partition adds another
# variable. Always restore rootfs PARTUUID because the stock kernel cmdline uses
# root=PARTUUID=614e0000-0000.
if [[ "$GROW_ROOTFS" == "1" ]]; then
  echo "[1c/8] GPT: absorb ports/vendor/oem/userdata into rootfs (~11.5 GiB)"
  ROOTFS_NEW_END=24608767  # end-LBA of stock userdata partition
  ROOTFS_START_SECTOR="${ROOTFS_START_SECTOR:-491520}"
  ROOTFS_SIZE_SECTORS="$((ROOTFS_NEW_END - ROOTFS_START_SECTOR + 1))"

  python3 - "$STOCK_IMG" "$OUTPUT_IMG" "$ROOTFS_NEW_END" <<'PYEOF'
import sys, struct, zlib
stock, out, new_end = sys.argv[1], sys.argv[2], int(sys.argv[3])
# Read stock rootfs PARTUUID bytes from entry 5 (byte 1664 + 16)
with open(stock, 'rb') as f:
    f.seek(1664 + 16); stock_partuuid = f.read(16)
print(f"  Stock rootfs PARTUUID bytes: {stock_partuuid.hex()}")
with open(out, 'r+b') as f:
    # Extend rootfs end-LBA to absorb partitions 7-10
    f.seek(1664 + 40); f.write(struct.pack('<Q', new_end))
    # Zero entries 6..9 (ports, vendor, oem, userdata) - bytes 1792..2303
    f.seek(1792); f.write(b'\x00' * (128 * 4))
    # Restore stock rootfs PARTUUID (defensive against tool-induced drift)
    f.seek(1664 + 16); f.write(stock_partuuid)
    # Recompute entries CRC32 (LBA 2..33 = 128 entries * 128 bytes)
    f.seek(2 * 512); ent = f.read(32 * 512)
    pe_crc = zlib.crc32(ent) & 0xFFFFFFFF
    f.seek(600); f.write(struct.pack('<I', pe_crc))
    # Recompute header CRC32
    f.seek(512); hdr = bytearray(f.read(92))
    hdr[16:20] = b'\x00\x00\x00\x00'
    hdr_crc = zlib.crc32(bytes(hdr)) & 0xFFFFFFFF
    f.seek(528); f.write(struct.pack('<I', hdr_crc))
print(f"  Entries CRC32: 0x{pe_crc:08x}")
print(f"  Header  CRC32: 0x{hdr_crc:08x}")
print(f"  rootfs end LBA: {new_end}")
PYEOF
  sgdisk -e "$OUTPUT_IMG" >/dev/null
fi

echo "[2/8] Attaching loop device"
LOOP_DEV="$(losetup --show -fP "$OUTPUT_IMG")"
sleep 1

ROOT_PART=""
if [[ -b "${LOOP_DEV}p6" ]]; then
  ROOT_PART="${LOOP_DEV}p6"
else
  ROOT_PART="$(lsblk -lnpo NAME,PARTLABEL "$LOOP_DEV" | awk '$2 == "rootfs" { print $1; exit }')"
fi
if [[ -z "$ROOT_PART" ]]; then
  root_offset="$((ROOTFS_START_SECTOR * 512))"
  root_sizelimit="$((ROOTFS_SIZE_SECTORS * 512))"
  echo "Partition node not found, using rootfs offset mapping: start=${ROOTFS_START_SECTOR} size=${ROOTFS_SIZE_SECTORS} sectors"
  ROOT_LOOP_DEV="$(losetup --show -f -o "$root_offset" --sizelimit "$root_sizelimit" "$OUTPUT_IMG")"
  ROOT_PART="$ROOT_LOOP_DEV"
fi
[[ -n "$ROOT_PART" ]] || die "Could not map rootfs partition in $OUTPUT_IMG"

echo "[3/8] Formatting rootfs partition ($ROOT_PART)"
mkfs.ext4 -F -L rootfs "$ROOT_PART" >/dev/null

echo "[4/8] Mounting rootfs"
mkdir -p "$MNT_DIR"
mount "$ROOT_PART" "$MNT_DIR"

echo "[5/8] Downloading Arch Linux ARM rootfs"
curl -L --retry 3 --retry-delay 2 -o "$TARBALL" "$ARCH_ROOTFS_URL"

echo "[6/8] Extracting Arch Linux ARM rootfs"
bsdtar -xpf "$TARBALL" -C "$MNT_DIR"

echo "[7/8] Applying RG DS overlay"
rsync -a "$OVERLAY_DIR"/ "$MNT_DIR"/
chmod +x \
  "$MNT_DIR/usr/local/sbin/rgds-firstboot.sh" \
  "$MNT_DIR/usr/local/sbin/rgds-wifibt-init.sh"

# The 'alarm' user already exists in the ALARM tarball (uid 1000), so /etc/skel
# is never consulted for its home. Anything the overlay drops into /home/alarm
# must be re-owned to alarm:alarm here.
if [[ -d "$MNT_DIR/home/alarm" ]]; then
  chown -R 1000:1000 "$MNT_DIR/home/alarm"
fi

mkdir -p "$MNT_DIR/etc/systemd/system/multi-user.target.wants"
mkdir -p "$MNT_DIR/etc/systemd/system/sysinit.target.wants"
ln -sf /etc/systemd/system/rgds-firstboot.service \
  "$MNT_DIR/etc/systemd/system/multi-user.target.wants/rgds-firstboot.service"
ln -sf /etc/systemd/system/rgds-wifibt.service \
  "$MNT_DIR/etc/systemd/system/multi-user.target.wants/rgds-wifibt.service"

ROOT_PARTUUID="$(blkid -s PARTUUID -o value "$ROOT_PART" 2>/dev/null || true)"
ROOT_FSTAB_SPEC="LABEL=rootfs"
if [[ -n "$ROOT_PARTUUID" ]]; then
  ROOT_FSTAB_SPEC="PARTUUID=${ROOT_PARTUUID}"
fi

echo "$HOSTNAME" > "$MNT_DIR/etc/hostname"
cat > "$MNT_DIR/etc/fstab" <<EOF
${ROOT_FSTAB_SPEC} / ext4 rw,noatime,discard 0 1
EOF

ROOT_HASH="$(openssl passwd -6 "$ROOT_PASS")"
ALARM_HASH="$(openssl passwd -6 "$ALARM_PASS")"
sed -i -E "s#^root:[^:]*:#root:${ROOT_HASH}:#" "$MNT_DIR/etc/shadow"
if grep -q '^alarm:' "$MNT_DIR/etc/shadow"; then
  sed -i -E "s#^alarm:[^:]*:#alarm:${ALARM_HASH}:#" "$MNT_DIR/etc/shadow"
fi

cat > "$MNT_DIR/etc/rgds-plasma-bootstrap.conf" <<EOF
RGDS_HOSTNAME="${HOSTNAME}"
RGDS_ENABLE_KDE_BETA="${ENABLE_KDE_BETA}"
RGDS_ENABLE_BIGSCREEN="${ENABLE_BIGSCREEN}"
RGDS_ENABLE_UNION="${ENABLE_UNION}"
RGDS_PLASMA_BETA_VERSION="${BETA_VERSION}"
RGDS_REBOOT_AFTER_BOOTSTRAP="${REBOOT_AFTER_BOOTSTRAP}"
RGDS_AUTOLOGIN_USER="alarm"
RGDS_BETA_MODULES="libplasma kwin plasma-workspace plasma-desktop union plasma-bigscreen"
EOF

# ---------------------------------------------------------------------------
# WiFi pre-configuration (optional)
# ---------------------------------------------------------------------------
if [[ -n "$WIFI_SSID" && -n "$WIFI_PSK" ]]; then
  echo "[7b/8] Pre-configuring WiFi SSID=\"$WIFI_SSID\""
  mkdir -p "$MNT_DIR/etc/NetworkManager/system-connections"
  # Generate a proper NM connection file
  NM_UUID="$(uuidgen 2>/dev/null || echo "rgds-$(date +%s)")"
  cat > "$MNT_DIR/etc/NetworkManager/system-connections/RGDS.nmconnection" <<NMEOF
[connection]
id=RGDS
uuid=${NM_UUID}
type=wifi
interface-name=wlan0
autoconnect=true

[wifi]
mode=infrastructure
ssid=${WIFI_SSID}

[wifi-security]
key-mgmt=wpa-psk
psk=${WIFI_PSK}

[ipv4]
method=auto

[ipv6]
method=auto
NMEOF
  chmod 600 "$MNT_DIR/etc/NetworkManager/system-connections/RGDS.nmconnection"
fi

# ---------------------------------------------------------------------------
# Package pre-installation via QEMU aarch64 emulation
# ---------------------------------------------------------------------------
if [[ "$SKIP_PACKAGE_INSTALL" != "1" ]]; then
  echo "[7c/8] Pre-installing packages via QEMU aarch64 emulation"

  # Ensure qemu-user-static-binfmt is installed and binfmt registered
  if ! grep -q "qemu-aarch64" /proc/sys/fs/binfmt_misc/qemu-aarch64 2>/dev/null; then
    pacman -Q qemu-user-static-binfmt &>/dev/null || pacman -S --noconfirm qemu-user-static-binfmt
    systemctl restart systemd-binfmt
  fi

  # Copy QEMU static binary into chroot (arch-chroot expects it here)
  cp "$(which qemu-aarch64-static)" "$MNT_DIR/usr/bin/qemu-aarch64-static"

  # QEMU emulation doesn't support pacman's Landlock sandbox.
  PACMD="pacman --disable-sandbox --noconfirm"
  # Pre-answer provider prompts with default choices (ttf-font=1, jack=1, qt6-multimedia=1)
  PROVIDER_ANS="printf '1\n1\n1\n'"
  # Clear pacman cache to maximize free space between installs
  CLEAN_CACHE="rm -rf /var/cache/pacman/pkg/*"

  echo "  -> Initializing pacman keyring..."
  arch-chroot "$MNT_DIR" /usr/bin/bash -c "pacman-key --init && pacman-key --populate archlinuxarm" || true

  echo "  -> Updating package databases..."
  arch-chroot "$MNT_DIR" /usr/bin/bash -c "$PACMD -Sy && $CLEAN_CACHE" || true

  echo "  -> Pre-installing provider packages to avoid selection prompts..."
  arch-chroot "$MNT_DIR" /usr/bin/bash -c "$PROVIDER_ANS | $PACMD -S --needed \
    ttf-dejavu jack2 qt6-multimedia-ffmpeg && $CLEAN_CACHE" 2>/dev/null || true

  echo "  -> Installing base display stack (SDDM, Plasma, Qt6 - highest priority)..."
  arch-chroot "$MNT_DIR" /usr/bin/bash -c "$PROVIDER_ANS | $PACMD -S --needed \
    sddm plasma-desktop plasma-workspace kscreen \
    qt6-wayland \
    pipewire wireplumber \
    xdg-desktop-portal-kde && $CLEAN_CACHE" || true

  echo "  -> Installing network stack (NetworkManager, wpa_supplicant)..."
  arch-chroot "$MNT_DIR" /usr/bin/bash -c "$PROVIDER_ANS | $PACMD -S --needed \
    networkmanager wpa_supplicant \
    plasma-nm && $CLEAN_CACHE" || true

  echo "  -> Installing Bluetooth stack..."
  arch-chroot "$MNT_DIR" /usr/bin/bash -c "$PROVIDER_ANS | $PACMD -S --needed \
    bluez bluez-utils && $CLEAN_CACHE" || true

  echo "  -> Installing on-screen keyboard (plasma-keyboard)..."
  arch-chroot "$MNT_DIR" /usr/bin/bash -c "$PROVIDER_ANS | $PACMD -S --needed \
    plasma-keyboard && $CLEAN_CACHE" || true

  echo "  -> Installing utilities (if space permits)..."
  arch-chroot "$MNT_DIR" /usr/bin/bash -c "$PROVIDER_ANS | $PACMD -S --needed \
    dolphin konsole kde-cli-tools && $CLEAN_CACHE" 2>/dev/null || true

  echo "  -> Enabling services..."
  arch-chroot "$MNT_DIR" /usr/bin/bash -c '
    systemctl enable NetworkManager 2>/dev/null || true
    systemctl enable bluetooth 2>/dev/null || true
    systemctl enable sddm 2>/dev/null || true
    systemctl set-default graphical.target 2>/dev/null || true
  '

  echo "  -> Final cleanup..."
  rm -f "$MNT_DIR/usr/bin/qemu-aarch64-static"
  rm -rf "$MNT_DIR/var/cache/pacman/pkg/"*
fi

if [[ -d "$STOCK_ROOTFS" ]]; then
  echo "[7d/8] Importing stock WiFi/BT compatibility blobs"
  mkdir -p "$MNT_DIR/lib/modules" "$MNT_DIR/usr/bin" "$MNT_DIR/lib/firmware"

  shopt -s nullglob
  for ko in "$STOCK_ROOTFS"/lib/modules/*.ko; do
    install -m 0644 "$ko" "$MNT_DIR/lib/modules/"
  done
  shopt -u nullglob

  for bin in rtk_hciattach rk_hciattach wifibt-init.sh wifibt-util.sh; do
    if [[ -f "$STOCK_ROOTFS/usr/bin/$bin" ]]; then
      install -m 0755 "$STOCK_ROOTFS/usr/bin/$bin" "$MNT_DIR/usr/bin/$bin"
    fi
  done

  for link in wifibt-bus wifibt-chip wifibt-id wifibt-info wifibt-module wifibt-vendor; do
    if [[ -e "$MNT_DIR/usr/bin/wifibt-util.sh" ]]; then
      ln -sf wifibt-util.sh "$MNT_DIR/usr/bin/$link"
    fi
  done

  if [[ -d "$STOCK_ROOTFS/lib/firmware" ]]; then
    rsync -a "$STOCK_ROOTFS/lib/firmware/rtl"* "$MNT_DIR/lib/firmware/" 2>/dev/null || true
    rsync -a "$STOCK_ROOTFS/lib/firmware/rtlbt" "$MNT_DIR/lib/firmware/" 2>/dev/null || true
  fi
else
  echo "WARN: Stock rootfs extract not found ($STOCK_ROOTFS), skipping WiFi/BT compatibility import."
fi

# ---------------------------------------------------------------------------
# First-boot safety net: boot to multi-user + autologin tty1, defer Plasma.
# Stock kernel cmdline is console=ttyFIQ0 only (UART). If SDDM/Plasma fails
# silently, the panel stays dark and you can't see what went wrong. Booting
# to multi-user with an autologin getty on tty1 gives a visible shell on the
# panel framebuffer (when fbcon is bound to tty1) so you can debug.
# ---------------------------------------------------------------------------
# Always install /root/rgds-enable-graphical.sh so the user can flip later.
install -m 0755 /dev/stdin "$MNT_DIR/root/rgds-enable-graphical.sh" <<'EOF'
#!/usr/bin/env bash
# Run on the device after confirming console boot works.
# Switches default systemd target to graphical and enables the Plasma firstboot.
set -e
systemctl enable rgds-firstboot.service
systemctl set-default graphical.target
echo "graphical.target set as default; rgds-firstboot.service enabled."
echo "Reboot to start Plasma first-boot bootstrap."
EOF

if [[ "$SAFE_FIRSTBOOT" == "1" ]]; then
  echo "[7e/8] Applying first-boot safety net (multi-user + tty1 autologin)"
  ln -sfn /usr/lib/systemd/system/multi-user.target "$MNT_DIR/etc/systemd/system/default.target"
  rm -f "$MNT_DIR/etc/systemd/system/multi-user.target.wants/rgds-firstboot.service"
  mkdir -p "$MNT_DIR/etc/systemd/system/getty@tty1.service.d"
  cat > "$MNT_DIR/etc/systemd/system/getty@tty1.service.d/autologin.conf" <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty -o "-p -f -- \\\\u" --noclear --autologin root --keep-baud 115200,38400,9600 %I \$TERM
EOF
  cat > "$MNT_DIR/etc/issue" <<EOF
RG DS Arch (safe-firstboot mode)
Boot: stock kernel/uboot/DTB + Arch userspace.
Plasma firstboot DEFERRED. To enable graphical + KDE: run /root/rgds-enable-graphical.sh

EOF
fi

echo "[8/8] Finalizing image"
# Ensure QEMU binary is cleaned up if something went wrong
rm -f "$MNT_DIR/usr/bin/qemu-aarch64-static"
sync
umount -R "$MNT_DIR"
if [[ -n "$ROOT_LOOP_DEV" ]]; then
  losetup -d "$ROOT_LOOP_DEV"
  ROOT_LOOP_DEV=""
fi
losetup -d "$LOOP_DEV"
LOOP_DEV=""

# Final verification: the stock kernel cmdline matches PARTUUID prefix 614e0000-0000.
# If anything in the build chain (gdisk/parted/udev hooks) rewrote the rootfs
# PARTUUID, kernel will never find the rootfs and the device will hang after the
# bootloader. Verify before declaring success.
python3 - "$OUTPUT_IMG" <<'PYEOF'
import sys, struct
with open(sys.argv[1], 'rb') as f:
    f.seek(1664 + 16); u = f.read(16)
d1=struct.unpack_from('<I',u,0)[0]; d2=struct.unpack_from('<H',u,4)[0]; d3=struct.unpack_from('<H',u,6)[0]
partuuid = f"{d1:08x}-{d2:04x}-{d3:04x}-{u[8:10].hex()}-{u[10:16].hex()}"
if not partuuid.startswith("614e0000-0000"):
    print(f"FATAL: rootfs PARTUUID={partuuid} does not match stock kernel cmdline prefix 614e0000-0000")
    sys.exit(1)
print(f"OK: rootfs PARTUUID={partuuid} matches stock kernel cmdline prefix.")
PYEOF

echo
echo "Done: $OUTPUT_IMG"
echo "Next: flash image to SD and boot RG DS."
if [[ "$SAFE_FIRSTBOOT" == "1" ]]; then
  echo "Safe-firstboot mode: boots to multi-user.target with autologin root on tty1."
  echo "If you see a console login, run /root/rgds-enable-graphical.sh + reboot to start Plasma."
elif [[ "$SKIP_PACKAGE_INSTALL" == "1" ]]; then
  echo "First boot runs /usr/local/sbin/rgds-firstboot.sh (will install packages - needs network)."
else
  echo "Packages pre-installed at build time. First boot should reach SDDM login quickly."
fi
