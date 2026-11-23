# CachyOS differences

OmaCachy installs Omarchy's own stable packages and then deliberately diverges
in a small, enumerable set of places. Everything here exists because blindly
running Omarchy's ISO install steps on an existing CachyOS machine would replace
what makes it CachyOS (kernel, drivers, pacman configuration, identity) with
Arch Linux defaults.

Nothing in this list changes Omarchy's desktop, keybindings, themes, CLI or
update flow.

## Package policy

| Package(s) | Decision | Why |
|---|---|---|
| `linux-omarchy`, `linux-omarchy-headers`, `linux-t2`, `linux-t2-headers` | never installed | CachyOS keeps its own kernel and its CachyOS-tuned variants; UKIs are built from it |
| `nvidia-*`, `nvidia-580xx-*`, `lib32-nvidia-*`, `libva-nvidia-driver` | skipped unless `--with-nvidia` | CachyOS `chwd` installs the correct prebuilt module for the GPU and kernel |
| `yay-debug` | skipped | debug symbols only |
| `asus-proart-p14-speaker-firmware` | skipped when the repos cannot satisfy it | upstream/repo drift; retried on the next run |
| packages pinned to an older dependency (e.g. `omarchy-hyprland-titlebars` needing the previous `hyprland`) | skipped with the reason, transaction retried | stable Omarchy releases can lag a rolling repo; the dry-run resolver keeps the install working and retries next run |
| `--no-apps` set | skipped on request | end-user applications (Chromium, LibreOffice, Obsidian, Nautilus, mpv, Omarchy apps, ...) without touching the desktop shell |

The package lists are read from the **installed** `omarchy` package
(`/usr/share/omarchy/install/omarchy-base.packages` and
`omarchy-other.packages`), so they always match the release on disk.

## pacman, mirrors and keys

| Upstream Omarchy behaviour | OmaCachy behaviour |
|---|---|
| `omarchy-refresh-pacman` replaces `/etc/pacman.conf` with Arch's | never run; CachyOS's `pacman.conf` is kept |
| Arch mirrors/keyrings are used | CachyOS mirrorlists, `cachyos-keyring` and `archlinux-keyring` are kept |
| `[omarchy]` is added at the end | added **before** the first repo section, stable channel only, with CachyOS's sections untouched |

`post-install/pacman.sh` is overlaid so Omarchy's installer cannot rewrite the
pacman configuration. The only repository change is adding the signed
`[omarchy]` stable section (and enabling `[multilib]` if it was absent).

## Identity

| File | Upstream Omarchy | OmaCachy |
|---|---|---|
| `/etc/os-release` | `omarchy-settings` rewrites it to `ID=omarchy` on install and upgrade | original recorded in `/var/lib/omacachy/os-release.original`; restored after the transaction and by `/etc/pacman.d/hooks/omacachy-os-release.hook` on every `omarchy update` |
| hostname | generated on the ISO path | never touched: no `hostnamectl`, no `/etc/hostname` write |
| fallback | - | if the original was lost, `/usr/share/libalpm/scripts/cachyos-branding os-release` rebuilds CachyOS identity from Arch's `/usr/lib/os-release` |

`omacachy doctor` fails if `/etc/os-release` no longer says CachyOS on a CachyOS
machine.

## initramfs

`omarchy-settings` ships `/etc/mkinitcpio.conf.d/00-omarchy-hooks.conf`, which
replaces `HOOKS` wholesale. On CachyOS that would drop distro additions (LUKS
variants, TPM, resume, ...).

OmaCachy records the `HOOKS` line present before the install to
`/var/lib/omacachy/mkinitcpio-hooks.baseline`, then writes
`/etc/mkinitcpio.conf.d/05-omacachy-hooks.conf` (sorts after `00-…`) with that
baseline plus `plymouth` (early, for the boot splash) and `btrfs-overlayfs`.

## System setup overlay

`omarchy-apply-system` honours `OMARCHY_INSTALL`. OmaCachy copies
`/usr/share/omarchy/install` to `/var/lib/omacachy/overlay` and replaces only:

| Upstream script | Replacement |
|---|---|
| `post-install/pacman.sh` | no pacman.conf/mirror refresh |
| `config/enable-services.sh` | enables only units that exist on this machine |
| `config/snapper.sh` | keeps an existing `snapper` config, adds missing timers |
| `config/firewall.sh` | same UFW policy, tolerates missing `ufw-docker` |
| `config/increase-lockout-limit.sh` | same policy, guards missing PAM files |
| `hardware/all.sh` | drops NVIDIA/power/DKMS steps owned by CachyOS and `chwd` |
| `user/xcompose.sh` | never overwrites an existing `~/.XCompose` |

Nothing in `/usr/share/omarchy` itself is modified, so `omarchy update` can
replace it cleanly.

## Services

`config/enable-services.sh` normally enables a fixed list. The overlay enables a
unit only when it exists, so a CachyOS machine without, for example, `iwd` or
`ufw` does not fail the whole install. CUPS, Avahi, Docker, NetworkManager,
Bluetooth, power profiles and SDDM are still enabled when present.

## Users and home

| Upstream | OmaCachy |
|---|---|
| creates the user and writes a fresh home | provisions the **existing** user |
| `/etc/skel` copied over | copied with `tar --skip-old-files`: existing files and dotfiles always win |
| migration markers start empty | `omarchy-provision-user --force --first-install` marks shipped migrations as applied, as on a fresh ISO install |

Ownership is fixed only for paths that the seeding run actually created.

## Desktop and login

- **Old desktop removal** is optional and conservative. Only packages that own
  session files (plus `cachyos-hyprland-settings` / `cachyos-hypr-noctalia`)
  are candidates. `pacman -Rcs --print` is evaluated first and the transaction
  is refused if it would remove Omarchy, Hyprland, Limine, the kernel/GPU stack,
  SDDM, PipeWire, NetworkManager, systemd/glibc or another base component.
  Configuration files are kept (no `-n`).
- **Greeter**: Omarchy's SDDM theme is the default. If declined, the previously
  active theme is kept through `/etc/sddm.conf.d/zz-omacachy-greeter.conf`
  (sorts after Omarchy's `10-theme.conf` and the unowned `99-omarchy-login.conf`)
  and reapplied by `/etc/pacman.d/hooks/omacachy-greeter.hook` after updates.
- **Login** stays password-based SDDM. No autologin is configured.

## Bootloader

Limine is required by Omarchy's packages; it is installed either way. The boot
order is only changed with `--boot=convert`. See
[bootloader.md](bootloader.md) for the full matrix.

## What is *not* different

- Omarchy's packages, configs, shell, themes, keybindings, CLI and menus.
- `omarchy update` (snapshots, keyrings, `pacman -Syu`, migrations, hooks).
- Omarchy's own pacman update guard: direct `pacman -Syu` is still blocked.
- The system name in the desktop: it is still **Omarchy**.
