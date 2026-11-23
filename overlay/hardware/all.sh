#!/bin/bash
# OmaCachy overlay: hardware setup for a machine that already runs CachyOS.
#
# Upstream's list is written for a machine whose kernel, GPU drivers, power
# management and DKMS state Omarchy created. Here CachyOS/chwd own those, so
# this list deliberately excludes:
#
#   hardware/nvidia.sh, hardware/nvidia-apps.sh   CachyOS (chwd) owns the NVIDIA stack
#   hardware/intel/thermald.sh, intel/lpmd.sh     CachyOS owns power management
#   hardware/dell-xps13-sidecar-amps.sh           DKMS module owned by CachyOS
#   hardware/n1x.sh, hardware/gb10/*              different platform
#
# Everything else is hardware-gated upstream (DMI/lspci checks) and is treated
# as best-effort: a missing DKMS package or firmware blob must not abort the
# desktop setup. The Limine/platform step at the end stays fatal, because the
# boot entries and snapshots depend on it.

optional() {
  local script=$1
  run_logged "$script" || echo "OmaCachy: optional hardware step failed, continuing: ${script##*/}"
}

optional "$OMARCHY_INSTALL/hardware/asus-rog.sh"
optional "$OMARCHY_INSTALL/hardware/framework16.sh"
optional "$OMARCHY_INSTALL/hardware/dell-xps-touchpad-haptics.sh"
optional "$OMARCHY_INSTALL/hardware/surface.sh"

optional "$OMARCHY_INSTALL/hardware/network.sh"
optional "$OMARCHY_INSTALL/hardware/set-wireless-regdom.sh"
optional "$OMARCHY_INSTALL/hardware/fix-fkeys.sh"
optional "$OMARCHY_INSTALL/hardware/fix-synaptic-touchpad.sh"
optional "$OMARCHY_INSTALL/hardware/bluetooth.sh"
optional "$OMARCHY_INSTALL/hardware/vulkan.sh"

optional "$OMARCHY_INSTALL/hardware/intel/video-acceleration.sh"
optional "$OMARCHY_INSTALL/hardware/intel/ipu7-camera.sh"
optional "$OMARCHY_INSTALL/hardware/intel/fix-wifi7-eht.sh"
optional "$OMARCHY_INSTALL/hardware/intel/fred.sh"
optional "$OMARCHY_INSTALL/hardware/intel/sof-firmware.sh"
optional "$OMARCHY_INSTALL/hardware/dell-xps13-ptl-speaker-firmware.sh"

optional "$OMARCHY_INSTALL/hardware/fix-elgato-camlink-4k.sh"
optional "$OMARCHY_INSTALL/hardware/asus/fix-asus-ptl-display-backlight.sh"
optional "$OMARCHY_INSTALL/hardware/asus/fix-asus-ptl-b9406-display.sh"
optional "$OMARCHY_INSTALL/hardware/asus/fix-asus-ptl-b9406-touchpad.sh"
optional "$OMARCHY_INSTALL/hardware/asus/fix-z13-touchpad.sh"
optional "$OMARCHY_INSTALL/hardware/asus/fix-asus-proart-p14-speakers.sh"

optional "$OMARCHY_INSTALL/hardware/lenovo/fix-yoga-pro7-bass-speakers.sh"
optional "$OMARCHY_INSTALL/hardware/lenovo/yoga-slim7x.sh"
optional "$OMARCHY_INSTALL/hardware/lenovo/thinkpad-t14s-camera.sh"

optional "$OMARCHY_INSTALL/hardware/fix-bcm43xx.sh"
optional "$OMARCHY_INSTALL/hardware/fix-surface-keyboard.sh"
optional "$OMARCHY_INSTALL/hardware/fix-yt6801-ethernet-adapter.sh"
optional "$OMARCHY_INSTALL/hardware/fix-tuxedo-backlight.sh"
optional "$OMARCHY_INSTALL/hardware/speaker-tuning.sh"

optional "$OMARCHY_INSTALL/hardware/apple/fix-spi-keyboard.sh"
optional "$OMARCHY_INSTALL/hardware/apple/fix-suspend-nvme.sh"
optional "$OMARCHY_INSTALL/hardware/apple/fix-brcmfmac-supplicant.sh"

# Hardware-specific pacman repositories (T2 Macs), then the platform's boot
# lifecycle hooks: this is what builds the Limine entries/UKIs.
optional "$OMARCHY_INSTALL/hardware/pacman.sh"
run_logged "$OMARCHY_INSTALL/hardware/platform-setup.sh"
