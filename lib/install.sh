#!/bin/bash
# shellcheck shell=bash
# The install command: preflight -> repo/keyring -> packages -> system -> user.

if [[ -n ${_OMACACHY_INSTALL:-} ]]; then return 0; fi
_OMACACHY_INSTALL=1

SKIP_PACKAGES=0
SKIP_SYSTEM=0
SKIP_USER=0
SKIP_UPGRADE=0
NO_APPS=0
REMOVE_EXISTING_DE=0
NO_GREETER=0
BOOT_MODE_SET=0
TUI_DONE=0
NO_PROGRESS=0

banner() {
  printf '\n%s  OmaCachy %s%s - Omarchy %s on CachyOS\n\n' \
    "$C_BOLD" "$OMACACHY_VERSION" "$C_RESET" "$OMACACHY_CHANNEL"
}

parse_install_args() {
  USER_ARG=''
  BOOT_MODE='refuse'

  while (($#)); do
    case $1 in
      --user | --as-user)
        USER_ARG=${2:-}
        shift 2
        ;;
      --boot)
        BOOT_MODE=${2:-}
        BOOT_MODE_SET=1
        shift 2
        ;;
      --boot=*)
        BOOT_MODE=${1#*=}
        BOOT_MODE_SET=1
        shift
        ;;
      -y | --yes)
        ASSUME_YES=1
        shift
        ;;
      -n | --dry-run)
        DRY_RUN=1
        shift
        ;;
      -v | --verbose)
        VERBOSE=1
        shift
        ;;
      --allow-non-btrfs)
        ALLOW_NON_BTRFS=1
        shift
        ;;
      --with-nvidia)
        WITH_NVIDIA=1
        shift
        ;;
      --no-apps)
        NO_APPS=1
        shift
        ;;
      --remove-existing-de)
        REMOVE_EXISTING_DE=1
        shift
        ;;
      --no-greeter)
        NO_GREETER=1
        shift
        ;;
      --skip-packages)
        SKIP_PACKAGES=1
        shift
        ;;
      --skip-system)
        SKIP_SYSTEM=1
        shift
        ;;
      --skip-user)
        SKIP_USER=1
        shift
        ;;
      --no-upgrade)
        SKIP_UPGRADE=1
        shift
        ;;
      --no-progress)
        NO_PROGRESS=1
        shift
        ;;
      # Internal: set on the sudo re-exec so the interactive setup is not
      # shown a second time.
      --tui-done)
        TUI_DONE=1
        shift
        ;;
      -h | --help)
        install_usage
        exit 0
        ;;
      *)
        die "Unknown option: $1 (see omacachy install --help)"
        ;;
    esac
  done

  case $BOOT_MODE in
    refuse | register | convert | skip) ;;
    *) die "--boot must be one of: refuse, register, convert, skip" ;;
  esac
}

install_usage() {
  cat <<'EOF'
Usage: omacachy install [options]

Installs the Omarchy desktop on an existing CachyOS system, using Omarchy's
signed *stable* packages (currently 4.5.x) and keeping CachyOS's kernel,
drivers, pacman.conf, mirrors and keyrings.

Options:
      --user USER        desktop user to provision (default: sudo caller)
      --boot MODE        how to handle Limine (Omarchy's required bootloader)
                           refuse   stop if Limine is not deployed (default)
                           register install Limine but keep the current default
                           convert  install Limine and make it the default
                           skip     manage the bootloader yourself
      --with-nvidia      install Omarchy's NVIDIA packages instead of leaving
                         the GPU stack to CachyOS/chwd
      --no-apps          install the desktop without Omarchy's preinstalled
                         applications (Chromium, LibreOffice, Obsidian, ...)
      --remove-existing-de
                         remove the desktop environment/window manager that was
                         already installed (asked by the interactive setup)
      --no-greeter       keep the current SDDM theme instead of Omarchy's
                         login greeter
      --allow-non-btrfs  permit a non-btrfs root (no snapshot rollback)
      --skip-packages    do not touch packages (assume Omarchy is installed)
      --skip-system      do not run Omarchy system setup
      --skip-user        do not touch the user's home
      --no-upgrade       do not run the full system upgrade first
      --no-progress      plain log output instead of the full-screen progress view
EOF
  usage_common
  cat <<'EOF'

Examples:
  sudo omacachy install --boot=register
  sudo omacachy install --user dhh --boot=convert --yes
  sudo omacachy install --dry-run
EOF
}

reexec_as_root() {
  local -a fwd
  local resolved_user

  (( EUID == 0 )) && return 0

  resolved_user=${USER_ARG:-${SUDO_USER:-${USER:-}}}
  [[ -n $resolved_user && $resolved_user != root ]] ||
    die "Run this from your normal user account, or pass --user USER"

  fwd=(--user "$resolved_user" --tui-done)
  (( ASSUME_YES )) && fwd+=(-y)
  (( DRY_RUN )) && fwd+=(-n)
  (( VERBOSE )) && fwd+=(-v)
  (( ALLOW_NON_BTRFS )) && fwd+=(--allow-non-btrfs)
  (( WITH_NVIDIA )) && fwd+=(--with-nvidia)
  (( NO_APPS )) && fwd+=(--no-apps)
  (( REMOVE_EXISTING_DE )) && fwd+=(--remove-existing-de)
  (( NO_GREETER )) && fwd+=(--no-greeter)
  (( SKIP_PACKAGES )) && fwd+=(--skip-packages)
  (( SKIP_SYSTEM )) && fwd+=(--skip-system)
  (( SKIP_USER )) && fwd+=(--skip-user)
  (( SKIP_UPGRADE )) && fwd+=(--no-upgrade)
  (( NO_PROGRESS )) && fwd+=(--no-progress)
  [[ $BOOT_MODE != refuse ]] && fwd+=(--boot "$BOOT_MODE")

  info "Requesting root privileges (sudo)"
  exec sudo -- bash "$OMACACHY_REPO/bin/omacachy" install "${fwd[@]}"
}

install_main() {
  parse_install_args "$@"

  # Interactive setup before sudo: it reads answers from /dev/tty, so it also
  # works for the `curl ... | bash` path (where stdin is the script itself).
  maybe_run_tui
  reexec_as_root

  OMACACHY_RUN_STAMP=$(date +%Y%m%d-%H%M%S)
  export OMACACHY_RUN_STAMP
  export LOGNAME="${LOGNAME:-root}"

  log_init
  if (( ! NO_PROGRESS )); then
    tui_progress_start || true
  fi
  banner

  resolve_target_user "$USER_ARG"

  if (( DRY_RUN )); then
    warn "Dry run: nothing will be changed"
  fi

  preflight

  # 0. The machine keeps its name and its /etc/os-release: record the file now,
  #    before Omarchy's packages can replace it, and install the guard that
  #    keeps it across `omarchy update`.
  capture_os_release
  install_os_release_guard

  # 0b. The same for the SDDM theme, when the user keeps the old greeter.
  capture_sddm_theme
  install_greeter_guard

  # 1. Repositories and signing key (stable Omarchy channel only).
  bootstrap_repos

  # 2. CachyOS stays current, so installing Omarchy is not a partial upgrade.
  if (( SKIP_UPGRADE )); then
    info "Skipping the system upgrade (--no-upgrade)"
  else
    system_upgrade
  fi

  # 2b. Optionally remove the desktop that was already installed. This runs
  #     before Omarchy's packages so the old session cannot win the greeter.
  remove_existing_desktops

  # 3. Bootloader preferences must exist before limine's pacman hook runs.
  configure_bootloader_preferences

  # 4. Packages: the Omarchy runtime first (it owns the package lists), then
  #    the full desktop set with CachyOS-first filtering.
  if (( SKIP_PACKAGES )); then
    info "Skipping package installation (--skip-packages)"
    pkg_installed omarchy || die "--skip-packages given but omarchy is not installed"
  else
    backup_overridden_files
    install_omarchy_runtime
    install_package_set
  fi
  restore_os_release
  apply_greeter_preference
  verify_omarchy_version

  # 5. Root system setup through the overlay.
  if (( SKIP_SYSTEM )); then
    info "Skipping Omarchy system setup (--skip-system)"
  else
    capture_mkinitcpio_baseline
    build_overlay
    write_mkinitcpio_dropin
    run_system_apply
    ensure_user_groups "$TARGET_USER"
  fi

  # 6. The existing user's home: seed, never overwrite, then let Omarchy finish.
  if (( SKIP_USER )); then
    info "Skipping user provisioning (--skip-user)"
  else
    seed_skel
    ensure_tty_fastfetch
    provision_user
  fi

  finalize_install
}
