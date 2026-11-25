#!/bin/bash
# shellcheck shell=bash
# The machine keeps its own identity: its hostname and its /etc/os-release.
#
# Omarchy's `omarchy-settings` scriptlet rewrites /etc/os-release to
# "Omarchy" on every install and upgrade: upstream considers the desktop to be
# the system. OmaCachy records the file that was there before anything was
# installed and puts it back, so the system keeps reporting CachyOS. Because
# that scriptlet also runs on `omarchy update`, the restore is installed as a
# pacman PostTransaction hook, not just done once at install time.
#
# The hostname is deliberately not managed here: upstream only generates one in
# the ISO's setup form (`omarchy_generate_hostname`). On an existing CachyOS
# machine OmaCachy never calls hostnamectl and never writes /etc/hostname.

if [[ -n ${_OMACACHY_IDENTITY:-} ]]; then return 0; fi
_OMACACHY_IDENTITY=1

OMACACHY_OS_RELEASE_ORIGINAL="$OMACACHY_STATE_DIR/os-release.original"
OMACACHY_OS_RELEASE_RESTORE=/usr/local/lib/omacachy/restore-os-release
OMACACHY_OS_RELEASE_HOOK=/etc/pacman.d/hooks/omacachy-os-release.hook
OMACACHY_CACHYOS_BRANDING=/usr/share/libalpm/scripts/cachyos-branding

is_omarchy_os_release() {
  local file=$1
  [[ -f $file ]] && grep -qx 'ID=omarchy' "$file" 2>/dev/null
}

# A saved copy is only useful when it is *not* Omarchy's (and not empty).
is_usable_os_release() {
  local file=$1
  [[ -s $file ]] || return 1
  ! is_omarchy_os_release "$file"
}

is_cachyos_os_release() {
  local file=$1
  [[ -f $file ]] || return 1
  grep -qE '^(ID=cachyos|NAME="?CachyOS( Linux)?"?)$' "$file" 2>/dev/null
}

# CachyOS's branding hook sets PRETTY_NAME="CachyOS". Normalize to
# "CachyOS Linux" (or "CachyOS Linux <VERSION_ID>" when a real version exists).
format_cachyos_os_release() {
  local file=$1 version
  [[ -f $file ]] || return 0
  is_cachyos_os_release "$file" || return 0

  version=$(sed -n 's/^VERSION_ID=//p' "$file" | tail -1 | tr -d '"'"'"'')
  [[ -n $version ]] || version=$(sed -n 's/^BUILD_ID=//p' "$file" | tail -1 | tr -d '"'"'"'')
  [[ -n $version ]] || version=rolling

  local pretty="CachyOS Linux"
  if [[ -n $version && $version != rolling ]]; then
    pretty="CachyOS Linux $version"
  fi
  sed -i \
    -e 's|^NAME=.*$|NAME="CachyOS Linux"|' \
    -e "s|^PRETTY_NAME=.*$|PRETTY_NAME=\"${pretty}\"|" \
    "$file"
}

# Older runs (or a manual `backup_file` before a package upgrade) may already
# have stored the original in the backup directory.
find_saved_os_release() {
  local f
  while IFS= read -r f; do
    if is_usable_os_release "$f"; then
      printf '%s\n' "$f"
      return 0
    fi
  done < <(
    find "$OMACACHY_BACKUP_DIR" -maxdepth 1 -type f -name '*os-release*' \
      -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-
  )
  return 1
}

# Last resort when /etc/os-release was already overwritten and nothing was
# saved: let CachyOS's own branding hook rebuild it from the Arch base file,
# exactly as it does after a `filesystem` upgrade.
reconstruct_cachyos_os_release() {
  [[ -x $OMACACHY_CACHYOS_BRANDING ]] || return 1
  [[ -f /usr/lib/os-release ]] || return 1
  grep -qx 'ID=arch' /usr/lib/os-release 2>/dev/null || return 1

  cp -L /usr/lib/os-release /etc/os-release
  "$OMACACHY_CACHYOS_BRANDING" os-release

  cp -a /etc/os-release "$OMACACHY_OS_RELEASE_ORIGINAL"
  chmod 0644 "$OMACACHY_OS_RELEASE_ORIGINAL"
  format_cachyos_os_release "$OMACACHY_OS_RELEASE_ORIGINAL"
  success "Rebuilt the CachyOS /etc/os-release with cachyos-branding"
}

capture_os_release() {
  local saved

  if [[ ${OS_IDENTITY_MODE:-cachyos} == omarchy ]]; then
    step "identity: keeping Omarchy /etc/os-release as requested"
    info "OS identity mode: omarchy (OmaCachy will not restore CachyOS os-release)"
    return 0
  fi

  step "identity: record /etc/os-release so the system keeps saying CachyOS"

  if is_usable_os_release "$OMACACHY_OS_RELEASE_ORIGINAL"; then
    info "Using the os-release recorded by an earlier run"
    return 0
  fi

  if (( DRY_RUN )); then
    info "would record the current /etc/os-release as the machine's own identity"
    return 0
  fi

  mkdir -p "$OMACACHY_STATE_DIR" "$OMACACHY_BACKUP_DIR"

  if is_usable_os_release /etc/os-release; then
    cp -a /etc/os-release "$OMACACHY_OS_RELEASE_ORIGINAL"
    chmod 0644 "$OMACACHY_OS_RELEASE_ORIGINAL"
    format_cachyos_os_release "$OMACACHY_OS_RELEASE_ORIGINAL"
    if is_cachyos_os_release "$OMACACHY_OS_RELEASE_ORIGINAL"; then
      success "Recorded CachyOS's /etc/os-release"
    else
      success "Recorded the machine's /etc/os-release (it will be preserved)"
    fi
    return 0
  fi

  if saved=$(find_saved_os_release); then
    cp -a "$saved" "$OMACACHY_OS_RELEASE_ORIGINAL"
    chmod 0644 "$OMACACHY_OS_RELEASE_ORIGINAL"
    format_cachyos_os_release "$OMACACHY_OS_RELEASE_ORIGINAL"
    success "Recovered the original /etc/os-release from $saved"
    return 0
  fi

  if is_omarchy_os_release /etc/os-release; then
    warn "/etc/os-release already says Omarchy and no older copy was saved"
    if reconstruct_cachyos_os_release; then
      return 0
    fi
    warn "Cannot rebuild it (cachyos-hooks missing?). /etc/os-release stays as it"
    warn "is and will not be protected across upgrades until it is restored once:"
    warn "  sudo pacman -S cachyos-hooks && sudo /usr/share/libalpm/scripts/cachyos-branding"
    return 0
  fi

  warn "/etc/os-release is missing; it will not be protected"
}

# Put the recorded file back. Only fights Omarchy's override: any other change
# made after the install is left alone, so a user editing (or a distro hook
# refreshing) /etc/os-release is not second-guessed.
restore_os_release() {
  local original=$OMACACHY_OS_RELEASE_ORIGINAL

  if [[ ${OS_IDENTITY_MODE:-cachyos} == omarchy ]]; then
    debug "OS identity mode omarchy: leaving /etc/os-release untouched"
    return 0
  fi

  [[ -f $original ]] || return 0

  if (( DRY_RUN )); then
    if is_omarchy_os_release /etc/os-release; then
      info "would restore the recorded /etc/os-release"
    fi
    return 0
  fi

  if [[ ! -e /etc/os-release ]]; then
    cp -a "$original" /etc/os-release
    success "/etc/os-release recreated from the recorded copy"
    return 0
  fi

  if ! is_omarchy_os_release /etc/os-release; then
    debug "/etc/os-release does not say Omarchy; leaving it untouched"
    return 0
  fi

  rm -f /etc/os-release
  cp -a "$original" /etc/os-release
  if [[ ! -L /etc/os-release ]]; then
    chmod 0644 /etc/os-release
  fi
  success "Restored /etc/os-release: the system keeps identifying as CachyOS"
}

install_os_release_guard() {
  local original=$OMACACHY_OS_RELEASE_ORIGINAL

  if [[ ${OS_IDENTITY_MODE:-cachyos} == omarchy ]]; then
    info "OS identity mode omarchy: os-release guard not installed"
    return 0
  fi

  if (( DRY_RUN )); then
    info "would install $OMACACHY_OS_RELEASE_RESTORE and $OMACACHY_OS_RELEASE_HOOK"
    return 0
  fi

  if [[ ! -f $original ]]; then
    warn "No original /etc/os-release recorded; the upgrade guard is not installed"
    return 0
  fi

  install -d -m 0755 "$(dirname "$OMACACHY_OS_RELEASE_RESTORE")"
  cat >"$OMACACHY_OS_RELEASE_RESTORE" <<EOF
#!/bin/bash
# Installed by OmaCachy.
#
# omarchy-settings rewrites /etc/os-release to "Omarchy" from its .INSTALL
# scriptlet on every install/upgrade, including the ones \`omarchy update\`
# performs. Put the machine's own file back so it keeps reporting CachyOS.
set -eu

original='$original'
[[ -f \$original ]] || exit 0

format_cachyos_os_release() {
  local file=\$1 version
  [[ -f \$file ]] || return 0
  grep -qE '^(ID=cachyos|NAME="?CachyOS( Linux)?"?)\$' "\$file" 2>/dev/null || return 0
  version=\$(sed -n 's/^VERSION_ID=//p' "\$file" | tail -1 | tr -d '"'"'"')
  [[ -n \$version ]] || version=\$(sed -n 's/^BUILD_ID=//p' "\$file" | tail -1 | tr -d '"'"'"')
  [[ -n \$version ]] || version=rolling
  local pretty="CachyOS Linux"
  if [[ -n \$version && \$version != rolling ]]; then
    pretty="CachyOS Linux \$version"
  fi
  sed -i \
    -e 's|^NAME=.*\$|NAME="CachyOS Linux"|' \
    -e "s|^PRETTY_NAME=.*\$|PRETTY_NAME=\\"\${pretty}\\"|" \
    "\$file"
}

# Keep the recorded copy in the desired format too, in case it was captured
# before OmaCachy started normalizing PRETTY_NAME.
format_cachyos_os_release "\$original"

if ! grep -qx 'ID=omarchy' /etc/os-release 2>/dev/null; then
  exit 0
fi

rm -f /etc/os-release
cp -a "\$original" /etc/os-release
[[ -L /etc/os-release ]] || chmod 0644 /etc/os-release
echo "OmaCachy: /etc/os-release restored (the system stays CachyOS)"
EOF
  chmod 0755 "$OMACACHY_OS_RELEASE_RESTORE"

  install -d -m 0755 /etc/pacman.d/hooks
  cat >"$OMACACHY_OS_RELEASE_HOOK" <<'EOF'
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = omarchy-settings

[Action]
Description = Restoring the system's own /etc/os-release (OmaCachy)
When = PostTransaction
Exec = /usr/local/lib/omacachy/restore-os-release
EOF
  chmod 0644 "$OMACACHY_OS_RELEASE_HOOK"

  success "os-release guard installed (runs whenever omarchy-settings is upgraded)"
}
