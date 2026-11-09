# Troubleshooting

The problems below come from mkosi defaults, the UEFI-only boot of the ISO, the Calamares files that garuda-tools used to generate, and the pacman keyring that the images do not ship.

## Build

### Package updates do not arrive

`build.sh` rebuilds every layer with a newer package version in the repositories, see [Building#Package updates](building.md#package-updates). Check the build log for `Rebuilding the <layer> layer`. If the layer was reused, the mirror may not have the update yet. The package versions in the result are in the manifest:

```console
$ jq -r '.packages[] | select(.name == "calamares-garuda") | .version' mkosi.output/garuda-mokka.iso.manifest
```

### A reused layer looks stale

The check sees versions only, not a package rebuilt under the same version, and not the driver packages in the local repository of the `mhwd` layer. Rebuild the layer and the layers above it with `--rebuild-layer <layer>`, or every layer with `--fresh`.

### The build fails on NixOS with missing tools or keyring errors

mkosi cannot use the NixOS host tools. Build in the builder container with `--container`, see [Building#Builder container](building.md#builder-container).

### The kernel value is refused

The build stops when `KERNEL` has no matching `mkosi.images/root/mkosi.conf.d/kernel-<kernel>.conf` file, where `<kernel>` is the kernel package name. Use a supported kernel or add a file for the new one.

### The build stops with "units enabled in presets but missing"

A preset file of this repository enables a unit that no package in the image ships. The message names the unit and the preset file. Either the unit name is wrong, or the package that ships it is missing from the layer. Check the name in the package's file list, then fix the preset or add the package.

### The build stops with "no valid signature by" for chaotic-keyring

`build.sh` checks the downloaded chaotic keyring and mirrorlist against the key `CHAOTIC_KEY` in `lib/chaotic.sh`. The message shows what _gpg_ found:

- `VALIDSIG` with another fingerprint: the packages are signed by another key. Compare it with the key on the [chaotic-aur](https://aur.chaotic.cx/) website before you change `CHAOTIC_KEY`.
- `BADSIG` or `ERRSIG`: the download is damaged or was changed. Download it again with `--refresh-keys`.

A message "could not import the chaotic signing key" means that `ci/chaotic-key.asc` is missing or damaged. A message "no valid signature" after a key rotation by chaotic-aur means that the vendored key and `CHAOTIC_KEY` need an update: export the new key from the `chaotic-keyring` package and check its fingerprint against the chaotic-aur instructions.

### Arch packages fail their signature check with "unknown trust"

The _archlinux-keyring_ of the tools tree is older than the key that signed the package. Bump `ToolsTreeSnapshot=` in `mkosi.conf` to a recent date, see [Building#Tools tree](building.md#tools-tree).

### A post-build step fails inside mkosi sandbox

`build.sh` runs its steps after mkosi in the tools tree through `mkosi sandbox`. A missing command means a package is missing in `ToolsTreePackages=` of `mkosi.conf`. If a loop device or mount fails there, run the steps without the sandbox to compare: `./build.sh --post <output> <edition>` uses the host tools, where `<output>` is the output and `<edition>` the edition, as in the build command.

### Packages from chaotic-aur fail their signature check during installation

The chaotic keyring in `mkosi.sandbox/` is outdated. Download it again:

```console
# ./build.sh --refresh-keys iso mokka
```

### The ISO build stops with "smaller than its layers"

The written ISO cannot hold the erofs layer images and their hash trees, so the write failed without an error. Check `iso-work/repart.log` of the build directory, which holds the output of _systemd-repart_.

### A file from mkosi.extra belongs to root

mkosi copies `mkosi.extra/` as root. Change the owner in the `mkosi.postinst.chroot` script of the layer, as done for `/var/lib/plasmalogin/.config` in the `desktop` layer.

## Live ISO

Test each boot path with `iso-test`, see [Testing#Live ISO](testing.md#live-iso). The serial log of the boot is in `mkosi.cache/qemu/iso-serial.log`.

### The boot stops in emergency mode

The initrd failed to mount the layers. Press `Enter` for a root shell. The live initrd opens it without a password (`SYSTEMD_SULOGIN_FORCE=1`). Then read the log of the layer setup:

```console
# journalctl -b -u garuda-live-mount.service
```

### The ISO does not appear as a boot device or shows no menu

The ISO boots _systemd-boot_ with UEFI only.

- The machine boots in legacy BIOS mode, or with the compatibility support module (CSM): switch the firmware to UEFI. Machines without UEFI cannot boot the ISO.
- Secure Boot is on: _systemd-boot_ on the ISO is not signed, so the firmware refuses it. Turn Secure Boot off in the firmware settings.
- The firmware lists the stick but drops back to its own menu: check the ESP of the ISO. `mdir -/ -i <file> ::/`, where `<file>` is the ESP image extracted from GPT partition 1 or `efiboot.img` in the build directory, must list `EFI/BOOT/BOOTX64.EFI`, `EFI/Linux/garuda.efi` and `loader/loader.conf`, and for a signed ISO also `EFI/BOOT/grubx64.efi` and `EFI/BOOT/mmx64.efi`. With Secure Boot on and the Garuda cert not enrolled, _MokManager_ starts instead, see [Architecture#Secure Boot](architecture.md#secure-boot).

In the menu, `e` edits the options of an entry, for example to add `copytoram`, see [Architecture#Boot options](architecture.md#boot-options).

### The live system does not find its layers

The initrd finds the boot disk by the label given in `garuda.label=` on the kernel command line, then the partitions `garuda-<layer>` and `garuda-<layer>-verity` on it. Check the output of `garuda-live-mount.service` in the serial log:

- "no medium with the label": the label on the command line must match the volume label of the ISO, which `blkid` shows for the whole disk, for example `/dev/sdb`, not a partition.
- "the layer partitions are missing": `lsblk -o NAME,PARTLABEL` on the disk must list the layer partitions. On a CD drive, they appear on the loop device of `systemd-loop@.service`: `journalctl -b -u "systemd-loop@*"` shows why it failed, for example a `systemd-dissect` message about the partitions of the image.

### Boot stops with "the layer is damaged"

The `checksum=y` check of the copytoram entries and the "verify the medium" entry found a block of a layer that does not match its dm-verity hash tree. The medium is damaged or was written incompletely. Write the ISO again, preferably after checking the `.sha256` file of the ISO, or use another USB stick.

### Boot stops with "does not match garuda.verity="

A layer on the medium is not the one the boot entry was written for: the layer was replaced, or its hash tree is damaged. Write the ISO again from a download whose `.sha256` file matches. A boot entry edited by hand needs the `garuda.verity=` value of the same build. "has no root hash for" means the value lacks a layer.

With the normal and persistence entries, which have no `checksum`, a damaged block shows up later as an I/O error in the live session, because dm-verity refuses to return it.

### Changes are lost although persistence was set

The boot log of `garuda-live-mount.service` says why, in one of these messages:

- "persistence needs a USB stick or disk": the ISO was booted from a CD drive. Create an ext4 partition labelled `GARUDA_PERSIST` on another disk and boot with `persistence=any`.
- "is not the boot stick of": the initrd did not change the disk, because its volume label is not the label of this ISO.
- "could not add the partition": _systemd-repart_ failed, most often because the USB stick has less than 1 GiB free behind the ISO. Its error is in the lines before.
- "could not mount": the partition `GARUDA_PERSIST` exists but does not mount as ext4. Check it with `fsck.ext4` from another system. The session runs from RAM meanwhile.
- "no persistence partition": no partition labelled `GARUDA_PERSIST` on the boot stick. A partition on another disk needs `persistence=any`.

Each ISO version has its own directory on the partition, so after an update the session starts clean. The older directories stay on the partition.

### Calamares does not start

Start it from a terminal with debug output to see the error:

```console
# calamares -d
```

- An error about `settings.conf` or a module file means that a file in `etc/calamares/` is missing or not valid YAML, see [Installer](installer.md).
- `invalid node` in `branding.desc` means that the file is the empty placeholder from the _calamares-branding-garuda_ package. The live layer must ship the complete file.

### An installation failed

After the installation, the installed system keeps the installer log as `/var/log/Calamares-install.log`, readable by root. The _preservefiles_ job writes it at the end, so an installation that stopped earlier leaves no copy: start `calamares -d` from a terminal to see the log while it runs.

## distrobox

### The box fails on its first start

_distrobox-init_ runs _pacman_ as root on the first start, before systemd and before any login. The image ships no pacman keyring, so the box needs the pre-init hook to make one:

```console
$ distrobox create --image <image> --name garuda --init \
    --pre-init-hooks "pacman-key --init && pacman-key --populate"
```

where `<image>` is `registry.gitlab.com/garuda-linux/tools/image-builder/garuda-distrobox:latest` or a local copy. If the box still fails, `podman logs garuda` shows the output of the distrobox setup.

### The box does not start in the current directory

podman cannot enter a host directory it has no access to, for example on another mount. Enter the box with `distrobox enter --no-workdir garuda`.

## Known issues

- As of November 2026, the editions other than _mokka_ have not been built and booted.
- The ISO is not published yet, see [Continuous integration#Known issues](ci.md#known-issues).

## See also

- [Building](building.md)
- [Testing](testing.md)
- [Installer](installer.md)
