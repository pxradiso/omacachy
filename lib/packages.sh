#!/bin/bash
# shellcheck shell=bash
# Package set selection and resilient installation.
#
# Omarchy's package lists are read from the *installed* omarchy package, so
# they always match the release that is actually on the machine. A few entries
# are filtered: CachyOS keeps its own kernel and driver stack, and packages that
# the current Arch/CachyOS repositories cannot satisfy are skipped with a
# warning instead of failing the whole install.

if [[ -n ${_OMACACHY_PACKAGES:-} ]]; then return 0; fi
_OMACACHY_PACKAGES=1

WITH_NVIDIA="${WITH_NVIDIA:-0}"
NO_APPS="${NO_APPS:-0}"

# Omarchy's preinstalled *applications*, as opposed to the desktop shell and
# its system dependencies. `--no-apps` skips exactly these (and nothing else),
# so a minimal install still has Hyprland, the shell, the terminal, fonts,
# audio, networking, the file-manager integration and the Omarchy CLI.
OMARCHY_APP_PACKAGES=(
  aether
  chromium
  cliamp
  disktree-bin
  evince
  gliff
  gnome-disk-utility
  herdr
  hype
  imv
  libreoffice-fresh
  localsend
  monologue
  moonlight-qt
  mpv
  mpv-mpris
  nautilus
  nautilus-python
  obsidian
  omacalc
  omacut
  omawrite
  pinta
  signed
  sushi
  superwhisper-bin
  system-config-printer
  tobi-try
  ttf-ia-writer
)

declare -A SKIP_REASON=()
SKIPPED=()
SKIPPED_REASONS=()
RESOLVED_PACKAGES=''

skip_add() {
  local name=$1 reason=$2
  SKIPPED+=("$name")
  SKIPPED_REASONS+=("$reason")
}

load_skip_policy() {
  SKIP_REASON=()

  # omacachy is CachyOS-first: the CachyOS kernel, its prebuilt NVIDIA modules
  # and chwd own the boot/kernel/driver layer. Omarchy's copies are not used.
  local p
  for p in linux-omarchy linux-omarchy-headers linux-t2 linux-t2-headers; do
    SKIP_REASON[$p]="CachyOS kernel is kept"
  done

  SKIP_REASON[yay-debug]="debug symbols"

  if (( ! WITH_NVIDIA )); then
    for p in nvidia-dkms nvidia-utils nvidia-open-dkms nvidia-580xx-dkms nvidia-580xx-utils \
      lib32-nvidia-utils lib32-nvidia-580xx-utils lib32-opencl-nvidia-580xx \
      opencl-nvidia-580xx nvidia-580xx-opencl libva-nvidia-driver; do
      SKIP_REASON[$p]="CachyOS (chwd) owns the NVIDIA stack"
    done
  fi

  # CachyOS (chwd) owns the power-profiles daemon; Omarchy's copy conflicts
  SKIP_REASON[omarchy-power-profiles-daemon]="CachyOS (chwd) owns the power-profiles daemon"

  if (( NO_APPS )); then
    for p in "${OMARCHY_APP_PACKAGES[@]}"; do
      SKIP_REASON[$p]="--no-apps"
    done
  fi
}

omarchy_pkg_files() {
  printf '%s\n' \
    /usr/share/omarchy/install/omarchy-base.packages \
    /usr/share/omarchy/install/omarchy-other.packages
}

read_omarchy_packages() {
  local f
  for f in $(omarchy_pkg_files); do
    [[ -r $f ]] || continue
    grep -hvE '^[[:space:]]*(#|$)' "$f"
  done | sed -E 's/[[:space:]]+$//' | sort -u
}

build_package_set() {
  PACKAGES=()
  local p
  while IFS= read -r p; do
    [[ -n $p ]] || continue
    [[ -v SKIP_REASON[$p] ]] && continue
    PACKAGES+=("$p")
  done < <(read_omarchy_packages)
}

install_omarchy_runtime() {
  step "packages: install the Omarchy runtime (stable)"
  if pkg_installed omarchy; then
    info "omarchy $(pkg_version omarchy) already installed; refreshing it with the rest of the set"
  fi
  if (( DRY_RUN )); then
    info "would install the omarchy package from the stable repository"
    return 0
  fi
  run pacman -S --needed --noconfirm --overwrite '*' omarchy ||
    die "Could not install the omarchy package from the stable repository"
}

# resolve_package_set: only used for --dry-run. Does a --print pass and
# drops unsatisfiable entries. Real installation uses install_package_set's
# iterative error-parsing (see below), which also handles multi-provider.
resolve_package_set() {
  local -a todo=("${PACKAGES[@]}")
  local out attempt name
  local -i attempt_max=50

  RESOLVED_PACKAGES=''
  for ((attempt = 1; attempt <= attempt_max; attempt++)); do
    if out=$(pacman -S --print --print-format '%n %v' --needed --noconfirm \
      --overwrite '*' omarchy "${todo[@]}" 2>&1); then
      RESOLVED_PACKAGES=$out
      PACKAGES=("${todo[@]}")
      return 0
    fi

    if [[ $out =~ target\ not\ found:\ ([^[:space:]]+) ]]; then
      name=${BASH_REMATCH[1]}
      todo=($(printf '%s\n' "${todo[@]}" | grep -vxF -- "$name"))
      skip_add "$name" "not available in the configured repositories"
      warn "Skipping $name: not available in the configured repositories"
      continue
    fi

    die "Could not resolve the package transaction:
$out"
  done

  die "Package resolution did not converge after $attempt_max attempts"
}

# normalize_pkg_name: strip version/epoch from a pacman conflict token
# (e.g. "pipewire-jack-1:1.6.11-2" -> "pipewire-jack").
normalize_pkg_name() {
  local n=$1
  n=${n%%:*}      # strip epoch (1:...)
  n=${n%%-*-*}    # strip -pkgver-pkgrel (but keep hyphens in name)
  printf '%s\n' "$n"
}

install_package_set() {
  step "packages: install the Omarchy desktop set"
  load_skip_policy

  if [[ ! -r /usr/share/omarchy/install/omarchy-base.packages ]]; then
    die "Omarchy package lists are missing (/usr/share/omarchy/install/omarchy-base.packages). Did the omarchy package install correctly?"
  fi

  build_package_set
  info "Considering ${#PACKAGES[@]} packages from Omarchy's stable lists"

  if (( DRY_RUN )); then
    info "would install ${#PACKAGES[@]} packages"
    resolve_package_set
    count=$(printf '%s\n' "$RESOLVED_PACKAGES" | grep -c . || true)
    info "Dry run: transaction resolves to $count packages"
    return 0
  fi

  # Install the real transaction, resolving multi-provider prompts and
  # package conflicts iteratively (pacman --noconfirm alone does not
  # disambiguate multi-provider like libtree-sitter.so or libunibilium.so,
  # and cannot resolve jack vs pipewire-jack conflicts).
  local -a todo=("${PACKAGES[@]}")
  local out lib provider a b to_remove name dep pkg
  local -i attempt=0
  local -i attempt_max=60

  while (( ${#todo[@]} > 0 )); do
    ((++attempt <= attempt_max)) || die "Too many resolution attempts for packages"

    info "Installing ${#todo[@]} packages (attempt $attempt): ${todo[*]}"

    if out=$(pacman -S --needed --noconfirm --overwrite '*' omarchy "${todo[@]}" 2>&1); then
      success "Omarchy desktop set installed"
      report_skipped_packages
      return 0
    fi

    warn "pacman returned non-zero:"
    printf '%s\n' "$out" | sed 's/^/  /' >&2

    # Multi-provider: "There are N providers available for libX.so=..."
    if [[ $out =~ providers\ available\ for\ ([^[:space:]=]+) ]]; then
      lib=${BASH_REMATCH[1]}
      provider=$(pacman -Ssq "^${lib}$" 2>/dev/null | head -1)
      if [[ -n $provider ]]; then
        info "Multi-provider for $lib: adding $provider explicitly (CachyOS-first)"
        todo+=("$provider")
        continue
      fi
    fi

    # Conflict: "pkgA-... and pkgB-... are in conflict (reason)"
    if [[ $out =~ ::[[:space:]]([a-z0-9_-]+)([^[:space:]]*)[[:space:]]and[[:space:]]([a-z0-9_-]+)([^[:space:]]*)[[:space:]]are[[:space:]]in[[:space:]]conflict ]]; then
      a=$(normalize_pkg_name "${BASH_REMATCH[1]}${BASH_REMATCH[2]}")
      b=$(normalize_pkg_name "${BASH_REMATCH[3]}${BASH_REMATCH[4]}")
      # Remove the one NOT already installed; prefer keeping what's on disk.
      if pacman -Q "$a" >/dev/null 2>&1; then
        to_remove="$b"
      else
        to_remove="$a"
      fi
      info "Conflict $a vs $b: removing $to_remove to proceed (CachyOS-first)"
      run pacman -R --noconfirm -- "$to_remove" 2>/dev/null || true
      todo=($(printf '%s\n' "${todo[@]}" | grep -vxF -- "$to_remove"))
      skip_add "$to_remove" "conflicts with ${a} (CachyOS-first)"
      continue
    fi

    # Target not found
    if [[ $out =~ target\ not\ found:\ ([^[:space:]]+) ]]; then
      name=${BASH_REMATCH[1]}
      todo=($(printf '%s\n' "${todo[@]}" | grep -vxF -- "$name"))
      skip_add "$name" "not available in the configured repositories"
      warn "Skipping $name: not available in the configured repositories"
      continue
    fi

    # Unable to satisfy dependency
    if [[ $out =~ unable\ to\ satisfy\ dependency\ \'([^\']+)\'\ required\ by\ ([^[:space:]]+) ]]; then
      dep=${BASH_REMATCH[1]}
      pkg=${BASH_REMATCH[2]}
      if printf '%s\n' "${todo[@]}" | grep -qxF -- "$pkg"; then
        todo=($(printf '%s\n' "${todo[@]}" | grep -vxF -- "$pkg"))
        skip_add "$pkg" "needs $dep"
        warn "Skipping $pkg: it needs $dep, which the repositories do not provide"
      else
        name=${dep%%=*}
        todo=($(printf '%s\n' "${todo[@]}" | grep -vxF -- "$name"))
        skip_add "$name" "required by $pkg"
        warn "Skipping $name: required by $pkg and not installable"
      fi
      continue
    fi

    die "Could not install the package set:
$out"
  done

  die "Package installation did not complete (all entries removed without success)"
}

report_skipped_packages() {
  local p reason
  if (( ${#SKIP_REASON[@]} )); then
    info "Intentionally not installing (CachyOS-first policy):"
    for p in "${!SKIP_REASON[@]}"; do
      printf '       - %-32s %s\n' "$p" "${SKIP_REASON[$p]}"
    done | sort
  fi
  if (( ${#SKIPPED[@]} )); then
    warn "Not installable right now (will be retried on the next run):"
    local i
    for i in "${!SKIPPED[@]}"; do
      printf '       - %-32s %s\n' "${SKIPPED[$i]}" "${SKIPPED_REASONS[$i]}"
    done
    cat >&2 <<EOF

  These are upstream/repository drift, not omacachy decisions: Omarchy's
  stable package set is usually rebuilt within days. Re-run:
    sudo omacachy install
  to pick them up once the repositories agree again.
EOF
  fi
}

verify_omarchy_version() {
  local version
  if (( DRY_RUN )); then
    info "would verify that Omarchy >= $OMACACHY_MIN_OMARCHY_VERSION is installed"
    return 0
  fi
  version=$(pkg_version omarchy)
  [[ -n $version ]] || die "omarchy package is not installed"
  if ! version_ge "$version" "$OMACACHY_MIN_OMARCHY_VERSION"; then
    die "Installed Omarchy $version is older than the required $OMACACHY_MIN_OMARCHY_VERSION"
  fi
  success "Omarchy $version installed (stable channel)"
  write_state OMACACHY_OMARCHY_VERSION "$version"
}
