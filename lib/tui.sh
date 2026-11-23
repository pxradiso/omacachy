#!/bin/bash
# shellcheck shell=bash
# Interactive setup shown by ./install.sh and `omacachy install`.
#
# It uses gum for the UI (Omarchy green, Yes always before No). It reads
# from stdin so it also works for the `curl ... | bash` path (where stdin is
# the script itself) — gum is told to read from /dev/tty when a real terminal
# is present, otherwise it falls back to non-interactive defaults.
# The installer then re-executes itself through sudo with the matching flags,
# so the privileged half never needs to ask a human.

if [[ -n ${_OMACACHY_TUI:-} ]]; then return 0; fi
_OMACACHY_TUI=1

OMACACHY_GREEN="#9ece6a"

TUI_ACTIVE=0

tui_open() {
  # We read answers from stdin; /dev/tty is only used by gum when available.
  [[ -t 0 ]] || return 0
  TUI_ACTIVE=1
}

tui_close() {
  (( TUI_ACTIVE )) || return 0
  # Restore the terminal after gum (it puts the tty in raw/alternate mode).
  stty sane 2>/dev/null || true
  TUI_ACTIVE=0
}

tui_logo() {
  # Green bold ASCII logo printed with raw ANSI (gum mangles the backticks
  # and apostrophes inside the Omarchy-style art).
  local g=$'\033[1;38;2;158;206;106m' r=$'\033[0m'
  printf '%b\n' "$g"
  cat <<'EOF'
   _______   _       _   _             
  |__   __| | |     | | (_)            
     | | ___| |_ ___| |_ _ _ __   __ _ 
     | |/ _ \ __/ _ \ __| | '_ \ / _` |
     | |  __/ ||  __/ |_| | | | | (_| |
     |_|\___|\__\___|\__|_|_| |_|\__,_|
EOF
  printf '%b\n' "$r"
  tui_gum style --foreground="$OMACACHY_GREEN" --bold "OmaCachy  Omarchy on CachyOS"
}

# tui_gum ARGS...: run gum; stdin stays as-is (the script's stdin), which is
# fine because gum prompts on the terminal by default.
tui_gum() {
  gum "$@"
}

tui_banner() {
  # Fullscreen look: clear the screen first, then the framed banner.
  clear >/dev/tty 2>/dev/null || clear 2>/dev/null || true
  tui_logo
  tui_gum style \
    --foreground="$OMACACHY_GREEN" \
    --border=normal \
    --border-foreground="$OMACACHY_GREEN" \
    --padding="2 4" \
    --margin="2" \
    "Install Omarchy on your existing CachyOS system." \
    "" \
    "CachyOS keeps its kernel, drivers, pacman.conf, mirrors and" \
    "/etc/os-release. Omarchy keeps its own update flow ('omarchy update')."
}

# tui_yes_no "question" yes|no -> 0 for yes, 1 for no.
# Yes is always the affirmative answer; No is the safe default.
tui_yes_no() {
  local prompt=$1 default=$2
  if (( ASSUME_YES )); then return 0; fi
  if [[ $default == yes ]]; then
    tui_gum confirm --prompt.foreground="$OMACACHY_GREEN" --default=true "$prompt"
  else
    tui_gum confirm --prompt.foreground="$OMACACHY_GREEN" --default=false "$prompt"
  fi
}

tui_abort() {
  tui_gum style --foreground="$OMACACHY_GREEN" --bold "Aborted. Nothing has been changed."
  exit 1
}

tui_limine_questions() {
  local default_entry=no
  [[ $BOOT_MODE == convert ]] && default_entry=yes

  if ! tui_yes_no "Install Limine? (Omarchy requires it)" "$1"; then
    if (( LIMINE_DEPLOYED )) || [[ $BOOT_MODE_SET == 1 && $BOOT_MODE == skip ]]; then
      BOOT_MODE=skip
      tui_gum style --foreground="$OMACACHY_GREEN" "Limine handling left to you (--boot=skip)."
      return 0
    fi
    tui_gum style --foreground="$OMACACHY_GREEN" ""
    tui_gum style --foreground="$OMACACHY_GREEN" "Omarchy's packages hard-depend on Limine"
    tui_gum style --foreground="$OMACACHY_GREEN" "(limine-mkinitcpio-hook, limine-snapper-sync)."
    tui_gum style --foreground="$OMACACHY_GREEN" "Without it there is no Omarchy install."
    tui_abort
  fi

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
    tui_gum style --foreground="$OMACACHY_GREEN" "Packages: skipped (--skip-packages)."
  else
    tui_gum style --foreground="$OMACACHY_GREEN" "Omarchy ships a set of desktop applications:"
    tui_gum style --foreground="$OMACACHY_GREEN" "Chromium, LibreOffice, Obsidian, Nautilus, mpv and the Omarchy apps"
    tui_gum style --foreground="$OMACACHY_GREEN" "(Omacalc, Omawrite, Hype, Monologue, ...) plus a few utilities."
    if tui_yes_no "Do you want Omarchy's preinstalled applications?" "$apps_default"; then
      NO_APPS=0
    else
      NO_APPS=1
    fi
  fi
  tui_gum style --foreground="$OMACACHY_GREEN" ""

  # 2. The desktop that is already installed.
  detect_current_desktops
  detect_conflicting_desktops
  (( REMOVE_EXISTING_DE )) && de_default=yes
  if (( ${#DETECTED_SESSION_PKGS[@]} )); then
    tui_gum style --foreground="$OMACACHY_GREEN" "Detected on this machine:"
    while IFS= read -r de_line; do
      tui_gum style --foreground="$OMACACHY_GREEN" "  - $de_line"
    done < <(detected_desktop_summary)
    tui_gum style --foreground="$OMACACHY_GREEN" ""
    if tui_yes_no "Do you want to uninstall your current DE or WM?" "$de_default"; then
      REMOVE_EXISTING_DE=1
    else
      REMOVE_EXISTING_DE=0
      if (( ${#CONFLICTING_PACKAGES[@]} )); then
        tui_gum style --foreground="$OMACACHY_GREEN" ""
        tui_gum style --foreground="$OMACACHY_GREEN" "Warning: ${CONFLICTING_PACKAGES[*]} ship their own Hyprland"
        tui_gum style --foreground="$OMACACHY_GREEN" "configuration and will compete with Omarchy's. Removing them is recommended."
      fi
    fi
  else
    tui_gum style --foreground="$OMACACHY_GREEN" "No separate desktop environment or window manager was detected."
    REMOVE_EXISTING_DE=0
  fi
  tui_gum style --foreground="$OMACACHY_GREEN" ""

  # 3. Limine.
  detect_esp
  detect_limine
  [[ $BOOT_MODE == skip ]] && limine_default=no
  tui_gum style --foreground="$OMACACHY_GREEN" "Boot: Limine is Omarchy's bootloader (UKIs + snapshot rollback)."
  if (( LIMINE_DEPLOYED )); then
    tui_gum style --foreground="$OMACACHY_GREEN" "      Limine already appears to be deployed on this machine."
  fi
  tui_limine_questions "$limine_default"
  tui_gum style --foreground="$OMACACHY_GREEN" ""

  # 4. The login greeter.
  (( NO_GREETER )) && greeter_default=no
  tui_gum style --foreground="$OMACACHY_GREEN" "Login: Omarchy ships its own SDDM greeter theme."
  if tui_yes_no "Do you want Omarchy's login greeter?" "$greeter_default"; then
    NO_GREETER=0
  else
    NO_GREETER=1
  fi
  tui_gum style --foreground="$OMACACHY_GREEN" ""

  # 5. Summary and final confirmation.
  tui_gum style --foreground="$OMACACHY_GREEN" --bold "Summary:"
  if (( SKIP_PACKAGES )); then
    tui_gum style --foreground="$OMACACHY_GREEN" "  Packages        unchanged (--skip-packages)"
  elif (( NO_APPS )); then
    tui_gum style --foreground="$OMACACHY_GREEN" "  Applications    desktop only (no preinstalled apps)"
  else
    tui_gum style --foreground="$OMACACHY_GREEN" "  Applications    Omarchy's preinstalled apps"
  fi
  if (( ${#DETECTED_SESSION_PKGS[@]} == 0 )); then
    tui_gum style --foreground="$OMACACHY_GREEN" "  Current DE/WM   none detected"
  elif (( REMOVE_EXISTING_DE )); then
    tui_gum style --foreground="$OMACACHY_GREEN" "  Current DE/WM   remove: ${DETECTED_SESSION_PKGS[*]}"
  else
    tui_gum style --foreground="$OMACACHY_GREEN" "  Current DE/WM   keep: ${DETECTED_SESSION_PKGS[*]}"
  fi
  case $BOOT_MODE in
    register) tui_gum style --foreground="$OMACACHY_GREEN" "  Boot            install Limine, keep the current default" ;;
    convert) tui_gum style --foreground="$OMACACHY_GREEN" "  Boot            install Limine and make it the default" ;;
    skip) tui_gum style --foreground="$OMACACHY_GREEN" "  Boot            leave Limine/boot order alone" ;;
    *) tui_gum style --foreground="$OMACACHY_GREEN" "  Boot            $BOOT_MODE" ;;
  esac
  if (( NO_GREETER )); then
    tui_gum style --foreground="$OMACACHY_GREEN" "  Login greeter   keep the current SDDM theme"
  else
    tui_gum style --foreground="$OMACACHY_GREEN" "  Login greeter   Omarchy's SDDM theme"
  fi
  tui_gum style --foreground="$OMACACHY_GREEN" ""

  if ! tui_yes_no "Are you sure you want to continue?" no; then
    tui_abort
  fi

  tui_gum style --foreground="$OMACACHY_GREEN" ""
  tui_gum style --foreground="$OMACACHY_GREEN" "Starting the install; sudo will ask for your password."
  tui_gum style --foreground="$OMACACHY_GREEN" ""
}

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
    warn "No interactive terminal available; using defaults"
    warn "Pass --yes for unattended installs, or --boot=register/convert explicitly"
    return 0
  fi

  tui_run
  tui_close
}
