# image-builder

image-builder builds Garuda Linux images with [mkosi](https://github.com/systemd/mkosi): a distrobox container image, a disk image for Lima VM tests, and the edition live ISOs that garuda-tools _buildiso_ built before. It keeps the [iso-profiles](https://gitlab.com/garuda-linux/tools/iso-profiles) model of shared packages and files plus edition-specific parts, as mkosi layers and profiles.

## Installation

The repository has a Nix development shell with the build and test commands. Enter it with `nix develop`, or allow the `.envrc` file with [direnv](https://direnv.net/). See [Building#Installation](docs/building.md#installation) for building without Nix.

## Usage

In the development shell, build and test an image:

```console
$ build distrobox
$ distrobox-test
$ build iso mokka
$ iso-test mokka
```

`build` runs `build.sh` as root in the builder container from `ci/Containerfile`. On an Arch-based host with mkosi 27 or later, `build.sh` also runs directly:

```console
# ./build.sh lima
```

The results are in the `mkosi.output/` directory.

## Documentation

The pages in `docs/` describe how to operate image-builder:

| Page                                       | Content                                                   |
| ------------------------------------------ | --------------------------------------------------------- |
| [Common tasks](docs/common-tasks.md)       | change packages, services and files, override per edition |
| [Architecture](docs/architecture.md)       | layers, outputs, live ISO boot, pacman keyring            |
| [Building](docs/building.md)               | build options, incremental builds, local settings         |
| [Testing](docs/testing.md)                 | boot check, distrobox, Lima and ISO tests                 |
| [Editions](docs/editions.md)               | edition files, adding an edition                          |
| [Installer](docs/installer.md)             | Calamares configuration                                   |
| [Continuous integration](docs/ci.md)       | jobs, triggers, publishing, signing, project setup        |
| [Troubleshooting](docs/troubleshooting.md) | known problems and their solutions                        |

## See also

- [mkosi documentation](https://github.com/systemd/mkosi/blob/main/mkosi/resources/man/mkosi.1.md)
- [KDE Linux](https://invent.kde.org/kde-linux/kde-linux), the reference for the mkosi layout
- [archiso](https://gitlab.archlinux.org/archlinux/archiso), the reference for the hybrid ISO
- [nspawn/mkosi-definitions](https://github.com/nspawn/mkosi-definitions), the source of the boot check, keyring, manifest and signing approach
- [garuda-tools](https://gitlab.com/garuda-linux/tools/garuda-tools)
