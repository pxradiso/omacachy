#!/bin/bash
# shellcheck shell=bash
# Bootloader preferences and the root half of Omarchy's setup.

if [[ -n ${_OMACACHY_SYSTEM:-} ]]; then return 0; fi
_OMACACHY_SYSTEM=1

OMARCHY_BIN=/usr/share/omarchy/bin

set_limine_kv() {
  local file=$1 key=$2 value=$3
  if grep -qE "^[[:space:]]*#?[[:space:]]*${key}=" "$file"; then
    sed -i -E "s|^[[:space:]]*#?[[:space:]]*${key}=.*|${key}=${value}|" "$file"
  else
    printf '%s=%s\n' "$key" "$value" >>"$file"
  fi
}

# Written *before* the packages are installed: limine-mkinitcpio-hook's pacman
# hook runs limine-install on install, and /etc/default/limine overrides the
# Omarchy drop-ins.
configure_bootloader_preferences() {
  local file=/etc/default/limine order fallback

  if [[ $BOOT_MODE == skip ]]; then
    info "bootloader: leaving firmware/Limine preferences untouched (--boot=skip)"
    return 0
  fi

  case $BOOT_MODE in
    register) order=keep fallback=no ;;
    convert) order=first fallback=yes ;;
    *) return 0 ;;
  esac

  if (( DRY_RUN )); then
    info "would set UEFI_BOOT_ORDER=$order and ENABLE_LIMINE_FALLBACK=$fallback in $file"
    return 0
  fi

  backup_file "$file" limine-default
  mkdir -p /etc/default
  [[ -f $file ]] || : >"$file"
  set_limine_kv "$file" UEFI_BOOT_ORDER "$order"
  set_limine_kv "$file" ENABLE_LIMINE_FALLBACK "$fallback"

  if have efibootmgr && [[ -d $OMACACHY_BACKUP_DIR ]]; then
    efibootmgr -v >"$OMACACHY_BACKUP_DIR/efibootmgr.before.txt" 2>/dev/null || true
  fi

  success "Limine preferences: UEFI_BOOT_ORDER=$order ENABLE_LIMINE_FALLBACK=$fallback"
  if [[ $BOOT_MODE == register ]]; then
    info "Limine will be registered in the firmware menu but the current default stays."
    info "Pick \"Limine\" in the firmware boot menu (or rerun with --boot=convert)."
  fi
}

run_system_apply() {
  local log="$OMACACHY_LOG_DIR/omarchy-system.log"

  step "system: apply Omarchy system setup through the OmaCachy overlay"

  if (( DRY_RUN )); then
    info "would run: OMARCHY_INSTALL=$OMACACHY_OVERLAY_DIR omarchy-apply-system --install-user $TARGET_USER --first-install"
    return 0
  fi

  mkdir -p "$OMACACHY_LOG_DIR"
  : >"$log"

  if ! env \
    OMARCHY_INSTALL="$OMACACHY_OVERLAY_DIR" \
    OMARCHY_PATH=/usr/share/omarchy \
    OMARCHY_INSTALL_USER="$TARGET_USER" \
    OMARCHY_INSTALL_LOG_FILE="$log" \
    PATH="$OMARCHY_BIN:/usr/local/bin:/usr/bin:/bin" \
    omarchy-apply-system --install-user "$TARGET_USER" --first-install; then
    error "Omarchy system setup failed. Last lines of $log:"
    tail -n 40 "$log" >&2 || true
    die "Fix the error above and rerun: sudo omacachy install --user $TARGET_USER"
  fi

  success "Omarchy system setup completed"
}

# The omarchy-settings scriptlet rewrites a handful of upstream-owned files on
# every install/upgrade (os-release, nsswitch.conf, faillock.conf, plymouthd,
# skel .bashrc, CUPS). That is upstream behaviour, but on an existing CachyOS
# system the originals are worth keeping around. /etc/os-release is handled by
# lib/identity.sh, which also installs the hook that keeps restoring it; the
# copy taken here doubles as a recovery source.
backup_overridden_files() {
  local f
  for f in /etc/os-release /etc/nsswitch.conf /etc/security/faillock.conf \
    /etc/plymouth/plymouthd.conf /etc/skel/.bashrc \
    /etc/cups/cups-files.conf /etc/cups/cups-browsed.conf; do
    [[ -e $f ]] || continue
    backup_file "$f" "before-$(basename "$f")"
  done
}

ensure_user_groups() {
  local user=$1
  local -a wanted=(wheel video render lp uucp rfkill)
  local -a add=()
  local group current

  if pkg_installed xpadneo-dkms || pkg_installed ydotool; then
    wanted+=(input)
  fi

  current=" $(id -nG "$user" 2>/dev/null) "
  for group in "${wanted[@]}"; do
    getent group "$group" >/dev/null 2>&1 || continue
    [[ $current == *" $group "* ]] && continue
    add+=("$group")
  done

  if (( ${#add[@]} == 0 )); then
    info "user: $user already has the required groups"
    return 0
  fi

  info "user: adding $user to ${add[*]}"
  run usermod -aG "$(IFS=,; echo "${add[*]}")" "$user"
}
