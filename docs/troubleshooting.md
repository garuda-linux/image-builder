# Troubleshooting

The problems below come from mkosi defaults, the UEFI-only boot of the ISO, the Calamares files that garuda-tools used to generate, and the pacman keyring that the images do not ship.

## Build

### Package updates do not arrive

`build.sh` reuses every layer whose inputs did not change, with the packages it was built with. Build with `--fresh` to rebuild every layer and install all packages again, see [Building#Incremental builds](building.md#incremental-builds).

### A reused layer looks stale

The stamps cover the repository files, but not everything outside them, for example a package that changed on the mirror under the same version. Build with `--fresh`, or delete the output of the layer in `mkosi.output/` to rebuild it and every layer above it.

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

The written ISO cannot hold the erofs layer files, so the write failed without an error. Check the output of _xorriso_ in the build log.

### A file from mkosi.extra belongs to root

mkosi copies `mkosi.extra/` as root. Change the owner in the `mkosi.postinst.chroot` script of the layer, as done for `/var/lib/plasmalogin/.config` in the `desktop` layer.

## Live ISO

Test each boot path with `iso-test`, see [Testing#Live ISO](testing.md#live-iso). The serial log of the boot is in `~/.cache/image-builder/iso-serial.log`.

### The boot stops in emergency mode

The initrd failed to mount the layers. Press `Enter` for a root shell. The live initrd opens it without a password (`SYSTEMD_SULOGIN_FORCE=1`). Then read the log of the layer setup:

```console
# journalctl -b -u garuda-live-mount.service
```

### The ISO does not appear as a boot device or shows no menu

The ISO boots _systemd-boot_ with UEFI only.

- The machine boots in legacy BIOS mode, or with the compatibility support module (CSM): switch the firmware to UEFI. Machines without UEFI cannot boot the ISO.
- Secure Boot is on: _systemd-boot_ on the ISO is not signed, so the firmware refuses it. Turn Secure Boot off in the firmware settings.
- The firmware lists the stick but drops back to its own menu: check the ESP of the ISO. `mdir -/ -i <file> ::/`, where `<file>` is the ESP image extracted from GPT partition 2 or `efiboot.img` in the build directory, must list `EFI/BOOT/BOOTX64.EFI`, `loader/entries/` and `garuda/`.

In the menu, `e` edits the options of an entry, for example to add `copytoram`, see [Architecture#Boot options](architecture.md#boot-options).

### The live system does not find its layers

The initrd mounts the ISO by the label given in `garuda.label=` on the kernel command line, then the layer files from it. Check the serial log for the failing `run-garuda-iso.mount` unit or the output of `garuda-live-mount.service`. The label on the command line must match the volume label of the ISO, which `blkid` shows.

### Boot stops with "one or more layer files are damaged"

The `checksum=y` check found a layer file that does not match `SHA256SUMS`. The medium is damaged or was written incompletely. Write the ISO again, preferably after checking the `.sha256` file of the ISO, or use another USB stick.

### Boot stops with "SHA256SUMS does not match garuda.sums="

`/garuda-live/layers/SHA256SUMS` on the medium is not the one the boot entry was written for: the layer files or the list were replaced, or the medium is damaged. Write the ISO again from a download whose `.sha256` file matches. A boot entry edited by hand needs the `garuda.sums=` value of the same build.

### Changes are lost although persistence was set

The boot log of `garuda-live-mount.service` says why, in one of these messages:

- "persistence needs a USB stick or disk": the ISO was booted from a CD drive. Create an ext4 partition labelled `GARUDA_PERSIST` on another disk and boot with `persistence=any`.
- "is not the boot stick of": the initrd did not change the disk, because its volume label is not the label of this ISO.
- "less than 1 GiB free": the USB stick is too small for the ISO and a persistence partition.
- "could not mount": the partition `GARUDA_PERSIST` exists but does not mount as ext4. Check it with `fsck.ext4` from another system. The session runs from RAM meanwhile.
- "already holds a file system, not formatting it": a partition named `GARUDA_PERSIST` was found without the ext4 label. Format it by hand with `mkfs.ext4 -L GARUDA_PERSIST`.
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
