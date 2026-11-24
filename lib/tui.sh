#!/bin/bash
# shellcheck shell=bash
# The setup wizard and the install progress screen.
#
# Both screens follow the visual language of Omarchy's own installer: a
# centered wordmark, plain text (no box drawing), and gum for every widget
# (choose/confirm). That is why the layout adapts to the terminal instead of
# drawing a fixed-width frame: nothing can look squashed on a narrow console.
#
# The wizard runs *before* sudo; the progress screen runs as root. Both talk to
# the terminal through /dev/tty, so `curl ... | bash` keeps working (stdin is
# the script, not the keyboard) and sudo's terminal is used, not a pipe.
#
# gum draws on stderr and returns the answer on stdout, so the widgets are run
# with `</dev/tty 2>&3`: the UI lands on the terminal and the choice is captured.

if [[ -n ${_OMACACHY_TUI:-} ]]; then return 0; fi
_OMACACHY_TUI=1

TUI_ACTIVE=0
TUI_STTY=''
TUI_ROWS=24
TUI_COLS=80
TUI_PAD=0
TUI_TEXT_W=72
TUI_LOGO_W=69
TUI_USE_BIG=1
TUI_UTF8=0

TUI_ALT_ON=$'\033[?1049h'
TUI_ALT_OFF=$'\033[?1049l'
TUI_CURSOR_OFF=$'\033[?25l'
TUI_CURSOR_ON=$'\033[?25h'
TUI_WRAP_OFF=$'\033[?7l'
TUI_WRAP_ON=$'\033[?7h'
TUI_CLEAR=$'\033[2J\033[H'
TUI_RESET=$'\033[0m'
TUI_BOLD=$'\033[1m'
TUI_DIM=$'\033[2m'
TUI_RED=$'\033[38;2;247;118;142m'
TUI_GREEN=$'\033[38;2;158;206;106m'
TUI_CYAN=$'\033[38;2;125;207;255m'
TUI_ACCENT=$TUI_GREEN
TUI_TAGLINE='Omarchy on CachyOS'

# gum colours: Omarchy green for "OMA", cyan for "CACHY" and prompts, a dark
# foreground on green so the selected choice stays readable.
GUM_GREEN='#9ece6a'
GUM_CYAN='#7dcfff'
GUM_DARK='#1a1b26'
GUM_TEXT='#c0caf5'

# Split between "OMA" and "CACHY" in the big wordmark (character columns).
TUI_LOGO_SPLIT=28

# Same wordmark shape as Omarchy's installer, sized to fit an 80-column
# console (69 wide). Narrow or non-UTF-8 terminals get the plain name.
TUI_LOGO_BIG=(
  ' ██████╗ ███╗   ███╗ █████╗  ██████╗ █████╗  ██████╗██╗  ██╗██╗   ██╗'
  '██╔═══██╗████╗ ████║██╔══██╗██╔════╝██╔══██╗██╔════╝██║  ██║╚██╗ ██╔╝'
  '██║   ██║██╔████╔██║███████║██║     ███████║██║     ███████║ ╚████╔╝ '
  '██║   ██║██║╚██╔╝██║██╔══██║██║     ██╔══██║██║     ██╔══██║  ╚██╔╝  '
  '╚██████╔╝██║ ╚═╝ ██║██║  ██║╚██████╗██║  ██║╚██████╗██║  ██║   ██║   '
  ' ╚═════╝ ╚═╝     ╚═╝╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝   ╚═╝   '
)

TUI_PROGRESS_ACTIVE=0
TUI_PROGRESS_DIR=''
TUI_PROGRESS_RENDER_PID=''
TUI_PROGRESS_LOG_OFFSET=0
TUI_LOG_REDIRECTED=0

# --- terminal primitives ----------------------------------------------------

tui_utf8() {
  [[ $(locale charmap 2>/dev/null) == UTF-8 ]]
}

tui_measure() {
  local size rows cols

  size=$(stty size <&3 2>/dev/null || true)
  rows=${size%% *}
  cols=${size##* }
  [[ $rows =~ ^[0-9]+$ ]] || rows=${LINES:-24}
  [[ $cols =~ ^[0-9]+$ ]] || cols=${COLUMNS:-80}
  if (( rows < 1 )); then rows=24; fi
  if (( cols < 1 )); then cols=80; fi
  if (( rows < 10 )); then rows=10; fi
  if (( cols < 40 )); then cols=40; fi
  TUI_ROWS=$rows
  TUI_COLS=$cols

  if (( TUI_UTF8 )) && (( cols >= ${#TUI_LOGO_BIG[0]} + 4 )); then
    TUI_USE_BIG=1
    TUI_LOGO_W=${#TUI_LOGO_BIG[0]}
  else
    TUI_USE_BIG=0
    TUI_LOGO_W=${#TUI_TAGLINE}
  fi
  if (( TUI_LOGO_W < 9 )); then TUI_LOGO_W=9; fi

  TUI_PAD=$(( (cols - TUI_LOGO_W) / 2 ))
  if (( TUI_PAD < 0 )); then TUI_PAD=0; fi

  TUI_TEXT_W=$(( cols - TUI_PAD - 3 ))
  if (( TUI_TEXT_W > 78 )); then TUI_TEXT_W=78; fi
  if (( TUI_TEXT_W < 30 )); then TUI_TEXT_W=30; fi
}

tui_clip() {
  local s=$1 w=$2 suffix='…'
  if (( ! TUI_UTF8 )); then suffix='...'; fi
  if (( w < 1 )); then return 0; fi
  if (( ${#s} <= w )); then
    printf '%s' "$s"
  else
    printf '%s%s' "${s:0:$(( w - ${#suffix} ))}" "$suffix"
  fi
}

tui_open() {
  [[ -r /dev/tty && -w /dev/tty ]] || return 1
  exec 3<>/dev/tty || return 1
  TUI_ACTIVE=1
  TUI_STTY=$(stty -g <&3 2>/dev/null || true)
  TUI_UTF8=0
  if tui_utf8; then TUI_UTF8=1; fi

  export GUM_CHOOSE_SHOW_HELP=false
  export GUM_CONFIRM_SHOW_HELP=false
  export GUM_FILTER_SHOW_HELP=false
  export GUM_INPUT_SHOW_HELP=false

  printf '%s%s%s%s' "$TUI_ALT_ON" "$TUI_CURSOR_OFF" "$TUI_WRAP_OFF" "$TUI_CLEAR" >&3
  trap 'tui_close; exit 130' INT TERM
  return 0
}

tui_close() {
  (( TUI_ACTIVE )) || return 0
  printf '%s%s%s' "$TUI_CURSOR_ON" "$TUI_WRAP_ON" "$TUI_ALT_OFF" >&3 2>/dev/null || true
  if [[ -n $TUI_STTY ]]; then stty "$TUI_STTY" <&3 2>/dev/null || true; fi
  exec 3>&-
  TUI_ACTIVE=0
  trap - INT TERM
  return 0
}

tui_abort() {
  tui_close
  {
    printf '\n%sAborted.%s Nothing has been changed.\n' "$TUI_BOLD" "$TUI_RESET"
    printf 'Run the installer again when you are ready.\n'
  } >/dev/tty 2>/dev/null || true
  exit 1
}

tui_after_say() {
  { printf '%s\n' "$@"; } >/dev/tty 2>/dev/null || true
}

# --- drawing ----------------------------------------------------------------

# Draw the wordmark and, optionally, a wrapped question and description.
#   tui_frame "question" "description line" ...
tui_frame() {
  local question=${1:-}
  shift || true
  local line pad tag tpad

  tui_measure

  {
    printf '%s' "$TUI_CLEAR"

    if (( TUI_USE_BIG )); then
      local left right
      for line in "${TUI_LOGO_BIG[@]}"; do
        left=${line:0:TUI_LOGO_SPLIT}
        right=${line:TUI_LOGO_SPLIT}
        printf '%*s%s%s%s%s%s%s\n' "$TUI_PAD" '' \
          "$TUI_GREEN$TUI_BOLD" "$left" \
          "$TUI_CYAN$TUI_BOLD" "$right" \
          "$TUI_RESET"
      done
    else
      printf '%*s%s%sOMA%s%sCACHY%s\n' "$TUI_PAD" '' \
        "$TUI_GREEN$TUI_BOLD" "$TUI_RESET" \
        "$TUI_CYAN$TUI_BOLD" "$TUI_RESET"
    fi

    tag=$TUI_TAGLINE
    tpad=$(( TUI_PAD + (TUI_LOGO_W - ${#tag}) / 2 ))
    if (( tpad < 0 )); then tpad=0; fi
    printf '%*s%s%s%s\n\n' "$tpad" '' "$TUI_DIM" "$tag" "$TUI_RESET"

    if [[ -n $question ]]; then
      while IFS= read -r line; do
        printf '%*s%s%s%s\n' "$TUI_PAD" '' "$TUI_CYAN$TUI_BOLD" "$line" "$TUI_RESET"
      done < <(printf '%s\n' "$question" | fold -s -w "$TUI_TEXT_W")
      printf '\n'
    fi

    for line in "$@"; do
      while IFS= read -r tag; do
        printf '%*s%s%s%s\n' "$TUI_PAD" '' "$TUI_DIM" "$tag" "$TUI_RESET"
      done < <(printf '%s\n' "$line" | fold -s -w "$TUI_TEXT_W")
    done
  } >&3 2>/dev/null || true
}

tui_say() {
  local line
  tui_measure
  {
    for line in "$@"; do
      while IFS= read -r tag; do
        printf '%*s%s\n' "$TUI_PAD" '' "$tag"
      done < <(printf '%s\n' "$line" | fold -s -w "$TUI_TEXT_W")
    done
  } >&3 2>/dev/null || true
}

tui_hint() {
  tui_measure
  printf '%*s%s%s%s\n' "$TUI_PAD" '' "$TUI_DIM" "$1" "$TUI_RESET" >&3 2>/dev/null || true
}

# Yes is always listed first, whatever the default is. The safe default is
# preselected (so Enter keeps it), but the order never changes and nobody can
# pick No by accident because the labels moved.
# Returns 0 for Yes, 1 for No. Ctrl+C aborts.
tui_yes_no() {
  local question=$1 default=$2
  shift 2
  local selected=Yes choice status=0

  [[ $default == no ]] && selected=No

  tui_frame "" "$@"
  tui_measure
  tui_hint 'Up/Down: move   Enter: confirm   Ctrl+C: abort'

  choice=$(GUM_CHOOSE_PADDING="0 0 0 $TUI_PAD" \
    gum choose \
      --height 2 \
      --header "$question" \
      --header.foreground "$GUM_CYAN" \
      --cursor.foreground "$GUM_GREEN" \
      --item.foreground "$GUM_TEXT" \
      --selected.foreground "$GUM_DARK" \
      --selected.background "$GUM_GREEN" \
      --selected "$selected" \
      -- Yes No </dev/tty 2>&3) || status=$?

  # Esc and Ctrl+C both leave without an answer: abort rather than guess.
  (( status == 0 )) || tui_abort
  [[ $choice == Yes ]]
}

# A notice with a way back to the question that produced it.
tui_message() {
  local title=$1
  shift
  local status=0

  tui_frame "$title" "$@"
  tui_measure
  tui_hint 'Enter: back to the question   Ctrl+C: abort'

  GUM_CONFIRM_PADDING="0 0 0 $TUI_PAD" \
    gum confirm \
      --prompt.foreground "$GUM_CYAN" \
      --selected.foreground "$GUM_DARK" \
      --selected.background "$GUM_GREEN" \
      --unselected.foreground "$GUM_TEXT" \
      --affirmative 'Back' --negative 'Abort' \
      'Back to the question?' </dev/tty >/dev/null 2>&3 || status=$?

  (( status == 0 )) || tui_abort
}

# --- setup wizard -----------------------------------------------------------

tui_run() {
  local apps_sel de_sel limine_sel entry_sel greeter_sel osid_sel browser_sel shell_sel backup_fish_sel
  local -a summary
  local detect_de=0 action=0

  apps_sel=$(( NO_APPS ? 1 : 0 ))
  de_sel=$(( REMOVE_EXISTING_DE ? 0 : 1 ))
  greeter_sel=$(( NO_GREETER ? 1 : 0 ))
  shell_sel=$([[ ${OMACACHY_SHELL:-fish} == bash ]] && echo 1 || echo 0)
  backup_fish_sel=$(( BACKUP_FISH ? 0 : 1 ))
  osid_sel=0
  [[ ${OS_IDENTITY_MODE:-cachyos} == omarchy ]] && osid_sel=1
  limine_sel=0
  entry_sel=1
  [[ $BOOT_MODE == convert ]] && entry_sel=0

  detect_current_desktops
  detect_conflicting_desktops
  detect_esp
  detect_limine
  (( ${#DETECTED_SESSION_PKGS[@]} )) && detect_de=1

  while :; do
    # 1. Omarchy's preinstalled applications.
    if (( SKIP_PACKAGES )); then
      apps_sel=0
    else
      local apps_default=no
      (( apps_sel == 0 )) && apps_default=yes
      if tui_yes_no \
        "Do you want the preinstalled applications of Omarchy?" "$apps_default" \
        "Omarchy ships a set of desktop applications: Chromium, LibreOffice," \
        "Obsidian, Nautilus, mpv, the Omarchy apps (Omacalc, Omawrite, Hype," \
        "Monologue, ...) and a few utilities." \
        "" \
        "No installs the desktop only. The shell, terminal, fonts, audio," \
        "networking, input methods and Omarchy's CLI are always installed."; then
        apps_sel=0
      else
        apps_sel=1
      fi
    fi

    # 2. The desktop that is already installed.
    if (( detect_de )); then
      local -a de_lines=()
      while IFS= read -r line; do de_lines+=("$line"); done < <(detected_desktop_summary)
      local de_default=no
      (( de_sel == 0 )) && de_default=yes
      if tui_yes_no \
        "Do you want to uninstall your current DE or WM?" "$de_default" \
        "Detected on this machine:" "" "${de_lines[@]}"; then
        de_sel=0
      else
        de_sel=1
        if (( ${#CONFLICTING_PACKAGES[@]} )); then
          tui_message "Heads up" \
            "${CONFLICTING_PACKAGES[*]} ship their own Hyprland configuration and" \
            "will compete with Omarchy's. Removing them is recommended."
        fi
      fi
    else
      de_sel=1
    fi

    # 3. Default browser.
    local browser_sel="${OMACACHY_BROWSER:-chromium}"
    [[ $browser_sel == auto ]] && browser_sel=chromium
    if (( ! SKIP_PACKAGES )); then
      tui_frame "" \
        "Choose the default browser to install and set as default."
      tui_measure
      tui_hint 'Up/Down: move   Enter: confirm   Ctrl+C: abort'
      local browser_choice browser_status=0 browser_selected="Chromium"
      case "$browser_sel" in
        chromium) browser_selected="Chromium" ;;
        firefox) browser_selected="Firefox" ;;
        brave-bin) browser_selected="Brave" ;;
        zen-browser) browser_selected="Zen Browser" ;;
        helium-browser) browser_selected="Helium Browser" ;;
      esac
      browser_choice=$(GUM_CHOOSE_PADDING="0 0 0 $TUI_PAD" \
        gum choose \
          --height 5 \
          --header "Which browser do you want as default?" \
          --header.foreground "$GUM_CYAN" \
          --cursor.foreground "$GUM_GREEN" \
          --item.foreground "$GUM_TEXT" \
          --selected.foreground "$GUM_DARK" \
          --selected.background "$GUM_GREEN" \
          --selected "$browser_selected" \
          -- "Chromium" "Firefox" "Brave" "Zen Browser" "Helium Browser" </dev/tty 2>&3) || browser_status=$?
      (( browser_status == 0 )) || tui_abort
      case "$browser_choice" in
        "Chromium") browser_sel=chromium ;;
        "Firefox") browser_sel=firefox ;;
        "Brave") browser_sel=brave-bin ;;
        "Zen Browser") browser_sel=zen-browser ;;
        "Helium Browser") browser_sel=helium-browser ;;
        *) browser_sel=chromium ;;
      esac
    else
      browser_sel=chromium
    fi

    # 4. Shell.
    local shell_default="Fish"
    [[ ${OMACACHY_SHELL:-fish} == bash ]] && shell_default="Bash (Omarchy's Default)"
    tui_frame "" \
      "Choose the shell you want to use."
    tui_measure
    tui_hint 'Up/Down: move   Enter: confirm   Ctrl+C: abort'
    local shell_choice shell_status=0
    shell_choice=$(GUM_CHOOSE_PADDING="0 0 0 $TUI_PAD" \
      gum choose \
        --height 2 \
        --header "Which shell do you want to use?:" \
        --header.foreground "$GUM_CYAN" \
        --cursor.foreground "$GUM_GREEN" \
        --item.foreground "$GUM_TEXT" \
        --selected.foreground "$GUM_DARK" \
        --selected.background "$GUM_GREEN" \
        --selected "$shell_default" \
        -- "Fish" "Bash (Omarchy's Default)" </dev/tty 2>&3) || shell_status=$?
    (( shell_status == 0 )) || tui_abort
    if [[ $shell_choice == "Bash (Omarchy's Default)" ]]; then
      shell_sel=1
      if tui_yes_no "Do you want to back up your existing fish config?" no \
        "This copies ~/.config/fish to a timestamped backup before switching to Bash."; then
        backup_fish_sel=0
      else
        backup_fish_sel=1
      fi
    else
      shell_sel=0
      backup_fish_sel=1
    fi

    # 5. Limine.
    local limine_default=yes
    [[ $BOOT_MODE == skip ]] && limine_default=no
    while :; do
      local -a limine_desc=(
        "Limine is Omarchy's bootloader (UKIs + snapshot rollback)."
        "Omarchy's packages hard-depend on limine, limine-mkinitcpio-hook,"
        "limine-snapper-sync and snapper."
      )
      (( LIMINE_DEPLOYED )) && limine_desc+=("Limine already appears to be deployed on this machine.")
      if tui_yes_no "Do you want to install Limine? (Omarchy requires it)" \
        "$limine_default" "${limine_desc[@]}"; then
        limine_sel=1
        local entry_default=no
        (( entry_sel == 0 )) && entry_default=yes
        if tui_yes_no "Make Limine the default boot entry?" "$entry_default" \
          "Register adds Limine to the firmware menu and leaves your current" \
          "default boot entry untouched." \
          "" \
          "Convert makes Limine the default right now."; then
          entry_sel=0
          BOOT_MODE=convert
        else
          entry_sel=1
          BOOT_MODE=register
        fi
        break
      fi

      limine_sel=0
      if (( LIMINE_DEPLOYED )) || [[ $BOOT_MODE_SET == 1 && $BOOT_MODE == skip ]]; then
        BOOT_MODE=skip
        break
      fi

      tui_message "Limine is required" \
        "Omarchy's packages hard-depend on limine, limine-mkinitcpio-hook," \
        "limine-snapper-sync and snapper. Without Limine there is no" \
        "Omarchy install." \
        "" \
        "Press Enter to go back, or Ctrl+C to abort."
    done

    # 5. The login greeter.
    local greeter_default=yes
    (( greeter_sel == 1 )) && greeter_default=no
    if tui_yes_no "Do you want Omarchy's login greeter?" "$greeter_default" \
      "Omarchy ships its own SDDM greeter theme." \
      "" \
      "No keeps the SDDM theme that is active on this machine now."; then
      greeter_sel=0
    else
      greeter_sel=1
    fi

    # 6. System name shown by the OS.
    tui_frame "" \
      "Choose which name the system should show in /etc/os-release." \
      "" \
      "CachyOS keeps the CachyOS identity (recommended)." \
      "Omarchy makes the system report Omarchy."
    tui_measure
    tui_hint 'Up/Down: move   Enter: confirm   Ctrl+C: abort'
    local osid_choice osid_status=0 osid_selected="CachyOS (keep system identity)"
    (( osid_sel == 1 )) && osid_selected="Omarchy (show Omarchy as system)"
    osid_choice=$(GUM_CHOOSE_PADDING="0 0 0 $TUI_PAD" \
      gum choose \
        --height 2 \
        --header "What system name do you want?" \
        --header.foreground "$GUM_CYAN" \
        --cursor.foreground "$GUM_GREEN" \
        --item.foreground "$GUM_TEXT" \
        --selected.foreground "$GUM_DARK" \
        --selected.background "$GUM_GREEN" \
        --selected "$osid_selected" \
        -- "CachyOS (keep system identity)" "Omarchy (show Omarchy as system)" </dev/tty 2>&3) || osid_status=$?
    (( osid_status == 0 )) || tui_abort
    [[ $osid_choice == "Omarchy (show Omarchy as system)" ]] && osid_sel=1 || osid_sel=0

    # 5. Summary and final confirmation.
    local -a summary=()
    if (( SKIP_PACKAGES )); then
      summary+=("Packages       unchanged (--skip-packages)")
    elif (( apps_sel == 0 )); then
      summary+=("Applications   Omarchy's preinstalled apps")
    else
      summary+=("Applications   desktop only (no preinstalled apps)")
    fi
    if (( SKIP_PACKAGES )); then
      summary+=("Browser        unchanged (--skip-packages)")
    else
      case "$browser_sel" in
        firefox) summary+=("Browser        Firefox") ;;
        brave-bin) summary+=("Browser        Brave") ;;
        zen-browser) summary+=("Browser        Zen Browser") ;;
        helium-browser) summary+=("Browser        Helium Browser") ;;
        *) summary+=("Browser        Chromium") ;;
      esac
    fi
    if (( shell_sel == 1 )); then
      if (( backup_fish_sel == 0 )); then summary+=("Shell          Bash (backup fish)"); else summary+=("Shell          Bash"); fi
    else
      summary+=("Shell          Fish")
    fi
    if (( detect_de == 0 )); then
      summary+=("Current DE/WM  none detected")
    elif (( de_sel == 0 )); then
      summary+=("Current DE/WM  remove: ${DETECTED_SESSION_PKGS[*]}")
    else
      summary+=("Current DE/WM  keep: ${DETECTED_SESSION_PKGS[*]}")
    fi
    case $BOOT_MODE in
      register) summary+=("Boot           install Limine, keep the current default") ;;
      convert) summary+=("Boot           install Limine and make it the default") ;;
      skip) summary+=("Boot           leave Limine/boot order alone") ;;
      *) summary+=("Boot           $BOOT_MODE") ;;
    esac
    if (( greeter_sel == 1 )); then
      summary+=("Login greeter  keep the current SDDM theme")
    else
      summary+=("Login greeter  Omarchy's SDDM theme")
    fi
    if (( osid_sel == 1 )); then
      summary+=("System name    Omarchy")
    else
      summary+=("System name    CachyOS")
    fi

    tui_frame "Setup summary"
    tui_say "" "${summary[@]}" ""
    tui_measure
    tui_hint 'Enter: install   Left/Right: change answers   Ctrl+C: abort'

    action=0
    GUM_CONFIRM_PADDING="0 0 0 $TUI_PAD" \
      gum confirm \
        --prompt.foreground "$GUM_CYAN" \
        --selected.foreground "$GUM_DARK" \
        --selected.background "$GUM_GREEN" \
        --unselected.foreground "$GUM_TEXT" \
        --affirmative 'Install' --negative 'Change answers' \
        "Are you sure you want to continue?" </dev/tty >/dev/null 2>&3 || action=$?

    (( action == 130 )) && tui_abort
    (( action == 0 )) && break
    # Esc and "Change answers" both go back to the questions.
  done

  NO_APPS=$apps_sel
  REMOVE_EXISTING_DE=$(( de_sel == 0 ? 1 : 0 ))
  NO_GREETER=$greeter_sel
  OS_IDENTITY_MODE=$( (( osid_sel == 1 )) && echo omarchy || echo cachyos )
  OMACACHY_BROWSER=${browser_sel:-chromium}
  OMACACHY_SHELL=$( (( shell_sel == 1 )) && echo bash || echo fish )
  OMACACHY_SHELL_EXPLICIT=1
  BACKUP_FISH=$(( backup_fish_sel == 0 ? 1 : 0 ))
  SETUP_FISH=$(( shell_sel == 0 ? 1 : 0 ))
  if (( limine_sel == 0 )); then BOOT_MODE=skip; fi

  tui_close

  local -a summary_text=()
  summary_text+=("" "OmaCachy - Omarchy on CachyOS" "")
  if (( SKIP_PACKAGES )); then
    summary_text+=("  Packages        unchanged")
  elif (( NO_APPS )); then
    summary_text+=("  Applications    desktop only (no preinstalled apps)")
  else
    summary_text+=("  Applications    Omarchy's preinstalled apps")
  fi
  if (( ! SKIP_PACKAGES )); then
    case "${OMACACHY_BROWSER:-chromium}" in
      firefox) summary_text+=("  Browser         Firefox") ;;
      brave-bin) summary_text+=("  Browser         Brave") ;;
      zen-browser) summary_text+=("  Browser         Zen Browser") ;;
      helium-browser) summary_text+=("  Browser         Helium Browser") ;;
      *) summary_text+=("  Browser         Chromium") ;;
    esac
  fi
  if [[ ${OMACACHY_SHELL:-fish} == bash ]]; then
    if (( BACKUP_FISH )); then summary_text+=("  Shell           Bash (fish config backed up)"); else summary_text+=("  Shell           Bash"); fi
  else
    summary_text+=("  Shell           Fish")
  fi
  if (( detect_de == 0 )); then
    summary_text+=("  Current DE/WM   none detected")
  elif (( REMOVE_EXISTING_DE )); then
    summary_text+=("  Current DE/WM   remove: ${DETECTED_SESSION_PKGS[*]}")
  else
    summary_text+=("  Current DE/WM   keep: ${DETECTED_SESSION_PKGS[*]}")
  fi
  case $BOOT_MODE in
    register) summary_text+=("  Boot            install Limine, keep the current default") ;;
    convert) summary_text+=("  Boot            install Limine and make it the default") ;;
    skip) summary_text+=("  Boot            leave Limine/boot order alone") ;;
  esac
  if (( NO_GREETER )); then
    summary_text+=("  Login greeter   keep the current SDDM theme")
  else
    summary_text+=("  Login greeter   Omarchy's SDDM theme")
  fi
  if [[ ${OS_IDENTITY_MODE:-cachyos} == omarchy ]]; then
    summary_text+=("  System name     Omarchy")
  else
    summary_text+=("  System name     CachyOS")
  fi
  summary_text+=("" "Starting the install; sudo will ask for your password." "")

  tui_after_say "${summary_text[@]}"
}

# gum is the setup UI. It is a tiny package in CachyOS's extra repository, and
# Omarchy's own package set installs it anyway; install it now so the screens
# work before pacman has run.
tui_ensure_gum() {
  have gum && return 0

  info "The setup screens use gum; installing it with pacman"
  if sudo pacman -S --needed --noconfirm gum </dev/tty >&2; then
    return 0
  fi
  return 1
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
  if [[ ! -r /dev/tty || ! -w /dev/tty ]]; then
    warn "No terminal available for the interactive setup; using defaults"
    warn "Pass --yes for unattended installs, or --boot=register/convert explicitly"
    return 0
  fi
  if ! tui_ensure_gum; then
    warn "gum is unavailable; skipping the interactive setup and using defaults"
    warn "Pass --yes for unattended installs, or --boot=register/convert explicitly"
    return 0
  fi
  if ! tui_open; then
    warn "No terminal available for the interactive setup; using defaults"
    warn "Pass --yes for unattended installs, or --boot=register/convert explicitly"
    return 0
  fi

  tui_run
}

# --- progress screen (root) -------------------------------------------------

tui_progress_enabled() {
  [[ ${NO_PROGRESS:-0} != 0 ]] && return 1
  [[ ${OMACACHY_NO_PROGRESS:-0} != 0 ]] && return 1
  [[ ${OMACACHY_NO_TUI:-0} != 0 ]] && return 1
  [[ -r /dev/tty && -w /dev/tty ]] || return 1
  return 0
}

tui_progress_start() {
  tui_progress_enabled || return 1

  exec 3<>/dev/tty || return 1
  TUI_ACTIVE=1
  TUI_STTY=$(stty -g <&3 2>/dev/null || true)
  TUI_UTF8=0
  if tui_utf8; then TUI_UTF8=1; fi
  printf '%s%s%s%s' "$TUI_ALT_ON" "$TUI_CURSOR_OFF" "$TUI_WRAP_OFF" "$TUI_CLEAR" >&3

  if ! mkdir -p "$OMACACHY_LOG_DIR" 2>/dev/null; then
    tui_close
    return 1
  fi
  : >>"$OMACACHY_LOG_FILE" 2>/dev/null || { tui_close; return 1; }
  TUI_PROGRESS_DIR=$(mktemp -d "${TMPDIR:-/tmp}/omacachy-tui.XXXXXX") || { tui_close; return 1; }
  : >"$TUI_PROGRESS_DIR/phases"
  printf '0\n' >"$TUI_PROGRESS_DIR/current"
  printf 'running\n' >"$TUI_PROGRESS_DIR/status"
  TUI_PROGRESS_LOG_OFFSET=$(stat -c %s "$OMACACHY_LOG_FILE" 2>/dev/null || echo 0)

  ( tui_progress_renderer "$TUI_PROGRESS_DIR" "$TUI_PROGRESS_LOG_OFFSET" ) &
  TUI_PROGRESS_RENDER_PID=$!
  TUI_PROGRESS_ACTIVE=1

  # Everything the install prints goes to the log; the progress screen (fd 3)
  # is the only thing that touches the terminal from now on.
  exec >>"$OMACACHY_LOG_FILE" 2>&1
  TUI_LOG_REDIRECTED=1
  trap 'tui_progress_exit $?' EXIT
  trap 'exit 130' INT TERM
  return 0
}

tui_progress_phase() {
  (( TUI_PROGRESS_ACTIVE )) || return 0
  [[ -n ${TUI_PROGRESS_DIR:-} ]] || return 0
  printf '%s\n' "$1" >>"$TUI_PROGRESS_DIR/phases"
  local n
  n=$(wc -l <"$TUI_PROGRESS_DIR/phases")
  printf '%s\n' "$(( n - 1 ))" >"$TUI_PROGRESS_DIR/current"
}

# One screen line, in gum's palette and padded to the same column as the
# wizard. Tags: A accent-bold, D dim, G green, R red, P plain.
tui_progress_line() {
  local tag=$1 text=$2 color=''
  case $tag in
    A) color=$TUI_CYAN$TUI_BOLD ;;
    D) color=$TUI_DIM ;;
    G) color=$TUI_GREEN ;;
    R) color=$TUI_RED ;;
  esac
  text=$(tui_clip "$text" "$TUI_TEXT_W")
  printf '%*s%s%s%s\033[K\n' "$TUI_PAD" '' "$color" "$text" "$TUI_RESET"
}

tui_progress_renderer() {
  local dir=$1 offset=$2
  local -a frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  local ok_mark='✓' fail_mark='✗' wait_mark='·' more_mark='…'
  if (( ! TUI_UTF8 )); then
    frames=('|' '/' '-' '\')
    ok_mark='OK' fail_mark='XX' wait_mark='-' more_mark='...'
  fi
  local tick=0 start=$SECONDS elapsed last current status i mark tag
  local maxshow first n_lines
  set +e
  exec 2>/dev/null

  while [[ ! -e $dir/stop ]]; do
    local -a phases=()
    mapfile -t phases <"$dir/phases" 2>/dev/null
    current=$(cat "$dir/current" 2>/dev/null || echo 0)
    status=$(cat "$dir/status" 2>/dev/null || echo running)
    [[ $current =~ ^[0-9]+$ ]] || current=0
    elapsed=$(( SECONDS - start ))

    tui_measure
    n_lines=$(( TUI_ROWS - 4 ))
    (( n_lines < 6 )) && n_lines=6

    {
      printf '\033[H'

      if (( TUI_USE_BIG )) && (( TUI_ROWS >= 28 )); then
        local left right
        for i in "${TUI_LOGO_BIG[@]}"; do
          left=${i:0:TUI_LOGO_SPLIT}
          right=${i:TUI_LOGO_SPLIT}
          printf '%*s%s%s%s%s%s%s\033[K\n' "$TUI_PAD" '' \
            "$TUI_GREEN$TUI_BOLD" "$left" \
            "$TUI_CYAN$TUI_BOLD" "$right" \
            "$TUI_RESET"
        done
        tui_progress_line D "$TUI_TAGLINE"
        printf '\n'
        n_lines=$(( n_lines - ${#TUI_LOGO_BIG[@]} - 2 ))
      else
        printf '%*s%sOMA%s%sCACHY%s\033[K\n' "$TUI_PAD" '' \
          "$TUI_GREEN$TUI_BOLD" "$TUI_RESET" \
          "$TUI_CYAN$TUI_BOLD" "$TUI_RESET"
        tui_progress_line D "$TUI_TAGLINE"
        printf '\n'
        n_lines=$(( n_lines - 3 ))
      fi

      # The phase list keeps the phases that are still relevant: all of them
      # when they fit, otherwise the tail plus a count of what scrolled away.
      maxshow=$(( n_lines - 5 ))
      (( maxshow < 3 )) && maxshow=3
      first=0
      (( ${#phases[@]} > maxshow )) && first=$(( ${#phases[@]} - maxshow ))
      if (( first > 0 )); then
        tui_progress_line D "$more_mark $first earlier phase(s)"
      fi

      for (( i = first; i < ${#phases[@]}; i++ )); do
        tag=P
        if (( i < current )); then
          mark=$ok_mark; tag=G
        elif (( i == current )); then
          if [[ $status == failed ]]; then mark=$fail_mark; tag=R
          elif [[ $status == done ]]; then mark=$ok_mark; tag=G
          else mark=${frames[tick % ${#frames[@]}]}; tag=A; fi
        else
          mark=$wait_mark; tag=D
        fi
        tui_progress_line "$tag" "$mark ${phases[i]}"
      done
      if (( ${#phases[@]} == 0 )); then
        tui_progress_line A "${frames[tick % ${#frames[@]}]} Preparing..."
      fi

      printf '\n'
      last=$(tail -c +$(( offset + 1 )) "$OMACACHY_LOG_FILE" 2>/dev/null |
        sed -e $'s/\033\\[[0-9;?]*[A-Za-z]//g' |
        sed '/^[[:space:]]*$/d' | tail -n 1)
      tui_progress_line D "  ${last:-working...}"

      printf '\n'
      if (( DRY_RUN )); then
        tui_progress_line D "dry run - nothing will be changed"
      fi
      tui_progress_line D "elapsed $(( elapsed / 60 ))m$(( elapsed % 60 ))s   log: $OMACACHY_LOG_FILE"

      printf '\033[J'
    } >&3

    sleep 0.15
    tick=$(( tick + 1 ))
  done
}

tui_progress_exit() {
  local rc=${1:-0}
  (( TUI_PROGRESS_ACTIVE )) || return 0
  TUI_PROGRESS_ACTIVE=0

  local dir=$TUI_PROGRESS_DIR
  if [[ -n $dir ]]; then
    if (( rc == 0 )); then printf 'done\n' >"$dir/status" 2>/dev/null
    else printf 'failed\n' >"$dir/status" 2>/dev/null; fi
    : >"$dir/stop" 2>/dev/null
  fi

  if [[ -n $TUI_PROGRESS_RENDER_PID ]]; then
    kill "$TUI_PROGRESS_RENDER_PID" 2>/dev/null || true
    wait "$TUI_PROGRESS_RENDER_PID" 2>/dev/null || true
  fi

  printf '%s%s%s' "$TUI_CURSOR_ON" "$TUI_WRAP_ON" "$TUI_ALT_OFF" >&3 2>/dev/null || true
  if [[ -n $TUI_STTY ]]; then stty "$TUI_STTY" <&3 2>/dev/null || true; fi

  {
    printf '\n'
    if (( rc == 0 )); then
      printf '%s✓%s OmaCachy: Omarchy is ready.\n' "$TUI_GREEN" "$TUI_RESET"
      printf '  Log: %s\n' "$OMACACHY_LOG_FILE"
      printf '  Next: reboot, then pick the Omarchy session in SDDM.\n'
    else
      printf '%s✗%s OmaCachy: install failed (exit %s).\n' "$TUI_RED$TUI_RESET" "$rc"
      printf '  Last log lines:\n'
      tail -n 12 "$OMACACHY_LOG_FILE" 2>/dev/null | sed 's/^/    /'
      printf '  Full log: %s\n' "$OMACACHY_LOG_FILE"
    fi
    printf '\n'
  } >&3 2>/dev/null || true

  exec 3>&-
  TUI_ACTIVE=0
  TUI_LOG_REDIRECTED=0
  trap - EXIT INT TERM
  [[ -n $dir ]] && rm -rf "$dir"
  return 0
}
