#!/bin/bash
# shellcheck shell=bash
# Final steps and the human-readable summary.

if [[ -n ${_OMACACHY_FINALIZE:-} ]]; then return 0; fi
_OMACACHY_FINALIZE=1

finalize_install() {
  step "finalize: default session and recorded state"

  # Afterwards, too: the overlay's last steps must not leave Omarchy's
  # os-release behind either.
  restore_os_release

  run systemctl daemon-reload
  if systemctl list-unit-files --no-legend --no-pager sddm.service 2>/dev/null | grep -q .; then
    run systemctl enable sddm.service
    ensure_sddm_login_user
  else
    warn "sddm.service is not installed; Omarchy expects SDDM as the display manager"
  fi
  run systemctl set-default graphical.target

  write_state OMACACHY_VERSION "$OMACACHY_VERSION"
  write_state OMACACHY_INSTALLED_AT "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  write_state OMACACHY_USER "$TARGET_USER"
  write_state OMACACHY_CHANNEL "$OMACACHY_CHANNEL"
  write_state OMACACHY_BOOT_MODE "$BOOT_MODE"
  write_state OMACACHY_APPS "$( ((NO_APPS)) && echo no || echo yes )"
  write_state OMACACHY_REMOVE_EXISTING_DE "$( ((REMOVE_EXISTING_DE)) && echo yes || echo no )"
  write_state OMACACHY_GREETER "$( ((NO_GREETER)) && echo keep || echo omarchy )"
  write_state OMACACHY_HOSTNAME "$(hostname 2>/dev/null || echo unknown)"

  print_summary
}

print_summary() {
  local omarchy_version sw omarchy_update='omarchy update'

  omarchy_version=$(pkg_version omarchy 2>/dev/null || echo unknown)
  echo
  printf '%s' "$C_GREEN"
  cat <<'EOF'
   ____                 ____      _           _
  / __ \_ __ ___   __ _/ ___|__ _| |__  _   _| |__
 | |  | | '_ ` _ \ / _` | |   / _` | '_ \| | | | '_ \
 | |__| | | | | | | (_| | |__| (_| | | | | |_| | | | |
  \____/|_| |_| |_|\__,_|\____\__,_|_| |_|\__, |_| |_|
                                         |___/
EOF
  printf '%s' "$C_RESET"
  echo
  printf ' %sOmarchy %s on CachyOS - installed by OmaCachy %s%s\n' \
    "$C_BOLD" "$omarchy_version" "$OMACACHY_VERSION" "$C_RESET"
  echo
  cat <<EOF
 Kept from CachyOS: kernel, GPU drivers (chwd), pacman.conf, mirrors, keyrings
 Kept from CachyOS: the machine's hostname and /etc/os-release (also across
                    'omarchy update', through OmaCachy's pacman hook)
 Installed from Omarchy's stable channel: the desktop, configs and lifecycle
 Provisioned user: $TARGET_USER
EOF

  if (( NO_APPS )); then
    echo " Applications:    skipped (--no-apps): desktop, terminal and Omarchy CLI only"
  fi
  if (( REMOVE_EXISTING_DE )); then
    echo " Old DE/WM:       removed on request (configuration files were kept)"
  fi
  if (( NO_GREETER )); then
    echo " Login greeter:   kept the previous SDDM theme (OmaCachy drop-in)"
  fi
  if (( ${#SKIPPED[@]} )); then
    echo
    echo " Skipped for now (upstream drift, retried on the next run):"
    local i
    for i in "${!SKIPPED[@]}"; do
      printf '   - %s (%s)\n' "${SKIPPED[$i]}" "${SKIPPED_REASONS[$i]}"
    done
  fi

  echo
  case $BOOT_MODE in
    register)
      echo " Boot: Limine was added to the firmware menu but is not the default yet."
      echo "       Pick \"Limine\" from the firmware boot menu at the next reboot,"
      echo "       or rerun: sudo omacachy install --boot=convert"
      ;;
    convert)
      echo " Boot: Limine is now the default boot entry (previous entries are kept)."
      ;;
  esac

  if (( ! OMACACHY_USER_PROVISION_OK )); then
    echo
    echo " ${C_YELLOW}User provisioning did not finish cleanly.${C_RESET} Rerun:"
    echo "   sudo -u $TARGET_USER omarchy-provision-user --force --first-install"
  fi

  echo
  if (( DRY_RUN )); then
    echo " Dry run: nothing was changed, so there is nothing to reboot or diagnose."
    echo
    echo " Logs would be written to:"
  else
    echo " Next steps:"
    echo "   1. Reboot."
    echo "   2. Log in (SDDM + password) and pick the Omarchy/Hyprland session."
    echo "   3. From then on, update Omarchy with:  omarchy update"
    echo "      (direct 'pacman -Syu' is intentionally guarded by Omarchy;"
    echo "       use OMARCHY_ALLOW_DIRECT_PACMAN=1 to bypass for a single transaction)"
    echo
    echo " Re-run 'sudo omacachy install' any time: every phase is idempotent."
    echo " Diagnose with: omacachy doctor"
    echo
    echo " Logs:"
  fi
  echo "   $OMACACHY_LOG_FILE"
  echo "   $OMACACHY_LOG_DIR/omarchy-system.log"
  echo "   $OMACACHY_LOG_DIR/omarchy-user.log"
  echo
}
