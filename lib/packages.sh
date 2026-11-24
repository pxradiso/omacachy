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

# Browser chosen by the user/TUI. "auto" picks the first installed/sensible one.
OMACACHY_BROWSER="${OMACACHY_BROWSER:-auto}"

# Core browsers shown in installer choices; other installed desktops are kept as
# possible defaults.
OMACACHY_BROWSER_CHOICES=(chromium firefox brave-bin zen-browser helium-browser)

# Omarchy's preinstalled *applications*, as opposed to the desktop shell and
# its system dependencies. `--no-apps` skips exactly these (and nothing else),
# so a minimal install still has Hyprland, the shell, the terminal, fonts,
# audio, networking, the file-manager integration and the Omarchy CLI.
OMARCHY_APP_PACKAGES=(
  aether
  alacritty
  chromium
  cliamp
  discord
  disktree-bin
  evince
  gliff
  gnome-disk-utility
  herdr
  hype
  imv
  libreoffice-fresh
  localsend
  meld
  micro
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
  signal-desktop
  signed
  spotify
  sushi
  superwhisper-bin
  system-config-printer
  tobi-try
  ttf-ia-writer
  typora
)

OMACACHY_BROWSER_PACKAGES=(chromium firefox brave-bin zen-browser helium-browser)

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

  # Hardware-specific drivers: avoid bloat and broken DKMS on unsupported machines.
  if (( ! IS_TUXEDO )); then
    for p in tuxedo-drivers-nocompatcheck-dkms tuxedo-drivers-dkms tuxedo-control-center-bin; do
      SKIP_REASON[$p]="TUXEDO hardware not detected"
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

browser_desktop_for_package() {
  case $1 in
    chromium) echo chromium.desktop ;;
    firefox) echo firefox.desktop ;;
    brave-bin | brave) echo brave-browser.desktop ;;
    zen-browser) echo zen-browser.desktop ;;
    helium-browser) echo helium-browser.desktop ;;
    *) echo '' ;;
  esac
}

resolve_omacachy_browser() {
  local choice=${OMACACHY_BROWSER:-auto}
  local p

  if [[ $choice != auto ]]; then
    printf '%s\n' "$choice"
    return 0
  fi

  for p in "${OMACACHY_BROWSER_CHOICES[@]}"; do
    if pkg_installed "$p"; then
      printf '%s\n' "$p"
      return 0
    fi
  done

  printf 'chromium\n'
}

build_package_set() {
  PACKAGES=()
  local p selected_browser
  selected_browser=$(resolve_omacachy_browser)

  while IFS= read -r p; do
    [[ -n $p ]] || continue
    [[ -v SKIP_REASON[$p] ]] && continue

    # Replace Omarchy's default browser with the selected one.
    case " ${OMACACHY_BROWSER_PACKAGES[*]} " in
      *" $p "*)
        [[ $p == "$selected_browser" ]] || continue
        ;;
    esac

    PACKAGES+=("$p")
  done < <(read_omarchy_packages)

  # Ensure selected browser is present when apps are installed.
  if (( ! NO_APPS )) && [[ -n $selected_browser ]]; then
    case " ${PACKAGES[*]} " in
      *" $selected_browser "*) ;;
      *) PACKAGES+=("$selected_browser") ;;
    esac
  fi
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
      --overwrite '*' omarchy "${todo[@]}" < /dev/null 2>&1); then
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

    if [[ $out =~ unable\ to\ satisfy\ dependency\ \'([^\']+)\'\ required\ by\ ([^[:space:]]+) ]] \
       || [[ $out =~ cannot\ be\ upgraded\ due\ to\ unresolvable\ dependencies:[[:space:]]+([^[:space:]]+) ]]; then
      if [[ ${BASH_REMATCH[1]:-} != "" && ${BASH_REMATCH[2]:-} != "" ]]; then
        dep=${BASH_REMATCH[1]}
        name=${BASH_REMATCH[2]}
      else
        dep=""
        name=${BASH_REMATCH[1]}
      fi
      todo=($(printf '%s\n' "${todo[@]}" | grep -vxF -- "$name"))
      skip_add "$name" "unresolvable dependency${dep:+ ($dep)}"
      warn "Skipping $name${dep:+ ($dep)}: unresolvable dependency"
      continue
    fi

    if [[ $out =~ are[[:space:]]in[[:space:]]conflict ]]; then
      # Try to extract a package name we can drop; fall back to failing clearly.
      if [[ $out =~ ([a-z0-9._+-]+)\ and\ ([a-z0-9._+-]+)\ are\ in\ conflict ]]; then
        name=${BASH_REMATCH[2]}
        todo=($(printf '%s\n' "${todo[@]}" | grep -vxF -- "$name"))
        skip_add "$name" "package conflict"
        warn "Skipping $name: package conflict"
        continue
      fi
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

# pacman_install PKG...: run pacman -S with output visible in real time
# (so the user sees downloads) while also capturing it in PACMAN_OUT for
# error analysis. Feeds /dev/null to stdin so pacman can never prompt.
pacman_install() {
  local tmp rc
  tmp=$(mktemp)
  PACMAN_OUT=''
  pacman -S --needed --noconfirm --overwrite '*' -- "$@" < /dev/null 2>&1 | tee "$tmp"
  rc=$?
  PACMAN_OUT=$(cat "$tmp")
  rm -f "$tmp"
  return $rc
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
    resolve_package_set
    local count
    count=$(printf '%s\n' "$RESOLVED_PACKAGES" | grep -c . || true)
    info "Dry run: transaction resolves to $count packages"
    return 0
  fi

  # Install packages one at a time for robustness: multi-provider prompts
  # (nvim, libtree-sitter.so, libunibilium.so, qt6-multimedia-backend) and
  # version conflicts (hyprland vs omarchy-hyprland-titlebars) cannot be
  # resolved by --noconfirm alone. Each failure is parsed and handled
  # individually so one bad package does not block the whole set.
  local -a todo=("${PACKAGES[@]}")
  local -a skipped=()
  local pkg lib provider name dep
  local -a provs=()
  local -i attempt=0
  local -i attempt_max=300
  local -i installed_ok=0

  while (( ${#todo[@]} > 0 )); do
    ((++attempt <= attempt_max)) || die "Too many resolution attempts for packages"

    pkg="${todo[0]}"
    todo=("${todo[@]:1}")

    # Never install '--' or an empty token (they are not real packages).
    [[ -z $pkg || $pkg == "--" ]] && continue

    # Output is visible in real time (downloads, progress bars) and also
    # captured in PACMAN_OUT for error parsing below.
    if pacman_install "$pkg"; then
      ((++installed_ok % 25 == 0)) && info "Installed $installed_ok packages so far..."
      continue
    fi

    # pacman crashed (e.g. "corrupted size vs. prev_size", SIGABRT): do not
    # parse its partial output: treat the current package as an unexpected
    # error and skip it so the install can continue.
    if [[ $PACMAN_OUT =~ corrupted\ size|Aborted|core\ dumped|Segmentation\ fault ]]; then
      warn "pacman crashed while installing $pkg:"
      printf '%s\n' "$PACMAN_OUT" | sed 's/^/  /' >&2
      skipped+=("$pkg: pacman crashed")
      continue
    fi

    # Multi-provider: "There are N providers available for nvim:" or
    # "There are N providers available for libtree-sitter.so=0.26-64:"
    if [[ $PACMAN_OUT =~ providers\ available\ for\ ([^[:space:]:]+) ]]; then
      lib=${BASH_REMATCH[1]}
      provs=()
      while IFS= read -r line; do
        if [[ $line =~ ^[[:space:]]*[0-9]+\)[[:space:]]+([a-z0-9._+-]+) ]]; then
          provs+=("${BASH_REMATCH[1]}")
        fi
      done <<< "$PACMAN_OUT"
      if (( ${#provs[@]} > 0 )); then
        provider="${provs[0]}"
        info "Multi-provider for $lib: installing $provider explicitly (CachyOS-first), skipping $pkg"
        skipped+=("$pkg: multi-provider, chose $provider")
        if pacman_install -- "$provider"; then
          continue
        fi
        warn "Could not install $provider (provider for $lib):"
        printf '%s\n' "$PACMAN_OUT" | sed 's/^/  /' >&2
        skipped+=("$provider: provider install failed")
        continue
      fi
    fi

    # Target not found
    if [[ $PACMAN_OUT =~ target\ not\ found:\ ([^[:space:]]+) ]]; then
      name=${BASH_REMATCH[1]}
      skipped+=("$name: not available in the configured repositories")
      warn "Skipping $name: not available in the configured repositories"
      continue
    fi

    # Unresolvable dependency: "unable to satisfy dependency 'X' required by Y"
    # or "The following package cannot be upgraded due to unresolvable dependencies: Y"
    if [[ $PACMAN_OUT =~ unable\ to\ satisfy\ dependency\ \'([^\']+)\'\ required\ by\ ([^[:space:]]+) ]] \
       || [[ $PACMAN_OUT =~ cannot\ be\ upgraded\ due\ to\ unresolvable\ dependencies:[[:space:]]+([^[:space:]]+) ]]; then
      if [[ ${BASH_REMATCH[1]:-} != "" && ${BASH_REMATCH[2]:-} != "" ]]; then
        dep=${BASH_REMATCH[1]}
        name=${BASH_REMATCH[2]}
      else
        dep=""
        name=${BASH_REMATCH[1]}
      fi
      skipped+=("$name: unresolvable dependency${dep:+ ($dep)}")
      warn "Skipping $name${dep:+ ($dep)}: unresolvable dependency"
      continue
    fi

    # Conflict: "pkgA and pkgB are in conflict (reason)"
    if [[ $PACMAN_OUT =~ are[[:space:]]in[[:space:]]conflict ]]; then
      skipped+=("$pkg: package conflict")
      warn "Skipping $pkg: package conflict with another package"
      continue
    fi

    warn "Unexpected pacman error for $pkg:"
    printf '%s\n' "$PACMAN_OUT" | sed 's/^/  /' >&2
    skipped+=("$pkg: unexpected pacman error")
    continue
  done

  report_skipped_packages "${skipped[@]}"
  success "Omarchy desktop set installed"
}

report_skipped_packages() {
  local -a skipped=("${@}")
  local p reason i

  if (( ${#SKIP_REASON[@]} )); then
    info "Intentionally not installing (CachyOS-first policy):"
    for p in "${!SKIP_REASON[@]}"; do
      printf '       - %-32s %s\n' "$p" "${SKIP_REASON[$p]}"
    done | sort
  fi

  if (( ${#skipped[@]} )); then
    warn "Not installed (will be retried on the next run):"
    for i in "${!skipped[@]}"; do
      printf '       - %-48s %s\n' "${skipped[$i]%%:*}" "${skipped[$i]#*:}"
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
