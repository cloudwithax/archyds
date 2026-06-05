# Stock WiFi/BT compatibility blobs

Realtek RTL8821CS WiFi/Bluetooth bits lifted from the stock Anbernic RG DS
rootfs (`rgds_sdcard_20260514.img`, partition 6 `rootfs`, sector 491520). The
vendor drivers are out-of-tree against Linux 6.1.141, so Arch can't pull them
from its own repos — the build imports these verbatim instead.

`scripts/build-rgds-arch-plasma67-image.sh` reads this tree by default
(`--stock-rootfs ./analysis/wifibt-blobs`) and, at step `[7d/8]`, copies:

- `lib/modules/*.ko`        → `RTL8821CS.ko`, `hci_uart.ko`, `rtk_btusb.ko`
- `usr/bin/`                → `rtk_hciattach`, `rk_hciattach`, `wifibt-init.sh`, `wifibt-util.sh`
                             (plus `wifibt-{bus,chip,id,info,module,vendor}` symlinks recreated in-image)
- `lib/firmware/`           → `rtl8821c_config`, `rtl8821c_fw`, and the `rtlbt/` dir

The directory mirrors a rootfs subtree so the importer finds each file at the
path it expects.

These are proprietary Anbernic/Realtek vendor blobs, redistributed here only so
the image build is reproducible without re-mounting the stock firmware. They are
not covered by this repo's MIT license.
