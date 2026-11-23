#!/bin/bash
# shellcheck shell=bash
# Build the install overlay: Omarchy's own install tree, with OmaCachy's
# CachyOS-aware replacements copied on top of it.

if [[ -n ${_OMACACHY_OVERLAY:-} ]]; then return 0; fi
_OMACACHY_OVERLAY=1

build_overlay() {
  step "overlay: build the CachyOS-aware Omarchy install tree"

  [[ -d /usr/share/omarchy/install ]] ||
    die "Omarchy install tree missing (/usr/share/omarchy/install). Install the omarchy package first."
  [[ -d $OMACACHY_REPO/overlay ]] ||
    die "OmaCachy overlay directory missing: $OMACACHY_REPO/overlay"

  if (( DRY_RUN )); then
    info "would copy /usr/share/omarchy/install -> $OMACACHY_OVERLAY_DIR and apply OmaCachy overrides"
    return 0
  fi

  rm -rf "$OMACACHY_OVERLAY_DIR"
  mkdir -p "$OMACACHY_OVERLAY_DIR"
  cp -a /usr/share/omarchy/install/. "$OMACACHY_OVERLAY_DIR"/

  local src rel
  while IFS= read -r -d '' src; do
    rel=${src#"$OMACACHY_REPO/overlay/"}
    install -D -m 0644 "$src" "$OMACACHY_OVERLAY_DIR/$rel"
    debug "overlay: $rel"
  done < <(find "$OMACACHY_REPO/overlay" -type f -print0)

  chown -R root:root "$OMACACHY_OVERLAY_DIR"
  success "Overlay ready: $OMACACHY_OVERLAY_DIR"
}

# The mkinitcpio HOOKS line the distro shipped before Omarchy's drop-ins. Used
# to keep CachyOS's initramfs baseline (LUKS, TPM, resume, ...) intact.
capture_mkinitcpio_baseline() {
  local raw hooks
  raw=$(awk '/^HOOKS=\(/{flag=1} flag{printf "%s ", $0} flag && /\)/{exit}' /etc/mkinitcpio.conf 2>/dev/null || true)
  raw=$(printf '%s' "$raw" | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')

  if [[ -z $raw ]]; then
    warn "No HOOKS=(...) line found in /etc/mkinitcpio.conf; Omarchy's hook baseline will be used as-is"
    return 0
  fi

  hooks=${raw#HOOKS=(}
  hooks=${hooks%)}
  hooks=$(printf '%s' "$hooks" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')

  if (( DRY_RUN )); then
    info "would record mkinitcpio baseline: $hooks"
    return 0
  fi

  mkdir -p "$(dirname "$OMACACHY_BASELINE_FILE")"
  printf '%s\n' "$hooks" >"$OMACACHY_BASELINE_FILE"
  info "Recorded CachyOS mkinitcpio baseline: $hooks"
}

write_mkinitcpio_dropin() {
  local dropin=/etc/mkinitcpio.conf.d/05-omacachy-hooks.conf
  local baseline
  local -a hooks new

  if [[ ! -r $OMACACHY_BASELINE_FILE ]]; then
    warn "Skipping mkinitcpio baseline drop-in (no baseline recorded)"
    return 0
  fi

  baseline=$(<"$OMACACHY_BASELINE_FILE")
  read -r -a hooks <<<"$baseline"

  if [[ " ${hooks[*]} " != *" plymouth "* ]]; then
    local h inserted=0
    new=()
    for h in "${hooks[@]}"; do
      new+=("$h")
      if (( !inserted )) && [[ $h == udev || $h == systemd ]]; then
        new+=(plymouth)
        inserted=1
      fi
    done
    if (( !inserted )); then
      new=(plymouth "${hooks[@]}")
    fi
    hooks=("${new[@]}")
  fi

  [[ " ${hooks[*]} " == *" btrfs-overlayfs "* ]] || hooks+=(btrfs-overlayfs)

  if (( DRY_RUN )); then
    info "would write $dropin with HOOKS=(${hooks[*]})"
    return 0
  fi

  mkdir -p /etc/mkinitcpio.conf.d
  {
    echo "# OmaCachy: keep CachyOS's mkinitcpio baseline."
    echo "#"
    echo "# omarchy-settings ships /etc/mkinitcpio.conf.d/00-omarchy-hooks.conf, which"
    echo "# replaces HOOKS wholesale with Omarchy's line. That would drop whatever the"
    echo "# distro added to its initramfs (LUKS variant, TPM, resume, ...). This drop-in"
    echo "# is sourced after it and restores the baseline captured when OmaCachy ran,"
    echo "# adding only the hooks Omarchy needs: plymouth and btrfs-overlayfs."
    echo "HOOKS=(${hooks[*]})"
  } >"$dropin"
  chmod 0644 "$dropin"
  success "mkinitcpio: CachyOS baseline preserved in $dropin"
}
