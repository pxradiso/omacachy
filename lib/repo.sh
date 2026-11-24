#!/bin/bash
# shellcheck shell=bash
# pacman repository + keyring bootstrap.
#
# omacachy only ever adds the *stable* Omarchy repository. CachyOS's own
# repositories, mirrorlists and [options] stay exactly as they are: this is the
# difference between omacachy and running omarchy-refresh-pacman, which would
# replace /etc/pacman.conf with Arch Linux's.

if [[ -n ${_OMACACHY_REPO:-} ]]; then return 0; fi
_OMACACHY_REPO=1

OMARCHY_REPO_BLOCK='[omarchy]
Server = https://pkgs.omarchy.org/stable/$arch
SigLevel = Required DatabaseOptional'

omarchy_repo_section() {
  awk '/^\[omarchy\]/{found=1} found{print} found && /^\[/ && !/^\[omarchy\]/{exit}' /etc/pacman.conf
}

ensure_omarchy_repo() {
  step "pacman: add the Omarchy stable repository"
  backup_file /etc/pacman.conf pacman.conf

  local section
  section=$(omarchy_repo_section)

  if [[ -n $section ]]; then
    if grep -qE '/edge/|/rc/' <<<"$section"; then
      die "[omarchy] points at an edge/rc channel:
$section
omacachy only follows the stable channel. Point it at $OMACACHY_OMARCHY_REPO (or remove the section and rerun)."
    fi
    if ! grep -q '/stable/' <<<"$section"; then
      warn "[omarchy] exists but does not look like the stable channel:"
      warn "$section"
    else
      info "[omarchy] already configured (stable)"
    fi
  else
    local tmp block
    block=$OMARCHY_REPO_BLOCK
    tmp=$(mktemp)
    awk -v block="$block" '
      BEGIN { done = 0 }
      /^\[options\]/ { print; next }
      /^\[[^]]+\]/ && !done { print block; print ""; done = 1 }
      { print }
      END { if (!done) { print ""; print block } }
    ' /etc/pacman.conf >"$tmp"
    if (( DRY_RUN )); then
      info "would insert [omarchy] (stable) before the first repository in /etc/pacman.conf"
    else
      install -m 0644 "$tmp" /etc/pacman.conf
      info "Inserted [omarchy] (stable) into /etc/pacman.conf"
    fi
    rm -f "$tmp"
  fi

  # lib32-nvidia-* and friends live in multilib; CachyOS enables it by default,
  # but a minimal CachyOS install may not.
  if ! grep -q '^\[multilib\]' /etc/pacman.conf; then
    if (( DRY_RUN )); then
      info "would enable [multilib]"
    else
      printf '\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n' >>/etc/pacman.conf
      info "Enabled [multilib]"
    fi
  fi
}

ensure_omarchy_key() {
  step "pacman: trust the Omarchy signing key"

  if pacman-key --list-keys "$OMACACHY_OMARCHY_KEY" >/dev/null 2>&1; then
    info "Omarchy key already present: $OMACACHY_OMARCHY_KEY"
    return 0
  fi

  if (( DRY_RUN )); then
    info "would fetch and locally sign $OMACACHY_OMARCHY_KEY"
    return 0
  fi

  [[ -d /etc/pacman.d/gnupg ]] || pacman-key --init

  # Download the public key over HTTPS (non-interactive) instead of
  # pacman-key --recv-keys, which can block waiting on a keyserver.
  local keyring_tmp
  keyring_tmp=$(mktemp)
  if ! curl -fsSL \
    "https://keys.openpgp.org/pks/lookup?op=get&search=0x${OMACACHY_OMARCHY_KEY}" \
    -o "$keyring_tmp" 2>/dev/null; then
    rm -f "$keyring_tmp"
    die "Could not download the Omarchy signing key from keys.openpgp.org"
  fi

  run pacman-key --add "$keyring_tmp" ||
    die "pacman-key --add failed for the Omarchy signing key"
  rm -f "$keyring_tmp"

  pacman-key --list-keys "$OMACACHY_OMARCHY_KEY" >/dev/null 2>&1 ||
    die "Omarchy signing key $OMACACHY_OMARCHY_KEY could not be imported"

  run pacman-key --lsign-key "$OMACACHY_OMARCHY_KEY" ||
    die "pacman-key --lsign-key failed for the Omarchy signing key"
  success "Omarchy key trusted"
}

refresh_and_install_keyring() {
  step "pacman: refresh databases and install omarchy-keyring"
  run pacman -Sy --noconfirm || die "pacman -Sy failed: is pkgs.omarchy.org reachable?"
  run pacman -S --needed --noconfirm omarchy-keyring ||
    die "Could not install omarchy-keyring from the stable repository"
}

bootstrap_repos() {
  ensure_omarchy_repo
  ensure_omarchy_key
  refresh_and_install_keyring
}

system_upgrade() {
  step "pacman: full system upgrade (CachyOS stays current)"
  info "Omarchy is installed on top of an up-to-date CachyOS; this avoids a partial upgrade."
  info "This can take a while, especially with many packages or slow mirrors; pacman output is in $OMACACHY_LOG_FILE."
  # CachyOS audio stack: pipewire-jack and jack2 conflict; pick one
  if pacman -Qgq jack2 2>/dev/null | grep -q . || pacman -Qgq pipewire-jack 2>/dev/null | grep -q .; then
    info "Resolving pipewire-jack / jack2 conflict (CachyOS-first: keeps jack2)"
    run pacman -R --noconfirm pipewire-jack 2>/dev/null || true
  fi
  # Omarchy's pacman guard blocks direct -Su; allow it for OmaCachy's managed upgrade.
  run env OMARCHY_ALLOW_DIRECT_PACMAN=1 pacman -Su --noconfirm || die "System upgrade failed. Fix pacman first, then rerun omacachy."
}
