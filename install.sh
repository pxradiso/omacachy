#!/bin/bash
# OmaCachy - install Omarchy on an existing CachyOS system.
#
# This is the only entry point you need:
#
#   ./install.sh                 # asks for sudo, then installs Omarchy
#   ./install.sh --boot=convert  # also make Limine the default boot entry
#   ./install.sh --help
#
# OmaCachy is the installer/repo name. What it installs is Omarchy: the
# desktop keeps calling itself Omarchy, uses Omarchy's own updater, and lives
# on top of CachyOS's kernel, drivers and pacman configuration.
set -Eeuo pipefail

SELF=${BASH_SOURCE[0]:-}
ROOT=''
if [[ -n $SELF && -f $SELF ]]; then
  ROOT=$(cd "$(dirname "$(readlink -f "$SELF")")" && pwd)
fi

if [[ -z $ROOT || ! -f $ROOT/bin/omacachy ]]; then
  # Bootstrap path for `curl -fsSL .../install.sh | bash`.
  #
  # The checkout has to live somewhere the *invoking* user can write, because
  # the interactive setup runs before sudo. It is a script repository, not a
  # system package.
  DATA_HOME=${XDG_DATA_HOME:-${HOME:-/tmp}/.local/share}
  DEST=${OMACACHY_DIR:-$DATA_HOME/omacachy}
  URL=${OMACACHY_REPO_URL:-https://github.com/pxradiso/omacachy}

  command -v git >/dev/null 2>&1 || {
    echo "OmaCachy: git is required to bootstrap from a pipe" >&2
    exit 1
  }

  echo "OmaCachy: fetching $URL into $DEST"
  if [[ -d $DEST/.git ]]; then
    if ! git -C "$DEST" pull --ff-only 2>/dev/null; then
      echo "OmaCachy: could not update $DEST (local changes or git issue); using existing checkout" >&2
    fi
  else
    mkdir -p "$(dirname "$DEST")"
    git clone --depth 1 "$URL" "$DEST"
  fi
  exec bash "$DEST/install.sh" "$@"
fi

exec bash "$ROOT/bin/omacachy" install "$@"
