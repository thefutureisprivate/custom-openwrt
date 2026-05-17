# custom-openwrt

Custom OpenWrt build for the AVM FRITZ!Box 7530, based on DivestedWRT
hardening patches.

## Build

Prepare caches and the container image:

```sh
./custom-openwrt.sh prepare
```

Build the firmware:

```sh
./custom-openwrt.sh build
```

Images are copied to:

```text
build/images/
```

Open menuconfig and write the result back to `.config`:

```sh
./custom-openwrt.sh menuconfig
```

Use a clean compiled build state for one run:

```sh
BUILD_CACHE=0 ./custom-openwrt.sh build
```