# Architecture

OmaCachy is an **installer**, not a fork. The machine ends up running Omarchy's
own signed packages, so omarchy's code, configs and updater are exactly what
upstream ships.

## The two halves

```
CachyOS base                      Omarchy desktop
├── linux-cachyos + headers       ├── omarchy, omarchy-settings
├── chwd / GPU drivers            ├── hyprland, quickshell, walker, ...
├── pacman.conf, mirrors, keys    ├── /etc/skel/.config/{hypr,omarchy,...}
├── snapper (optional)            ├── /usr/share/omarchy (CLI, defaults)
└── systemd, SDDM                 └── omarchy update (updater + migrations)
```

The only thing OmaCachy adds is the glue that lets the right half sit on the
left half without either overwriting the other.

## Install pipeline

`bin/omacachy install` (see `lib/install.sh`) runs:

0. **Interactive setup** (`lib/tui.sh`) - before sudo, on `/dev/tty`: apps,
   current DE/WM, Limine, greeter, final confirmation. Answers become flags.
1. **Preflight** (`lib/detect.sh`) - CachyOS/Arch, UEFI, btrfs, ESP, free
   space, Limine state, conflicting CachyOS Hyprland config packages.
2. **Repositories** (`lib/repo.sh`) - `[omarchy]` stable before the first repo
   section, `[multilib]` if missing, signing key via `pacman-key`.
3. **Upgrade** - `pacman -Su` so the 200+ package install is not a partial
   upgrade.
3b. **Old desktop removal** (`lib/desktops.sh`) - optional, preflighted with
   `pacman -Rcs --print` and refused if it would touch protected packages.
4. **Bootloader preferences** (`lib/system.sh`) - `/etc/default/limine` keys
   before `limine-mkinitcpio-hook`'s pacman hook fires.
5. **Packages** (`lib/packages.sh`) - `omarchy` first (it owns the package
   lists), then the filtered lists from `/usr/share/omarchy/install/`.
5b. **Greeter** (`lib/greeter.sh`) - restore the pre-Omarchy SDDM theme when
   the user declined Omarchy's greeter, with a pacman hook for updates.
6. **System setup** - `omarchy-apply-system --install-user USER
   --first-install` with `OMARCHY_INSTALL` pointing at the overlay.
7. **User** (`lib/user.sh`) - seed `/etc/skel` (no clobber), then
   `omarchy-provision-user --force --first-install` as the user.
8. **Finalize** - SDDM, `graphical.target`, recorded state, summary.

## The overlay

`omarchy-apply-system` respects `OMARCHY_INSTALL`. At install time OmaCachy
copies `/usr/share/omarchy/install` to `/var/lib/omacachy/overlay` and drops
`overlay/` files on top. Nothing in `/usr/share/omarchy` is modified, so package
upgrades replace it cleanly.

Replaced scripts (full reasoning in
[docs/cachyos-differences.md](cachyos-differences.md)):

```
post-install/pacman.sh                 never replace CachyOS pacman.conf
config/enable-services.sh              only enable units that exist
config/snapper.sh                      keep an existing snapper config
config/firewall.sh                     tolerate missing ufw/ufw-docker
config/increase-lockout-limit.sh       guard missing PAM files
hardware/all.sh                        drop NVIDIA/power/DKMS steps
user/xcompose.sh                       keep an existing ~/.XCompose
```

## Package policy

Read from the installed `omarchy` package, so the lists always match the
release on disk.

- **Always skipped**: `linux-omarchy*`, `linux-t2*` (CachyOS kernel), `yay-debug`.
- **Skipped unless `--with-nvidia`**: `nvidia-*`, `lib32-nvidia-*`,
  `libva-nvidia-driver` (CachyOS's `chwd` owns them).
- **Resilience loop**: the transaction is dry-run with `pacman -S --print`.
  If a package cannot be satisfied (a pinned dependency, a package removed
  from the repos), it is skipped with its reason and the transaction is
  retried, up to 50 times. The install runs once, at the end, with the
  installable set.

This is what keeps a stable Omarchy release installable on a rolling CachyOS
when upstream lags a rebuild (e.g. a plugin pinned to the previous Hyprland).

## Idempotency

- `pacman -S --needed` for everything.
- `/etc/default/limine` keys are set, not appended twice.
- `/etc/pacman.conf` gets `[omarchy]` only when absent.
- `/etc/skel` seeding uses `tar --skip-old-files`; ownership is fixed only for
  paths created by that run.
- `omarchy-provision-user --force --first-install` is re-runnable and marks all
  shipped migrations as applied.
- Backups are per-run (`/var/lib/omacachy/backups/*.<timestamp>`).

## State and logs

```
/var/lib/omacachy/state.env                  versions, user, boot mode, date
/var/lib/omacachy/overlay/                   install-time overlay
/var/lib/omacachy/mkinitcpio-hooks.baseline  CachyOS HOOKS captured at install
/var/lib/omacachy/backups/                   pacman.conf, os-release, limine, ...
/var/log/omacachy/install.log                OmaCachy phases
/var/log/omacachy/omarchy-system.log         omarchy-apply-system output
/var/log/omacachy/omarchy-user.log           omarchy-provision-user output
```
