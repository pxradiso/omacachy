# Bootloader, UKIs and snapshots

Omarchy is built around **Limine** + **UKIs** (Unified Kernel Images) +
**snapper**. This is not a preference: Omarchy's packages hard-depend on
`limine`, `limine-mkinitcpio-hook`, `limine-snapper-sync` and `snapper`, because
the boot menu is also the snapshot/rollback menu. OmaCachy therefore cannot
install Omarchy on a machine that boots GRUB or systemd-boot *without* also
installing Limine.

The kernel is not replaced: `linux-omarchy` and `linux-t2` are skipped, so the
UKIs are built from your CachyOS kernel (`linux-cachyos`, `linux-cachyos-lts`,
... whichever is installed).

## Boot modes

`--boot=MODE` (or the interactive question) controls only the firmware/boot
order side. Limine is installed either way, except with `skip`.

| Mode | What OmaCachy writes to `/etc/default/limine` | What happens |
|---|---|---|
| `refuse` (default) | nothing | aborts before changing anything if Limine is not already deployed |
| `register` | `UEFI_BOOT_ORDER=keep`, `ENABLE_LIMINE_FALLBACK=no` | Limine is registered in the UEFI menu, the current default entry stays; you pick Limine once from the firmware menu |
| `convert` | `UEFI_BOOT_ORDER=first`, `ENABLE_LIMINE_FALLBACK=yes` | Limine becomes the first/default firmware entry |
| `skip` | nothing | you manage bootloader/boot order yourself; only sensible if Limine already boots the machine |

The preferences are written **before** the packages are installed, because
`limine-mkinitcpio-hook` installs a pacman hook that runs `limine-install` as
soon as the package is installed. `/etc/default/limine` overrides Omarchy's
drop-ins.

Current EFI boot entries are saved with `efibootmgr -v` to
`/var/lib/omacachy/backups/efibootmgr.before.txt` before anything changes.

## ESP

The installer looks for a vfat EFI System Partition at `/efi`, `/boot/efi`,
`/boot` and `/limine`, in that order. UKIs and the Limine binary live there, so
at least ~1 GiB free is recommended (the installer warns below that). One UKI is
created per installed kernel.

If your ESP is mounted at `/boot`, note that it is shared with the kernel
packages. That is supported; it is also the layout Omarchy's own ISO uses.

## Snapshots

`snapper` is required. OmaCachy keeps an existing `/etc/snapper/configs/root`
and only adds what is missing (timers, `limine-snapper-sync`). Omarchy's
`snapper.sh` normally rewrites the config; the overlay makes it merge instead.

Snapshot rollback is performed from the Limine boot menu: boot a snapshot, then
use Omarchy's restore flow. The `limine-snapper-sync.service` keeps the boot
entries in sync with snapper; `omacachy doctor` checks that it is enabled.

## Verifying

```bash
omacachy doctor                 # Limine packages, deployment, snapper, UKI hooks
efibootmgr -v                   # firmware entries and current BootOrder
bootctl status 2>/dev/null || true
ls -l /boot /efi /limine 2>/dev/null
cat /etc/default/limine
lsinitcpio /boot/initramfs-linux-cachyos.img 2>/dev/null | head  # if present
```

## Recovering the firmware order

If `--boot=convert` is not what you wanted, restore the previous entry:

```bash
sudo efibootmgr -v                          # read the saved/original order
sudo efibootmgr -o 0001,0002,0003           # put your old entry first again
```

Or rerun the installer with `--boot=register` (it rewrites
`/etc/default/limine` and re-registers Limine without taking over the default).

## BIOS/CSM machines

Not supported: Omarchy needs UEFI for Limine UKIs. The installer stops early if
`/sys/firmware/efi` is missing.
