#!/bin/bash
# Package-resolution harness.
#
# Builds the Omarchy package set the way the installer does, then dry-runs the
# full transaction with `pacman -S --print`, with and without --no-apps.
#
#   tests/resolve.sh
#   OMACACHY_TEST_PACMAN_CONF=/path/to/pacman.conf tests/resolve.sh
#
# OMACACHY_TEST_PACMAN_CONF is useful for an offline/thin fixture: the file must
# point DBPath/Server entries at a populated pacman database. Without it, the
# host's own pacman configuration is used, which needs network access and the
# [omarchy] repository enabled.
#
# Requires the omarchy package (for /usr/share/omarchy/install/*.packages).
# Runs without root; `pacman --print` only reads databases.
set -Eeuo pipefail

ROOT=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)

if [[ ! -r /usr/share/omarchy/install/omarchy-base.packages ]]; then
  echo "skip: /usr/share/omarchy/install/omarchy-base.packages is missing" >&2
  echo "      install the omarchy package (or run this on an installed system)" >&2
  exit 77
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export OMACACHY_STATE_DIR="$work/state"
export OMACACHY_LOG_DIR="$work/log"
mkdir -p "$OMACACHY_STATE_DIR" "$OMACACHY_LOG_DIR"

export OMACACHY_REPO="$ROOT"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=../lib/identity.sh
source "$ROOT/lib/identity.sh"
# shellcheck source=../lib/detect.sh
source "$ROOT/lib/detect.sh"
# shellcheck source=../lib/desktops.sh
source "$ROOT/lib/desktops.sh"
# shellcheck source=../lib/greeter.sh
source "$ROOT/lib/greeter.sh"
# shellcheck source=../lib/tui.sh
source "$ROOT/lib/tui.sh"
# shellcheck source=../lib/repo.sh
source "$ROOT/lib/repo.sh"
# shellcheck source=../lib/packages.sh
source "$ROOT/lib/packages.sh"
# shellcheck source=../lib/overlay.sh
source "$ROOT/lib/overlay.sh"
# shellcheck source=../lib/system.sh
source "$ROOT/lib/system.sh"
# shellcheck source=../lib/user.sh
source "$ROOT/lib/user.sh"
# shellcheck source=../lib/finalize.sh
source "$ROOT/lib/finalize.sh"
# shellcheck source=../lib/doctor.sh
source "$ROOT/lib/doctor.sh"
# shellcheck source=../lib/install.sh
source "$ROOT/lib/install.sh"

DRY_RUN=1
ASSUME_YES=1

if [[ -n ${OMACACHY_TEST_PACMAN_CONF:-} ]]; then
  [[ -r $OMACACHY_TEST_PACMAN_CONF ]] || {
    echo "error: OMACACHY_TEST_PACMAN_CONF is not readable" >&2
    exit 2
  }
  conf=$OMACACHY_TEST_PACMAN_CONF
  pacman() { /usr/bin/pacman --config "$conf" "$@"; }
  echo "using pacman config: $conf"
else
  echo "using the host pacman configuration"
fi

fails=0
check() {
  local label=$1 ok=$2
  if ((ok)); then
    printf '  ok   %s\n' "$label"
  else
    printf '  FAIL %s\n' "$label"
    fails=$((fails + 1))
  fi
}

resolve_set() {
  local mode=$1
  NO_APPS=$mode
  load_skip_policy
  build_package_set
  RESOLVED_PACKAGES=''
  SKIPPED=()
  SKIPPED_REASONS=()
  resolve_package_set >/dev/null 2>&1 || return 1
  printf '%s\n' "$RESOLVED_PACKAGES"
}

echo
echo "== full set (NO_APPS=0) =="
full=$(resolve_set 0) || { echo "resolution failed"; exit 1; }
full_count=$(printf '%s\n' "$full" | grep -c . || true)
full_names=$(printf '%s\n' "$full" | awk '{print $1}')
echo "  resolved: $full_count packages"
check "transaction resolves to more than 100 packages" "$((full_count > 100))"
for pkg in omarchy hyprland sddm; do
  if grep -qxF "$pkg" <<<"$full_names"; then
    check "full set includes $pkg" 1
  else
    check "full set includes $pkg" 0
  fi
done
for pkg in linux-omarchy linux-omarchy-headers linux-t2 nvidia-utils nvidia-dkms; do
  if grep -qxF "$pkg" <<<"$full_names"; then
    check "full set must not include $pkg" 0
  else
    check "full set excludes $pkg" 1
  fi
done

echo
echo "== desktop-only set (NO_APPS=1) =="
slim=$(resolve_set 1) || { echo "resolution failed"; exit 1; }
slim_count=$(printf '%s\n' "$slim" | grep -c . || true)
slim_names=$(printf '%s\n' "$slim" | awk '{print $1}')
# Dependencies may legitimately pull in an app (mpv, for example). The filter
# decision is about the *requested* set, so check that one too.
NO_APPS=1
load_skip_policy
build_package_set
slim_direct=$(printf '%s\n' "${PACKAGES[@]}")
echo "  resolved: $slim_count packages (${#PACKAGES[@]} requested)"
check "desktop-only set resolves" "$((slim_count > 100))"
check "desktop-only set is smaller than the full set" "$((slim_count < full_count))"
for pkg in omarchy hyprland sddm foot; do
  if grep -qxF "$pkg" <<<"$slim_names"; then
    check "desktop-only set still includes $pkg" 1
  else
    check "desktop-only set still includes $pkg" 0
  fi
done
for pkg in chromium libreoffice-fresh obsidian nautilus mpv hype omacalc; do
  if grep -qxF "$pkg" <<<"$slim_direct"; then
    check "desktop-only set must not request $pkg" 0
  else
    check "desktop-only set does not request $pkg" 1
  fi
done

echo
if ((fails)); then
  printf '%d resolution check(s) failed\n' "$fails"
  exit 1
fi
printf 'package resolution looks good (%d -> %d packages)\n' "$full_count" "$slim_count"
