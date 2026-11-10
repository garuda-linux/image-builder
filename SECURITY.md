# Security policy

image-builder builds and signs the Garuda Linux images: the live ISOs with their Secure Boot chain, the generic UKIs, the distrobox image and the Lima and VM disk images. A flaw in the build, the signing or the CI pipeline can reach every machine that boots them.

## Reporting a vulnerability

Send reports to `team@garudalinux.org`. Do **not** open a public issue or merge request for a vulnerability.

Include:

- the affected image, file or CI job, and the commit or image version
- the steps that reproduce the problem
- what an attacker gains, for example code execution in the build, a boot chain that accepts unsigned code, or a published image that differs from its source

## Scope

In scope:

- the Secure Boot chain of the ISO and the generic UKIs: _shim_, _systemd-boot_, the UKIs and their signed command lines, see [Architecture#Secure Boot](docs/architecture.md#secure-boot)
- the dm-verity protection of the live layers
- the CI pipeline: the jobs that run as root on the build host, the signing and publishing jobs, see [CI](docs/ci.md)
- pinned downloads and their hashes, for example _shim_ in `lib/secureboot.sh`

Packages inside the images come from Arch Linux, Chaotic-AUR and the Garuda repository. Report flaws in a package to the project that ships it.
