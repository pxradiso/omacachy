<div align="center">

<br/>
<br/>

<img src="assets/omacachy.png" alt="OmaCachy Logo" width="600" />

**Installs DHH's dotfiles ([Omarchy](https://omarchy.org)) on [CachyOS](https://cachyos.org).**

[![License: MIT](https://img.shields.io/badge/license-MIT-yellow.svg?logo=opensourceinitiative&logoColor=black)](LICENSE)
[![Release](https://img.shields.io/github/v/release/pxradiso/omacachy?color=blue&logo=github&logoColor=white)](https://github.com/pxradiso/omacachy/releases)
[![Omarchy stable](https://img.shields.io/badge/Omarchy%20stable-4.5.x-2dd4bf?logo=omarchy&logoColor=%230f172a)](https://pkgs.omarchy.org/stable)
[![CachyOS](https://img.shields.io/badge/CachyOS-fully%20working%21-00a3e0?logo=cachyos&logoColor=white)](https://cachyos.org)
</div>

OmaCachy is the installer (`./install.sh`) and this repository. What ends up on
the machine is **Omarchy**: Omarchy's packages, configs, CLI and update flow.
CachyOS keeps what makes it CachyOS: its kernel, its `chwd` driver stack, its
`pacman.conf`, mirrors and keyrings.

Install it in 1 command!
```bash
curl -fsSL https://raw.githubusercontent.com/pxradiso/omacachy/main/install.sh | bash
```

Or Clone it:

```bash
git clone https://github.com/pxradiso/omacachy
cd omacachy
./install.sh
```

The piped form clones the repository into
`${XDG_DATA_HOME:-~/.local/share}/omacachy` (override with `OMACACHY_DIR`) and
starts the same interactive setup.

`./install.sh` starts an interactive setup (also when it is piped from
`curl -fsSL .../install.sh | bash`). It asks whether to install Omarchy's
preinstalled applications, whether to remove the desktop environment that is
already on the machine, how to handle Limine, and whether to keep the current
SDDM greeter. Every question has a safe default; the last one asks for
confirmation before `sudo` is requested. The screens use `gum`, the same
toolkit as Omarchy's own installer, and the installer adds it if missing. Pass
`--yes` (or set `OMACACHY_NO_TUI=1`) for an unattended install.

> Upstream Omarchy 4.x is ISO-only: it ships a prebuilt btrfs image with Arch
> packages. OmaCachy does not fork it, does not rebuild it and does not clone
> the dotfiles from git. It installs Omarchy's **signed stable packages**
> (`pkgs.omarchy.org/stable`, currently 4.5.x) and only replaces the few
> install-time steps that would overwrite CachyOS with Arch.

---

## Requirements

| Requirement | Details |
|---|---|
| Distribution | CachyOS (Arch-like systems work, with a warning) |
| Firmware | UEFI |
| Root filesystem | BTRFS (snapshots + rollback are part of Omarchy) |
| Bootloader | Limine is required by Omarchy's packages; see [docs/bootloader.md](docs/bootloader.md) |
| ESP | vfat, mounted at `/efi`, `/boot/efi`, `/boot` or `/limine`; ≥ 1 GiB free |
| Disk | ≥ 10 GiB free on `/` |
| Account | a normal user with `sudo` (not root) |
| Setup UI | `gum` (CachyOS `extra`); the installer adds it with pacman if missing |
| Network | required during install |

Omarchy's packages hard-depend on `limine`, `limine-mkinitcpio-hook`,
`limine-snapper-sync` and `snapper`. If your CachyOS install uses GRUB or
systemd-boot, choose `--boot=register` (Limine added to the firmware menu, your
current default untouched) or `--boot=convert` (Limine becomes the default).

## Quick start

```bash
# Interactive: asks about apps, the current DE/WM, Limine and the greeter.
./install.sh

# Unattended with the safe default: add Limine to the firmware menu, keep the
# current default boot entry.
./install.sh --yes --boot=register

# Or make Limine the default boot entry right away.
./install.sh --yes --boot=convert

sudo reboot
```

After the reboot, log in through SDDM with your password and pick the
**Omarchy** / Hyprland session (on `--boot=register`, choose *Limine* in the
firmware boot menu first).

The installer can be re-run at any time: every phase is idempotent.

## Options

```
./install.sh [options]

  --user USER        desktop user to provision (default: the sudo caller)
  --boot MODE        refuse | register | convert | skip   (default: refuse)
  --with-nvidia      install Omarchy's NVIDIA packages instead of leaving the
                     GPU stack to CachyOS/chwd
  --no-apps          desktop only: skip Omarchy's preinstalled applications
  --remove-existing-de
                     remove the desktop environment/window manager already
                     installed (also asked by the interactive setup)
  --no-greeter       keep the current SDDM theme instead of Omarchy's greeter
  --allow-non-btrfs  permit a non-btrfs root (snapshots/rollback will not work)
  --skip-packages    do not touch packages
  --skip-system      do not run Omarchy system setup
  --skip-user        do not touch the user's home
  --no-upgrade       skip the full system upgrade before installing
  -y, --yes          never prompt (skips the interactive setup)
  -n, --dry-run      print the plan, change nothing
  -v, --verbose      extra output
```

`--no-apps` skips a documented set of end-user applications, not the desktop:
Chromium, LibreOffice, Obsidian, Nautilus, mpv, Evince, Pinta, LocalSend,
Moonlight, the Omarchy apps (Omacalc, Omacut, Omawrite, Hype, Monologue,
Signed, ...), Herdr, Gliff, Disktree and their helpers. The shell, terminal,
fonts, audio, networking, input methods and Omarchy's CLI are always installed.

## What it changes

1. **Repositories** - appends `[omarchy]` (stable channel) to
   `/etc/pacman.conf`, enables `[multilib]` if missing, trusts Omarchy's signing
   key. CachyOS's sections are left exactly as they are.
2. **Packages** - a full CachyOS upgrade, then the Omarchy runtime, then
   Omarchy's own package lists (`omarchy-base.packages` +
   `omarchy-other.packages`) filtered through a CachyOS-first policy.
3. **System setup** - runs Omarchy's own `omarchy-apply-system` through an
   overlay (`/var/lib/omacachy/overlay`) that replaces only these steps:

   | Upstream step | OmaCachy replacement |
   |---|---|
   | `post-install/pacman.sh` | keeps CachyOS's `pacman.conf`, mirrors and keyrings |
   | `config/enable-services.sh` | enables only units that exist on CachyOS |
   | `config/snapper.sh` | keeps an existing CachyOS snapper config, adds Omarchy's timers |
   | `config/firewall.sh` | same UFW policy, tolerant of missing `ufw-docker` |
   | `config/increase-lockout-limit.sh` | same policy, guarded on missing PAM files |
   | `hardware/all.sh` | skips NVIDIA/power/DKMS steps owned by CachyOS |
   | `user/xcompose.sh` | never overwrites an existing `~/.XCompose` |

4. **mkinitcpio** - records CachyOS's `HOOKS` baseline and writes
   `/etc/mkinitcpio.conf.d/05-omacachy-hooks.conf`, so Omarchy gets `plymouth`
   and `btrfs-overlayfs` without throwing away the distro's initramfs setup.
5. **User** - seeds `/etc/skel` into the existing home **without overwriting
   anything**, then runs `omarchy-provision-user --force --first-install` so
   Omarchy's migrations are marked as already applied (exactly what a fresh
   Omarchy user gets from the ISO).

The interactive setup can also remove the desktop environment/window manager
that was already installed. That step only targets packages that own session
files (and the known CachyOS Hyprland configuration packages), and it refuses a
removal transaction that would touch Omarchy itself, Limine, the kernel/GPU
stack, SDDM, PipeWire, NetworkManager or another base component.

If you answer "no" to Omarchy's login greeter, OmaCachy keeps the SDDM theme
that was active before the install by writing
`/etc/sddm.conf.d/zz-omacachy-greeter.conf` and installing a pacman hook that
reapplies it after `omarchy update`.

State, overlay and backups live in `/var/lib/omacachy`; logs in
`/var/log/omacachy`.

## What it never does

- **No edge/rc channel, no git dotfiles.** Only `pkgs.omarchy.org/stable`
  signed packages, so Omarchy updates keep coming through `omarchy update`.
- **No `omarchy-refresh-pacman`.** Your CachyOS `pacman.conf`, mirrorlists and
  keyrings are never replaced with Arch's.
- **No home-directory clobbering.** Existing files win; only missing paths are
  seeded.
- **No second kernel.** `linux-omarchy`, `linux-t2` and Omarchy's NVIDIA
  packages are skipped; CachyOS/chwd own the kernel and drivers.
- **No silent bootloader switch.** Boot order changes only with
  `--boot=convert`.

## Updates

Omarchy keeps updating itself:

```bash
omarchy update          # snapshots, keyrings, pacman -Syu, migrations, hooks
```

Direct `pacman -Syu` is blocked by Omarchy's own pacman hook (upstream
behaviour). For a one-off exception: `sudo env OMARCHY_ALLOW_DIRECT_PACMAN=1 pacman -Syu`.

OmaCachy itself is just this repo: `git pull` to get installer fixes. It does
not add an update channel of its own.

## Health checks

```bash
omacachy doctor          # read-only: packages, repo, key, Limine, snapper, user
omacachy status          # installed versions and recorded state
```

## Repository layout

```
install.sh              entry point (./install.sh, interactive setup)
bin/omacachy            CLI: install | update | doctor | status
lib/                    detection, TUI, desktops, greeter, repo, packages,
                        overlay, system, identity, user
overlay/                install-time replacements copied over Omarchy's tree
docs/                   architecture, bootloader, CachyOS differences, troubleshooting,
                        uninstall
tests/                  syntax checks and a package-resolution harness
```

## Documentation

- [docs/architecture.md](docs/architecture.md) - how the overlay works and why
- [docs/bootloader.md](docs/bootloader.md) - Limine, UKIs, snapshots, boot order
- [docs/cachyos-differences.md](docs/cachyos-differences.md) - every deliberate difference
- [docs/troubleshooting.md](docs/troubleshooting.md) - common failures
- [docs/uninstall.md](docs/uninstall.md) - going back to a plain CachyOS

## License

MIT. Omarchy itself is MIT-licensed and remains the work of its authors; this
repository only contains the CachyOS adaptation layer.
