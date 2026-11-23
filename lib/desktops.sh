#!/bin/bash
# shellcheck shell=bash
# Detect and, when asked, remove the desktop environment or window manager that
# was already on the machine before Omarchy.
#
# Omarchy is a Wayland/Hyprland desktop: a second display manager session or a
# distro Hyprland configuration would compete with it. Removing the old session
# is optional, but it is the clean way to start. The removal is deliberately
# conservative:
#
#   * only session providers (the packages that own *.desktop files) and the
#     known CachyOS Hyprland config packages are considered;
#   * `pacman -Rcs --print` is evaluated first and the transaction is refused
#     if it would touch Omarchy itself, the kernel/GPU stack, the display
#     manager, PipeWire, NetworkManager or another base component;
#   * package configuration files are kept (no `-n`), so dotfiles and settings
#     are still there if the user changes their mind.

if [[ -n ${_OMACACHY_DESKTOPS:-} ]]; then return 0; fi
_OMACACHY_DESKTOPS=1

REMOVE_EXISTING_DE="${REMOVE_EXISTING_DE:-0}"

DETECTED_SESSION_NAMES=()
DETECTED_SESSION_PKGS=()
DETECTED_SESSION_FILES=()

# Packages that must never be pulled out by a desktop removal. The pattern is
# intentionally broader than the desktop set: a broken boot, network or GPU
# stack is much worse than a leftover session entry.
is_protected_package() {
  local pkg=$1
  case $pkg in
    omarchy | omarchy-* | hyprland | hyprland-* | sddm | sddm-* | quickshell | uwsm)
      return 0 ;;
    linux | linux-* | linux-firmware* | amd-ucode | intel-ucode | nvidia* | mesa | vulkan-* | lib32-*)
      return 0 ;;
    networkmanager | nm-* | iwd | wpa_supplicant | dhcpcd | systemd-resolved)
      return 0 ;;
    pipewire | pipewire-* | wireplumber | pulseaudio* | alsa-* | sof-firmware)
      return 0 ;;
    systemd | systemd-* | dbus | dbus-broker | glibc | gcc-libs | bash | coreutils | util-linux)
      return 0 ;;
    pacman | pacman-* | sudo | polkit | filesystem | base | base-devel | archlinux-keyring | cachyos-keyring)
      return 0 ;;
    wayland | wayland-protocols | xdg-desktop-portal | xdg-desktop-portal-*)
      return 0 ;;
  esac
  return 1
}

# Fill DETECTED_SESSION_* from the session files installed on the machine.
# Omarchy's own session and SDDM are never candidates.
detect_current_desktops() {
  DETECTED_SESSION_NAMES=()
  DETECTED_SESSION_PKGS=()
  DETECTED_SESSION_FILES=()

  local dir file pkg name
  local -A seen=()

  for dir in \
    /usr/local/share/xsessions \
    /usr/local/share/wayland-sessions \
    /usr/share/xsessions \
    /usr/share/wayland-sessions; do
    [[ -d $dir ]] || continue
    for file in "$dir"/*.desktop; do
      [[ -e $file ]] || continue
      pkg=$(pacman -Qoq "$file" 2>/dev/null || true)
      name=$(sed -n 's/^Name=//p' "$file" 2>/dev/null | head -1)

      case $pkg in
        '' | omarchy | omarchy-* | sddm | sddm-*) continue ;;
      esac
      # Hyprland is reused by Omarchy; do not tear it out just to reinstall it.
      [[ $pkg == hyprland ]] && continue
      [[ -n ${seen[$pkg]:-} ]] && continue

      seen[$pkg]=1
      DETECTED_SESSION_PKGS+=("$pkg")
      DETECTED_SESSION_NAMES+=("${name:-$pkg}")
      DETECTED_SESSION_FILES+=("$file")
    done
  done

  # CachyOS ships config packages that own ~/.config/hypr through skel. They are
  # not session providers, but they must go if Omarchy's configuration is to
  # win. Keep them in the same candidate list so one confirmation covers both.
  for pkg in cachyos-hyprland-settings cachyos-hypr-noctalia; do
    pkg_installed "$pkg" || continue
    [[ -n ${seen[$pkg]:-} ]] && continue
    seen[$pkg]=1
    DETECTED_SESSION_PKGS+=("$pkg")
    DETECTED_SESSION_NAMES+=("$pkg (CachyOS Hyprland configuration)")
    DETECTED_SESSION_FILES+=("")
  done

  debug "sessions: ${DETECTED_SESSION_NAMES[*]:-none}"
}

detected_desktop_summary() {
  local i
  for i in "${!DETECTED_SESSION_NAMES[@]}"; do
    printf '%s [%s]\n' "${DETECTED_SESSION_NAMES[$i]}" "${DETECTED_SESSION_PKGS[$i]}"
  done
}

# Print the package name from a `pacman -Rs --print` line (name-version-rel).
print_target_name() {
  sed -E 's/-[^-]+-[^-]+$//' <<<"$1"
}

# Check a preflight transaction. Sets REMOVAL_BLOCKED to a human-readable list
# (empty when the transaction is safe).
check_removal_transaction() {
  local out=$1 line name
  REMOVAL_BLOCKED=''
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    name=$(print_target_name "$line")
    if is_protected_package "$name"; then
      REMOVAL_BLOCKED+="${REMOVAL_BLOCKED:+, }$name"
    fi
  done <<<"$out"
  [[ -z $REMOVAL_BLOCKED ]]
}

remove_existing_desktops() {
  (( REMOVE_EXISTING_DE )) || return 0

  step "desktop: removing the session that was already installed"
  detect_current_desktops

  if (( ${#DETECTED_SESSION_PKGS[@]} == 0 )); then
    info "No separate desktop environment or window manager detected"
    return 0
  fi

  local i pkg out
  local -a removed=() skipped=()
  for i in "${!DETECTED_SESSION_PKGS[@]}"; do
    pkg=${DETECTED_SESSION_PKGS[$i]}

    if ! pkg_installed "$pkg"; then
      continue
    fi

    if ! out=$(pacman -Rcs --print --noconfirm "$pkg" 2>&1); then
      warn "Not removing $pkg: pacman refused the transaction"
      while IFS= read -r line; do
        [[ -n $line ]] && warn "  $line"
      done <<<"$out"
      skipped+=("$pkg")
      continue
    fi

    if ! check_removal_transaction "$out"; then
      warn "Not removing $pkg: it would also remove protected packages: $REMOVAL_BLOCKED"
      skipped+=("$pkg")
      continue
    fi

    debug "removal targets for $pkg:"
    while IFS= read -r line; do
      [[ -n $line ]] && debug "  $line"
    done <<<"$out"

    if (( DRY_RUN )); then
      info "would remove $pkg and its unneeded dependencies"
      removed+=("$pkg")
      continue
    fi

    if run pacman -Rcs --noconfirm "$pkg"; then
      success "Removed $pkg"
      removed+=("$pkg")
    else
      warn "Could not remove $pkg; leaving it in place"
      skipped+=("$pkg")
    fi
  done

  if (( ${#removed[@]} )); then
    info "Removed: ${removed[*]}"
  fi
  if (( ${#skipped[@]} )); then
    warn "Not removed (protected or in use): ${skipped[*]}"
    warn "Omarchy can still be installed, but old session entries may remain."
  fi
}
