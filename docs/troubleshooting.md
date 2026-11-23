# Troubleshooting

Start with the read-only checks:

```bash
omacachy doctor          # exit code 1 only for real failures
omacachy status
```

Logs:

```
/var/log/omacachy/install.log            OmaCachy phases
/var/log/omacachy/omarchy-system.log     omarchy-apply-system (root setup)
/var/log/omacachy/omarchy-user.log       omarchy-provision-user
```

Every phase is idempotent. The usual fix is to correct the reported problem and
rerun:

```bash
sudo omacachy install --user "$USER"
```

## The installer aborts with "Limine is not the bootloader of this machine"

Omarchy's packages hard-depend on Limine. You have three choices:

```bash
sudo omacachy install --boot=register   # add Limine to the firmware menu, keep current default
sudo omacachy install --boot=convert    # make Limine the default entry
sudo omacachy install --boot=skip       # only if Limine already boots this machine
```

The EFI entries are backed up to
`/var/lib/omacachy/backups/efibootmgr.before.txt` before anything changes. See
[bootloader.md](bootloader.md) for restoring the order.

## "This system booted in BIOS/CSM mode" / "No vfat EFI System Partition found"

Omarchy needs UEFI and a vfat ESP. On a BIOS install there is no supported path:
convert the firmware/boot to UEFI first. If the machine is UEFI but the ESP is
elsewhere, mount it at `/efi`, `/boot/efi`, `/boot` or `/limine`.

## Root filesystem is not btrfs

Snapshots and rollback are part of Omarchy. Either reinstall CachyOS on btrfs,
or accept the limitation explicitly:

```bash
sudo omacachy install --allow-non-btrfs
```

`omacachy doctor` will keep reporting it as a failure, because it is one.

## Package resolution skips something

The resolver dry-runs the whole transaction and drops only entries the
repositories cannot satisfy (a pinned dependency, a package removed upstream).
The reason is printed and recorded. This is upstream/repository drift, not an
OmaCachy choice:

```
WARN Skipping omarchy-hyprland-titlebars: it needs hyprland=0.56.2, …
```

Rerun after the next repository sync; nothing else is needed. The install is
still complete and usable.

## "Could not install the omarchy package"

Usually keyring or mirror related:

```bash
sudo pacman -Sy --noconfirm omarchy-keyring
sudo pacman-key --list-keys 40DFB630FF42BCFFB047046CF0134EE680CAC571
sudo pacman-key --refresh-keys
sudo pacman -Syu
```

Check that `/etc/pacman.conf` still has the CachyOS sections. If `[omarchy]`
points at `/stable/` and the key is trusted, the next run proceeds.

## `/etc/os-release` says Omarchy

The restore hook did not run. Fix it without a full reinstall:

```bash
sudo /usr/local/lib/omacachy/restore-os-release
cat /etc/os-release
```

If the restore script is missing, rerun `sudo omacachy install`; it reinstalls
the script and `/etc/pacman.d/hooks/omacachy-os-release.hook`. If the original
copy was lost, the fallback uses CachyOS's own branding script:

```bash
sudo /usr/share/libalpm/scripts/cachyos-branding os-release
```

## The login greeter switched back to Omarchy

You chose to keep the old theme, but an `omarchy update` replaced
`/etc/sddm.conf.d/10-theme.conf`. Reapply the drop-in:

```bash
sudo /usr/local/lib/omacachy/restore-greeter
```

Verify:

```bash
cat /etc/sddm.conf.d/zz-omacachy-greeter.conf
sudo systemctl restart sddm     # or reboot; this ends your session
```

If the drop-in is wrong or missing, rerun the installer with `--no-greeter` (or
accept Omarchy's theme by running without it).

## SDDM starts, but there is no Omarchy session

Check the session file and the session list:

```bash
ls -l /usr/local/share/wayland-sessions/omarchy.desktop
ls /usr/share/wayland-sessions/
journalctl -u sddm -b --no-pager | tail -50
```

`omacachy doctor` reports a missing session file as a failure. Rerun the
installer to re-provision it, then log out and back in.

## The desktop starts but looks like plain Hyprland

The CachyOS Hyprland config packages win over Omarchy's when both write
`~/.config/hypr`. Remove them (the interactive setup offers this):

```bash
sudo pacman -Rcs cachyos-hyprland-settings cachyos-hypr-noctalia
```

Then log out and back in. Existing personal files are never overwritten by the
installer; move conflicting personal config aside if needed.

## NVIDIA GPU, software rendering, or no external display

CachyOS owns the GPU stack. Let `chwd` pick the module:

```bash
sudo chwd -a
sudo chwd --list-installed
```

Reboot afterwards. Do **not** install Omarchy's `nvidia-*` packages unless you
explicitly want them (`--with-nvidia`), because they can fight `chwd`.

## `pacman -Syu` is blocked

That is Omarchy's own update guard, not OmaCachy:

```bash
omarchy update                                   # supported path
sudo env OMARCHY_ALLOW_DIRECT_PACMAN=1 pacman -Syu   # one-off exception
```

## The old desktop was not removed

Removal is conservative by design. `pacman -Rcs --print` is evaluated first and
the transaction is refused when it would also remove Omarchy, Hyprland, Limine,
the kernel/GPU stack, SDDM, PipeWire, NetworkManager or another base component.
A full KDE removal often pulls in `sddm`, so it is refused; Omarchy reuses that
same SDDM package anyway, and the old session is simply not selected at login.

Remove it by hand if you want the packages gone too:

```bash
sudo pacman -Rcs plasma-meta        # review the transaction; keep sddm if asked
```

Then log out and back in. Omarchy is unaffected.

## Snapper / rollback is unhappy

```bash
sudo snapper -c root list
systemctl status limine-snapper-sync.service
sudo systemctl enable --now limine-snapper-sync.service
```

OmaCachy keeps an existing `/etc/snapper/configs/root`; it does not recreate it.

## A previous run was interrupted

Nothing is left half-configured on purpose; rerun the same command. If pacman
itself was interrupted:

```bash
sudo rm -f /var/lib/pacman/db.lck     # only when no pacman is running
sudo pacman -Syu
sudo omacachy install --user "$USER"
```

## The interactive setup does not appear

It is skipped when:

- `--yes` is passed,
- `OMACACHY_NO_TUI=1` is set, or
- there is no usable `/dev/tty` (for example inside a container).

Use the flags directly:

```bash
sudo omacachy install --yes --boot=register --no-apps --no-greeter
```

## Unknown option / wrong user

```bash
omacachy install --help
sudo omacachy install --user "$USER"
```

The installer refuses to provision `root`; it targets a normal user with `sudo`.
