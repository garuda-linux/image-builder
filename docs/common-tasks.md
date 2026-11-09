# Common tasks

Most changes add or remove packages, services or files, either for all editions or for one. After each change, build and test it as described in [Build and test a change](#build-and-test-a-change).

## Packages

Packages are listed in `Packages=` of an `mkosi.conf` file, one per line and indented. A `#` starts a comment, also at the end of a line.

### Where a package belongs

The file depends on where the package is needed:

| The package is needed                                 | File                                                       |
| ----------------------------------------------------- | ---------------------------------------------------------- |
| everywhere, also in the distrobox container           | `mkosi.images/base/mkosi.conf`                             |
| on every booted system (kernel, firmware, disk tools) | `mkosi.images/root/mkosi.conf`                             |
| on every desktop edition                              | `mkosi.images/desktop/mkosi.conf`                          |
| on one edition                                        | `mkosi.images/desktop/mkosi.profiles/<edition>/mkosi.conf` |
| only in the live session (installer, rescue tools)    | `mkosi.images/live/mkosi.conf`                             |
| only in the live session of one edition               | `mkosi.images/live/mkosi.profiles/<edition>/mkosi.conf`    |
| only in the distrobox container                       | `mkosi.profiles/distrobox/mkosi.conf`                      |
| only on the Lima image                                | `mkosi.profiles/lima/mkosi.conf`                           |
| as an offline driver for the installer                | `MHWD_PACKAGES` in `mkosi.images/mhwd/mkosi.conf`          |

`<edition>` is the edition name, for example `mokka`.

Packages that garuda-tools marked `>extra` go to the `mkosi.conf.d/50-extra.conf` file of the layer instead. The _kde-lite_ edition leaves them out.

Packages in the `desktop` layer and below end up on the installed system. Packages in the `live` layer do not.

### Add a package for all editions

Add the package to `mkosi.images/desktop/mkosi.conf`, under the matching comment:

```ini
Packages=
        ...
        # Garuda specific
        garuda-toolbox
        garuda-new-tool
```

The change affects every ISO. Build one edition to check it. The continuous integration builds the others.

### Add a package to one edition

Add the package to `mkosi.images/desktop/mkosi.profiles/<edition>/mkosi.conf`:

```ini
[Content]
Packages=
        ...
        # Other apps
        mpv
        new-app
```

### Remove a package

Delete its line. If another package depends on it, it stays installed. The package manifest of the next build shows whether it is still there:

```console
$ grep --only-matching '"name": "<package>"' mkosi.output/garuda-<edition>-*.iso.manifest
```

where `<package>` is the package name.

### Change the kernel

The default kernel is `Environment=KERNEL=` in `mkosi.conf`. An edition with another kernel is listed in `EDITION_KERNEL` in `lib/iso.sh`. To use another kernel for one build only:

```console
# ./build.sh iso mokka -E KERNEL=linux-lts
```

## Services

Services are enabled or disabled with systemd preset files in the `usr/lib/systemd/system-preset/` directory of a layer's `mkosi.extra/`:

| Scope                                    | File                                                                                                                |
| ---------------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| every desktop edition                    | `mkosi.images/desktop/mkosi.extra/usr/lib/systemd/system-preset/80-garuda-desktop.preset`                           |
| one edition, also after the installation | `mkosi.images/desktop/mkosi.profiles/<edition>/mkosi.extra/.../70-garuda-<edition>.preset`                          |
| the live session of every edition        | `mkosi.images/live/mkosi.extra/.../60-garuda-live.preset` (enable), `50-garuda-live.preset` (disable)               |
| the live session of one edition          | `mkosi.images/live/mkosi.profiles/<edition>/mkosi.extra/.../50-garuda-<edition>-live.preset`, create it when needed |

Add a line such as `enable sshd.service` or `disable preload.service`. When two files name the same unit, the file with the lower number wins. See `systemd.preset(5)` for the format. The build stops when an enabled unit does not exist in the image, so a misspelt unit name shows up at once. It also stops when a file enables a unit that a file with a higher number disables, because that disable has no effect.

A package that enables a unit in its install script (`systemctl enable` in `post_install`) needs the same unit in a preset file. mkosi runs `systemctl preset-all` on every layer after the packages are installed, and the `disable *` line of Arch's `99-default.preset` turns off every unit that no preset file enables. The lists in `80-garuda-base.preset` and `80-garuda-desktop.preset` name the package each unit comes from.

## Files

A file under a `mkosi.extra/` directory is copied into the layer at the same path. For example, `mkosi.images/desktop/mkosi.extra/etc/vconsole.conf` becomes `/etc/vconsole.conf`.

| Scope                                    | Directory                                                    |
| ---------------------------------------- | ------------------------------------------------------------ |
| every system, also the container         | `mkosi.images/base/mkosi.extra/`                             |
| every desktop edition                    | `mkosi.images/desktop/mkosi.extra/`                          |
| one edition, also after the installation | `mkosi.images/desktop/mkosi.profiles/<edition>/mkosi.extra/` |
| the live session of every edition        | `mkosi.images/live/mkosi.extra/`                             |
| the live session of one edition          | `mkosi.images/live/mkosi.profiles/<edition>/mkosi.extra/`    |

Files for new users go to `etc/skel/`.

### Override a shared file in one edition

Put the edition's version at the same path in the edition's `mkosi.extra/`. mkosi copies the shared directory first and the edition's directory after it, so the edition's file replaces the shared one. For example, _dr460nized-gaming_ replaces the shared Calamares user settings with the following file:

```text
mkosi.images/live/mkosi.profiles/dr460nized-gaming/mkosi.extra/etc/calamares/modules/users.conf
```

The override replaces the whole file. Copy the shared file first and change only what differs.

### File owner and mode

mkosi copies files as root and keeps the mode from Git: `0644`, or `0755` for executables. For another owner or mode, add a `chown` or `chmod` command to the `mkosi.postinst.chroot` script of the layer, as done for `/var/lib/plasmalogin/.config` in the `desktop` layer.

## Local settings

To change a setting only on this machine, copy `mkosi.local.conf.example` to `mkosi.local.conf` and uncomment the settings you need:

```ini
[Build]
Environment=KERNEL=linux-lts
Incremental=no
```

Git ignores `mkosi.local.conf`. Options on the `build.sh` command line win over it.

## Build and test a change

1. Check the configuration of every output:

   ```console
   $ lint
   ```

2. Build the affected output. For a shared change, one edition is enough locally:

   ```console
   $ build iso mokka
   ```

   `build.sh` rebuilds only the layers the change or a package update affects and reuses the others, see [Building#Incremental builds](building.md#incremental-builds). To rebuild one layer and the layers above it, add `--rebuild-layer <layer>`. To rebuild every layer, add `--fresh`:

   ```console
   $ build --fresh iso mokka
   ```

3. Test the build, see [Testing](testing.md):

   ```console
   $ iso-test mokka
   ```

4. Commit the change. A push to the default branch builds every output the change affects, see [Continuous integration#Triggers](ci.md#triggers). To force a build, put a tag such as `[build mokka]` or `[build all]` in the commit message.

## See also

- [Editions](editions.md), to add a new edition
- [Installer](installer.md), to change the Calamares configuration
- [Building](building.md)
- `systemd.preset(5)`: [preset files](https://www.freedesktop.org/software/systemd/man/latest/systemd.preset.html)
