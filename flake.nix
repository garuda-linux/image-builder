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
            "lima-test"
            "iso-test"
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
            "git"
            "lima"
            "mkosi"
            "qemu"
            "skopeo"
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
              (tool "lima-test")
              (tool "iso-test")
              (tool "lint")
              (pytool "manifest-diff" "scripts/manifest_diff.py")
              (pytool "sbom" "scripts/sbom.py")
              git
              lima
              mkosi
              nixfmt
              prek
              prettier
              qemu
              ruff
              shellcheck
              shfmt
              skopeo
              yamllint
            ];

            shellHook = ''
              ${self.checks.${system}.pre-commit-check.shellHook}

              printf '\033[1;35mGaruda image-builder devshell\033[0m ❄️\n'
              printf '  \033[2mtools:\033[0m %s\n' "${lib.concatStringsSep " " tools}"
              printf '  \033[2mdeps: \033[0m %s\n' "${lib.concatStringsSep " " deps}"

              export LC_ALL="C.UTF-8"
              export NIX_PATH=nixpkgs=${nixpkgs}

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
