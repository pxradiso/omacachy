#!/bin/bash
# shellcheck shell=bash
# Post-install checks: omacachy doctor

if [[ -n ${_OMACACHY_DOCTOR:-} ]]; then return 0; fi
_OMACACHY_DOCTOR=1

DOC_FAILS=0
DOC_WARNS=0

doc_ok()   { printf '  %s[ ok ]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
doc_warn() { printf '  %s[warn]%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; DOC_WARNS=$((DOC_WARNS + 1)); }
doc_fail() { printf '  %s[FAIL]%s %s\n' "$C_RED" "$C_RESET" "$*"; DOC_FAILS=$((DOC_FAILS + 1)); }

doctor_main() {
  local user=''

  while (($#)); do
    case $1 in
      --user) user=${2:-} shift 2 ;;
      -h | --help)
        cat <<'EOF'
Usage: omacachy doctor [--user USER]

Read-only checks for an OmaCachy installation. Exit code 1 when something is
broken (not merely missing), so it can be used from scripts.
EOF
        return 0
        ;;
      *) die "Unknown option for doctor: $1" ;;
    esac
  done

  printf '\n%sOmaCachy doctor%s (%s %s)\n\n' "$C_BOLD" "$C_RESET" "${OS_NAME:-$(uname -s)}" "$(date +%Y-%m-%d)"

  detect_distro
  detect_root_fs
  detect_esp
  detect_limine
  detect_omarchy
  detect_conflicting_desktops

  TARGET_USER=''
  TARGET_HOME=''
  local candidate=${user:-${SUDO_USER:-${USER:-}}}
  if [[ -n $candidate && $candidate != root ]] && getent passwd "$candidate" >/dev/null 2>&1; then
    TARGET_USER=$candidate
    TARGET_HOME=$(getent passwd "$candidate" | cut -d: -f6)
  fi

  echo "Omarchy:"
  if [[ -n $OMARCHY_VERSION ]]; then
    if version_ge "$OMARCHY_VERSION" "$OMACACHY_MIN_OMARCHY_VERSION"; then
      doc_ok "omarchy $OMARCHY_VERSION installed (stable)"
    else
      doc_fail "omarchy $OMARCHY_VERSION is older than $OMACACHY_MIN_OMARCHY_VERSION"
    fi
  else
    doc_fail "omarchy package is not installed"
  fi

  if grep -q '^\[omarchy\]' /etc/pacman.conf 2>/dev/null; then
    if omarchy_repo_section | grep -q '/stable/'; then
      doc_ok "[omarchy] repository points at the stable channel"
    else
      doc_fail "[omarchy] repository is not the stable channel"
    fi
  else
    doc_warn "[omarchy] repository is missing from /etc/pacman.conf"
  fi

  if pacman-key --list-keys "$OMACACHY_OMARCHY_KEY" >/dev/null 2>&1; then
    doc_ok "Omarchy signing key is trusted"
  else
    doc_warn "Omarchy signing key is not in the pacman keyring (needed for updates)"
  fi

  pkg_installed omarchy-keyring && doc_ok "omarchy-keyring installed" ||
    doc_warn "omarchy-keyring is missing"

  if (( IS_CACHYOS )); then
    if grep -q '^\[cachyos\]' /etc/pacman.conf 2>/dev/null; then
      doc_ok "CachyOS repositories still configured"
    else
      doc_fail "CachyOS repositories are gone from /etc/pacman.conf (something ran omarchy-refresh-pacman?)"
    fi
  fi

  echo
  echo "Identity:"
  printf '  %s[info]%s hostname: %s (never modified by OmaCachy)\n' \
    "$C_BLUE" "$C_RESET" "$(hostname 2>/dev/null || echo unknown)"

  if (( IS_CACHYOS )); then
    if is_cachyos_os_release /etc/os-release; then
      doc_ok "/etc/os-release still identifies the system as CachyOS"
    elif is_omarchy_os_release /etc/os-release; then
      doc_fail "/etc/os-release says Omarchy: the restore hook did not run"
    else
      doc_fail "/etc/os-release no longer identifies the system as CachyOS"
    fi
  elif [[ -r /etc/os-release ]]; then
    doc_ok "/etc/os-release: $(sed -n 's/^PRETTY_NAME=//p' /etc/os-release | head -1)"
  fi

  if [[ -x $OMACACHY_OS_RELEASE_RESTORE && -f $OMACACHY_OS_RELEASE_HOOK ]]; then
    doc_ok "os-release restore hook installed (survives 'omarchy update')"
  else
    doc_warn "os-release restore hook missing: an omarchy-settings upgrade will say Omarchy"
  fi

  echo
  echo "Boot and snapshots:"
  if [[ $ROOT_FSTYPE == btrfs ]]; then
    doc_ok "root is btrfs ($ROOT_SOURCE)"
  else
    doc_fail "root is ${ROOT_FSTYPE:-unknown}, snapshots/rollback need btrfs"
  fi

  if pkg_installed limine && pkg_installed limine-mkinitcpio-hook; then
    doc_ok "limine + limine-mkinitcpio-hook installed"
  else
    doc_fail "limine packages are missing (Omarchy hard-depends on them)"
  fi

  if (( LIMINE_DEPLOYED )); then
    doc_ok "Limine is deployed (ESP: $ESP_PATH)"
  else
    doc_warn "Limine is not registered/deployed in the firmware"
  fi

  if [[ -f /etc/snapper/configs/root ]]; then
    doc_ok "snapper config for / exists"
  else
    doc_warn "no snapper config for / (/etc/snapper/configs/root)"
  fi

  if systemctl is-enabled --quiet limine-snapper-sync.service 2>/dev/null; then
    doc_ok "limine-snapper-sync.service enabled"
  else
    doc_warn "limine-snapper-sync.service is not enabled"
  fi

  if [[ -f /etc/mkinitcpio.conf.d/05-omacachy-hooks.conf ]]; then
    if grep -q 'btrfs-overlayfs' /etc/mkinitcpio.conf.d/05-omacachy-hooks.conf &&
      grep -q 'plymouth' /etc/mkinitcpio.conf.d/05-omacachy-hooks.conf; then
      doc_ok "mkinitcpio keeps the CachyOS baseline plus Omarchy hooks"
    else
      doc_fail "mkinitcpio drop-in exists but lacks plymouth/btrfs-overlayfs"
    fi
  else
    doc_warn "mkinitcpio drop-in missing (Omarchy's HOOKS replace CachyOS's)"
  fi

  echo
  echo "Desktop:"
  if [[ -f /usr/local/share/wayland-sessions/omarchy.desktop || -f /usr/share/wayland-sessions/omarchy.desktop ]]; then
    doc_ok "Omarchy Wayland session is installed"
  else
    doc_fail "Omarchy Wayland session file is missing"
  fi

  if systemctl is-enabled --quiet sddm.service 2>/dev/null; then
    doc_ok "sddm.service enabled"
  else
    doc_warn "sddm.service is not enabled"
  fi

  if [[ -r /var/lib/sddm/state.conf ]]; then
    local sddm_user
    sddm_user=$(sed -n 's/^User=//p' /var/lib/sddm/state.conf | tail -1)
    if [[ -n $TARGET_USER && $sddm_user == "$TARGET_USER" ]]; then
      doc_ok "SDDM preselects $TARGET_USER (Omarchy's greeter has no username field)"
    elif [[ -z $sddm_user ]]; then
      doc_fail "SDDM has no last user: Omarchy's greeter will send an empty username"
    else
      doc_warn "SDDM preselects '$sddm_user', not ${TARGET_USER:-the target user}"
    fi
  else
    doc_warn "cannot read /var/lib/sddm/state.conf (run doctor with sudo to check the greeter user)"
  fi

  if systemctl get-default 2>/dev/null | grep -q graphical.target; then
    doc_ok "default systemd target is graphical.target"
  else
    doc_warn "default systemd target is not graphical.target"
  fi

  if [[ -f /usr/share/libalpm/hooks/00-omarchy-update-guard.hook ]]; then
    doc_ok "omarchy update guard installed (use 'omarchy update')"
  else
    doc_warn "omarchy update guard hook is missing"
  fi

  echo
  echo "User:"
  if [[ -n $TARGET_USER ]]; then
    local groups
    groups=" $(id -nG "$TARGET_USER" 2>/dev/null) "
    local group missing=()
    for group in wheel video render; do
      [[ $groups == *" $group "* ]] || missing+=("$group")
    done
    if ((${#missing[@]} == 0)); then
      doc_ok "$TARGET_USER is in wheel, video, render"
    else
      doc_fail "$TARGET_USER is missing groups: ${missing[*]}"
    fi

    if [[ -e $TARGET_HOME/.local/state/omarchy/done/finalize-user ]]; then
      doc_ok "$TARGET_USER has Omarchy's finalize-user marker"
    else
      doc_warn "$TARGET_USER has not completed omarchy-provision-user"
    fi
  else
    doc_warn "no target user detected (pass --user USER)"
  fi

  if ((${#CONFLICTING_PACKAGES[@]})); then
    doc_warn "CachyOS Hyprland config packages still installed: ${CONFLICTING_PACKAGES[*]}"
  fi

  if have lspci && lspci 2>/dev/null | grep -qi 'nvidia' &&
    ! pkg_installed nvidia-utils && ! pkg_installed nvidia-open-dkms; then
    doc_warn "NVIDIA GPU detected but no NVIDIA driver is installed; run: sudo chwd -a"
  fi

  echo
  echo "Known Omarchy drift:"
  local tb_pkg=omarchy-hyprland-titlebars
  if pkg_installed "$tb_pkg"; then
    doc_ok "$tb_pkg installed"
    if command -v hyprctl >/dev/null 2>&1 && hyprctl plugin list 2>/dev/null | grep -q 'titlebars'; then
      doc_ok "Hyprland titlebars plugin loaded"
    else
      doc_warn "$tb_pkg installed but titlebars plugin not loaded (try: hyprctl plugin load /usr/lib/omarchy-hyprland-titlebars/titlebars.so)"
    fi
  else
    local hl_ver dep_needed
    hl_ver=$(pkg_version hyprland 2>/dev/null || true)
    dep_needed=$(pacman -Si "$tb_pkg" 2>/dev/null | awk -F: '/^Depends On/{print $2}' | tr ' ' '\n' | sed -n 's/^hyprland=//p' | head -1)
    if [[ -n $hl_ver && -n $dep_needed && $hl_ver != "$dep_needed" ]]; then
      doc_warn "$tb_pkg missing: needs hyprland=$dep_needed, installed hyprland=$hl_ver (Omarchy repo drift). Floating windows may lack decorations."
      printf '        Wait for Omarchy rebuild, then run: sudo omacachy install\n'
    else
      doc_warn "$tb_pkg not installed; floating windows may lack decorations/titlebars"
    fi
  fi

  echo
  if ((DOC_FAILS)); then
    printf '%s%d failure(s), %d warning(s)%s\n\n' "$C_RED" "$DOC_FAILS" "$DOC_WARNS" "$C_RESET"
    return 1
  fi
  printf '%sAll good (%d warning(s))%s\n\n' "$C_GREEN" "$DOC_WARNS" "$C_RESET"
  return 0
}
