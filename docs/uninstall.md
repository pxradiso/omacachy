# Uninstalling OmaCachy / Omarchy

OmaCachy has no one-shot uninstall command: removing a desktop that other
packages depend on is exactly the kind of transaction that needs a human
looking at it. This is the safe order.

> **Take a snapshot first.** Omarchy keeps them:
> `sudo snapper -c root create --description "before removing Omarchy"`.
> Work from a TTY (`Ctrl+Alt+F3`) if the only graphical session is Omarchy.

## 1. Record what is there

```bash
omacachy status
sudo omacachy doctor
pacman -Qq | grep -E '^(omarchy|omarchy-)' | sort
ls /var/lib/omacachy /var/log/omacachy
```

Backups from the install are in `/var/lib/omacachy/backups/`
(`pacman.conf.<stamp>`, `before-os-release.<stamp>`, `limine-default.<stamp>`,
`efibootmgr.before.txt`).

## 2. Keep CachyOS's identity

Restore the original file **before** removing the packages, so the
`omarchy-settings` scriptlet cannot win the last round:

```bash
sudo cp -a /var/lib/omacachy/os-release.original /etc/os-release
```

Confirm:

```bash
grep -E '^(ID|NAME|PRETTY_NAME)=' /etc/os-release
```

## 3. Remove Omarchy's pacman integration

```bash
sudo rm -f /etc/pacman.d/hooks/omacachy-os-release.hook \
           /etc/pacman.d/hooks/omacachy-greeter.hook
sudo rm -f /usr/local/lib/omacachy/restore-os-release \
           /usr/local/lib/omacachy/restore-greeter
sudo rm -f /etc/sddm.conf.d/zz-omacachy-greeter.conf
```

Remove the `[omarchy]` block from `/etc/pacman.conf` (or restore the backup).
Keep the `[cachyos]` sections and the CachyOS mirrorlists.

```bash
sudo cp -a /var/lib/omacachy/backups/pacman.conf.<stamp> /etc/pacman.conf
sudo pacman -Sy
```

The `omarchy-keyring` package and its key can stay; they are harmless. To drop
them:

```bash
sudo pacman -Rns omarchy-keyring
sudo pacman-key --delete 40DFB630FF42BCFFB047046CF0134EE680CAC571
```

## 4. Restore the initramfs baseline

```bash
sudo rm -f /etc/mkinitcpio.conf.d/05-omacachy-hooks.conf
sudo mkinitcpio -P
```

If you also want to drop Omarchy's own `00-omarchy-hooks.conf`, it belongs to
`omarchy-settings` and goes away with the package in the next step.

## 5. Remove the packages

Start with the Omarchy runtime; `pacman` will tell you what still depends on it.
Use `-Rns` (no `--noconfirm`) so you see the transaction and can abort.

```bash
sudo pacman -Rns omarchy omarchy-settings
```

If that refuses because of reverse dependencies, list the Omarchy packages and
remove them together, reviewing the transaction:

```bash
sudo pacman -Rns $(pacman -Qq | grep -E '^(omarchy|omarchy-|hype|monologue|omacalc|omacut|omawrite|aether|cliamp|gliff|herdr|signed|tobi-try|disktree-bin|omarchy-)' | sort -u)
```

`omarchy` / `omarchy-settings` own most of `/usr/share/omarchy`, `/usr/local/bin`
entries and the session file. Applications you installed yourself are not
touched.

Keep Hyprland if you want to continue using it with your own config:

```bash
# do NOT include hyprland / quickshell / walker in the removal list
```

## 6. Restore the greeter and the boot order

```bash
ls /usr/share/sddm/themes/           # pick a theme that exists
# /etc/sddm.conf.d/zz-omacachy-greeter.conf is gone; 10-theme.conf may still
# point at Omarchy's theme, which was removed with the package.
sudo systemctl restart sddm
```

If you used `--boot=convert`, put your previous firmware entry back:

```bash
cat /var/lib/omacachy/backups/efibootmgr.before.txt
sudo efibootmgr -o 0001,0002,0003
```

Limine itself can stay installed; it boots the CachyOS UKIs fine. Remove it only
if you know what you are replacing it with.

## 7. Remove OmaCachy's own state

Only after the packages are gone:

```bash
sudo rm -rf /var/lib/omacachy /var/log/omacachy
sudo rm -f /etc/default/limine        # only if you do not want Omarchy's keys
```

## 8. Reboot and reinstall your old desktop

```bash
sudo reboot
```

If you removed KDE/GNOME/etc. during the install, install the metapackage again
(for example `sudo pacman -S plasma-meta`), then log back in.

Personal files are never deleted by this procedure: Omarchy configs live in your
home (`~/.config/hypr`, `~/.config/omarchy`, `~/.local/share/omarchy`, ...) and
were seeded without overwriting anything. Remove them by hand if you no longer
want them.
