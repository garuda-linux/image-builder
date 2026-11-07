# Editions

An edition is an mkosi profile with the name of the edition. Its parts live in the layers they belong to, see [Architecture#Layers](architecture.md#layers). As of November 2026, the editions are _mokka_, _dr460nized_, _dr460nized-gaming_, _kde-lite_, _gnome_, _cinnamon_, _xfce_, _i3_, _sway_, _hyprland_ and the community edition _cosmic_.

## Configuration

The files of an edition and the iso-profiles entries they replace:

| File                                                                       | Content                                                                                         | iso-profiles source                  |
| -------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- | ------------------------------------ |
| `mkosi.images/desktop/mkosi.profiles/<edition>/mkosi.conf`                 | packages, `Environment=EDITION=<edition>`                                                       | `Packages-Desktop`                   |
| `mkosi.images/desktop/mkosi.profiles/<edition>/mkosi.extra/`               | files of the installed desktop                                                                  | `desktop-overlay`                    |
| `.../desktop/.../usr/lib/systemd/system-preset/70-garuda-<edition>.preset` | services and display manager                                                                    | `enable_systemd`, `displaymanager`   |
| `mkosi.images/live/mkosi.profiles/<edition>/mkosi.conf`                    | hostname, live user settings that differ from the shared ones in `mkosi.images/live/mkosi.conf` | `hostname`, `autologin`, `addgroups` |
| `mkosi.images/live/mkosi.profiles/<edition>/mkosi.extra/`                  | files of the live session only, Calamares overrides                                             | `live-overlay`                       |
| `mkosi.images/live/mkosi.extra/.../50-garuda-live.preset`                  | services disabled in every live session                                                         | `disable_systemd_live`               |

Files that several editions share live in a tree next to `mkosi.extra/`, added by a drop-in in `mkosi.conf.d/` with one `Profiles=|<edition>` line per edition:

| Tree                                          | Drop-in                                                            | Editions                                                              |
| --------------------------------------------- | ------------------------------------------------------------------ | --------------------------------------------------------------------- |
| `mkosi.images/desktop/mkosi.extra.lightdm`    | `mkosi.images/desktop/mkosi.conf.d/50-lightdm.conf`                | cinnamon, i3, xfce: LightDM settings in `lightdm.conf.d`              |
| `mkosi.images/desktop/mkosi.extra.dr460nized` | `mkosi.images/desktop/mkosi.conf.d/50-dr460nized-plasmalogin.conf` | dr460nized, dr460nized-gaming: plasmalogin theme                      |
| `mkosi.images/live/mkosi.extra.plasma`        | `mkosi.images/live/mkosi.conf.d/50-plasma-live.conf`               | dr460nized, dr460nized-gaming, kde-lite, mokka: live session settings |

The edition's own `mkosi.extra/` is copied after the shared tree, so it can override a shared file.

`<edition>` is the edition name. Files in the desktop part end up on the installed system. Files in the live part exist only in the live session.

## Change an edition

The usual changes and where they go:

| Change           | Where                                                                                            |
| ---------------- | ------------------------------------------------------------------------------------------------ |
| packages         | `Packages=` in the desktop `mkosi.conf`                                                          |
| services         | the preset files, one `enable <unit>` or `disable <unit>` line per unit                          |
| files            | the `mkosi.extra/` directory of the desktop or live part, at their path                          |
| live user groups | `LIVE_GROUPS` in the live `mkosi.conf` of the edition, default in `mkosi.images/live/mkosi.conf` |
| installer        | see [Installer](installer.md)                                                                    |

mkosi applies the presets when it builds the layer, so they also apply on the installed system. mkosi copies files as root. If a file must belong to another user, change the owner in `mkosi.images/desktop/mkosi.postinst.chroot`, as done for `/var/lib/plasmalogin/.config`. [Common tasks](common-tasks.md) shows each change in detail.

Rebuild and test the edition:

```console
$ build iso <edition>
$ iso-test <edition>
```

## Add an edition

1. Create both profile directories. Copy an edition with the same desktop as a start:

   ```console
   $ cp --recursive mkosi.images/desktop/mkosi.profiles/mokka \
       mkosi.images/desktop/mkosi.profiles/<edition>
   $ cp --recursive mkosi.images/live/mkosi.profiles/mokka \
       mkosi.images/live/mkosi.profiles/<edition>
   ```

   where `<edition>` is the name of the new edition.

2. Rename the desktop preset file after the edition and adjust its services. The display manager unit must be enabled in the desktop preset, otherwise the system boots without a login screen.
3. Set `EDITION=` and the packages in the desktop `mkosi.conf`, and `Hostname=` in the live `mkosi.conf`. Set `LIVE_*` values there only where the edition differs from the shared ones. If the edition uses a shared tree, add a `Profiles=|<edition>` line to its drop-in.
4. If the users of the edition need other groups than the shared `users.conf` gives them, add `mkosi.extra/etc/calamares/modules/users.conf` to the live part.
5. If the edition needs another kernel, add it to `EDITION_KERNEL` in `lib/iso.sh`.
6. Check the configuration, then build and test the edition:

   ```console
   $ lint
   $ build iso <edition>
   $ iso-test <edition>
   ```

No other file lists the editions. `scripts/editions.sh` reads them from the directories in `mkosi.images/desktop/mkosi.profiles/`, and `lint` and the continuous integration take the list from there, see [Continuous integration#Jobs](ci.md#jobs). The build stops when an enabled unit in the preset files does not exist, for example a misspelt display manager unit.

## Variants

### Without the extra packages

garuda-tools left out the packages marked `>extra` for `extra=false`. Here, they are in the `50-extra.conf` files of the `base`, `root`, `desktop` and `mhwd` layers, which match `Profiles=!kde-lite`. To leave them out for another edition, add it to these matches.

### Another kernel

`build.sh` passes `-E KERNEL=<kernel>` for the editions in `EDITION_KERNEL`, for example `linux-lts` for _xfce_, unless the build command sets `-E KERNEL=` itself.

## See also

- [Architecture](architecture.md)
- [Common tasks](common-tasks.md)
- [Installer](installer.md)
- `systemd.preset(5)`: [preset files](https://www.freedesktop.org/software/systemd/man/latest/systemd.preset.html)
