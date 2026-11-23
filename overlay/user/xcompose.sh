#!/bin/bash
# OmaCachy overlay: do not overwrite an existing ~/.XCompose.
#
# Upstream unconditionally rewrites ~/.XCompose. On an existing CachyOS home
# that would silently drop the user's own compose rules. Seed Omarchy's file
# only when there is none, or when the existing one is already Omarchy's.

compose=$HOME/.XCompose

if [[ -s $compose ]] && ! grep -q '/usr/share/omarchy/default/xcompose' "$compose"; then
  echo "OmaCachy: keeping the existing ~/.XCompose (not Omarchy's)"
  exit 0
fi

tee "$compose" >/dev/null <<EOF
# Run omarchy-restart-xcompose to apply changes

# Include fast emoji access
include "/usr/share/omarchy/default/xcompose"

# Identification
<Multi_key> <space> <n> : "$OMARCHY_USER_NAME"
<Multi_key> <space> <e> : "$OMARCHY_USER_EMAIL"
EOF
