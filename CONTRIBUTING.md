# Contributing

Changes come in as merge requests against the default branch of [image-builder](https://gitlab.com/garuda-linux/tools/image-builder). For security issues, see [SECURITY.md](SECURITY.md).

## Development shell

The repository has a Nix development shell with the build, test and lint commands, see [Building#Installation](docs/building.md#installation). Enter it with `nix develop`, or allow the `.envrc` file with [direnv](https://direnv.net/). The shell installs the pre-commit hooks of `flake.nix`, so they run on every commit.

## Checks

Run the checks before opening a merge request:

```console
$ lint
```

`lint` runs the pre-commit hooks, _shellcheck_, _shfmt_, _ruff_, _yamllint_, _hadolint_ and a mkosi check of every output and edition. CI runs the same checks in the `lint` and `flake-check` jobs, and a failing check stops the pipeline before any build starts, see [CI](docs/ci.md).

> [!NOTE]
> Merge request branches are not protected, so their pipelines lint only and build no images. Test an image change locally, see [Testing](docs/testing.md).

## Commit messages

Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/). The _commitizen_ hook checks them, configured in `.cz.yaml`:

```
<type>(<scope>): <summary>
```

where `<type>` is for example `feat`, `fix`, `docs`, `ci` or `style`. Keep the body to one line, or leave it out.

The scope is required and comes from this list, several are separated by commas, for example `fix(iso,lima): ...`:

| Kind    | Scopes                                                                                     |
| ------- | ------------------------------------------------------------------------------------------ |
| output  | `distrobox`, `lima`, `vm`, `uki`, `iso`                                                    |
| edition | each edition of `scripts/editions.sh`, for example `mokka` or `gnome`                      |
| layer   | `layers` for several layers, or `base`, `root`, `desktop`, `live`, `mhwd`, `live-initrd`   |
| area    | `build`, `secureboot`, `container`, `installer`, `openqa`, `scripts`, `ci`, `docs`, `deps` |

`scripts/commit-scope.sh` checks it as a commit-msg hook of the development shell and again for the pushed commits in the `lint` job. Exempt are `ci: ...` for changes to the pipeline as a whole, `bump: ...` of `cz bump`, `Merge ...` and `Revert "..."`.
