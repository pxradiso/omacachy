#!/bin/bash
# shellcheck shell=bash
# Final steps and the human-readable summary.

if [[ -n ${_OMACACHY_FINALIZE:-} ]]; then return 0; fi
_OMACACHY_FINALIZE=1

OMACACHY_ENV_PATCH=/usr/local/lib/omacachy/patch-omarchy-env
OMACACHY_ENV_HOOK=/etc/pacman.d/hooks/omacachy-omarchy-env.hook
OMACACHY_PROVISION_PATCH=/usr/local/lib/omacachy/patch-omarchy-provision
OMACACHY_PROVISION_HOOK=/etc/pacman.d/hooks/omacachy-omarchy-provision.hook
OMACACHY_VERSION_CHANNEL_PATCH=/usr/local/lib/omacachy/patch-omarchy-version-channel
OMACACHY_VERSION_CHANNEL_HOOK=/etc/pacman.d/hooks/omacachy-omarchy-version-channel.hook
OMACACHY_FASTFETCH_PATCH=/usr/local/lib/omacachy/patch-omarchy-fastfetch
OMACACHY_FASTFETCH_HOOK=/etc/pacman.d/hooks/omacachy-omarchy-fastfetch.hook
OMACACHY_OPENCODE_RESTART_PATCH=/usr/local/lib/omacachy/patch-omarchy-opencode-restart
OMACACHY_OPENCODE_RESTART_HOOK=/etc/pacman.d/hooks/omacachy-omarchy-opencode-restart.hook

install_omacachy_command() {
  local bin=/usr/local/bin/omacachy
  local target="$OMACACHY_REPO/bin/omacachy"
  local browser_bin=/usr/local/bin/omacachy-browser-default
  local browser_target="$OMACACHY_REPO/bin/omacachy-browser-default"

  [[ -x $target ]] || {
    warn "omacachy command not installed: $target is missing"
    return 0
  }

  if (( DRY_RUN )); then
    info "would symlink $bin -> $target"
    [[ -x $browser_target ]] && info "would symlink $browser_bin -> $browser_target"
    return 0
  fi

  mkdir -p /usr/local/bin
  ln -sfn "$target" "$bin"
  [[ -x $browser_target ]] && ln -sfn "$browser_target" "$browser_bin"
  success "Installed omacachy command: $bin"
}

patch_omarchy_fastfetch_env() {
  local f

  if (( DRY_RUN )); then
    info "would ensure omarchy-i18n/omarchy-language default OMARCHY_PATH"
    return 0
  fi

  for f in /usr/bin/omarchy-i18n /usr/bin/omarchy-language; do
    [[ -f $f ]] || continue
    grep -q 'OMARCHY_PATH:=/usr/share/omarchy' "$f" && continue
    backup_file "$f" "$(basename "$f")"
    sed -i '/^set -euo pipefail$/a : "${OMARCHY_PATH:=/usr/share/omarchy}"' "$f"
    success "Patched $f: defaults OMARCHY_PATH for fastfetch/non-login shells"
  done
}

patch_omarchy_version_channel() {
  local f=/usr/bin/omarchy-version-channel
  [[ -f $f ]] || return 0
  grep -q 'omacachy-stable-channel' "$f" && return 0

  if (( DRY_RUN )); then
    info "would patch omarchy-version-channel to report stable on OmaCachy"
    return 0
  fi

  backup_file "$f" "$(basename "$f")"
  python3 - <<'PY'
from pathlib import Path
p = Path('/usr/bin/omarchy-version-channel')
s = p.read_text()
patterns = [
    (r"""if [[ $mirror == "unknown" || $pkgs == "unknown" ]]; then
  echo "unknown"
elif [[ $mirror == "$pkgs" ]]; then
  echo "$mirror"
else
  echo "$mirror / $pkgs"
fi""",
     r"""# omacachy-stable-channel: CachyOS keeps its own mirrorlist; Omarchy packages use stable.
if [[ $pkgs == "unknown" ]] && grep -q "https://pkgs.omarchy.org/stable/" /etc/pacman.conf 2>/dev/null; then
  pkgs="stable"
fi
if [[ $mirror == "unknown" && $pkgs == "stable" ]]; then
  mirror="stable"
fi

if [[ $mirror == "unknown" || $pkgs == "unknown" ]]; then
  echo "unknown"
elif [[ $mirror == "$pkgs" ]]; then
  echo "$mirror"
else
  echo "$mirror / $pkgs"
fi"""),
    (r"""if [[ $mirror == $pkgs ]]; then
  echo $mirror
else
  echo "$mirror / $pkgs"
fi""",
     r"""# omacachy-stable-channel: CachyOS keeps its own mirrorlist; Omarchy packages use stable.
if [[ $pkgs == "unknown" ]] && grep -q "https://pkgs.omarchy.org/stable/" /etc/pacman.conf 2>/dev/null; then
  pkgs="stable"
fi
if [[ $mirror == "unknown" && $pkgs == "stable" ]]; then
  mirror="stable"
fi

if [[ $mirror == $pkgs ]]; then
  echo $mirror
else
  echo "$mirror / $pkgs"
fi"""),
]
for old, new in patterns:
    if old in s:
        p.write_text(s.replace(old, new))
        break
PY
  success "Patched omarchy-version-channel for OmaCachy stable reporting"
}

install_omarchy_version_channel_guard() {
  if (( DRY_RUN )); then
    info "would install $OMACACHY_VERSION_CHANNEL_PATCH and $OMACACHY_VERSION_CHANNEL_HOOK"
    return 0
  fi

  install -d -m 0755 "$(dirname "$OMACACHY_VERSION_CHANNEL_PATCH")"
  cat >"$OMACACHY_VERSION_CHANNEL_PATCH" <<'EOF'
#!/bin/bash
set -eu
f=/usr/bin/omarchy-version-channel
[[ -f $f ]] || exit 0
grep -q 'omacachy-stable-channel' "$f" && exit 0
python3 - <<'PY'
from pathlib import Path
p = Path('/usr/bin/omarchy-version-channel')
s = p.read_text()
patterns = [
    (r"""if [[ $mirror == "unknown" || $pkgs == "unknown" ]]; then
  echo "unknown"
elif [[ $mirror == "$pkgs" ]]; then
  echo "$mirror"
else
  echo "$mirror / $pkgs"
fi""",
     r"""# omacachy-stable-channel: CachyOS keeps its own mirrorlist; Omarchy packages use stable.
if [[ $pkgs == "unknown" ]] && grep -q "https://pkgs.omarchy.org/stable/" /etc/pacman.conf 2>/dev/null; then
  pkgs="stable"
fi
if [[ $mirror == "unknown" && $pkgs == "stable" ]]; then
  mirror="stable"
fi

if [[ $mirror == "unknown" || $pkgs == "unknown" ]]; then
  echo "unknown"
elif [[ $mirror == "$pkgs" ]]; then
  echo "$mirror"
else
  echo "$mirror / $pkgs"
fi"""),
    (r"""if [[ $mirror == $pkgs ]]; then
  echo $mirror
else
  echo "$mirror / $pkgs"
fi""",
     r"""# omacachy-stable-channel: CachyOS keeps its own mirrorlist; Omarchy packages use stable.
if [[ $pkgs == "unknown" ]] && grep -q "https://pkgs.omarchy.org/stable/" /etc/pacman.conf 2>/dev/null; then
  pkgs="stable"
fi
if [[ $mirror == "unknown" && $pkgs == "stable" ]]; then
  mirror="stable"
fi

if [[ $mirror == $pkgs ]]; then
  echo $mirror
else
  echo "$mirror / $pkgs"
fi"""),
]
for old, new in patterns:
    if old in s:
        p.write_text(s.replace(old, new))
        print('OmaCachy: patched omarchy-version-channel')
        break
PY
EOF
  chmod 0755 "$OMACACHY_VERSION_CHANNEL_PATCH"

  install -d -m 0755 /etc/pacman.d/hooks
  cat >"$OMACACHY_VERSION_CHANNEL_HOOK" <<'EOF'
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = omarchy

[Action]
Description = Patching Omarchy version channel for OmaCachy
When = PostTransaction
Exec = /usr/local/lib/omacachy/patch-omarchy-version-channel
EOF
  chmod 0644 "$OMACACHY_VERSION_CHANNEL_HOOK"
  info "Omarchy version-channel guard installed (survives omarchy update)"
}

install_omarchy_env_guard() {
  if (( DRY_RUN )); then
    info "would install $OMACACHY_ENV_PATCH and $OMACACHY_ENV_HOOK"
    return 0
  fi

  install -d -m 0755 "$(dirname "$OMACACHY_ENV_PATCH")"
  cat >"$OMACACHY_ENV_PATCH" <<'EOF'
#!/bin/bash
# Installed by OmaCachy.
# omarchy-i18n/omarchy-language use OMARCHY_PATH with set -u; fastfetch command
# modules may run without that env, so provide a safe default.
set -eu
for f in /usr/bin/omarchy-i18n /usr/bin/omarchy-language; do
  [[ -f $f ]] || continue
  grep -q 'OMARCHY_PATH:=/usr/share/omarchy' "$f" && continue
  sed -i '/^set -euo pipefail$/a : "${OMARCHY_PATH:=/usr/share/omarchy}"' "$f"
  echo "OmaCachy: patched $(basename "$f") with default OMARCHY_PATH"
done
EOF
  chmod 0755 "$OMACACHY_ENV_PATCH"

  install -d -m 0755 /etc/pacman.d/hooks
  cat >"$OMACACHY_ENV_HOOK" <<'EOF'
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = omarchy

[Action]
Description = Patching Omarchy scripts for fastfetch env (OmaCachy)
When = PostTransaction
Exec = /usr/local/lib/omacachy/patch-omarchy-env
EOF
  chmod 0644 "$OMACACHY_ENV_HOOK"
  info "Omarchy env guard installed (survives omarchy update)"
}

patch_omarchy_fastfetch_config() {
  local f=/etc/fastfetch/config.jsonc
  [[ -f $f ]] || return 0
  grep -q 'OmaCachy fastfetch OS identity' "$f" && return 0

  if (( DRY_RUN )); then
    info "would patch fastfetch config to show CachyOS identity on OmaCachy"
    return 0
  fi

  backup_file "$f" "$(basename "$f")"
  python3 - <<'PY'
from pathlib import Path
p = Path('/etc/fastfetch/config.jsonc')
s = p.read_text()
old = '"text": "version=$(omarchy-version) && echo \\"Omarchy $version\\""'
new = '"text": "ver=$(omarchy-version 2>/dev/null); . /etc/os-release 2>/dev/null; name=${PRETTY_NAME:-${NAME:-CachyOS Linux}}; if [ \\"${ID:-}\\" = omarchy ]; then echo \\"Omarchy ${ver}\\"; else echo \\"${name} / Omarchy ${ver}\\"; fi" // OmaCachy fastfetch OS identity'
if old in s:
    p.write_text(s.replace(old, new))
    print('OmaCachy: patched fastfetch OS identity')
PY
}

install_omarchy_fastfetch_guard() {
  if (( DRY_RUN )); then
    info "would install $OMACACHY_FASTFETCH_PATCH and $OMACACHY_FASTFETCH_HOOK"
    return 0
  fi

  install -d -m 0755 "$(dirname "$OMACACHY_FASTFETCH_PATCH")"
  cat >"$OMACACHY_FASTFETCH_PATCH" <<'EOF'
#!/bin/bash
# Installed by OmaCachy.
# Keep fastfetch reporting CachyOS identity on OmaCachy systems.
set -eu
f=/etc/fastfetch/config.jsonc
[[ -f $f ]] || exit 0
grep -q 'OmaCachy fastfetch OS identity' "$f" && exit 0
python3 - <<'PY'
from pathlib import Path
p = Path('/etc/fastfetch/config.jsonc')
s = p.read_text()
old = '"text": "version=$(omarchy-version) && echo \\"Omarchy $version\\""'
new = '"text": "ver=$(omarchy-version 2>/dev/null); . /etc/os-release 2>/dev/null; name=${PRETTY_NAME:-${NAME:-CachyOS Linux}}; if [ \\"${ID:-}\\" = omarchy ]; then echo \\"Omarchy ${ver}\\"; else echo \\"${name} / Omarchy ${ver}\\"; fi" // OmaCachy fastfetch OS identity'
if old in s:
    p.write_text(s.replace(old, new))
    print('OmaCachy: patched fastfetch OS identity')
PY
EOF
  chmod 0755 "$OMACACHY_FASTFETCH_PATCH"

  install -d -m 0755 /etc/pacman.d/hooks
  cat >"$OMACACHY_FASTFETCH_HOOK" <<'EOF'
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = omarchy-settings

[Action]
Description = Patching fastfetch OS identity for OmaCachy
When = PostTransaction
Exec = /usr/local/lib/omacachy/patch-omarchy-fastfetch
EOF
  chmod 0644 "$OMACACHY_FASTFETCH_HOOK"
  info "Fastfetch OS identity guard installed (survives omarchy-settings update)"
}


patch_omarchy_opencode_restart() {
  local f=/usr/bin/omarchy-restart-opencode
  [[ -f $f ]] || return 0
  grep -q 'opencode.exe' "$f" && return 0

  if (( DRY_RUN )); then
    info "would patch omarchy-restart-opencode for opencode.exe processes"
    return 0
  fi

  backup_file "$f" "$(basename "$f")"
  cat >"$f" <<'EOF'
#!/bin/bash

# omarchy:summary=Reload opencode configuration (used by the Omarchy theme switching).

for pat in opencode opencode.exe; do
  pgrep -x "$pat" >/dev/null 2>&1 && pkill -SIGUSR2 -x "$pat" 2>/dev/null || true
done
EOF
  chmod 0755 "$f"
  success "Patched omarchy-restart-opencode for opencode.exe"
}

install_omarchy_opencode_restart_guard() {
  local f=/usr/bin/omarchy-restart-opencode
  [[ -f $f ]] || return 0

  if (( DRY_RUN )); then
    info "would install omarchy-restart-opencode guard/hook"
    return 0
  fi

  mkdir -p /usr/local/lib/omacachy /etc/pacman.d/hooks
  cat >"$OMACACHY_OPENCODE_RESTART_PATCH" <<'EOF'
#!/bin/bash
set -euo pipefail
f=/usr/bin/omarchy-restart-opencode
[[ -f $f ]] || exit 0
grep -q 'opencode.exe' "$f" && exit 0
cat >"$f" <<'SCRIPT'
#!/bin/bash

# omarchy:summary=Reload opencode configuration (used by the Omarchy theme switching).

for pat in opencode opencode.exe; do
  pgrep -x "$pat" >/dev/null 2>&1 && pkill -SIGUSR2 -x "$pat" 2>/dev/null || true
done
SCRIPT
chmod 0755 "$f"
echo "OmaCachy: patched omarchy-restart-opencode for opencode.exe"
EOF
  chmod 0755 "$OMACACHY_OPENCODE_RESTART_PATCH"

  cat >"$OMACACHY_OPENCODE_RESTART_HOOK" <<EOF
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = omarchy

[Action]
Description = Keeping omarchy-restart-opencode compatible with opencode.exe (OmaCachy)
When = PostTransaction
Exec = $OMACACHY_OPENCODE_RESTART_PATCH
EOF
  info "omarchy-restart-opencode guard installed (survives omarchy update)"
}

patch_omarchy_provision_user() {
  local f=/usr/bin/omarchy-provision-user
  [[ -f $f ]] || return 0
  grep -q 'omacachy-browser-default' "$f" && return 0

  if (( DRY_RUN )); then
    info "would patch omarchy-provision-user to avoid hard chromium dependency"
    return 0
  fi

  backup_file "$f" "$(basename "$f")"
  python3 - <<'PY'
from pathlib import Path
p = Path('/usr/bin/omarchy-provision-user')
s = p.read_text()
old = """omarchy-refresh-applications
if command -v omacachy-browser-default >/dev/null 2>&1; then
  omacachy-browser-default
else
  browser_desktop=""
  for b in chromium.desktop firefox.desktop brave-browser.desktop zen-browser.desktop helium-browser.desktop; do
    [[ -f /usr/share/applications/$b ]] && browser_desktop=$b && break
  done
  [[ -n $browser_desktop ]] && env -u BROWSER XDG_CURRENT_DESKTOP= xdg-settings set default-web-browser "$browser_desktop" || true
fi
xdg-mime default HEY.desktop x-scheme-handler/mailto || true"""
new = """omarchy-refresh-applications
if command -v omacachy-browser-default >/dev/null 2>&1; then
  omacachy-browser-default
else
  browser_desktop=chromium.desktop
  for b in chromium.desktop firefox.desktop brave-browser.desktop zen-browser.desktop helium-browser.desktop; do
    [[ -f /usr/share/applications/$b ]] && browser_desktop=$b && break
  done
  env -u BROWSER XDG_CURRENT_DESKTOP= xdg-settings set default-web-browser "$browser_desktop" || true
fi
xdg-mime default HEY.desktop x-scheme-handler/mailto || true"""
if old in s:
    p.write_text(s.replace(old, new))
PY
  success "Patched omarchy-provision-user: browser default is resilient"
}

install_omarchy_provision_guard() {
  if (( DRY_RUN )); then
    info "would install $OMACACHY_PROVISION_PATCH and $OMACACHY_PROVISION_HOOK"
    return 0
  fi

  install -d -m 0755 "$(dirname "$OMACACHY_PROVISION_PATCH")"
  cat >"$OMACACHY_PROVISION_PATCH" <<'EOF'
#!/bin/bash
set -eu
f=/usr/bin/omarchy-provision-user
[[ -f $f ]] || exit 0
grep -q 'omacachy-browser-default' "$f" && exit 0
python3 - <<'PY'
from pathlib import Path
p = Path('/usr/bin/omarchy-provision-user')
s = p.read_text()
old = """omarchy-refresh-applications
if command -v omacachy-browser-default >/dev/null 2>&1; then
  omacachy-browser-default
else
  browser_desktop=""
  for b in chromium.desktop firefox.desktop brave-browser.desktop zen-browser.desktop helium-browser.desktop; do
    [[ -f /usr/share/applications/$b ]] && browser_desktop=$b && break
  done
  [[ -n $browser_desktop ]] && env -u BROWSER XDG_CURRENT_DESKTOP= xdg-settings set default-web-browser "$browser_desktop" || true
fi
xdg-mime default HEY.desktop x-scheme-handler/mailto || true"""
new = """omarchy-refresh-applications
if command -v omacachy-browser-default >/dev/null 2>&1; then
  omacachy-browser-default
else
  browser_desktop=chromium.desktop
  for b in chromium.desktop firefox.desktop brave-browser.desktop zen-browser.desktop helium-browser.desktop; do
    [[ -f /usr/share/applications/$b ]] && browser_desktop=$b && break
  done
  env -u BROWSER XDG_CURRENT_DESKTOP= xdg-settings set default-web-browser "$browser_desktop" || true
fi
xdg-mime default HEY.desktop x-scheme-handler/mailto || true"""
if old in s:
    p.write_text(s.replace(old, new))
    print('OmaCachy: patched omarchy-provision-user browser default')
PY
EOF
  chmod 0755 "$OMACACHY_PROVISION_PATCH"

  install -d -m 0755 /etc/pacman.d/hooks
  cat >"$OMACACHY_PROVISION_HOOK" <<'EOF'
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = omarchy

[Action]
Description = Patching Omarchy user provisioning browser default (OmaCachy)
When = PostTransaction
Exec = /usr/local/lib/omacachy/patch-omarchy-provision
EOF
  chmod 0644 "$OMACACHY_PROVISION_HOOK"
  info "Omarchy provisioning guard installed (survives omarchy update)"
}

OMACACHY_HERDR_PATCH=/usr/local/lib/omacachy/patch-omarchy-herdr-autostart
OMACACHY_HERDR_HOOK=/etc/pacman.d/hooks/omacachy-omarchy-herdr.hook

patch_omarchy_herdr_autostart() {
  local f=/usr/share/omarchy/default/hypr/autostart.lua
  [[ -f $f ]] || return 0
  grep -q 'omarchy-cmd-present herdr' "$f" && return 0

  if (( DRY_RUN )); then
    info "would patch herdr autostart to run only when herdr is installed"
    return 0
  fi

  backup_file "$f" "$(basename \"$f\")"
  python3 - <<'PY'
from pathlib import Path
p = Path('/usr/share/omarchy/default/hypr/autostart.lua')
s = p.read_text()
old = '  hl.exec_cmd(o.launch("herdr server"))'
new = """  if o.cmd_present("herdr") then
    hl.exec_cmd(o.launch("herdr server"))
  end"""
if old in s:
    p.write_text(s.replace(old, new))
PY
  success "Patched herdr autostart: skipped when herdr is not installed"
}

install_omarchy_herdr_guard() {
  if (( DRY_RUN )); then
    info "would install $OMACACHY_HERDR_PATCH and $OMACACHY_HERDR_HOOK"
    return 0
  fi

  install -d -m 0755 "$(dirname \"$OMACACHY_HERDR_PATCH\")"
  cat >"$OMACACHY_HERDR_PATCH" <<'EOF'
#!/bin/bash
set -eu
f=/usr/share/omarchy/default/hypr/autostart.lua
[[ -f $f ]] || exit 0
grep -q 'omarchy-cmd-present herdr' "$f" && exit 0
python3 - <<'PY'
from pathlib import Path
p = Path('/usr/share/omarchy/default/hypr/autostart.lua')
s = p.read_text()
old = '  hl.exec_cmd(o.launch("herdr server"))'
new = """  if o.cmd_present("herdr") then
    hl.exec_cmd(o.launch("herdr server"))
  end"""
if old in s:
    p.write_text(s.replace(old, new))
    print('OmaCachy: patched herdr autostart guard')
PY
EOF
  chmod 0755 "$OMACACHY_HERDR_PATCH"

  install -d -m 0755 /etc/pacman.d/hooks
  cat >"$OMACACHY_HERDR_HOOK" <<'EOF'
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = omarchy-settings

[Action]
Description = Patching Omarchy herdr autostart guard (OmaCachy)
When = PostTransaction
Exec = /usr/local/lib/omacachy/patch-omarchy-herdr-autostart
EOF
  chmod 0644 "$OMACACHY_HERDR_HOOK"
  info "Omarchy herdr autostart guard installed (survives omarchy update)"
}


OMACACHY_LIMINE_NAME_PATCH=/usr/local/lib/omacachy/patch-omarchy-limine-name
OMACACHY_LIMINE_NAME_HOOK=/etc/pacman.d/hooks/omacachy-omarchy-limine-name.hook

patch_omarchy_limine_name() {
  local def=/etc/default/limine
  local dropin=/etc/limine-entry-tool.d/99-omacachy.conf
  local os_mode=${OS_IDENTITY_MODE:-cachyos}
  local name='CachyOS'
  [[ $os_mode == omarchy ]] && name='Omarchy'

  if (( DRY_RUN )); then
    info "would set Limine TARGET_OS_NAME=\"$name\" in $def and $dropin"
    return 0
  fi

  mkdir -p /etc/limine-entry-tool.d
  if [[ -f $def ]]; then
    backup_file "$def" limine-default
    set_limine_kv "$def" TARGET_OS_NAME "\"$name\""
  fi
  cat >"$dropin" <<EOF
# Installed by OmaCachy: keep Limine OS name stable.
TARGET_OS_NAME="$name"
EOF
  success "Limine TARGET_OS_NAME set to $name"
}

install_omarchy_limine_name_guard() {
  if (( DRY_RUN )); then
    info "would install $OMACACHY_LIMINE_NAME_PATCH and $OMACACHY_LIMINE_NAME_HOOK"
    return 0
  fi

  install -d -m 0755 "$(dirname "$OMACACHY_LIMINE_NAME_PATCH")"
  cat >"$OMACACHY_LIMINE_NAME_PATCH" <<'EOF'
#!/bin/bash
set -eu
state=/var/lib/omacachy/state.env
os_mode=cachyos
[[ -r $state ]] && . "$state"
os_mode=${OMACACHY_OS_IDENTITY:-$os_mode}
name=CachyOS
[[ $os_mode == omarchy ]] && name=Omarchy
mkdir -p /etc/limine-entry-tool.d
cat > /etc/limine-entry-tool.d/99-omacachy.conf <<CONF
# Installed by OmaCachy: keep Limine OS name stable.
TARGET_OS_NAME="$name"
CONF
if [[ -f /etc/default/limine ]]; then
  if grep -q '^TARGET_OS_NAME=' /etc/default/limine; then
    sed -i "s|^TARGET_OS_NAME=.*$|TARGET_OS_NAME=\"$name\"|" /etc/default/limine
  else
    printf '\nTARGET_OS_NAME="%s"\n' "$name" >> /etc/default/limine
  fi
fi
echo "OmaCachy: Limine TARGET_OS_NAME set to $name"
EOF
  chmod 0755 "$OMACACHY_LIMINE_NAME_PATCH"

  install -d -m 0755 /etc/pacman.d/hooks
  cat >"$OMACACHY_LIMINE_NAME_HOOK" <<'EOF'
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = omarchy-settings
Target = limine
Target = limine-entry-tool

[Action]
Description = Keeping Limine OS name (OmaCachy)
When = PostTransaction
Exec = /usr/local/lib/omacachy/patch-omarchy-limine-name
EOF
  chmod 0644 "$OMACACHY_LIMINE_NAME_HOOK"
  info "Limine OS name guard installed (survives omarchy/limine updates)"
}

apply_omacachy_fixes() {
  local mode=${1:-install}

  # Safe, idempotent repairs/guards. Run during install and after omacachy update.
  restore_os_release || true

  if (( EUID == 0 )); then
    patch_omarchy_fastfetch_env || true
    install_omarchy_env_guard || true
    patch_omarchy_version_channel || true
    install_omarchy_version_channel_guard || true
    patch_omarchy_fastfetch_config || true
    install_omarchy_fastfetch_guard || true
    patch_omarchy_opencode_restart || true
    install_omarchy_opencode_restart_guard || true
    patch_omarchy_provision_user || true
    install_omarchy_provision_guard || true
    patch_omarchy_herdr_autostart || true
    install_omarchy_herdr_guard || true
    patch_omarchy_limine_name || true
    install_omarchy_limine_name_guard || true
    install_omacachy_command || true
  else
    info "Skipping system patch/guard application (requires root)"
  fi

  write_state OMACACHY_BROWSER "${OMACACHY_BROWSER:-$(state_get OMACACHY_BROWSER 2>/dev/null || echo chromium)}"
  [[ -n ${OS_IDENTITY_MODE:-} ]] && write_state OMACACHY_OS_IDENTITY "$OS_IDENTITY_MODE" || true
  write_state OMACACHY_VERSION "$OMACACHY_VERSION"
  write_state OMACACHY_LAST_FIXES_AT "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  write_state OMACACHY_LAST_FIXES_MODE "$mode"
}

finalize_install() {
  step "finalize: default session and recorded state"

  restore_os_release

  run systemctl daemon-reload
  if systemctl list-unit-files --no-legend --no-pager sddm.service 2>/dev/null | grep -q .; then
    run systemctl enable sddm.service
    ensure_sddm_login_user
  else
    warn "sddm.service is not installed; Omarchy expects SDDM as the display manager"
  fi
  run systemctl set-default graphical.target

  apply_omacachy_fixes install

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
EOF
  if [[ ${OS_IDENTITY_MODE:-cachyos} == omarchy ]]; then
    cat <<EOF
 System identity: Omarchy (/etc/os-release follows Omarchy)
 Installed from Omarchy's stable channel: the desktop, configs and lifecycle
 Provisioned user: $TARGET_USER
EOF
  else
    cat <<EOF
 Kept from CachyOS: the machine's hostname and /etc/os-release (also across
                    'omarchy update', through OmaCachy's pacman hook)
 Installed from Omarchy's stable channel: the desktop, configs and lifecycle
 Provisioned user: $TARGET_USER
EOF
  fi

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
