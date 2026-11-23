#!/bin/bash
# OmaCachy overlay: CachyOS-aware snapper setup.
#
# Upstream always writes Omarchy's retention template over /etc/snapper/configs/root.
# On an existing CachyOS system that config may already exist (CachyOS's
# cachyos-snapper-support, or the user's own tuning), so OmaCachy only applies
# the Omarchy template when it creates the config itself. The timers and
# Limine sync that Omarchy relies on are still enabled either way.

SNAPPER_CONFIG_PATH="${OMARCHY_SNAPPER_CONFIG_PATH:-/etc/snapper/configs/root}"
SNAPPER_CONF_PATH="${OMARCHY_SNAPPER_CONF_PATH:-/etc/conf.d/snapper}"
template="${OMARCHY_SNAPPER_TEMPLATE:-${OMARCHY_PATH:-/usr/share/omarchy}/default/snapper/root}"

if [[ $(findmnt -no FSTYPE / 2>/dev/null || true) != btrfs && -z ${OMARCHY_SNAPPER_CONFIGURE_TEST:-} ]]; then
  echo "OmaCachy: / is not btrfs, skipping snapper configuration"
  exit 0
fi

echo "Configuring snapper (CachyOS layout)"

created=0
if [[ ! -f $SNAPPER_CONFIG_PATH ]]; then
  mkdir -p "$(dirname "$SNAPPER_CONFIG_PATH")"

  if [[ ${OMARCHY_SNAPPER_CONFIGURE_TEST:-0} == "1" ]]; then
    : >"$SNAPPER_CONFIG_PATH"
  else
    snapper --no-dbus -c root create-config / >/dev/null 2>&1 ||
      snapper -c root create-config / >/dev/null
  fi
  created=1
fi

if (( created )) && [[ -f $template ]]; then
  install -m 0644 "$template" "$SNAPPER_CONFIG_PATH"
else
  echo "Keeping the existing snapper config at $SNAPPER_CONFIG_PATH"
fi

# Keep every timeline/cleanup configuration the system already has, and only
# make sure root is part of SNAPPER_CONFIGS.
mkdir -p "$(dirname "$SNAPPER_CONF_PATH")"
if [[ -f $SNAPPER_CONF_PATH ]] && grep -q '^SNAPPER_CONFIGS=' "$SNAPPER_CONF_PATH"; then
  if ! grep -qE '^SNAPPER_CONFIGS=.*root' "$SNAPPER_CONF_PATH"; then
    sed -i -E 's/^SNAPPER_CONFIGS="(.*)"/SNAPPER_CONFIGS="\1 root"/' "$SNAPPER_CONF_PATH"
  fi
else
  printf '%s\n' 'SNAPPER_CONFIGS="root"' >>"$SNAPPER_CONF_PATH"
fi
chmod 0644 "$SNAPPER_CONF_PATH"

# Omarchy snapshots on pacman transactions through limine-snapper-sync, and
# keeps the count small (the Limine config allows MAX_SNAPSHOT_ENTRIES=6).
systemctl disable --now snapper-timeline.timer >/dev/null 2>&1 || true
systemctl enable --now snapper-cleanup.timer limine-snapper-sync.service >/dev/null 2>&1 || true
