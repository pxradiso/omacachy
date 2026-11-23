#!/bin/bash
# shellcheck shell=bash
# The interactive setup shown by ./install.sh and `omacachy install`.
#
# It runs *before* sudo is requested, reads from /dev/tty (a `curl ... | bash`
# pipe owns stdin) and only records answers. The installer then re-executes
# itself through sudo with the matching flags, so the privileged half never
# needs to ask a human.

if [[ -n ${_OMACACHY_TUI:-} ]]; then return 0; fi
_OMACACHY_TUI=1

TUI_FD=3
TUI_ACTIVE=0

tui_say() {
  printf '%s\n' "$*" >&"$TUI_FD"
}

tui_say_n() {
  printf '%s' "$*" >&"$TUI_FD"
}

tui_open() {
  [[ -r /dev/tty && -w /dev/tty ]] || return 1
  exec 3<>/dev/tty || return 1
  TUI_ACTIVE=1
}

tui_close() {
  (( TUI_ACTIVE )) || return 0
  exec 3>&- 3<&-
  TUI_ACTIVE=0
}

tui_banner() {
  tui_say ""
  tui_say "${C_BOLD}OmaCachy${C_RESET} - Omarchy on CachyOS"
  tui_say ""
  tui_say "This installs the Omarchy desktop on top of your existing CachyOS system."
  tui_say "CachyOS keeps its kernel, drivers, pacman.conf, mirrors, hostname and"
  tui_say "/etc/os-release. Omarchy keeps its own update flow (omarchy update)."
  tui_say ""
}

# tui_yes_no "question" yes|no -> 0 for yes, 1 for no. Re-asks on invalid input.
# Yes is always the affirmative answer (y/yes/SI), No is n/N.
# The suffix shows [Y/n] when default is yes, [y/N] otherwise.
tui_yes_no() {
  local prompt=$1 default=$2 answer suffix
  [[ $default == yes ]] && suffix='[Y/n]' || suffix='[y/N]'

  while :; do
    tui_say_n "  $prompt $suffix "
    if ! IFS= read -r answer <&"$TUI_FD"; then
      tui_say ""
      return 1
    fi
    answer=${answer//[[:space:]]/}
    case ${answer,,} in
      y | yes | s | si | sì) return 0 ;;
      n | no) return 1 ;;
      '') [[ $default == yes ]] && return 0 || return 1 ;;
      *) tui_say "  Please answer y or n." ;;
    esac
  done
}

tui_abort() {
  tui_say ""
  tui_say "Aborted. Nothing has been changed."
  exit 1
}

tui_limine_questions() {
  local default_entry=no

  if ! tui_yes_no "Do you want to install Limine? (Omarchy requires it)" "$1"; then
    if (( LIMINE_DEPLOYED )) || [[ $BOOT_MODE_SET == 1 && $BOOT_MODE == skip ]]; then
      BOOT_MODE=skip
      tui_say "  Limine handling is left to you (--boot=skip)."
      return 0
    fi
    tui_say ""
    tui_say "  Omarchy's packages hard-depend on Limine (limine-mkinitcpio-hook,"
    tui_say "  limine-snapper-sync). Without it there is no Omarchy install."
    tui_abort
  fi

  [[ $BOOT_MODE == convert ]] && default_entry=yes
  if tui_yes_no "Make Limine the default boot entry?" "$default_entry"; then
    BOOT_MODE=convert
  else
    BOOT_MODE=register
  fi
}

tui_run() {
  local apps_default=yes de_default=no greeter_default=yes limine_default=yes
  local de_line

  tui_banner

  # 1. Omarchy's preinstalled applications.
  (( NO_APPS )) && apps_default=no
  if (( SKIP_PACKAGES )); then
    tui_say "Packages: skipped by --skip-packages."
  else
    tui_say "Omarchy ships a set of desktop applications: Chromium, LibreOffice,"
    tui_say "Obsidian, Nautilus, mpv, the Omarchy apps (Omacalc, Omawrite, Hype,"
    tui_say "Monologue, ...) and a few utilities."
    if tui_yes_no "Do you want the preinstalled applications of Omarchy?" "$apps_default"; then
      NO_APPS=0
    else
      NO_APPS=1
    fi
  fi
  tui_say ""

  # 2. The desktop that is already installed.
  detect_current_desktops
  detect_conflicting_desktops
  (( REMOVE_EXISTING_DE )) && de_default=yes
  if (( ${#DETECTED_SESSION_PKGS[@]} )); then
    tui_say "Detected on this machine:"
    while IFS= read -r de_line; do
      tui_say "  - $de_line"
    done < <(detected_desktop_summary)
    tui_say ""
    if tui_yes_no "Do you want to uninstall your current DE or WM?" "$de_default"; then
      REMOVE_EXISTING_DE=1
    else
      REMOVE_EXISTING_DE=0
      if (( ${#CONFLICTING_PACKAGES[@]} )); then
        tui_say ""
        tui_say "  ${C_YELLOW}Warning:${C_RESET} ${CONFLICTING_PACKAGES[*]} ship their own Hyprland"
        tui_say "  configuration and will compete with Omarchy's. Removing them is recommended."
      fi
    fi
  else
    tui_say "No separate desktop environment or window manager was detected."
    REMOVE_EXISTING_DE=0
  fi
  tui_say ""

  # 3. Limine.
  detect_esp
  detect_limine
  [[ $BOOT_MODE == skip ]] && limine_default=no
  tui_say "Boot: Limine is Omarchy's bootloader (UKIs + snapshot rollback)."
  if (( LIMINE_DEPLOYED )); then
    tui_say "      Limine already appears to be deployed on this machine."
  fi
  tui_limine_questions "$limine_default"
  tui_say ""

  # 4. The login greeter.
  (( NO_GREETER )) && greeter_default=no
  tui_say "Login: Omarchy ships its own SDDM greeter theme."
  if tui_yes_no "Do you want Omarchy's login greeter?" "$greeter_default"; then
    NO_GREETER=0
  else
    NO_GREETER=1
  fi
  tui_say ""

  # 5. Summary and final confirmation.
  tui_say "Summary:"
  if (( SKIP_PACKAGES )); then
    tui_say "  Packages        unchanged (--skip-packages)"
  elif (( NO_APPS )); then
    tui_say "  Applications    desktop only (no preinstalled apps)"
  else
    tui_say "  Applications    Omarchy's preinstalled apps"
  fi
  if (( ${#DETECTED_SESSION_PKGS[@]} == 0 )); then
    tui_say "  Current DE/WM   none detected"
  elif (( REMOVE_EXISTING_DE )); then
    tui_say "  Current DE/WM   remove: ${DETECTED_SESSION_PKGS[*]}"
  else
    tui_say "  Current DE/WM   keep: ${DETECTED_SESSION_PKGS[*]}"
  fi
  case $BOOT_MODE in
    register) tui_say "  Boot            install Limine, keep the current default" ;;
    convert) tui_say "  Boot            install Limine and make it the default" ;;
    skip) tui_say "  Boot            leave Limine/boot order alone" ;;
    *) tui_say "  Boot            $BOOT_MODE" ;;
  esac
  if (( NO_GREETER )); then
    tui_say "  Login greeter   keep the current SDDM theme"
  else
    tui_say "  Login greeter   Omarchy's SDDM theme"
  fi
  tui_say ""

  if ! tui_yes_no "Are you sure you want to continue?" no; then
    tui_abort
  fi

  tui_say ""
  tui_say "Starting the install; sudo will ask for your password."
  tui_say ""
}

# maybe_run_tui: show the questions once, before root privileges are requested.
maybe_run_tui() {
  if (( TUI_DONE )); then return 0; fi
  if (( ASSUME_YES )); then
    info "Non-interactive mode (--yes): using the command-line defaults"
    return 0
  fi
  if [[ ${OMACACHY_NO_TUI:-0} != 0 ]]; then
    info "Interactive setup disabled by OMACACHY_NO_TUI"
    return 0
  fi
  if ! tui_open; then
    warn "No terminal available for the interactive setup; using defaults"
    warn "Pass --yes for unattended installs, or --boot=register/convert explicitly"
    return 0
  fi

  tui_run
  tui_close
}
