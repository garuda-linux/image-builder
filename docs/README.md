# image-builder documentation

These pages describe how to operate image-builder: build and test the Garuda images, maintain the editions and the installer, and run the continuous integration.

The commands assume the development shell, see [Building#Installation](building.md#installation). A prompt of `#` means root, `$` a regular user.

| Page                                  | Read it to                                                           |
| ------------------------------------- | -------------------------------------------------------------------- |
| [Common tasks](common-tasks.md)       | change packages, services and files, override per edition, build     |
| [Architecture](architecture.md)       | understand the layers, the outputs and how the live ISO boots        |
| [Building](building.md)               | build the distrobox image, the Lima image and the ISOs               |
| [Testing](testing.md)                 | check a build before it is published                                 |
| [Editions](editions.md)               | change an edition or add a new one                                   |
| [Installer](installer.md)             | change the Calamares configuration                                   |
| [Continuous integration](ci.md)       | run, trigger and set up the GitLab pipelines, publishing and signing |
| [Troubleshooting](troubleshooting.md) | solve known build and boot problems                                  |

## See also

- [image-builder README](../README.md)
- [mkosi documentation](https://github.com/systemd/mkosi/blob/main/mkosi/resources/man/mkosi.1.md)
