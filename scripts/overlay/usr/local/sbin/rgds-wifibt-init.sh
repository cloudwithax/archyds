#!/usr/bin/env bash
# RG DS WiFi/BT init wrapper. Splits start into WiFi-first then BT, so a
# BT-side failure (e.g. rtk_hciattach hiccup) can't take WiFi down with
# it via the vendor script's `bash -e`. Also runs a direct insmod
# fallback so WiFi still comes up if vendor chip detection misfires, and
# captures a per-boot diagnostic dump to /var/log/rgds-wifibt.log.

set -u

LOG=/var/log/rgds-wifibt.log
VENDOR=/usr/bin/wifibt-init.sh
MODULE=/lib/modules/RTL8821CS.ko

log() {
	printf '[%s] %s\n' "$(date '+%FT%T')" "$*" >> "$LOG"
}

run_logged() {
	log "+ $*"
	"$@" >>"$LOG" 2>&1
	rc=$?
	log "= rc=$rc"
	return $rc
}

dump_state() {
	{
		echo
		echo "--- $1 ---"
		echo "lsmod (wifi/bt related):"
		lsmod | grep -iE 'rtl|hci|btusb|cfg80211|mac80211' || true
		echo "ip link:"
		ip -br link 2>/dev/null || true
		echo "/sys/class/net:"
		ls /sys/class/net 2>/dev/null || true
		echo "/sys/bus/sdio/devices:"
		ls -l /sys/bus/sdio/devices 2>/dev/null || true
		echo "/sys/class/bluetooth:"
		ls -l /sys/class/bluetooth 2>/dev/null || true
		echo "rfkill:"
		rfkill list 2>/dev/null || true
		echo "wifibt-util.sh info:"
		/usr/bin/wifibt-util.sh info 2>&1 || true
	} >>"$LOG"
}

wait_wlan() {
	for _ in $(seq 60); do
		for n in /sys/class/net/*; do
			[ -e "$n/uevent" ] || continue
			if grep -wq DEVTYPE=wlan "$n/uevent" 2>/dev/null; then
				log "wlan iface up: $(basename "$n")"
				return 0
			fi
			case "$(basename "$n")" in
				wlan*|p2p*) log "wlan iface up: $(basename "$n")"; return 0 ;;
			esac
		done
		sleep 0.5
	done
	log "wlan iface never appeared"
	return 1
}

ensure_wifi_module() {
	if lsmod | grep -wq RTL8821CS; then
		log "RTL8821CS already loaded"
		return 0
	fi
	if [ -f "$MODULE" ]; then
		log "direct insmod fallback: $MODULE"
		run_logged insmod "$MODULE" || true
	fi
	lsmod | grep -wq RTL8821CS
}

do_start() {
	mkdir -p "$(dirname "$LOG")"
	log "=== rgds-wifibt start ==="
	dump_state "before"

	if [ -x "$VENDOR" ]; then
		log "calling vendor: $VENDOR start_wifi"
		run_logged "$VENDOR" start_wifi || true
		# vendor backgrounds the actual work; give it a moment then
		# confirm with wait_wlan
		sleep 1
	else
		log "vendor wifibt-init.sh missing; using direct insmod path"
	fi

	if ! wait_wlan; then
		log "wlan not up after vendor flow; trying direct insmod"
		ensure_wifi_module || true
		wait_wlan || log "wlan still down after fallback"
	fi

	if [ -x "$VENDOR" ]; then
		log "calling vendor: $VENDOR start_bt"
		run_logged "$VENDOR" start_bt || true
	fi

	dump_state "after"
	log "=== rgds-wifibt start done ==="
}

do_stop() {
	log "=== rgds-wifibt stop ==="
	if [ -x "$VENDOR" ]; then
		run_logged "$VENDOR" stop || true
	fi
	log "=== rgds-wifibt stop done ==="
}

case "${1:-start}" in
	start)   do_start ;;
	stop)    do_stop ;;
	restart) do_stop; do_start ;;
	*) echo "Usage: $0 [start|stop|restart]" >&2; exit 2 ;;
esac
