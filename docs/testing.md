# Testing

Each output has a test command in the development shell. The continuous integration runs `boot-check` before it publishes an image. The other tests are run by hand after a change.

The tests per output:

| Output    | Test                                | Checks                                                                                                |
| --------- | ----------------------------------- | ----------------------------------------------------------------------------------------------------- |
| any       | `lint`                              | pre-commit hooks, _shellcheck_, _shfmt_, _ruff_, _yamllint_, mkosi config of every output and edition |
| distrobox | `boot-check`, `distrobox-test`      | boot, box creation, Garuda packages, sudo, systemd, keyring                                           |
| Lima      | `boot-check` on `root`, `lima-test` | boot, SSH, btrfs layout, systemd-boot and UKI, keyring, pacman                                        |
| ISO       | `iso-test`                          | boot with UEFI from USB or CD, live desktop, installation, installed system                           |

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

`iso-test` boots an ISO in QEMU with UEFI, attached as a USB stick, in a window. The serial console goes to `~/.cache/image-builder/iso-serial.log`. Without an argument, it boots the _mokka_ edition:

```console
$ iso-test dr460nized
```

The ISO boots in two ways, both with UEFI: as a USB stick, the default, and as a CD drive with `--cdrom`. The firmware finds the same ESP image as GPT partition 2 or as the El Torito EFI image:

```console
$ iso-test --cdrom
```

To test an installation, add a disk, install with Calamares, then boot the installed system without the ISO:

```console
$ iso-test --disk
$ iso-test --boot-disk
```

The disk is `~/.cache/image-builder/iso-test-disk.qcow2` (30 GB). Delete it to start from an empty disk.

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

## See also

- [Building](building.md)
- [Troubleshooting](troubleshooting.md)
- `systemd-nspawn(1)`: [systemd-nspawn manual](https://www.freedesktop.org/software/systemd/man/latest/systemd-nspawn.html)
