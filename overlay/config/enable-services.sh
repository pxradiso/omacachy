#!/bin/bash
# omacachy overlay: CachyOS-aware service enablement.
#
# Same intent as upstream (enable services only, reboot afterwards), but every
# unit is optional: a CachyOS install may not ship linux-modules-cleanup,
# power-profiles-daemon or NetworkManager, and `systemctl enable` on a missing
# unit returns non-zero, which would abort the whole Omarchy setup.

enable_if_present() {
  local unit=$1
  if systemctl list-unit-files --no-legend --no-pager "$unit" 2>/dev/null | grep -q .; then
    systemctl enable "$unit"
  else
    echo "omacachy: $unit is not provided on this system, skipping"
  fi
}

mask_if_present() {
  local unit=$1
  if systemctl list-unit-files --no-legend --no-pager "$unit" 2>/dev/null | grep -q .; then
    systemctl mask "$unit"
  fi
}

enable_if_present cups.service
enable_if_present avahi-daemon.service
enable_if_present linux-modules-cleanup.service
enable_if_present docker.socket
enable_if_present systemd-resolved.service
enable_if_present NetworkManager.service
mask_if_present NetworkManager-wait-online.service
enable_if_present power-profiles-daemon.service
enable_if_present sddm.service
enable_if_present systemd-oomd.service

# CachyOS ships systemd-boot/GRUB helpers too; never let them fight SDDM.
if [[ -f /etc/systemd/system/display-manager.service ]]; then
  if ! systemctl is-enabled --quiet sddm.service 2>/dev/null; then
    echo "omacachy: another display manager owns display-manager.service; SDDM was enabled and takes over"
  fi
fi
