{
  description = "doclive - Fast Markdown and Org preview for AI docs";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      eachSystem = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      devShells = eachSystem (
        pkgs:
        let
          emacs = pkgs.emacs;
        in
        {
          default = pkgs.mkShell {
            packages = [
              emacs
            ];

            shellHook = ''
              make autoloads 2>/dev/null

              echo "doclive development environment loaded"
              echo "  emacs: $(emacs --version | head -1)"
              echo ""
              echo "=== Automated checks ==="
              echo "  make check              Run local release gate"
              echo "  make compile            Byte-compile with warnings as errors"
              echo "  make test               Run ERT test suite"
              echo "  make lint               Run checkdoc"
              echo "  make package-lint       Run package-lint"
              echo "  nix run .#compile       Byte-compile (standalone)"
              echo "  nix run .#test          Run tests (standalone)"
              echo "  nix run .#lint          Run checkdoc (standalone)"
              echo "  nix run .#package-lint  Run package-lint (standalone)"
              echo "  nix flake check         Run all checks (sandboxed)"
              echo ""
              echo "=== Manual testing ==="
              echo "  emacs -Q -L . -l doclive.el example/sample.md"
              echo "    1. M-x doclive-preview-buffer"
              echo "    2. Edit the buffer and confirm the preview updates"
              echo "    3. M-x doclive-stop-server"
              echo ""
              echo "  emacs -Q -L . -l doclive.el example/sample.org"
              echo "    1. M-x doclive-preview-buffer"
              echo "    2. Click local .md / .org links in the preview"
              echo "    3. M-x doclive-stop-server"
              echo ""
            '';
          };
        }
      );

      apps = eachSystem (
        pkgs:
        let
          emacs = pkgs.emacs;
          emacsWithPkgLint = (pkgs.emacsPackagesFor emacs).emacsWithPackages (epkgs: [
            epkgs.package-lint
          ]);
          make = "${pkgs.gnumake}/bin/make";
          mkApp = emacsPkg: target: {
            type = "app";
            program = toString (
              pkgs.writeShellScript "doclive-${target}" ''
                EMACS=${pkgs.lib.getExe emacsPkg} ${make} ${target}
              ''
            );
          };
        in
        {
          compile = mkApp emacs "compile";
          test = mkApp emacs "test";
          lint = mkApp emacs "lint";
          package-lint = mkApp emacsWithPkgLint "package-lint";
        }
      );

      checks = eachSystem (
        pkgs:
        let
          emacs = pkgs.emacs;
          emacsWithPkgLint = (pkgs.emacsPackagesFor emacs).emacsWithPackages (epkgs: [
            epkgs.package-lint
          ]);
          src = pkgs.lib.cleanSource ./.;
        in
        {
          compile = pkgs.stdenvNoCC.mkDerivation {
            name = "doclive-compile";
            inherit src;
            nativeBuildInputs = [ emacs ];
            env.EMACS = pkgs.lib.getExe emacs;
            buildPhase = ''
              make compile
            '';
            installPhase = ''
              touch $out
            '';
          };

          test = pkgs.stdenvNoCC.mkDerivation {
            name = "doclive-test";
            inherit src;
            nativeBuildInputs = [ emacs ];
            env.EMACS = pkgs.lib.getExe emacs;
            buildPhase = ''
              make test
            '';
            installPhase = ''
              touch $out
            '';
          };

          lint = pkgs.stdenvNoCC.mkDerivation {
            name = "doclive-lint";
            inherit src;
            nativeBuildInputs = [ emacs ];
            env.EMACS = pkgs.lib.getExe emacs;
            buildPhase = ''
              make lint
            '';
            installPhase = ''
              touch $out
            '';
          };

          package-lint = pkgs.stdenvNoCC.mkDerivation {
            name = "doclive-package-lint";
            inherit src;
            nativeBuildInputs = [ emacsWithPkgLint ];
            env.EMACS = pkgs.lib.getExe emacsWithPkgLint;
            buildPhase = ''
              make package-lint
            '';
            installPhase = ''
              touch $out
            '';
          };
        }
      );
    };
}
