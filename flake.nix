{
  description = "isonim-tui-serve - WebSocket bridge for the M26 packet driver in isonim-tui";

  inputs = {
    nixos-modules.url = "github:metacraft-labs/nixos-modules";
    nixpkgs.follows = "nixos-modules/nixpkgs-unstable";
    flake-parts.follows = "nixos-modules/flake-parts";
    git-hooks.follows = "nixos-modules/git-hooks-nix";
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      flake-parts,
      git-hooks,
      ...
    }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      perSystem =
        { pkgs, system, ... }:
        let
          preCommit = git-hooks.lib.${system}.run {
            src = ./.;
            hooks = {
              check-added-large-files = {
                enable = true;
                args = [ "--maxkb=1200" ];
              };
              check-merge-conflicts.enable = true;
              lint = {
                enable = true;
                name = "just lint";
                entry = "just lint";
                language = "system";
                pass_filenames = false;
              };
            };
          };
        in
        {
          checks.pre-commit = preCommit;
          devShells.default = pkgs.mkShell {
            packages = with pkgs; [
              nim
              nimble
              just
              nixfmt-rfc-style
              markdownlint-cli2
              shellcheck
              shfmt
            ];
            shellHook = ''
              ${preCommit.shellHook}
              echo "isonim-tui-serve dev shell - nim $(nim --version 2>&1 | head -1)"
            '';
          };
          packages.default = pkgs.stdenvNoCC.mkDerivation {
            pname = "isonim-tui-serve";
            version = "0.1.0";
            src = ./.;
            installPhase = ''
              mkdir -p $out
              cp -R src isonim_tui_serve.nimble README.md LICENSE static $out/
            '';
          };
        };
    };
}
