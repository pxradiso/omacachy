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

# Keep the parameters that actually boot this machine (LUKS, root device,
# btrfs subvolume, resume). Presentation parameters are dropped because
# Omarchy's limine-entry-tool drops add their own.
boot_critical_cmdline() {
  local line=$1 token
  local -a kept=()
  for token in $line; do
    case $token in
      BOOT_IMAGE=* | initrd=* | quiet | splash | loglevel=* | \
        systemd.show_status=* | rd.udev.log_level=* | \
        vt.global_cursor_default=* | systemd.tty.term.console=* | \
        initramfs_async=*)
        continue
        ;;
    esac
    kept+=("$token")
  done
  printf '%s\n' "${kept[*]}"
}

# limine-entry-tool only falls back to /etc/kernel/cmdline or /proc/cmdline
# when no KERNEL_CMDLINE[*] is configured. Omarchy's drop-in always configures
# one, so a CachyOS LUKS root would be missing from every Limine entry:
# the kernel then cannot open the container ("root partition not found").
# Copy the machine's own parameters into both places.
ensure_limine_cmdline() {
  local file=$1
  local kernel_cmdline=/etc/kernel/cmdline
  local source='' params tmp src

  if [[ -s $kernel_cmdline ]] && grep -qE '(^|[[:space:]])root=' "$kernel_cmdline"; then
    source=$(<"$kernel_cmdline")
  fi
  # A CachyOS install with an encrypted root needs cryptdevice=. If the saved
  # file does not have it, the running kernel's command line is authoritative.
  if [[ $source != *cryptdevice=* && -r /proc/cmdline ]] &&
    grep -q 'cryptdevice=' /proc/cmdline; then
    source=$(</proc/cmdline)
  fi
  if [[ -z $source && -r /proc/cmdline ]] &&
    grep -qE '(^|[[:space:]])root=' /proc/cmdline; then
    source=$(</proc/cmdline)
  fi

  if [[ -z $source ]]; then
    warn "bootloader: no kernel command line found; Limine entries may not find the root filesystem"
    return 0
  fi

  params=$(boot_critical_cmdline "$source")
  if [[ $params != *root=* ]]; then
    warn "bootloader: the kernel command line has no root=; Limine entries may not boot"
    return 0
  fi

  if [[ ! -s $kernel_cmdline ]] ||
    ! grep -qE '(^|[[:space:]])root=' "$kernel_cmdline"; then
    backup_file "$kernel_cmdline" kernel-cmdline
    if (( DRY_RUN )); then
      info "would record the kernel command line in $kernel_cmdline"
    else
      mkdir -p /etc/kernel
      printf '%s\n' "$params" >"$kernel_cmdline"
      chmod 0644 "$kernel_cmdline"
      info "Recorded the kernel command line in $kernel_cmdline"
    fi
  fi

  tmp=$(mktemp) || return 0
  src=$file
  [[ -f $src ]] || src=/dev/null
  awk '
    /^# OmaCachy: boot parameters/ { skip = 1; next }
    skip && /^KERNEL_CMDLINE\[default\]\+=/ { skip = 0; next }
    { print }
  ' "$src" >"$tmp"
  {
    echo '# OmaCachy: boot parameters copied from this machine.'
    printf 'KERNEL_CMDLINE[default]+="%s"\n' "$params"
  } >>"$tmp"
  if [[ -n $ESP_PATH ]] && ! grep -qE '^[[:space:]]*ESP_PATH=' "$tmp"; then
    printf 'ESP_PATH="%s"\n' "$ESP_PATH" >>"$tmp"
  fi

  if (( DRY_RUN )); then
    info "would add KERNEL_CMDLINE[default]+=\"$params\" to $file"
    rm -f "$tmp"
    return 0
  fi

  backup_file "$file" limine-default
  install -m 0644 "$tmp" "$file"
  rm -f "$tmp"
  success "Limine boot parameters: root device and LUKS are preserved"
}

# Written *before* the packages are installed: limine-mkinitcpio-hook's pacman
# hook runs limine-install on install, and /etc/default/limine overrides the
# Omarchy drop-ins.
configure_bootloader_preferences() {
  local file=/etc/default/limine order='' fallback=''

  case $BOOT_MODE in
    register) order=keep fallback=no ;;
    convert) order=first fallback=yes ;;
    skip) ;;
    *) return 0 ;;
  esac

  if (( DRY_RUN )); then
    if [[ -n $order ]]; then
      info "would set UEFI_BOOT_ORDER=$order, ENABLE_LIMINE_FALLBACK=$fallback and TARGET_OS_NAME=\"CachyOS\" in $file"
    else
      info "would set TARGET_OS_NAME=\"CachyOS\" in $file (--boot=skip keeps other boot preferences)"
    fi
    ensure_limine_cmdline "$file"
    return 0
  fi

  backup_file "$file" limine-default
  mkdir -p /etc/default
  [[ -f $file ]] || : >"$file"

  # Omarchy-settings sets TARGET_OS_NAME="Omarchy"; keep the OS name as CachyOS.
  # /etc/default/limine has highest priority over limine-entry-tool drop-ins.
  set_limine_kv "$file" TARGET_OS_NAME '"CachyOS"'

  if [[ -n $order ]]; then
    set_limine_kv "$file" UEFI_BOOT_ORDER "$order"
    set_limine_kv "$file" ENABLE_LIMINE_FALLBACK "$fallback"
  else
    info "bootloader: keeping firmware/Limine preferences untouched (--boot=skip)"
  fi

  ensure_limine_cmdline "$file"

  if [[ -n $order ]] && have efibootmgr && [[ -d $OMACACHY_BACKUP_DIR ]]; then
    efibootmgr -v >"$OMACACHY_BACKUP_DIR/efibootmgr.before.txt" 2>/dev/null || true
  fi

  if [[ -n $order ]]; then
    success "Limine preferences: TARGET_OS_NAME=CachyOS UEFI_BOOT_ORDER=$order ENABLE_LIMINE_FALLBACK=$fallback"
    if [[ $BOOT_MODE == register ]]; then
      info "Limine will be registered in the firmware menu but the current default stays."
      info "Pick \"Limine\" in the firmware boot menu (or rerun with --boot=convert)."
    fi
  else
    success "Limine OS name set to CachyOS"
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
