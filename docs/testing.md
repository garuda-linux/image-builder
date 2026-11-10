# Testing

Each output has a test command in the development shell. The continuous integration runs `boot-check` before it publishes an image. The other tests are run by hand after a change.

The tests per output:

| Output              | Test                                | Checks                                                                                                |
| ------------------- | ----------------------------------- | ----------------------------------------------------------------------------------------------------- |
| any                 | `lint`                              | pre-commit hooks, _shellcheck_, _shfmt_, _ruff_, _yamllint_, mkosi config of every output and edition |
| distrobox           | `boot-check`, `distrobox-test`      | boot, box creation, Garuda packages, sudo, systemd, keyring                                           |
| Lima                | `boot-check` on `root`, `lima-test` | boot, SSH, btrfs layout, systemd-boot and UKI, keyring, pacman                                        |
| ISO                 | `iso-test`                          | boot with UEFI from USB or CD, live desktop, installation, installed system                           |
| VM image            | `vm-test`                           | boot with UEFI as in virt-manager, first login with password change, desktop                          |
| ISO, UKI, distrobox | `repro-check`                       | two fresh builds give the same bytes                                                                  |

## Configuration check

`lint` runs the pre-commit hooks, _shellcheck_ and _shfmt_ on all shell scripts, _ruff_ on the Python scripts, _yamllint_ on the YAML files, and `mkosi summary` for every output and every edition. The mkosi check parses the configuration without building anything. The continuous integration runs `lint` before every build. To check the configuration of one edition only:

```console
$ mkosi --profile iso --profile <edition> \
    --environment=GARUDA_BUILD_BASE=1 --environment=GARUDA_BUILD_ROOT=1 \
    --environment=GARUDA_BUILD_DESKTOP=1 --environment=GARUDA_BUILD_LIVE=1 \
    --environment=GARUDA_BUILD_MHWD=1 --environment=GARUDA_BUILD_LIVE_INITRD=1 \
    summary >/dev/null
```

where `<edition>` is the edition name, for example `dr460nized`. The `GARUDA_BUILD_<LAYER>` variables select the layers, as `build.sh` does, see [Building](building.md). Without them, the summary shows no layers. The command prints nothing on success.

## Boot check

`boot-check` boots an OCI image directory or a layer tree with _systemd-nspawn_. It passes when:

- systemd reaches the `running` state with no failed unit,
- systemd answers on D-Bus,
- the image ships no machine ID and no pacman keyring.

```console
$ boot-check mkosi.output/garuda-distrobox
$ boot-check mkosi.output/root
```

The script runs itself with _sudo_. A layer tree is booted with `--volatile=overlay` and stays unchanged. The check needs no systemd on the host, so it also runs in the container of the continuous integration: a check unit inside the machine writes the result to a directory shared with the host, then powers the machine off.

The `desktop` and `live` trees are not boot-checked. Display managers and the hardware detection fail in a container, so these trees would never reach `running`. Test them with `iso-test`.

## distrobox

`distrobox-test` copies the image into podman, creates a box called `garuda-test` with `--init`, and checks it:

```console
$ distrobox-test
```

The first start of the box shows the output of the distrobox setup, where most problems appear. On failure, the last lines of the container log follow.

## Lima

`lima-test` starts a Lima VM from `mkosi.output/garuda-lima.qcow2` and checks SSH, the `@` subvolume, that _systemd-boot_ booted the kernel from a UKI, the pacman keyring that `pacman-init.service` made on the first boot, and a repository sync with _pacman_:

```console
$ lima-test
```

`--keep` leaves the VM running for a closer look with `limactl shell <instance>`, where `<instance>` is the VM name that `lima-test` prints.

The VM template `lima/garuda.yaml` has `images: []` and does not pass `limactl validate` on its own. `lima-test` fills in the image with `--set`. To start a VM by hand, give the image the same way:

```console
$ limactl start --name=garuda \
    --set ".images = [{\"location\": \"$PWD/mkosi.output/garuda-lima.qcow2\", \"arch\": \"x86_64\"}]" \
    lima/garuda.yaml
```

## Live ISO

`iso-test` boots an ISO in QEMU with UEFI, attached as a USB stick, in a window. The serial console goes to `mkosi.cache/qemu/iso-serial.log`. `build.sh` makes that directory for the owner of the checkout, because `mkosi.cache` belongs to root and the test tools run as the user. Without an argument, it boots the _mokka_ edition:

```console
$ iso-test dr460nized
```

The ISO boots in two ways, both with UEFI: as a USB stick, the default, and as a CD drive with `--cdrom`. The firmware finds the same ESP as GPT partition 1 or through the El Torito boot catalog. On a CD drive, the initrd reads the partitions through a loop device:

```console
$ iso-test --cdrom
```

To test an installation, add a disk, install with Calamares, then boot the installed system without the ISO:

```console
$ iso-test --disk
$ iso-test --boot-disk
```

The disk is `mkosi.cache/qemu/iso-test-disk.qcow2` (30 GB). Delete it to start from an empty disk.

The VM has 6 GB of RAM. The `copytoram=y` boot option only copies the layer files when they fit with 2 GiB to spare, otherwise it boots from the medium. To test it with a `fast` build, give the VM more RAM:

```console
$ iso-test --ram=12G
```

Check on the live system:

- The desktop starts and the live user is logged in.
- Calamares starts. Its log is in `~/.cache/calamares/session.log`.
- On Plasma editions, `/var/lib/plasmalogin/.config` belongs to the `plasmalogin` user.

Check on the installed system:

- systemd-boot, the display manager and the desktop start.
- _pacman_ works, which needs the keyring that Calamares made.
- `/usr/lib/garuda/garuda-release` names the right edition.

## VM image

`vm-test` boots the VM image of an edition, `mkosi.output/garuda-vm-<edition>.qcow2`, in a QEMU window with UEFI and virtio graphics, as virt-manager does. Without an argument, it boots mokka:

```console
$ vm-test dr460nized
```

The VM writes to an overlay, `mkosi.cache/qemu/vm-test-<edition>.qcow2`, on top of the built image, so the image stays unchanged and every run starts like a fresh download. `--keep` boots the overlay of the last run again, for example to check a system after its first login. The serial console goes to `mkosi.cache/qemu/vm-serial.log`.

Check on the first boot:

- systemd-boot starts the UKI, the display manager shows the login screen.
- The login as `garuda` with the password `garuda` starts the desktop, and a notification asks to change the password. It shows once: the next login has none.
- `df -h /` shows about 40 GB: _systemd-repart_ grew the root partition to the disk.
- _pacman_ works, with the keyring that `pacman-init.service` made.
- `/usr/lib/garuda/garuda-release` names the edition, `hostnamectl` shows `garuda-<edition>`.

## openQA

The [openQA](https://open.qa) tests live in their own repository, _os-autoinst-distri-garuda_, and run with `isotovideo` alone, in CI or locally with its `run-local.sh`. In one job, they test the live ISO (the _systemd-boot_ menu, the boot into the live session and checks inside it), an unattended installation with Calamares on an empty 40 GB disk, and the installed system after a reboot from the disk. For the installation, the test turns the Calamares configuration of the ISO into an unattended one, see the README of the test repository.

The live ISO has an openQA mode for them. `garuda.openqa` on the kernel command line, which the test types into the _systemd-boot_ editor, starts `garuda-openqa.service`:

- a root shell runs on the virtio console `hvc0`, the `root-virtio-terminal` of os-autoinst, with the plain prompt `# ` and 2048 columns, so the test sends commands over that port and reads their output and exit status there, at once and independent of the keyboard layout. root is also logged in on tty2, for tests that need the screen,
- `garuda-openqa: ready (<state>)` goes to the serial port once the boot is done, where `<state>` is the state of systemd.

The _systemd-boot_ menu itself needs no openQA mode: OVMF mirrors the firmware console to the serial port, where the test finds the menu entries. A normal boot never starts the service. For CI, see [Continuous integration#openQA](ci.md#openqa). To create needles, `webui-local.sh` of the test repository runs the tests in a local openQA web UI with its needle editor.

## Package changes

`manifest-diff` compares the package manifests of two builds and lists the added, removed and updated packages:

```console
$ manifest-diff mkosi.output/garuda-distrobox.manifest mkosi.output/garuda-lima.manifest
...
removed  btrfsmaintenance 0.5.2-3
added    cloud-init 26.2-1
...
```

Compare a manifest with the one of an earlier build to see what changed between them. The continuous integration writes this list for every build as the `.manifest.changes` artifact, see [Continuous integration#Jobs](ci.md#jobs).

## Reproducibility

`repro-check` builds the ISO of an edition, the generic UKIs and the distrobox image twice, each with `--fresh`, and compares the results. Without an argument, it builds _mokka_:

```console
$ repro-check dr460nized
```

Both runs use the same `VERSION` and `SOURCE_DATE_EPOCH`, see [Building#Reproducible builds](building.md#reproducible-builds). The second run passes `--cache-only=metadata` to mkosi, so it installs from the repository metadata of the first run, and a package update in between does not show up as a difference. The script compares by sha256:

- the erofs images, verity hash trees and root hashes of the `root`, `desktop`, `mhwd` and `live` layers
- the ISO
- the rescue and Easy Anti-Cheat UKIs
- every file of the distrobox OCI layout

The copies of both runs stay in `mkosi.cache/repro/a/` and `mkosi.cache/repro/b/`. For each file that differs, `repro-check` writes a [diffoscope](https://diffoscope.org/) report to `mkosi.cache/repro/diffoscope/` when _diffoscope_ is installed. The development shell does not include it, because of its size. To compare one file by hand:

```console
$ nix run nixpkgs#diffoscope -- mkosi.cache/repro/a/<file> mkosi.cache/repro/b/<file>
```

where `<file>` is a path from the list of differing files.

> [!NOTE]
> Six fresh builds take several hours. With `ISO_COMPRESSION=max`, the two ISO builds take longer still.

## See also

- [Building](building.md)
- [Troubleshooting](troubleshooting.md)
- `systemd-nspawn(1)`: [systemd-nspawn manual](https://www.freedesktop.org/software/systemd/man/latest/systemd-nspawn.html)
