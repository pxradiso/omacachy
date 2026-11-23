#!/bin/bash
# omacachy overlay: replaces Omarchy's post-install pacman step.
#
# Upstream omarchy-apply-pacman copies Omarchy's own /etc/pacman.conf (Arch
# mirrors, Arch keyrings) over the system's. On CachyOS that would delete the
# CachyOS repositories and silently turn the machine into Arch.
#
# omacachy owns the repository setup itself (lib/repo.sh) and keeps CachyOS's
# pacman.conf, mirrorlists and keyrings untouched.

echo "OmaCachy: keeping the CachyOS pacman configuration (Omarchy pacman step skipped)"

# CUPS configuration override, as upstream does after package installation.
if [[ -f $OMARCHY_PATH/etc-overrides/cups-cups-files.conf && -f /etc/cups/cups-files.conf ]]; then
  install -m 0640 -o root -g cups "$OMARCHY_PATH/etc-overrides/cups-cups-files.conf" /etc/cups/cups-files.conf
  rm -f /etc/cups/cups-files.conf.pacnew
fi

# Still honour Omarchy's hardware-specific repository extensions (e.g. the
# arch-mact2 repository on T2 Macs).
if [[ -r $OMARCHY_INSTALL/hardware/pacman.sh ]]; then
  # shellcheck source=/dev/null
  source "$OMARCHY_INSTALL/hardware/pacman.sh"
fi
