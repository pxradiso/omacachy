#!/bin/bash
# shellcheck shell=bash
# Shared helpers for omacachy. Sourced by bin/omacachy and every lib.

if [[ -n ${_OMACACHY_COMMON:-} ]]; then return 0; fi
_OMACACHY_COMMON=1

OMACACHY_VERSION="0.1.0"

# omacachy tracks Omarchy's *stable* channel only: the signed packages
# published below. It never follows edge/rc and never clones DHH's dotfiles
# from git, so every Omarchy file on the machine comes from a released
# package (currently Omarchy 4.5.0-3) and keeps updating through `omarchy
# update`.
OMACACHY_CHANNEL="stable"
OMACACHY_OMARCHY_REPO="https://pkgs.omarchy.org/stable/\$arch"
OMACACHY_MIN_OMARCHY_VERSION="4.5.0"
OMACACHY_OMARCHY_KEY="40DFB630FF42BCFFB047046CF0134EE680CAC571"

OMACACHY_REPO="${OMACACHY_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
OMACACHY_STATE_DIR="${OMACACHY_STATE_DIR:-/var/lib/omacachy}"
OMACACHY_LOG_DIR="${OMACACHY_LOG_DIR:-/var/log/omacachy}"
OMACACHY_STATE_FILE="${OMACACHY_STATE_FILE:-$OMACACHY_STATE_DIR/state.env}"
OMACACHY_BACKUP_DIR="${OMACACHY_BACKUP_DIR:-$OMACACHY_STATE_DIR/backups}"
OMACACHY_LOG_FILE="${OMACACHY_LOG_FILE:-$OMACACHY_LOG_DIR/install.log}"
OMACACHY_OVERLAY_DIR="${OMACACHY_OVERLAY_DIR:-$OMACACHY_STATE_DIR/overlay}"
OMACACHY_BASELINE_FILE="${OMACACHY_BASELINE_FILE:-$OMACACHY_STATE_DIR/mkinitcpio-hooks.baseline}"

DRY_RUN="${DRY_RUN:-0}"
ASSUME_YES="${ASSUME_YES:-0}"
VERBOSE="${VERBOSE:-0}"
TUI_LOG_REDIRECTED="${TUI_LOG_REDIRECTED:-0}"

if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
  C_RESET=$'\033[0m' C_BOLD=$'\033[1m' C_DIM=$'\033[2m'
  C_RED=$'\033[31m' C_GREEN=$'\033[32m' C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m' C_CYAN=$'\033[36m'
else
  C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_CYAN=''
fi

_log_ts() { date '+%Y-%m-%d %H:%M:%S'; }

log_init() {
  [[ -n ${_OMACACHY_LOG_READY:-} ]] && return 0
  (( EUID == 0 )) || return 0
  (( DRY_RUN )) && return 0
  mkdir -p "$OMACACHY_LOG_DIR" "$OMACACHY_STATE_DIR" "$OMACACHY_BACKUP_DIR"
  touch "$OMACACHY_LOG_FILE"
  _OMACACHY_LOG_READY=1
  printf '\n=== omacachy %s: %s ===\n' "$OMACACHY_VERSION" "$(_log_ts)" >>"$OMACACHY_LOG_FILE"
}

_log() {
  local level=$1 color=$2 stream=$3
  shift 3
  local msg=$*
  printf '%s%s%s %s\n' "$color" "$level" "$C_RESET" "$msg" >&"$stream"
  if [[ -n ${_OMACACHY_LOG_READY:-} ]] && (( ! TUI_LOG_REDIRECTED )); then
    printf '[%s] %-5s %s\n' "$(_log_ts)" "$level" "$msg" >>"$OMACACHY_LOG_FILE"
  fi
}

info()    { _log 'INFO'  "$C_CYAN"   1 "$@"; }
success() { _log 'OK'    "$C_GREEN"  1 "$@"; }
warn()    { _log 'WARN'  "$C_YELLOW" 2 "$@"; }
error()   { _log 'ERROR' "$C_RED"    2 "$@"; }

die() {
  error "$@"
  exit 1
}

step() {
  if declare -F tui_progress_phase >/dev/null 2>&1; then
    tui_progress_phase "$*"
  fi
  printf '\n%s==> %s%s\n' "$C_BOLD" "$*" "$C_RESET"
  info "$*"
}

debug() {
  (( VERBOSE )) || return 0
  printf '%s[omacachy]%s %s\n' "$C_DIM" "$C_RESET" "$*" >&2
}

have() { command -v "$1" >/dev/null 2>&1; }

require_cmd() {
  local cmd
  for cmd in "$@"; do
    have "$cmd" || die "Required command not found: $cmd"
  done
}

require_root() {
  (( EUID == 0 )) || die "This action must run as root."
}

pkg_installed() { pacman -Q -- "$1" >/dev/null 2>&1; }

pkg_version() { pacman -Q -- "$1" 2>/dev/null | awk '{print $2}'; }

# run CMD...: mutate the system unless --dry-run was requested.
run() {
  if (( DRY_RUN )); then
    printf '%s[dry-run]%s %s\n' "$C_YELLOW" "$C_RESET" "$*"
    return 0
  fi
  (( VERBOSE )) && printf '%s+%s %s\n' "$C_DIM" "$C_RESET" "$*" >&2
  "$@"
}

confirm() {
  local prompt=$1 default=${2:-no} answer suffix
  if (( ASSUME_YES )); then return 0; fi
  if [[ ! -t 0 ]]; then
    die "$prompt (no TTY available: pass --yes to continue)"
  fi
  suffix='[y/N]'
  [[ $default == yes ]] && suffix='[Y/n]'
  read -r -p "$prompt $suffix " answer || true
  if [[ -z $answer ]]; then
    [[ $default == yes ]]
    return
  fi
  [[ $answer =~ ^[Yy]([Ee][Ss])?$ ]]
}

backup_file() {
  local src=$1 name=${2:-$(basename "$1")} stamp dest
  [[ -e $src ]] || return 0
  stamp="${OMACACHY_RUN_STAMP:-$(date +%Y%m%d-%H%M%S)}"
  dest="$OMACACHY_BACKUP_DIR/$name.$stamp"
  if [[ -e $dest ]]; then
    debug "backup already exists: $dest"
    return 0
  fi
  if (( DRY_RUN )); then
    info "would back up $src -> $dest"
    return 0
  fi
  mkdir -p "$OMACACHY_BACKUP_DIR"
  cp -a -- "$src" "$dest"
  info "Backed up $src -> $dest"
}

# write_state KEY VALUE: persist facts about this installation, idempotently.
write_state() {
  local key=$1 value=$2 tmp
  (( DRY_RUN )) && return 0
  mkdir -p "$OMACACHY_STATE_DIR"
  touch "$OMACACHY_STATE_FILE"
  if grep -q "^${key}=" "$OMACACHY_STATE_FILE"; then
    tmp=$(mktemp)
    sed "s|^${key}=.*|${key}=${value//|/\\|}|" "$OMACACHY_STATE_FILE" >"$tmp"
    mv "$tmp" "$OMACACHY_STATE_FILE"
  else
    printf '%s=%s\n' "$key" "$value" >>"$OMACACHY_STATE_FILE"
  fi
}

state_get() {
  [[ -r $OMACACHY_STATE_FILE ]] || return 1
  sed -n "s/^$1=//p" "$OMACACHY_STATE_FILE" | tail -1
}

# run_as_user USER CMD...: run a command with the target user's identity and a
# clean environment (no inherited XDG_RUNTIME_DIR/session state).
run_as_user() {
  local user=$1 home shell
  shift
  home=$(getent passwd "$user" | cut -d: -f6)
  shell=$(getent passwd "$user" | cut -d: -f7)
  [[ -n $home && -d $home ]] || die "Home directory for $user is missing: $home"
  run runuser -u "$user" -- env -i \
    HOME="$home" USER="$user" LOGNAME="$user" SHELL="${shell:-/bin/bash}" \
    PATH="/usr/local/bin:/usr/bin:/bin:/usr/share/omarchy/bin" \
    TERM="${TERM:-dumb}" LANG="${LANG:-C.UTF-8}" \
    "$@"
}

version_ge() {
  # version_ge A B -> true when A >= B (simple dotted comparison)
  local a=$1 b=$2 IFS=.
  local -a av bv
  read -r -a av <<<"$a"
  read -r -a bv <<<"$b"
  local i n=${#av[@]} j
  (( ${#bv[@]} > n )) && n=${#bv[@]}
  for ((i = 0; i < n; i++)); do
    j=${av[i]:-0}
    local k=${bv[i]:-0}
    j=${j%%[^0-9]*}
    k=${k%%[^0-9]*}
    if (( j > k )); then return 0; fi
    if (( j < k )); then return 1; fi
  done
  return 0
}

usage_common() {
  cat <<'EOF'
Common options:
  -y, --yes             never prompt (required for unattended installs)
  -n, --dry-run         show what would happen; change nothing
  -v, --verbose         extra output
      --user USER       desktop user to provision (default: $SUDO_USER or $USER)
  -h, --help            show help
EOF
}
