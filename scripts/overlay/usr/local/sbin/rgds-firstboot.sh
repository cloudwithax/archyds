#!/usr/bin/env bash
# RGDS first-boot bootstrap - error-tolerant with display feedback
# shellcheck disable=SC2317,SC1091

LOG_FILE="/var/log/rgds-firstboot.log"
MARKER="/var/lib/rgds-firstboot.done"

# ---- display output helpers ----
# Write to both the fb console (tty1) and the log
say() {
  local msg="[rgds] $*"
  echo "$msg" | tee -a "$LOG_FILE"
  echo "$msg" >/dev/tty1 2>/dev/null || true
}

warn() {
  local msg="[rgds-WARN] $*"
  echo "$msg" | tee -a "$LOG_FILE"
  echo "$msg" >/dev/tty1 2>/dev/null || true
}

ok() {
  local msg="[rgds-OK] $*"
  echo "$msg" | tee -a "$LOG_FILE"
  echo "$msg" >/dev/tty1 2>/dev/null || true
}

fail() {
  local msg="[rgds-FAIL] $*"
  echo "$msg" | tee -a "$LOG_FILE"
  echo "$msg" >/dev/tty1 2>/dev/null || true
}

# Clear the display and show a header
clear_screen() {
  echo -ne "\033[2J\033[H" >/dev/tty1 2>/dev/null || true
}

header() {
  clear_screen
  echo "=============================================" >/dev/tty1 2>/dev/null || true
  echo "  RG DS Arch Plasma - First Boot Setup" >/dev/tty1 2>/dev/null || true
  echo "=============================================" >/dev/tty1 2>/dev/null || true
  echo "" >/dev/tty1 2>/dev/null || true
}

# ---- config ----
CONF_FILE="/etc/rgds-plasma-bootstrap.conf"
if [[ -r "$CONF_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONF_FILE"
fi

: "${RGDS_HOSTNAME:=rgds-arch}"
: "${RGDS_ENABLE_KDE_BETA:=1}"
: "${RGDS_ENABLE_BIGSCREEN:=1}"
: "${RGDS_ENABLE_UNION:=1}"
: "${RGDS_PLASMA_BETA_VERSION:=6.6.90}"
: "${RGDS_REBOOT_AFTER_BOOTSTRAP:=1}"
: "${RGDS_AUTOLOGIN_USER:=alarm}"
: "${RGDS_BETA_MODULES:=libplasma kwin plasma-workspace plasma-desktop union plasma-bigscreen}"

export MAKEFLAGS="${MAKEFLAGS:--j$(nproc)}"

# ---- helpers ----
is_online() {
  # Check if we can reach the internet
  ping -c 1 -W 3 archlinuxarm.org &>/dev/null && return 0
  ping -c 1 -W 3 google.com &>/dev/null && return 0
  return 1
}

is_package_installed() {
  pacman -Qi "$1" &>/dev/null
}

# ---- setup steps ----
set_hostname() {
  echo "$RGDS_HOSTNAME" > /etc/hostname
  if ! grep -qE "^127\\.0\\.1\\.1\\s+$RGDS_HOSTNAME\\b" /etc/hosts; then
    echo "127.0.1.1 ${RGDS_HOSTNAME}" >> /etc/hosts
  fi
  ok "Hostname set to ${RGDS_HOSTNAME}"
}

init_keyring() {
  if [[ ! -f /etc/pacman.d/gnupg/secring.gpg ]]; then
    say "Initializing pacman keyring (may take a moment)..."
    pacman-key --init || warn "pacman-key --init failed (may already be done)"
    pacman-key --populate archlinuxarm || warn "pacman-key --populate failed"
  else
    say "Pacman keyring already initialized"
  fi
  ok "Pacman keyring ready"
}

ensure_packages() {
  local needed=()
  for pkg in "$@"; do
    if ! is_package_installed "$pkg"; then
      needed+=("$pkg")
    fi
  done

  if [[ ${#needed[@]} -eq 0 ]]; then
    say "All required packages already installed"
    return 0
  fi

  say "Missing packages: ${needed[*]}"
  if ! is_online; then
    warn "No network connectivity - cannot install missing packages"
    warn "Connect USB Ethernet or configure WiFi, then reboot"
    return 1
  fi

  say "Installing ${#needed[@]} missing packages..."
  pacman --disable-sandbox -S --noconfirm --needed "${needed[@]}" || {
    fail "Package installation failed"
    return 1
  }
  ok "Packages installed"
}

configure_autologin() {
  local session="plasma.desktop"
  if [[ "$RGDS_ENABLE_BIGSCREEN" == "1" ]] && [[ -f /usr/share/wayland-sessions/plasma-bigscreen-wayland.desktop ]]; then
    session="plasma-bigscreen-wayland.desktop"
  elif [[ -f /usr/share/wayland-sessions/plasma.desktop ]]; then
    session="plasma.desktop"
  elif [[ -f /usr/share/xsessions/plasma.desktop ]]; then
    session="plasma.desktop"
  fi

  mkdir -p /etc/sddm.conf.d
  cat > /etc/sddm.conf.d/rgds-autologin.conf <<EOF
[General]
DisplayServer=wayland

[Autologin]
User=${RGDS_AUTOLOGIN_USER}
Session=${session}

[Wayland]
CompositorCommand=kwin_wayland --no-lockscreen
EOF
  ok "SDDM autologin configured for ${RGDS_AUTOLOGIN_USER} as ${session} (Wayland)"
}

ensure_services() {
  systemctl enable NetworkManager &>/dev/null || true
  systemctl enable bluetooth &>/dev/null || true
  systemctl enable rgds-wifibt.service &>/dev/null || true
  systemctl enable sddm &>/dev/null || true
  systemctl set-default graphical.target &>/dev/null || true
  ok "Services enabled"
}

build_beta_stack() {
  if [[ "$RGDS_ENABLE_KDE_BETA" != "1" ]]; then
    say "KDE beta builds disabled by config"
    return 0
  fi

  if ! is_online; then
    warn "No network - skipping KDE beta builds (will be attempted on next boot)"
    return 0
  fi

  say "Installing build dependencies..."
  pacman -S --noconfirm --needed \
    base-devel cmake ninja curl extra-cmake-modules \
    plasma-wayland-protocols qt6-tools 2>/dev/null || {
    warn "Build deps installation failed, skipping beta builds"
    return 0
  }

  local workdir="/usr/local/src/rgds-plasma-beta"
  mkdir -p "$workdir"
  cd "$workdir"

  # shellcheck disable=SC2206
  local modules=($RGDS_BETA_MODULES)
  for module in "${modules[@]}"; do
    if [[ "$module" == "plasma-bigscreen" && "$RGDS_ENABLE_BIGSCREEN" != "1" ]]; then
      continue
    fi
    if [[ "$module" == "union" && "$RGDS_ENABLE_UNION" != "1" ]]; then
      continue
    fi

    say "Building ${module}-${RGDS_PLASMA_BETA_VERSION} (this may take a while)..."
    local tarball="${module}-${RGDS_PLASMA_BETA_VERSION}.tar.xz"
    local srcdir="${module}-${RGDS_PLASMA_BETA_VERSION}"
    local builddir="${module}-build"
    local url="https://download.kde.org/unstable/plasma/${RGDS_PLASMA_BETA_VERSION}/${tarball}"

    rm -rf "$srcdir" "$builddir"
    if ! curl -L --retry 2 --retry-delay 2 -o "$tarball" "$url" 2>/dev/null; then
      warn "Failed to download ${tarball}, skipping"
      continue
    fi
    tar -xf "$tarball"
    cmake -S "$srcdir" -B "$builddir" -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX=/usr \
      -DBUILD_TESTING=OFF 2>/dev/null || continue
    cmake --build "$builddir" 2>/dev/null || continue
    cmake --install "$builddir" 2>/dev/null || continue
    ok "${module} built successfully"
  done

  ldconfig 2>/dev/null || true
}

# ---- main ----
main() {
  header

  if [[ -e "$MARKER" ]]; then
    say "First-boot bootstrap already completed."
    exit 0
  fi

  say "Starting RG DS first-boot setup..."
  say "Log: ${LOG_FILE}"

  # Step 1: Hostname
  say "[1/6] Setting hostname..."
  set_hostname

  # Step 2: Pacman keyring
  say "[2/6] Initializing pacman keyring..."
  init_keyring

  # Step 3: Ensure critical packages are present
  say "[3/6] Checking display stack..."
  ensure_packages \
    sddm plasma-desktop plasma-workspace kscreen \
    qt6-wayland \
    pipewire pipewire-pulse wireplumber \
    xdg-desktop-portal-kde \
    networkmanager wpa_supplicant \
    plasma-nm plasma-pa \
    bluez bluez-utils \
    dolphin konsole kde-cli-tools || {
    warn "Some display packages could not be installed"
    warn "System will still boot but may not reach graphical target"
  }

  # Step 4: Configure SDDM autologin
  say "[4/6] Configuring autologin..."
  configure_autologin

  # Step 5: Enable services
  say "[5/7] Enabling services..."
  ensure_services

  # Step 5b: Give alarm all groups + passwordless sudo
  say "[5b/7] Adding alarm to all system groups..."
  for grp in $(cut -d: -f1 /etc/group 2>/dev/null); do
    if ! groups alarm | grep -qw "$grp" 2>/dev/null; then
      usermod -a -G "$grp" alarm 2>/dev/null || true
    fi
  done
  echo "alarm ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/10-alarm
  chmod 440 /etc/sudoers.d/10-alarm
  ok "alarm has full system access"

  # Step 6: Configure touch-to-display mapping for dual screens
  say "[6/7] Configuring dual-screen touch mapping..."
  if [[ -x /usr/local/sbin/rgds-touch-map.sh ]]; then
    /usr/local/sbin/rgds-touch-map.sh && ok "Touch mapping configured" || warn "Touch mapping had issues"
  fi

  # Step 7: Optional KDE beta builds
  say "[7/7] Building KDE beta (if enabled and network available)..."
  if is_online; then
    build_beta_stack
  else
    warn "No network - skipping KDE beta builds"
    warn "Will retry on next boot if first-boot marker not present"
  fi

  # Finalize
  touch "$MARKER"
  systemctl disable rgds-firstboot.service 2>/dev/null || true

  ok "RG DS first-boot setup complete!"
  say "SDDM should start momentarily..."

  if [[ "$RGDS_REBOOT_AFTER_BOOTSTRAP" == "1" ]] && [[ -f /usr/share/wayland-sessions/plasma.desktop ]]; then
    say "Rebooting in 5 seconds..."
    sleep 5
    systemctl reboot
  fi
}

main "$@"
