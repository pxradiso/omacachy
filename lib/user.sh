#!/bin/bash
# shellcheck shell=bash
# Per-user half: seed /etc/skel without clobbering anything, then let Omarchy
# finalize the account (skills, xdg dirs, theme, migrations, ...).

if [[ -n ${_OMACACHY_USER:-} ]]; then return 0; fi
_OMACACHY_USER=1

OMACACHY_USER_PROVISION_OK=1

seed_skel() {
  local home=$TARGET_HOME group
  local before after added

  step "user: seed Omarchy's shipped configs into $home"

  [[ -d /etc/skel ]] || {
    warn "No /etc/skel on this system; skipping config seeding"
    return 0
  }

  if [[ -L $home/.config || -L $home/.local ]]; then
    warn "$home/.config or $home/.local is a symlink (dotfiles repo?)."
    warn "New Omarchy files will be created through it; existing files are never overwritten."
  fi

  if (( DRY_RUN )); then
    info "would copy /etc/skel into $home, skipping files that already exist"
    return 0
  fi

  group=$(id -gn "$TARGET_USER")
  before=$(mktemp)
  after=$(mktemp)
  added=$(mktemp)

  (cd "$home" && find . -mindepth 1 -print | sort) >"$before"

  # --skip-old-files: an existing CachyOS home keeps every file it already has.
  # tar also creates missing directories and preserves symlinks/modes.
  tar -C /etc/skel -cf - . | tar -C "$home" -xpf - --skip-old-files

  (cd "$home" && find . -mindepth 1 -print | sort) >"$after"
  comm -13 "$before" "$after" >"$added"

  local count
  count=$(wc -l <"$added")
  if (( count > 0 )); then
    # Only the paths created by this run change hands; pre-existing files keep
    # their current ownership.
    (cd "$home" && tr '\n' '\0' <"$added" | xargs -0 -r chown -h "$TARGET_USER:$group")
    success "Seeded $count new path(s) from /etc/skel, owned by $TARGET_USER:$group"
  else
    info "Nothing to seed: $home already contains every shipped config"
  fi

  rm -f "$before" "$after" "$added"
}

# Omarchy's fastfetch is shown by the user's interactive shell, not by the
# desktop. CachyOS's existing dotfiles win over /etc/skel (they are never
# overwritten), so a converted account often lands on tty2 with no banner.
# Add small, idempotent hooks for both shells instead of replacing any dotfile.
ensure_tty_fastfetch() {
  local home=$TARGET_HOME group
  local fish_dir fish_file bashrc=$TARGET_HOME/.bashrc
  local marker='# OmaCachy: show fastfetch on a Linux console login'

  step "user: show Omarchy's fastfetch on console logins"

  [[ -d $home ]] || return 0
  if (( DRY_RUN )); then
    info "would add tty fastfetch hooks for $TARGET_USER (fish and bash)"
    return 0
  fi
  group=$(id -gn "$TARGET_USER")

  # Fish: a conf.d drop-in, so the user's own config.fish is untouched. The
  # tty check keeps fastfetch off SSH and off terminals inside Hyprland.
  if command -v fish >/dev/null 2>&1; then
    fish_dir="$home/.config/fish/conf.d"
    fish_file="$fish_dir/omacachy-fastfetch.fish"
    install -d -o "$TARGET_USER" -g "$group" -m 0755 "$fish_dir"
    cat >"$fish_file" <<'EOF'
# Installed by OmaCachy: Omarchy's fastfetch on a Linux console login.
if status is-login; and status is-interactive
    if not set -q OMACACHY_FASTFETCH_SHOWN
        if string match -qr '^/dev/tty[0-9]+$' -- (tty 2>/dev/null)
            if command -q fastfetch
                set -gx OMACACHY_FASTFETCH_SHOWN 1
                fastfetch
            end
        end
    end
end
EOF
    chown "$TARGET_USER:$group" "$fish_file"
    chmod 0644 "$fish_file"
  fi

  # Bash: append one marked block. Existing content and ownership stay as they
  # are, and rerunning the installer does not add it twice. If .bashrc execs
  # fish, the fish drop-in runs instead and this block is never reached.
  if [[ -f $bashrc ]] && ! grep -qF "$marker" "$bashrc"; then
    cat >>"$bashrc" <<'EOF'

# OmaCachy: show fastfetch on a Linux console login
case "$(tty 2>/dev/null)" in
  /dev/tty[0-9]*)
    if [[ $- == *i* && -z ${OMACACHY_FASTFETCH_SHOWN:-} ]] && command -v fastfetch >/dev/null 2>&1; then
      export OMACACHY_FASTFETCH_SHOWN=1
      fastfetch
    fi
    ;;
esac
EOF
  fi

  success "Console logins show Omarchy's fastfetch (tty only, once per login)"
}

setup_omarchy_fish() {
  (( SETUP_FISH )) || return 0

  step "user: setup Omarchy fish shell"

  if (( DRY_RUN )); then
    info "would install omarchy-fish and run omarchy-setup-fish for $TARGET_USER"
    return 0
  fi

  pkg_installed omarchy-fish || run pacman -S --needed --noconfirm omarchy-fish
  command -v omarchy-setup-fish >/dev/null 2>&1 || {
    warn "omarchy-setup-fish not found; skipping fish setup"
    return 0
  }

  run_as_user "$TARGET_USER" omarchy-setup-fish || warn "omarchy-setup-fish reported an error"
  ensure_tty_fastfetch
  success "Omarchy fish setup complete for $TARGET_USER"
}

provision_user() {
  local log="$OMACACHY_LOG_DIR/omarchy-user.log"
  local marker

  step "user: run Omarchy user provisioning for $TARGET_USER"

  if (( DRY_RUN )); then
    info "would run as $TARGET_USER: omarchy-provision-user --force --first-install"
    return 0
  fi

  mkdir -p "$OMACACHY_LOG_DIR"
  : >"$log"

  # --force re-runs the idempotent steps; --first-install marks every shipped
  # migration as already applied, which is what a fresh Omarchy user gets from
  # the ISO (an existing CachyOS home must not replay old migrations).
  if ! run_as_user "$TARGET_USER" omarchy-provision-user --force --first-install 2>&1 | tee -a "$log"; then
    OMACACHY_USER_PROVISION_OK=0
    warn "Omarchy user provisioning reported an error (see $log)."
    warn "Rerun it later with:"
    warn "  sudo -u $TARGET_USER omarchy-provision-user --force --first-install"
    return 0
  fi

  marker="$TARGET_HOME/.local/state/omarchy/done/finalize-user"
  if [[ -e $marker ]]; then
    success "User provisioning complete (marker: ${marker#"$TARGET_HOME"/})"
  else
    OMACACHY_USER_PROVISION_OK=0
    warn "Provisioning finished but the Omarchy finalize marker is missing"
  fi
}
