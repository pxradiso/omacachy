#!/bin/bash
# shellcheck shell=bash
# System detection and preflight checks.

if [[ -n ${_OMACACHY_DETECT:-} ]]; then return 0; fi
_OMACACHY_DETECT=1

OS_ID=''
OS_NAME=''
OS_ID_LIKE=''
IS_CACHYOS=0
IS_ARCH=0
ROOT_FSTYPE=''
ROOT_SOURCE=''
ESP_PATH=''
ESP_FSTYPE=''
LIMINE_INSTALLED=0
LIMINE_DEPLOYED=0
OMARCHY_VERSION=''
TARGET_USER=''
TARGET_HOME=''
BOOT_MODE='refuse'   # refuse | register | convert
ALLOW_NON_BTRFS=0
CONFLICTING_PACKAGES=()

detect_distro() {
  [[ -r /etc/os-release ]] || die "/etc/os-release is missing: unsupported system"
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID=${ID:-}
  OS_NAME=${PRETTY_NAME:-${NAME:-$OS_ID}}
  OS_ID_LIKE=${ID_LIKE:-}

  case "$OS_ID $OS_ID_LIKE" in
    *cachyos*) IS_CACHYOS=1 ;;
  esac
  case "$OS_ID $OS_ID_LIKE" in
    *arch*) IS_ARCH=1 ;;
  esac

  # After Omarchy is installed, /etc/os-release says ID=omarchy (the
  # omarchy-settings scriptlet owns that file, exactly as on upstream Omarchy).
  # The CachyOS repositories are what identify the base distro then.
  if grep -q '^\[cachyos\]' /etc/pacman.conf 2>/dev/null ||
    [[ -f /etc/pacman.d/cachyos-mirrorlist ]]; then
    IS_CACHYOS=1
    IS_ARCH=1
  fi

  debug "distro: ID=$OS_ID LIKE=$OS_ID_LIKE pretty=$OS_NAME"
}

detect_root_fs() {
  ROOT_FSTYPE=$(findmnt -no FSTYPE / 2>/dev/null || true)
  ROOT_SOURCE=$(findmnt -no SOURCE / 2>/dev/null || true)
  debug "root: $ROOT_SOURCE ($ROOT_FSTYPE)"
}

detect_esp() {
  local candidate fstype
  ESP_PATH='' ESP_FSTYPE=''
  for candidate in /efi /boot/efi /boot /limine; do
    [[ -d $candidate ]] || continue
    fstype=$(findmnt -M "$candidate" -no FSTYPE 2>/dev/null || true)
    if [[ $fstype == vfat ]]; then
      ESP_PATH=$candidate ESP_FSTYPE=$fstype
      # Prefer an ESP that actually holds the Limine binary or config.
      if [[ -f $candidate/limine.conf || -f $candidate/EFI/limine/limine_x64.efi ]]; then
        break
      fi
    fi
  done
  debug "ESP: ${ESP_PATH:-none} (${ESP_FSTYPE:-n/a})"
}

detect_limine() {
  LIMINE_INSTALLED=0 LIMINE_DEPLOYED=0
  if pkg_installed limine-mkinitcpio-hook || pkg_installed limine-entry-tool || pkg_installed limine; then
    LIMINE_INSTALLED=1
  fi
  if [[ -n $ESP_PATH ]]; then
    if [[ -f $ESP_PATH/limine.conf || -f $ESP_PATH/EFI/limine/limine_x64.efi ]]; then
      LIMINE_DEPLOYED=1
    fi
  fi
  if have efibootmgr && efibootmgr 2>/dev/null | grep -qi 'limine'; then
    LIMINE_DEPLOYED=1
  fi
  debug "limine: installed=$LIMINE_INSTALLED deployed=$LIMINE_DEPLOYED"
}

detect_omarchy() {
  OMARCHY_VERSION=''
  if pkg_installed omarchy; then
    OMARCHY_VERSION=$(pkg_version omarchy)
  fi
  debug "omarchy: ${OMARCHY_VERSION:-not installed}"
}

resolve_target_user() {
  local requested=${1:-}
  if [[ -n $requested ]]; then
    TARGET_USER=$requested
  elif [[ -n ${SUDO_USER:-} && ${SUDO_USER:-} != root ]]; then
    TARGET_USER=$SUDO_USER
  elif [[ $EUID -eq 0 && -n ${OMACACHY_INVOKING_USER:-} ]]; then
    TARGET_USER=$OMACACHY_INVOKING_USER
  else
    TARGET_USER=${USER:-}
  fi

  [[ -n $TARGET_USER ]] || die "Could not determine the desktop user: pass --user USER"
  getent passwd "$TARGET_USER" >/dev/null || die "User '$TARGET_USER' does not exist"
  [[ $TARGET_USER != root ]] || die "Refusing to provision Omarchy for root: pass --user USER"

  TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
  [[ -n $TARGET_HOME ]] || die "User '$TARGET_USER' has no home directory"
  debug "target user: $TARGET_USER ($TARGET_HOME)"
}

detect_conflicting_desktops() {
  local found=()
  local pkg
  for pkg in cachyos-hyprland-settings cachyos-hypr-noctalia; do
    if pkg_installed "$pkg"; then found+=("$pkg"); fi
  done
  if (( ${#found[@]} )); then
    CONFLICTING_PACKAGES=("${found[@]}")
  else
    CONFLICTING_PACKAGES=()
  fi
}

detect_hardware() {
  IS_TUXEDO=0
  IS_ASUS=0
  IS_APPLE_T2=0
  IS_DELL_XPS=0
  HAS_NVIDIA_GPU=0
  HAS_AMD_GPU=0
  HAS_INTEL_CPU=0
  IS_FRAMEWORK=0
  IS_MACBOOK_SPI=0

  local vendor product
  vendor=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || true)
  product=$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)
  case "$vendor $product" in
    *TUXEDO* | *Schenker* | *XMG* | *Mechrevo* | *Tongfang* | *Uniwill*)
      IS_TUXEDO=1
      ;;
  esac
  case "$vendor" in
    *ASUSTeK* | *ASUS*) IS_ASUS=1 ;;
    *Framework*) IS_FRAMEWORK=1 ;;
    *Apple*) IS_MACBOOK_SPI=1 ;;
  esac
  # Apple T2 Macs have T2 chip; detect via sys vendor/product or lspci apple/t2
  if [[ "$vendor" == *Apple* ]] || have_lspci_t2; then
    IS_APPLE_T2=1
  fi
  case "$vendor $product" in
    *Dell*XPS*|*Dell*Latitude*XPS*) IS_DELL_XPS=1 ;;
    *Dell*) [[ "$product" == *XPS* ]] && IS_DELL_XPS=1 ;;
  esac

  if have lspci; then
    lspci 2>/dev/null | grep -qi 'nvidia' && HAS_NVIDIA_GPU=1
    if lspci 2>/dev/null | grep -qiE 'VGA compatible controller.*(AMD|ATI|Advanced Micro Devices)|Display controller.*(AMD|ATI|Advanced Micro Devices)|3D controller.*(AMD|ATI|Advanced Micro Devices)'; then
      HAS_AMD_GPU=1
    fi
  fi
  if [[ $(uname -m) == x86_64 ]] && grep -qi intel /proc/cpuinfo 2>/dev/null; then
    HAS_INTEL_CPU=1
  fi

  debug "hardware: tuxedo=$IS_TUXEDO asus=$IS_ASUS apple_t2=$IS_APPLE_T2 dell_xps=$IS_DELL_XPS framework=$IS_FRAMEWORK macbook_spi=$IS_MACBOOK_SPI nvidia_gpu=$HAS_NVIDIA_GPU amd_gpu=$HAS_AMD_GPU intel_cpu=$HAS_INTEL_CPU vendor=$vendor"
}

have_lspci_t2() {
  have lspci || return 1
  lspci -nn 2>/dev/null | grep -qiE 'apple|t2|106b:180[12]'
}

free_kib() { df -Pk "$1" 2>/dev/null | awk 'NR==2 {print $4}'; }

check_disk_space() {
  local root_avail esp_avail
  root_avail=$(free_kib /)
  if [[ -n $root_avail ]] && (( root_avail < 10 * 1024 * 1024 )); then
    die "Not enough free space on /: $(( root_avail / 1024 )) MiB (need at least 10 GiB for the Omarchy package set)"
  fi
  if [[ -n $ESP_PATH ]]; then
    esp_avail=$(free_kib "$ESP_PATH")
    if [[ -n $esp_avail ]] && (( esp_avail < 1024 * 1024 )); then
      warn "Less than 1 GiB free on the ESP ($ESP_PATH): UKIs for several kernels may not fit."
    fi
  fi
}

check_boot_prereqs() {
  if [[ ! -d /sys/firmware/efi ]]; then
    die "This system booted in BIOS/CSM mode. Omarchy needs UEFI (Limine + UKI)."
  fi
  [[ -n $ESP_PATH ]] || die "No vfat EFI System Partition found (looked at /efi, /boot/efi, /boot, /limine)."

  if (( ! LIMINE_DEPLOYED )); then
    case $BOOT_MODE in
      register | convert | skip) ;;
      *)
        cat >&2 <<EOF
${C_RED}Limine is not the bootloader of this machine.${C_RESET}

Omarchy's packages hard-depend on Limine (\`limine-mkinitcpio-hook\`,
\`limine-snapper-sync\`) because boot entries and snapshot rollback are Limine
UKIs. Installing them registers Limine in the firmware.

Choose how omacachy should handle the bootloader:

  --boot=register   install Limine but keep the current default boot entry
                    (Limine is added to the firmware menu; you switch later)
  --boot=convert    install Limine and make it the default boot entry
  --boot=skip       only for machines that already boot Limine

The current EFI boot entries are backed up before anything changes.
EOF
        exit 1
        ;;
    esac
  fi
}

preflight() {
  step "Preflight"
  require_root
  require_cmd pacman findmnt systemctl grep sed awk tar

  detect_distro
  if (( ! IS_CACHYOS )); then
    if (( IS_ARCH )); then
      warn "This is not CachyOS but an Arch-like system ($OS_NAME). Continuing."
    else
      die "Unsupported distribution ($OS_NAME). omacachy targets CachyOS and Arch-like systems."
    fi
  fi

  detect_root_fs
  if [[ $ROOT_FSTYPE != btrfs ]]; then
    if (( ALLOW_NON_BTRFS )); then
      warn "/ is not btrfs ($ROOT_FSTYPE). Snapshots/rollback will not work (--allow-non-btrfs)."
    else
      die "/ is $ROOT_FSTYPE, not btrfs. Omarchy's snapshot/rollback model needs btrfs + snapper (use --allow-non-btrfs to override)."
    fi
  fi

  detect_esp
  detect_limine
  detect_omarchy
  detect_hardware
  detect_conflicting_desktops
  check_disk_space
  check_boot_prereqs

  if (( ${#CONFLICTING_PACKAGES[@]} )); then
    warn "CachyOS Hyprland config packages detected: ${CONFLICTING_PACKAGES[*]}"
    warn "They ship their own ~/.config/hypr and will fight Omarchy's. Remove them first:"
    warn "  sudo pacman -Rns ${CONFLICTING_PACKAGES[*]}"
  fi

  if [[ -n $OMARCHY_VERSION ]]; then
    info "Omarchy already installed: $OMARCHY_VERSION (install will repair/refresh it)"
  fi

  info "System:   $OS_NAME"
  info "Root:     $ROOT_SOURCE ($ROOT_FSTYPE)"
  info "ESP:      $ESP_PATH"
  info "Limine:   installed=$LIMINE_INSTALLED deployed=$LIMINE_DEPLOYED"
  info "Boot mode: $BOOT_MODE"
  info "User:     $TARGET_USER ($TARGET_HOME)"
}
