#!/bin/bash
# shellcheck shell=bash
# Guided uninstall/cleanup for OmaCachy. Keeps user data and does not touch
# bootloader entries unless explicitly requested.

if [[ -n ${_OMACACHY_UNINSTALL:-} ]]; then return 0; fi
_OMACACHY_UNINSTALL=1

UNINSTALL_REMOVE_PACKAGES=0
UNINSTALL_REMOVE_REPO=0
UNINSTALL_YES=${ASSUME_YES:-0}

uninstall_usage() {
  cat <<'EOF'
Usage: omacachy uninstall [options]

Removes OmaCachy guards/hooks and restores CachyOS-managed files where possible.
By default it does not remove Omarchy packages or the [omarchy] repo.

Options:
  --remove-packages   remove Omarchy/OmaCachy-installed desktop packages (interactive pacman)
  --remove-repo       remove [omarchy] repo block from /etc/pacman.conf and refresh
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
      --remove-packages) UNINSTALL_REMOVE_PACKAGES=1; shift ;;
      --remove-repo) UNINSTALL_REMOVE_REPO=1; shift ;;
      -y|--yes) UNINSTALL_YES=1; ASSUME_YES=1; shift ;;
      -n|--dry-run) DRY_RUN=1; shift ;;
      -h|--help) uninstall_usage; exit 0 ;;
      *) die "Unknown uninstall option: $1" ;;
    esac
  done
}

rm_if_exists() {
  local f
  for f in "$@"; do
    if [[ -e $f || -L $f ]]; then
      if (( DRY_RUN )); then
        info "would remove $f"
      else
        rm -rf "$f"
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

remove_omarchy_packages() {
  (( UNINSTALL_REMOVE_PACKAGES )) || return 0
  local -a pkgs=()
  local p
  while IFS= read -r p; do
    [[ -n $p ]] || continue
    pkgs+=("$p")
  done < <(pacman -Qq 2>/dev/null | grep -E '^(omarchy($|-)|hype($|-)|monologue($|-)|omacalc($|-)|omacut($|-)|omawrite($|-)|aether($|-)|cliamp($|-)|gliff($|-)|herdr($|-)|signed($|-)|tobi-try($|-)|disktree-bin($|-))' | sort -u)

  if (( ${#pkgs[@]} == 0 )); then
    info "No Omarchy packages detected"
    return 0
  fi

  warn "This will ask pacman to remove: ${pkgs[*]}"
  warn "Review the transaction carefully before confirming in pacman."
  confirm_uninstall "Proceed with removing Omarchy packages?" || { info "Skipped package removal"; return 0; }

  if (( DRY_RUN )); then
    info "would run: pacman -Rns ${pkgs[*]}"
    return 0
  fi

  pacman -Rns "${pkgs[@]}" || warn "Package removal failed or was cancelled; rerun after resolving pacman issues"
}

uninstall_main() {
  uninstall_parse_args "$@"
  require_root
  log_init
  detect_distro || true
  resolve_target_user "${SUDO_USER:-${USER:-}}" || true

  warn "OmaCachy uninstall removes OmaCachy hooks/guards and can optionally remove Omarchy packages."
  warn "It does not remove Limine, user data, or boot entries."
  confirm_uninstall "Continue with OmaCachy uninstall?" || die "Uninstall cancelled"

  step "uninstall: remove OmaCachy hooks and helpers"
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
    /usr/local/bin/omacachy

  step "uninstall: restore system identity/config"
  restore_os_release_for_uninstall
  remove_omarchy_repo_block

  if (( ! DRY_RUN )); then
    if command -v mkinitcpio >/dev/null 2>&1; then
      run mkinitcpio -P || warn "mkinitcpio -P failed; check boot/initramfs state"
    fi
  else
    info "would run mkinitcpio -P"
  fi

  remove_omarchy_packages

  step "uninstall: cleanup OmaCachy state"
  if confirm_uninstall "Remove /var/lib/omacachy and /var/log/omacachy?"; then
    rm_if_exists "$OMACACHY_STATE_DIR" "$OMACACHY_LOG_DIR"
  else
    info "Kept OmaCachy state/log directories"
  fi

  success "OmaCachy uninstall steps completed"
  warn "Review docs/uninstall.md for bootloader/desktop restoration steps."
}
