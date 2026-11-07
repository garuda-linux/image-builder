# Installer

The live ISO installs Garuda with [Calamares](https://calamares.io/), from the _calamares-garuda_ package. garuda-tools generated its configuration at build time. image-builder ships it as static files in the live layer instead.

## Configuration

The configuration files, relative to `mkosi.images/live/mkosi.extra/`:

| Path                                                | Content                                            |
| --------------------------------------------------- | -------------------------------------------------- |
| `etc/calamares/settings.conf`                       | the module sequence, branding and general switches |
| `etc/calamares/modules/<module>.conf`               | one file per configured module                     |
| `usr/share/calamares/branding/garuda/branding.desc` | product names, window size, sidebar colours        |

`<module>` is the Calamares module name, for example `users`.

### Change a setting for all editions

Edit the file in `mkosi.images/live/mkosi.extra/etc/calamares/`.

### Change a setting for one edition

Copy the file to the same path under `mkosi.images/live/mkosi.profiles/<edition>/mkosi.extra/` and edit the copy. The copy replaces the shared file in that edition, see [Common tasks#Override a shared file in one edition](common-tasks.md#override-a-shared-file-in-one-edition). As of November 2026, only _dr460nized-gaming_ does this, with `modules/users.conf` for its extra groups.

### Change the module sequence

Edit `settings.conf`. Each module in the `exec` part that needs settings has a file in `modules/`.

### Validate a changed file

Check that a changed file is valid YAML before building, for example with _yq_:

```console
$ yq eval . mkosi.images/live/mkosi.extra/etc/calamares/modules/users.conf >/dev/null
```

Then rebuild and test an installation, see [Testing#Live ISO](testing.md#live-iso).

The codename in `branding.desc` is the placeholder `@CODENAME@`. `mkosi.postinst.chroot` of the live layer replaces it with `DISTRIB_CODENAME` from `/etc/lsb-release` of the _garuda-lsb_ package.

## Installation process

The installer works offline:

1. The _partition_ and _mount_ modules create the Garuda btrfs subvolumes `@`, `@home`, `@root`, `@srv`, `@cache`, `@log` and `@tmp`.
2. _unpackfs_ copies `/run/garuda/install`, the `root` and `desktop` layers of the ISO, with _rsync_ (`sourcefs: "file"`).
3. _ghtcfg_ installs the drivers from the offline repository `/opt/ght/pkg` of the `mhwd` layer.
4. _services-systemd_ only sets the graphical target. All other services come from the preset files, which were already applied in the copied layers.
5. _postcfg_ creates the pacman keyring of the new system and rebuilds the initramfs: it removes the microcode package of the other CPU vendor, which triggers the dracut pacman hook, or runs `dracut-rebuild` itself when the vendor is unknown.
6. _bootloader_ installs _systemd-boot_ on the ESP at `/efi` (4 GiB in automatic partitioning, at least 1 GiB when an existing ESP is picked), writes `/etc/kernel/cmdline` and runs `kernel-install add` for every kernel, which builds the UKIs with the configuration in `/etc/kernel/`, see [Architecture#systemd-boot](architecture.md#systemd-boot). The new system carries no GRUB.
7. _preservefiles_ copies the installer log to `/var/log/Calamares-install.log` of the new system.

The initramfs images in `/boot` are built in the `root` layer and rebuilt by _postcfg_ for the installed system. No separate _dracut_ module runs.

## Known issues

The installer supports offline installation only. The garuda-tools options for _netinstall_, OEM mode and ZFS are not ported.

## See also

- [Calamares module documentation](https://github.com/calamares/calamares/tree/calamares/src/modules)
- [Editions](editions.md)
- [Testing](testing.md)
