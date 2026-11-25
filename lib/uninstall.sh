#!/bin/bash
# shellcheck shell=bash
# Guided uninstall/cleanup for OmaCachy + Omarchy.

if [[ -n ${_OMACACHY_UNINSTALL:-} ]]; then return 0; fi
_OMACACHY_UNINSTALL=1

UNINSTALL_REMOVE_PACKAGES=1
UNINSTALL_REMOVE_REPO=1
UNINSTALL_REMOVE_CONFIGS=1
UNINSTALL_YES=${ASSUME_YES:-0}

uninstall_usage() {
  cat <<'EOF'
Usage: omacachy uninstall [options]

Removes Omarchy and OmaCachy from this system. By default removes Omarchy
packages, [omarchy] repo, and Omarchy/OmaCachy configs/guards. It does not
remove Limine, boot entries, or personal non-Omarchy user data.

Options:
  --keep-packages     do not remove Omarchy packages
  --keep-repo         do not remove [omarchy] repo from /etc/pacman.conf
  --keep-configs      do not remove Omarchy/OmaCachy config files and state
  --remove-packages   remove Omarchy packages (default)
  --remove-repo       remove [omarchy] repo (default)
  -y, --yes           do not prompt for confirmation
  -n, --dry-run       print actions without changing anything
  -h, --help          show this help
EOF
}

confirm_uninstall() {
  local prompt=$1
  if (( UNINSTALL_YES || DRY_RUN )); then
    return 0
  fi
  if [[ ! -t 0 && ! -c /dev/tty ]]; then
    die "No TTY for confirmation. Re-run with --yes"
  fi
  local ans
  printf '%s [y/N]: ' "$prompt" >/dev/tty
  read -r ans </dev/tty || die "Confirmation aborted"
  [[ $ans == y || $ans == Y || $ans == yes || $ans == YES ]]
}

uninstall_parse_args() {
  while (($#)); do
    case $1 in
      --keep-packages) UNINSTALL_REMOVE_PACKAGES=0; shift ;;
      --keep-repo) UNINSTALL_REMOVE_REPO=0; shift ;;
      --keep-configs) UNINSTALL_REMOVE_CONFIGS=0; shift ;;
      --remove-packages) UNINSTALL_REMOVE_PACKAGES=1; shift ;;
      --remove-repo) UNINSTALL_REMOVE_REPO=1; shift ;;
      -y|--yes) UNINSTALL_YES=1; ASSUME_YES=1; shift ;;
      -n|--dry-run) DRY_RUN=1; shift ;;
      -h|--help) uninstall_usage; exit 0 ;;
      *) die "Unknown uninstall option: $1" ;;
    esac
  done
}

safe_uninstall_path() {
  local f=$1
  [[ -n $f && $f == /* ]] || return 1
  case "$f" in
    /|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var) return 1 ;;
    /etc/*|/usr/*|/var/lib/omacachy/*|/var/log/omacachy/*|"$TARGET_HOME"/*|"$TARGET_HOME") return 0 ;;
  esac
  # Allow explicit known top-level state dirs.
  [[ $f == "$OMACACHY_STATE_DIR" || $f == "$OMACACHY_LOG_DIR" ]] && return 0
  return 1
}

rm_if_exists() {
  local f
  for f in "$@"; do
    [[ -n $f ]] || continue
    if ! safe_uninstall_path "$f"; then
      warn "Refusing to remove unsafe path: $f"
      continue
    fi
    if [[ -e $f || -L $f ]]; then
      if (( DRY_RUN )); then
        info "would remove $f"
      else
        rm -r -- "$f"
        info "removed $f"
      fi
    fi
  done
}

restore_os_release_for_uninstall() {
  local original="$OMACACHY_OS_RELEASE_ORIGINAL"
  local backup
  if [[ ! -f $original ]]; then
    backup=$(find_saved_os_release 2>/dev/null || true)
    [[ -n $backup ]] && original=$backup
  fi

  if [[ -f $original ]] && is_usable_os_release "$original"; then
    if (( DRY_RUN )); then
      info "would restore /etc/os-release from $original"
    else
      backup_file /etc/os-release os-release.before-uninstall
      cp -a "$original" /etc/os-release
      chmod 0644 /etc/os-release 2>/dev/null || true
      success "Restored /etc/os-release"
    fi
  else
    warn "No original os-release backup found; leaving /etc/os-release as-is"
  fi
}

remove_omarchy_repo_block() {
  (( UNINSTALL_REMOVE_REPO )) || return 0
  local file=/etc/pacman.conf
  [[ -f $file ]] || return 0
  grep -q '^\[omarchy\]' "$file" || { info "[omarchy] repo not present"; return 0; }

  if (( DRY_RUN )); then
    info "would remove [omarchy] repo block from $file"
    return 0
  fi

  backup_file "$file" pacman.conf.before-uninstall
  awk '
    /^\[omarchy\]/{skip=1; next}
    skip && /^\[/ {skip=0}
    !skip {print}
  ' "$file" >"${file}.omacachy.tmp"
  mv "${file}.omacachy.tmp" "$file"
  success "Removed [omarchy] repo from /etc/pacman.conf"
  run pacman -Sy --noconfirm || warn "pacman -Sy failed after removing [omarchy] repo"
}

omarchy_installed_packages() {
  pacman -Qq 2>/dev/null | grep -E '^(omarchy($|-)|omarchy-|hyprland($|-)|hypr[^ ]*-omarchy|quickshell($|-)|walker($|-)|hype($|-)|monologue($|-)|omacalc($|-)|omacut($|-)|omawrite($|-)|aether($|-)|cliamp($|-)|gliff($|-)|herdr($|-)|signed($|-)|tobi-try($|-)|disktree-bin($|-)|omarchy-keyring($|-))' | sort -u || true
}

remove_omarchy_packages() {
  (( UNINSTALL_REMOVE_PACKAGES )) || return 0
  local -a pkgs=()
  local p
  while IFS= read -r p; do
    [[ -n $p ]] || continue
    pkgs+=("$p")
  done < <(omarchy_installed_packages)

  if (( ${#pkgs[@]} == 0 )); then
    info "No Omarchy packages detected"
    return 0
  fi

  warn "About to remove Omarchy packages: ${pkgs[*]}"
  warn "Review the pacman transaction carefully before confirming."
  confirm_uninstall "Proceed with removing Omarchy packages?" || { info "Skipped package removal"; return 0; }

  if (( DRY_RUN )); then
    info "would run: pacman -Rns ${pkgs[*]}"
    return 0
  fi

  if ! pacman -Rns "${pkgs[@]}"; then
    warn "Bulk removal failed; retrying without dependency cascade for remaining packages"
    local -a remaining=()
    while IFS= read -r p; do [[ -n $p ]] && remaining+=("$p"); done < <(omarchy_installed_packages)
    if (( ${#remaining[@]} )); then
      pacman -Rdd --noconfirm "${remaining[@]}" || warn "Some Omarchy packages could not be removed; rerun after resolving pacman issues"
    fi
  fi
}

remove_omarchy_user_configs() {
  (( UNINSTALL_REMOVE_CONFIGS )) || return 0
  local home=$TARGET_HOME
  [[ -n $home && -d $home ]] || { warn "Target home not found; skipping user config removal"; return 0; }

  local -a paths=(
    "$home/.config/omarchy"
    "$home/.local/share/omarchy"
    "$home/.local/state/omarchy"
    "$home/.cache/omarchy"
  )
  rm_if_exists "${paths[@]}"

  # Remove Omarchy webapp launchers/desktop entries in user applications.
  local apps_dir="$home/.local/share/applications"
  if [[ -d $apps_dir ]]; then
    local f
    while IFS= read -r -d '' f; do
      if grep -qE 'Exec=.*(omarchy-|/usr/share/omarchy/|omarchy-launch-webapp|omarchy-webapp-handler)' "$f" 2>/dev/null; then
        rm_if_exists "$f"
      fi
    done < <(find "$apps_dir" -maxdepth 1 -type f -name '*.desktop' -print0 2>/dev/null)
    if command -v update-desktop-database >/dev/null 2>&1; then
      run_as_user "$TARGET_USER" update-desktop-database "$apps_dir" >/dev/null 2>&1 || true
    fi
  fi

  # Remove Omarchy-specific Hypr config only if it's clearly Omarchy-managed.
  if [[ -f "$home/.config/hypr/hyprland.conf" ]] && grep -q '/usr/share/omarchy\|~/.config/omarchy' "$home/.config/hypr/hyprland.conf" 2>/dev/null; then
    warn "Detected Omarchy-managed Hypr config at $home/.config/hypr/hyprland.conf"
    if confirm_uninstall "Remove $home/.config/hypr Omarchy config?"; then
      rm_if_exists "$home/.config/hypr"
    else
      info "Kept $home/.config/hypr"
    fi
  fi
}

remove_omarchy_system_configs() {
  (( UNINSTALL_REMOVE_CONFIGS )) || return 0

  rm_if_exists \
    "$OMACACHY_OS_RELEASE_HOOK" \
    "$OMACACHY_OS_RELEASE_RESTORE" \
    "$OMACACHY_GREETER_HOOK" \
    "$OMACACHY_GREETER_RESTORE" \
    "$OMACACHY_ENV_HOOK" \
    "$OMACACHY_ENV_PATCH" \
    "$OMACACHY_PROVISION_HOOK" \
    "$OMACACHY_PROVISION_PATCH" \
    "$OMACACHY_VERSION_CHANNEL_HOOK" \
    "$OMACACHY_VERSION_CHANNEL_PATCH" \
    "$OMACACHY_FASTFETCH_HOOK" \
    "$OMACACHY_FASTFETCH_PATCH" \
    "$OMACACHY_OPENCODE_RESTART_HOOK" \
    "$OMACACHY_OPENCODE_RESTART_PATCH" \
    "$OMACACHY_HERDR_HOOK" \
    "$OMACACHY_HERDR_PATCH" \
    "$OMACACHY_LIMINE_NAME_HOOK" \
    "$OMACACHY_LIMINE_NAME_PATCH" \
    /etc/sddm.conf.d/zz-omacachy-greeter.conf \
    /etc/mkinitcpio.conf.d/05-omacachy-hooks.conf \
    /etc/limine-entry-tool.d/99-omacachy.conf \
    /usr/local/bin/omacachy \
    /usr/local/lib/omacachy

  # Remove Omarchy-owned system config leftovers only if present.
  rm_if_exists \
    /etc/mkinitcpio.conf.d/00-omarchy-hooks.conf \
    /etc/mkinitcpio.conf.d/omarchy_hooks.conf \
    /etc/mkinitcpio.conf.d/omarchy_vconsole.conf \
    /etc/pacman.d/hooks/omarchy-*.hook \
    /usr/share/omarchy

  # SDDM theme may still point at Omarchy; reset to a safe default if needed.
  if [[ -f /etc/sddm.conf.d/10-theme.conf ]] && grep -qi omarchy /etc/sddm.conf.d/10-theme.conf 2>/dev/null; then
    if (( DRY_RUN )); then
      info "would remove Omarchy SDDM theme config /etc/sddm.conf.d/10-theme.conf"
    else
      backup_file /etc/sddm.conf.d/10-theme.conf 10-theme.conf.before-uninstall
      rm -f /etc/sddm.conf.d/10-theme.conf
      info "removed Omarchy SDDM theme config"
    fi
  fi
}

rebuild_initramfs_after_uninstall() {
  if (( DRY_RUN )); then
    info "would run mkinitcpio -P (if installed)"
    return 0
  fi
  if command -v mkinitcpio >/dev/null 2>&1; then
    run mkinitcpio -P || warn "mkinitcpio -P failed; check boot/initramfs state"
  fi
}

uninstall_main() {
  uninstall_parse_args "$@"
  require_root
  log_init
  detect_distro || true
  resolve_target_user "${SUDO_USER:-${USER:-}}" || true

  warn "This will remove Omarchy/OmaCachy packages and configs according to selected options."
  warn "Limine and boot entries are not removed."
  confirm_uninstall "Continue with uninstall?" || die "Uninstall cancelled"

  if (( UNINSTALL_REMOVE_PACKAGES )); then
    detect_current_desktops || true
    if (( ${#DETECTED_SESSION_PKGS[@]} == 0 )); then
      warn "No other desktop environment/window manager session detected."
      confirm_uninstall "Are you sure you want to continue without DE or WM?" || die "Uninstall cancelled"
    fi
  fi

  step "uninstall: remove OmaCachy guards and Omarchy system configs"
  remove_omarchy_system_configs
  restore_os_release_for_uninstall
  remove_omarchy_repo_block

  step "uninstall: remove Omarchy packages"
  remove_omarchy_packages

  step "uninstall: remove Omarchy user configs"
  remove_omarchy_user_configs

  step "uninstall: rebuild initramfs"
  rebuild_initramfs_after_uninstall

  step "uninstall: cleanup OmaCachy state"
  local remove_state=0
  if (( UNINSTALL_REMOVE_CONFIGS )); then
    if confirm_uninstall "Remove /var/lib/omacachy and /var/log/omacachy?"; then
      remove_state=1
    else
      info "Kept OmaCachy state/log directories"
    fi
  else
    info "Keeping OmaCachy state/log directories (--keep-configs)"
  fi

  if (( remove_state )); then
    _OMACACHY_LOG_READY=
    TUI_LOG_REDIRECTED=1
  fi
  if (( remove_state )); then
    rm_if_exists "$OMACACHY_STATE_DIR" "$OMACACHY_LOG_DIR"
  fi

  printf '%sOK%s OmaCachy uninstall steps completed\n' "${C_GREEN:-}" "${C_RESET:-}"
  printf '%sWARN%s Reboot recommended. If you removed a desktop, install/login to another session first.\n' "${C_YELLOW:-}" "${C_RESET:-}" >&2
}
