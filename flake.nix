{
  description = "Garuda Linux image-builder flake ❄️";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    pre-commit-hooks = {
      url = "github:cachix/pre-commit-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      ...
    }@inputs:
    let
      inherit (nixpkgs) lib;

      # The images, mkosi and the QEMU tests are x86_64 only
      systems = [ "x86_64-linux" ];

      forAllSystems =
        f:
        lib.genAttrs systems (
          system:
          let
            pkgs = import nixpkgs { inherit system; };
          in
          f (pkgs // { inherit system; })
        );

      mkPreCommitCheck =
        pkgs:
        inputs.pre-commit-hooks.lib.${pkgs.stdenv.hostPlatform.system}.run {
          package = pkgs.prek;
          hooks = {
            commitizen.enable = true;
            commit-scope = {
              enable = true;
              name = "Commit message scope";
              entry = "${pkgs.bash}/bin/bash scripts/commit-scope.sh";
              stages = [ "commit-msg" ];
              language = "system";
            };
            # The default files pattern only matches Dockerfile*
            hadolint = {
              enable = true;
              files = "(Dockerfile|Containerfile)$";
            };
            nixfmt.enable = true;
            scripts-formatting = {
              enable = true;
              name = "Shell scripts shfmt";
              # The same file list as scripts/lint.sh, including the scripts without .sh
              entry = "${pkgs.bash}/bin/bash scripts/shell-files.sh --exec ${pkgs.shfmt}/bin/shfmt -d -w";
              pass_filenames = false;
              language = "system";
            };
            prettier.enable = true;
            ruff.enable = true;
            ruff-format.enable = true;
          };
          src = ./.;
        };
    in
    {
      checks = forAllSystems (pkgs: {
        pre-commit-check = mkPreCommitCheck pkgs;
      });

      devShells = forAllSystems (
        {
          pkgs,
          system,
          ...
        }:
        let
          # Both run the file in the checkout, so that edits apply without reentering the shell
          tool =
            name:
            pkgs.writeShellScriptBin name ''exec ${pkgs.bash}/bin/bash "$(git rev-parse --show-toplevel)/scripts/${name}.sh" "$@"'';
          pytool =
            name: file:
            pkgs.writeShellScriptBin name ''exec ${pkgs.python3}/bin/python3 -I "$(git rev-parse --show-toplevel)/${file}" "$@"'';

          tools = [
            "boot-check"
            "build"
            "distrobox-test"
            "oci-test"
            "lima-test"
            "iso-test"
            "vm-test"
            "repro-check"
            "lint"
            "manifest-diff"
            "sbom"
            "nixfmt"
            "prek"
            "prettier"
            "ruff"
            "shellcheck"
            "shfmt"
            "yamllint"
          ];

          deps = [
            "e2fsprogs"
            "git"
            "hadolint"
            "jq"
            "libnotify"
            "lima"
            "mtools"
            "openssl"
            "mkosi"
            "qemu"
            "sbsigntool"
            "skopeo"
            "swtpm"
            "systemd"
            "virt-firmware"
          ];
        in
        {
          default = pkgs.mkShell {
            name = "image-builder-devshell";

            # podman and distrobox come from the host: rootless podman needs the
            # system's newuidmap wrappers.
            packages = with pkgs; [
              (tool "boot-check")
              (tool "build")
              (tool "distrobox-test")
              (tool "oci-test")
              (tool "lima-test")
              (tool "iso-test")
              (tool "vm-test")
              (tool "repro-check")
              (tool "lint")
              (pytool "manifest-diff" "scripts/manifest_diff.py")
              (pytool "sbom" "scripts/sbom.py")
              e2fsprogs # chattr for build virt
              git
              hadolint
              jq
              libnotify # notify-send for build --notify
              lima
              mtools
              mkosi
              nixfmt
              openssl # build verify
              prek
              prettier
              qemu
              sbsigntool # sbverify for build verify
              ruff
              shellcheck
              shfmt
              skopeo
              swtpm
              systemd
              python3Packages.virt-firmware
              yamllint
            ];

            shellHook = ''
              ${self.checks.${system}.pre-commit-check.shellHook}

              printf '\033[1;35mGaruda image-builder devshell\033[0m ❄️\n'
              printf '  \033[2mtools:\033[0m %s\n' "${lib.concatStringsSep " " tools}"
              printf '  \033[2mdeps: \033[0m %s\n' "${lib.concatStringsSep " " deps}"

              export LC_ALL="C.UTF-8"
              export NIX_PATH=nixpkgs=${nixpkgs}

              # fish (also through direnv) links completions/build.fish instead, see docs/building.md
              if [ -n "''${BASH_VERSION:-}" ]; then
                source "$(git rev-parse --show-toplevel)/completions/build.bash" 2>/dev/null || true
              fi

              if [ ! -f /etc/containers/policy.json ] && [ ! -f ~/.config/containers/policy.json ]; then
                echo "No podman policy.json found (skopeo and podman need one). To install the default:"
                echo "  install -Dm644 ${pkgs.skopeo.src}/default-policy.json ~/.config/containers/policy.json"
              fi
            '';
          };
        }
      );

      formatter = forAllSystems (pkgs: pkgs.nixfmt);
    };
}
