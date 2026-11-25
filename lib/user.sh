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
  local shell_choice=${OMACACHY_SHELL:-fish}

  if [[ $shell_choice == bash ]]; then
    setup_omarchy_bash
    return 0
  fi

  (( SETUP_FISH )) || [[ ${OMACACHY_SHELL_EXPLICIT:-0} == 1 ]] || return 0

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

setup_omarchy_bash() {
  local home=$TARGET_HOME group bashrc skel_bashrc backup
  local fish_cfg fish_backup

  step "user: setup Omarchy bash shell"

  bashrc="$home/.bashrc"
  skel_bashrc=/etc/skel/.bashrc
  group=$(id -gn "$TARGET_USER")

  if (( DRY_RUN )); then
    info "would set $TARGET_USER shell to bash"
    (( BACKUP_FISH )) && info "would back up $home/.config/fish"
    info "would install Omarchy bashrc for $TARGET_USER"
    return 0
  fi

  if (( BACKUP_FISH )); then
    fish_cfg="$home/.config/fish"
    if [[ -e $fish_cfg ]]; then
      fish_backup="$home/.config/fish.backup-omacachy-$(date +%Y%m%d-%H%M%S)"
      cp -a "$fish_cfg" "$fish_backup"
      chown -R "$TARGET_USER:$group" "$fish_backup" 2>/dev/null || true
      success "Backed up fish config to $fish_backup"
    else
      info "No fish config to back up at $fish_cfg"
    fi
  fi

  if [[ -f $bashrc ]]; then
    backup="$home/.bashrc.backup-omacachy-$(date +%Y%m%d-%H%M%S)"
    cp -a "$bashrc" "$backup"
    chown "$TARGET_USER:$group" "$backup" 2>/dev/null || true
    info "Backed up existing .bashrc to $backup"
  fi

  if [[ -f $skel_bashrc ]]; then
    install -m 0644 -o "$TARGET_USER" -g "$group" "$skel_bashrc" "$bashrc"
  else
    warn "Missing $skel_bashrc; keeping existing .bashrc"
  fi

  chsh -s /bin/bash "$TARGET_USER" || warn "Could not change login shell to bash for $TARGET_USER"
  ensure_tty_fastfetch
  success "Omarchy bash shell configured for $TARGET_USER"
}

prune_optional_omarchy_apps() {
  (( NO_APPS )) || return 0

  local home=$TARGET_HOME
  local apps_dir="$home/.local/share/applications"
  local -a remove=(
    "Alacritty.desktop"
    "imv.desktop"
    "imv-dir.desktop"
    "micro.desktop"
    "org.gnome.meld.desktop"
  )
  local f src df

  step "user: prune optional Omarchy apps/webapps (--no-apps)"

  if (( DRY_RUN )); then
    info "would remove optional desktop entries/webapps from $apps_dir"
    return 0
  fi

  mkdir -p "$apps_dir"
  for f in "${remove[@]}"; do
    rm -f "$apps_dir/$f"
  done

  # Remove Omarchy-shipped webapps; keep user-created webapps where possible.
  for src in /usr/share/omarchy/applications/*.desktop; do
    [[ -f $src ]] || continue
    if grep -qE 'Exec=.*(omarchy-launch-webapp|omarchy-webapp-handler)' "$src" 2>/dev/null; then
      rm -f "$apps_dir/$(basename "$src")"
    fi
  done

  # Also remove webapp entries in user dir that exactly match Omarchy defaults.
  while IFS= read -r -d '' df; do
    if grep -qE 'Exec=.*(omarchy-launch-webapp|omarchy-webapp-handler)' "$df" 2>/dev/null; then
      src="/usr/share/omarchy/applications/$(basename "$df")"
      if [[ -f $src ]]; then
        rm -f "$df"
      fi
    fi
  done < <(find "$apps_dir" -maxdepth 1 -name '*.desktop' -print0 2>/dev/null)

  # Keep omasnap: needed for screenshots.
  if command -v update-desktop-database >/dev/null 2>&1; then
    run_as_user "$TARGET_USER" update-desktop-database "$apps_dir" >/dev/null 2>&1 || true
  fi

  success "Optional Omarchy apps/webapps pruned (omasnap kept)"
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
