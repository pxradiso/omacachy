#!/bin/bash
# Static checks for the OmaCachy repository.
#
#   tests/check.sh              syntax + policy checks
#   tests/check.sh --shellcheck also run shellcheck when it is installed
#
# Runs without root and without touching the system.
set -Eeuo pipefail

ROOT=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
cd "$ROOT"

RUN_SHELLCHECK=0
[[ ${1:-} == --shellcheck ]] && RUN_SHELLCHECK=1

fails=0
ok() { printf '  ok   %s\n' "$*"; }
bad() { printf '  FAIL %s\n' "$*"; fails=$((fails + 1)); }

echo "== syntax =="
while IFS= read -r file; do
  if bash -n "$file" 2>/tmp/omacachy-check.err; then
    ok "$file"
  else
    bad "$file: $(cat /tmp/omacachy-check.err)"
  fi
done < <(printf '%s\n' install.sh bin/omacachy lib/*.sh tests/*.sh | sort -u)
rm -f /tmp/omacachy-check.err

echo
echo "== required files =="
for file in \
  install.sh bin/omacachy README.md LICENSE .gitignore \
  lib/common.sh lib/detect.sh lib/desktops.sh lib/greeter.sh lib/tui.sh \
  lib/identity.sh lib/repo.sh lib/packages.sh lib/overlay.sh lib/system.sh \
  lib/user.sh lib/finalize.sh lib/doctor.sh lib/install.sh \
  overlay/post-install/pacman.sh overlay/config/enable-services.sh \
  overlay/config/snapper.sh overlay/config/firewall.sh \
  overlay/config/increase-lockout-limit.sh overlay/hardware/all.sh \
  overlay/user/xcompose.sh \
  docs/architecture.md docs/bootloader.md docs/cachyos-differences.md \
  docs/troubleshooting.md docs/uninstall.md; do
  [[ -f $file ]] && ok "$file" || bad "missing $file"
done

echo
echo "== policy =="
# The stable channel only: no edge/rc repository, no git checkout of Omarchy.
if grep -RInE 'pkgs\.omarchy\.org/(edge|rc)|/edge/\$arch|/rc/\$arch' \
  --include='*.sh' --include='*.md' . >/dev/null 2>&1; then
  bad "edge/rc repository referenced"
else
  ok "stable channel only (no edge/rc repository)"
fi

if grep -RInE 'git clone[^#]*(omarchy|dhh)' --include='*.sh' . >/dev/null 2>&1; then
  bad "a script clones Omarchy's dotfiles from git"
else
  ok "no git dotfiles checkout"
fi

if grep -RInE '^[[:space:]]*(sudo[[:space:]]+|run[[:space:]]+|exec[[:space:]]+)?omarchy-refresh-pacman' \
  --include='*.sh' lib overlay install.sh bin >/dev/null 2>&1; then
  bad "omarchy-refresh-pacman is invoked (it would replace CachyOS's pacman.conf)"
else
  ok "never runs omarchy-refresh-pacman"
fi

if grep -RInE 'hostnamectl[[:space:]]+set-hostname|(^|[^a-z])>+/etc/hostname' \
  --include='*.sh' lib overlay install.sh bin >/dev/null 2>&1; then
  bad "the hostname is modified somewhere"
else
  ok "hostname is never modified"
fi

grep -q '^OMACACHY_CHANNEL="stable"$' lib/common.sh &&
  ok "OMACACHY_CHANNEL is stable" ||
  bad "OMACACHY_CHANNEL is not stable"

grep -q 'OMACACHY_OMARCHY_KEY="40DFB630FF42BCFFB047046CF0134EE680CAC571"' lib/common.sh &&
  ok "Omarchy signing key pinned" ||
  bad "Omarchy signing key is not pinned"

# The flag-parsing bug that made every installer option a no-op.
if grep -nE '(^|[[:space:]])[A-Z_]+=1[[:space:]]+shift' lib/*.sh >/dev/null 2>&1; then
  bad "found 'VAR=1 shift' (the shift becomes the command, the flag is lost)"
else
  ok "no 'VAR=1 shift' flag-parsing bug"
fi

# The install entry points must forward the options that the TUI produces.
for flag in --no-apps --remove-existing-de --no-greeter --boot; do
  grep -q -- "$flag" lib/install.sh && ok "install accepts $flag" ||
    bad "install does not accept $flag"
done

# The sudo re-exec must not show the interactive setup a second time.
grep -q -- '--tui-done)' lib/install.sh && ok "install accepts --tui-done" ||
  bad "install does not accept --tui-done"
grep -q -- 'fwd=(--user "$resolved_user" --tui-done)' lib/install.sh &&
  ok "sudo re-exec marks the TUI as done" ||
  bad "sudo re-exec does not mark the TUI as done"

# Full-screen UI: the wizard and the progress view.
grep -q -- '--no-progress' lib/install.sh && ok "install accepts --no-progress" ||
  bad "install does not accept --no-progress"
grep -q 'tui_progress_start' lib/install.sh && ok "install shows the progress view" ||
  bad "install never starts the progress view"
grep -q 'tui_progress_phase' lib/common.sh && ok "step() feeds the progress view" ||
  bad "step() does not feed the progress view"
grep -q 'gum confirm' lib/tui.sh && ok "setup uses gum widgets" ||
  bad "setup does not use gum"
grep -q 'tui_ensure_gum' lib/tui.sh && ok "setup can install gum" ||
  bad "setup does not install gum when missing"

# Yes/No must keep a fixed order; the default is preselected, not swapped.
grep -q -- '--selected "$selected"' lib/tui.sh &&
  ok "Yes/No keeps a fixed order with a preselected default" ||
  bad "Yes/No order depends on the default"
grep -q 'gum choose' lib/tui.sh &&
  ok "Yes/No uses gum choose" ||
  bad "Yes/No does not use gum choose"

# Limine entries need the machine's LUKS/root parameters, not only Omarchy's.
grep -q 'KERNEL_CMDLINE\[default\]' lib/system.sh &&
  ok "Limine entries inherit the machine's kernel cmdline" ||
  bad "Limine entries do not get cryptdevice/root"
grep -q 'sd-btrfs-overlayfs' lib/overlay.sh &&
  ok "mkinitcpio picks the overlay hook that matches the initramfs" ||
  bad "mkinitcpio does not handle systemd initramfs"

echo
echo "== TUI questions =="
while IFS= read -r question; do
  [[ -n $question ]] || continue
  if grep -qF -- "$question" lib/tui.sh; then
    ok "$question"
  else
    bad "missing TUI question: $question"
  fi
done <<'EOF'
Do you want the preinstalled applications of Omarchy?
Do you want to uninstall your current DE or WM?
Do you want to install Limine?
Do you want Omarchy's login greeter?
What system name do you want?
Are you sure you want to continue?
EOF

echo
echo "== docs links =="
while IFS= read -r link; do
  [[ -f $link ]] || bad "README links to a missing file: $link"
done < <(grep -oE '\]\((docs/[^)]+)\)' README.md | sed -E 's/^\]\((.*)\)$/\1/')
ok "README document links checked"

echo
if ((RUN_SHELLCHECK)); then
  echo "== shellcheck =="
  if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck -x -S warning install.sh bin/omacachy lib/*.sh tests/*.sh; then
      ok "shellcheck"
    else
      bad "shellcheck reported findings"
    fi
  else
    printf '  skip shellcheck (not installed)\n'
  fi
fi

echo
if ((fails)); then
  printf '%d check(s) failed\n' "$fails"
  exit 1
fi
printf 'all checks passed\n'
