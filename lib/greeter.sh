#!/bin/bash
# shellcheck shell=bash
# Keep the machine's previous SDDM greeter when the user declines Omarchy's.
#
# Omarchy's `omarchy-settings` package ships /etc/sddm.conf.d/10-theme.conf with
# `Current=omarchy`, and `omarchy update` may rewrite it. When the user answers
# "no" to Omarchy's login greeter, OmaCachy records the theme that was active
# before the install and writes a later-sorting drop-in
# (zz-omacachy-greeter.conf) so it keeps winning. A pacman PostTransaction hook
# reinstalls that drop-in after omarchy/omarchy-settings upgrades, so
# `omarchy update` does not silently switch the greeter back.

if [[ -n ${_OMACACHY_GREETER:-} ]]; then return 0; fi
_OMACACHY_GREETER=1

NO_GREETER="${NO_GREETER:-0}"

SDDM_CONFIG_DIR=/etc/sddm.conf.d
OMACACHY_GREETER_DROPIN="$SDDM_CONFIG_DIR/zz-omacachy-greeter.conf"
OMACACHY_GREETER_RESTORE=/usr/local/lib/omacachy/restore-greeter
OMACACHY_GREETER_HOOK=/etc/pacman.d/hooks/omacachy-greeter.hook

sddm_theme_from_file() {
  local file=$1
  [[ -r $file ]] || return 1
  sed -n -E 's/^[[:space:]]*Current[[:space:]]*=[[:space:]]*//p' "$file" | tail -1
}

# Record the theme that is active before Omarchy's packages are installed.
# Leaves SDDM_PREVIOUS_THEME empty when the machine had no explicit theme.
capture_sddm_theme() {
  local file value theme=''

  for file in /etc/sddm.conf "$SDDM_CONFIG_DIR"/*.conf; do
    [[ -r $file ]] || continue
    value=$(sddm_theme_from_file "$file" || true)
    [[ -n $value ]] && theme=$value
  done

  # A previous OmaCachy run already knows the answer; an Omarchy theme value is
  # not a user preference, so fall back to the recorded one in that case.
  if [[ -z $theme || $theme == omarchy ]]; then
    value=$(state_get OMACACHY_SDDM_THEME 2>/dev/null || true)
    [[ -n $value ]] && theme=$value
  fi

  SDDM_PREVIOUS_THEME=$theme
  write_state OMACACHY_SDDM_THEME "$theme"
  write_state OMACACHY_GREETER_PREFERENCE "$( ((NO_GREETER)) && echo keep || echo omarchy )"
  debug "sddm theme: ${theme:-<default>} (preference: $( ((NO_GREETER)) && echo keep || echo omarchy ))"
}

greeter_fallback_theme() {
  local theme
  for theme in cachyos breeze elarun maldives maya; do
    [[ -d /usr/share/sddm/themes/$theme ]] && { printf '%s\n' "$theme"; return 0; }
  done
  return 1
}

# The drop-in must sort after Omarchy's 10-theme.conf and after the unowned
# 99-omarchy-login.conf, hence the "zz-" prefix.
write_greeter_dropin() {
  local theme=$1
  mkdir -p "$SDDM_CONFIG_DIR"
  {
    echo "# OmaCachy: keep the greeter theme that was configured before Omarchy."
    echo "[Theme]"
    echo "Current=$theme"
  } >"$OMACACHY_GREETER_DROPIN"
  chmod 0644 "$OMACACHY_GREETER_DROPIN"
}

remove_greeter_dropin() {
  if [[ -e $OMACACHY_GREETER_DROPIN ]]; then
    rm -f "$OMACACHY_GREETER_DROPIN"
    info "Removed $OMACACHY_GREETER_DROPIN (Omarchy's greeter is selected)"
  fi
}

apply_greeter_preference() {
  local theme

  if (( ! NO_GREETER )); then
    write_state OMACACHY_GREETER_PREFERENCE omarchy
    if (( DRY_RUN )); then
      info "would keep Omarchy's SDDM greeter"
      return 0
    fi
    remove_greeter_dropin
    return 0
  fi

  write_state OMACACHY_GREETER_PREFERENCE keep
  theme=${SDDM_PREVIOUS_THEME:-$(state_get OMACACHY_SDDM_THEME 2>/dev/null || true)}
  if [[ -z $theme || $theme == omarchy ]]; then
    theme=$(greeter_fallback_theme || true)
  fi
  [[ -n $theme ]] || theme=elarun

  if (( DRY_RUN )); then
    info "would keep the previous SDDM greeter theme: $theme"
    return 0
  fi

  write_greeter_dropin "$theme"
  success "Keeping the previous SDDM greeter theme: $theme"
}

install_greeter_guard() {
  if (( DRY_RUN )); then
    info "would install $OMACACHY_GREETER_RESTORE and $OMACACHY_GREETER_HOOK"
    return 0
  fi

  install -d -m 0755 "$(dirname "$OMACACHY_GREETER_RESTORE")"
  cat >"$OMACACHY_GREETER_RESTORE" <<'EOF'
#!/bin/bash
# Installed by OmaCachy.
#
# omarchy-settings ships /etc/sddm.conf.d/10-theme.conf with Current=omarchy and
# omarchy update may replace it. If the user chose to keep the pre-Omarchy
# greeter, restore OmaCachy's later-sorting drop-in after the transaction.
set -eu

state=/var/lib/omacachy/state.env
dropin=/etc/sddm.conf.d/zz-omacachy-greeter.conf

preference=$(sed -n 's/^OMACACHY_GREETER_PREFERENCE=//p' "$state" 2>/dev/null | tail -1 || true)

if [[ $preference == keep ]]; then
  theme=$(sed -n 's/^OMACACHY_SDDM_THEME=//p' "$state" 2>/dev/null | tail -1 || true)
  [[ -n $theme ]] || theme=elarun
  install -d -m 0755 /etc/sddm.conf.d
  {
    echo "# OmaCachy: keep the greeter theme that was configured before Omarchy."
    echo "[Theme]"
    echo "Current=$theme"
  } >"$dropin"
  chmod 0644 "$dropin"
  echo "OmaCachy: kept the previous SDDM greeter theme ($theme)"
else
  rm -f "$dropin"
fi
EOF
  chmod 0755 "$OMACACHY_GREETER_RESTORE"

  install -d -m 0755 /etc/pacman.d/hooks
  cat >"$OMACACHY_GREETER_HOOK" <<'EOF'
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = omarchy
Target = omarchy-settings

[Action]
Description = Keeping the pre-Omarchy SDDM greeter (OmaCachy)
When = PostTransaction
Exec = /usr/local/lib/omacachy/restore-greeter
EOF
  chmod 0644 "$OMACACHY_GREETER_HOOK"

  info "SDDM greeter guard installed (survives omarchy update)"
}
