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
