#!/bin/bash -e

WIFI_FILE="/var/run/.wifi-interfaces"
BT_FILE="/var/run/.bt-state"
RELOAD_FILE="/var/run/.wifibt-reload"

bt_set_disabled()
{
	rm -f "$BT_FILE"
}

bt_is_disabled()
{
	[ ! -r "$BT_FILE" ]
}

bt_set_enabled()
{
	echo enable > "$BT_FILE"
}

bt_is_enabled()
{
	[ -r "$BT_FILE" ] && grep -wq enable "$BT_FILE"
}

bt_set_suspended()
{
	echo suspend > "$BT_FILE"
}

bt_is_suspended()
{
	[ -r "$BT_FILE" ] && grep -wq suspend "$BT_FILE"
}

# usage: do_insmod <module> [sleep:<time>] [options]
do_insmod()
{
	local MODULE="${1%.ko}.ko" SLEEP=0
	shift

	if lsmod | grep -wq "${MODULE%.ko}"; then
		return 0
	fi

	echo "Installing $MODULE $@..."

	case "$1" in
		"sleep:"*) SLEEP="${1#*:}"; shift ;;
	esac

	insmod "$MODULE" "$@"
	sleep "$SLEEP"
}

try_insmod()
{
	if [ -f "${1%.ko}.ko" ]; then
		do_insmod $@
	fi
}

wifi_interfaces()
{
	for d in /sys/class/net/*; do
		local DEV="$(basename "$d")"
		local UEVENT="$d/uevent"
		case "$DEV" in
			lo | eth*) ;;
			p2p* | wlan*) echo $DEV ;;
			*)
				if [ -f "$UEVENT" ] && \
					grep -wq "DEVTYPE=wlan" "$UEVENT"; then
					echo $DEV
				fi
				;;
		esac
	done
}

wifi_ready()
{
	[ -n "$(wifi_interfaces)" ]
}

bt_ready()
{
	hciconfig | grep -wqE "hci0"
}

wait_wifi()
{
	for i in `seq 60`; do
		if wifi_ready; then
			return 0
		fi
		sleep .1
	done
	return 1
}

wait_bt()
{
	for i in `seq 60`; do
		if bt_ready; then
			return 0
		fi
		sleep .1
	done
	return 1
}

# Blocked init for Broadcom uart BT
init_bt_brcm()
{
	which brcm_patchram_plus1 >/dev/null

	brcm_patchram_plus1 --enable_hci --no2bytes \
		--use_baudrate_for_download --tosleep 200000 \
		--baudrate 1500000 \
		--patchram ${WIFIBT_FIRMWARE_DIR:-/lib/firmware}/ $WIFIBT_TTY
}

# Blocked init for Rockchip uart BT
init_bt_rk_uart()
{
	which rk_hciattach >/dev/null

	rk_hciattach -n -s 115200 $WIFIBT_TTY rockchip 3000000 flow nosleep \
		11:22:33:44:55:66
}

# Blocked init for Realtek uart BT
init_bt_rtk_uart()
{
	which rtk_hciattach >/dev/null

	if ! lsmod | grep -wq hci_uart; then
		if [ -d /sys/module/hci_uart ]; then
			echo "Please disable CONFIG_BT_HCIUART in kernel!"
			return 1
		fi

		do_insmod hci_uart "sleep:0.5"
	fi

	rtk_hciattach -n -s 115200 $WIFIBT_TTY rtk_h5
}

# Blocked init for Realtek USB BT
init_bt_rtk_usb()
{
	if [ -d /sys/module/btusb ]; then
		echo "Please disable CONFIG_BT_HCIBTUSB in kernel!"
		return 1
	fi

	do_insmod rtk_btusb

	# Wait for BT disabled
	while ! bt_is_disabled; do
		sleep 1
	done
}

# Blocked re-init
do_init_bt()
{
	cd "${WIFIBT_MODULE_DIR:-/lib/modules}"

	# Reset BT
	stop_bt
	local RFKILL=$(grep -rl "^bluetooth" /sys/class/rfkill/*/type | \
		sed 's/type$/state/' 2>/dev/null || true)
	if [ "$RFKILL" ]; then
		echo 0 | tee $RFKILL >/dev/null
		echo 0 > /proc/bluetooth/sleep/btwrite
		sleep .5
		echo 1 | tee $RFKILL >/dev/null
		echo 1 > /proc/bluetooth/sleep/btwrite
		sleep .5
	fi

	# Blocked init
	case "$WIFIBT_VENDOR" in
		Rockchip) init_bt_rk_uart;;
		Broadcom) init_bt_brcm;;
		Realtek)
			case "$WIFIBT_BUS" in
				usb) init_bt_rtk_usb;;
				*) init_bt_rtk_uart;;
			esac
			;;
		*)
			echo "Unknown Wi-Fi/BT chip, fallback to Broadcom..."
			init_bt_brcm
			;;
	esac
}

init_bt()
{
	# Mark enabled
	bt_set_enabled

	# BT guardian
	{
		# Keep BT alive when enabled
		while ! bt_is_disabled; do
			# BT suspended
			if bt_is_suspended; then
				sleep .5
				continue
			fi

			# Blocked init
			do_init_bt
		done
	}&

	wait_bt
}

start_bt()
{
	# Ignore start request while suspending
	if bt_is_suspended; then
		echo "BT is suspended..."
		return 1
	fi

	# BT guardian is running?
	if bt_is_enabled; then
		wait_bt || true
	fi

	if bt_ready; then
		echo "BT is already inited..."
		return 0
	fi

	if ! init_bt; then
		echo "Failed to init BT for $WIFIBT_CHIP!"
		bt_set_disabled
		return 1
	fi

	if [ -e "/dev/rfkill" ]; then
		echo "HACK: Remove /dev/rfkill to disable external BT power operations."
		rm -f /dev/rfkill
	fi

	echo "Successfully init BT for $WIFIBT_CHIP!"
}

init_wifi()
{
	echo "Wi-Fi module: $WIFIBT_MODULE"

	case "$WIFIBT_VENDOR" in
		Broadcom) try_insmod dhd_static_buf ;;
		Realtek) try_insmod rtkm ;;
	esac

	do_insmod $(echo $WIFIBT_MODULE | tr ':' ' ')

	wait_wifi
}

enable_wifi()
{
	for iface in $(cat "$WIFI_FILE" 2>/dev/null || true); do
		echo "Enabling $iface..."
		ifup $iface 2>/dev/null || true &
		ifconfig $iface up || true
	done
}

start_wifi()
{
	if wifi_ready; then
		echo "Wi-Fi is already inited..."
		enable_wifi
		return 0
	fi

	if ! init_wifi; then
		echo "Failed to init Wi-Fi for $WIFIBT_CHIP!"
		return 1
	fi

	# Enable all available Wi-Fi interfaces
	wifi_interfaces > "$WIFI_FILE" || true
	enable_wifi

	echo "Successfully init Wi-Fi for $WIFIBT_CHIP!"
}

start_wifibt()
{
	echo -e "\nHandling $1 for Wi-Fi/BT chip:"
	wifibt-util.sh info | xargs

	case "$1" in
		start | restart)
			echo "Starting Wi-Fi/BT..."
			start_bt
			start_wifi
			echo "Done"
			;;
		start_wifi)
			echo "Starting Wi-Fi..."
			start_wifi
			echo "Done"
			;;
		start_bt)
			echo "Starting BT..."
			start_bt
			echo "Done"
			;;
	esac
}

stop_wifi()
{
	for iface in $(wifi_interfaces); do
		echo "Disabling $iface..."
		ifdown $iface 2>/dev/null || true &
		ifconfig $iface down || true
	done
}

stop_bt()
{
	if bt_ready; then
		echo "Disabling BT..."
		hciconfig hci0 down || true
	fi
	killall -q -9 brcm_patchram_plus1 rtk_hciattach rk_hciattach || true
}

stop_wifibt()
{
	echo -n "Stopping Wi-Fi/BT..."
	rm -rf "$WIFI_FILE"
	stop_wifi

	bt_set_disabled
	stop_bt
	echo "Done"
}

unload_wifibt()
{
	rm -rf $RELOAD_FILE

	# Unload Wi-Fi module
	local MODULE_NAME="${WIFIBT_MODULE%.ko*}"
	if lsmod | grep -wq "$MODULE_NAME"; then
		echo "Uninstalling $MODULE_NAME..."
		rmmod $MODULE_NAME || true
		echo "module:$MODULE_NAME" > $RELOAD_FILE
	fi

	local BUS_DEV="$(find /sys/devices/platform/ -name $WIFIBT_DEVICE | \
		cut -d'/' -f5 || true)"
	[ "$BUS_DEV" ] || return 0

	local BUS_DRV="$(realpath "/sys/devices/platform/$BUS_DEV/driver")"
	[ "$BUS_DRV" ] || return 0

	[ -e $BUS_DRV/$BUS_DEV ] || return 0

	echo "bus:$BUS_DEV:$BUS_DRV" >> $RELOAD_FILE

	# Unbind BUS driver to workaround hardware issue
	echo "Unbinding $BUS_DEV..."
	echo "$BUS_DEV" > $BUS_DRV/unbind
}

reload_wifibt()
{
	[ -f "$RELOAD_FILE" ] || return 0

	local MODULE_NAME="$(grep "^module:" "$RELOAD_FILE" | \
		cut -d':' -f2 || true)"
	local BUS_DEV="$(grep "^bus:" "$RELOAD_FILE" | cut -d':' -f2 || true)"
	local BUS_DRV="$(grep "^bus:" "$RELOAD_FILE" | cut -d':' -f3 || true)"
	rm -f "$RELOAD_FILE"

	# Bind BUS driver
	if [ "$BUS_DEV" ] && [ "$BUS_DRV" ] && [ ! -e $BUS_DRV/$BUS_DEV ]; then
		echo "Binding $BUS_DEV..."
		echo "$BUS_DEV" > $BUS_DRV/bind
	fi

	# Reload Wi-Fi module
	if [ "$MODULE_NAME" ]; then
		init_wifi || true
	fi
}

suspend_wifibt()
{
	# Mark BT suspended
	if ! bt_is_disabled; then
		bt_set_suspended

		# Restart BT later in resume, since it might lose power during S2R
		stop_bt
	fi

	# Store enabled Wi-Fi interfaces
	wifi_interfaces > "$WIFI_FILE" || true
	stop_wifi

	case "$WIFIBT_QUIRK" in
		suspend-reload) unload_wifibt ;;
	esac
}

resume_wifibt()
{
	case "$WIFIBT_QUIRK" in
		suspend-reload) reload_wifibt ;;
	esac

	# Retore enabled Wi-Fi interfaces
	enable_wifi

	if ! bt_is_disabled; then
		echo "Enabling BT..."

		# Kick the BT guardian to re-init it
		bt_set_enabled
	fi
}

WIFIBT_CHIP=$(wifibt-util.sh chip || true)
if [ -z "$WIFIBT_CHIP" ]; then
	echo "Failed to detect Wi-Fi/BT chip!"
	exit 1
fi

WIFIBT_VENDOR="$(wifibt-util.sh vendor)"
WIFIBT_BUS="$(wifibt-util.sh bus)"
WIFIBT_DEVICE="$(wifibt-util.sh device)"
WIFIBT_MODULE="$(wifibt-util.sh module)"
WIFIBT_TTY=$(wifibt-util.sh tty)
WIFIBT_QUIRK=$(wifibt-util.sh quirk)

cd "${WIFIBT_MODULE_DIR:-/lib/modules}"

case "$1" in
	start | restart | start_wifi | start_bt | "")
		start_wifibt "${1:-start}" &
		;;
	stop) stop_wifibt ;;
	suspend) suspend_wifibt ;;
	resume) resume_wifibt ;;
	*)
		echo "Usage: [start|stop|start_wifi|start_bt|restart|suspend|resume]" >&2
		exit 3
		;;
esac

:
