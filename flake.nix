{
  description = "md-live - Fast Markdown and Org preview for AI docs";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      eachSystem = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      devShells = eachSystem (pkgs:
        let
          emacsWithPkgLint = (pkgs.emacsPackagesFor pkgs.emacs).emacsWithPackages (epkgs: [
            epkgs.package-lint
          ]);
        in
        {
          default = pkgs.mkShell {
            packages = [
              emacsWithPkgLint
              pkgs.gnumake
            ];
            shellHook = ''
              make autoloads >/dev/null 2>&1 || true

              echo "md-live development shell"
              echo "  make compile"
              echo "  make test"
              echo "  make lint"
              echo "  make package-lint"
              echo "  make autoloads"
              echo "  nix flake check"
            '';
          };
        });

      apps = eachSystem (pkgs:
        let
          emacsWithPkgLint = (pkgs.emacsPackagesFor pkgs.emacs).emacsWithPackages (epkgs: [
            epkgs.package-lint
          ]);
          make = "${pkgs.gnumake}/bin/make";
          mkApp = name: emacs: {
            type = "app";
            program = toString (pkgs.writeShellScript "md-live-${name}" ''
              set -euo pipefail
              EMACS=${pkgs.lib.getExe emacs} ${make} ${name}
            '');
          };
        in
        {
          compile = mkApp "compile" pkgs.emacs;
          test = mkApp "test" pkgs.emacs;
          lint = mkApp "lint" pkgs.emacs;
          package-lint = mkApp "package-lint" emacsWithPkgLint;
          autoloads = mkApp "autoloads" pkgs.emacs;
        });

      checks = eachSystem (pkgs:
        let
          emacsWithPkgLint = (pkgs.emacsPackagesFor pkgs.emacs).emacsWithPackages (epkgs: [
            epkgs.package-lint
          ]);
          src = pkgs.lib.cleanSource ./.;
          mkCheck = name: emacs: pkgs.stdenvNoCC.mkDerivation {
            pname = "md-live-${name}";
            version = "0.1.0";
            inherit src;
            nativeBuildInputs = [ emacs pkgs.gnumake ];
            env.EMACS = pkgs.lib.getExe emacs;
            buildPhase = ''
              runHook preBuild
              make ${name}
              runHook postBuild
            '';
            installPhase = ''
              runHook preInstall
              touch $out
              runHook postInstall
            '';
          };
        in
        {
          compile = mkCheck "compile" pkgs.emacs;
          test = mkCheck "test" pkgs.emacs;
          lint = mkCheck "lint" pkgs.emacs;
          package-lint = mkCheck "package-lint" emacsWithPkgLint;
          autoloads = mkCheck "autoloads" pkgs.emacs;
        });

      formatter = eachSystem (pkgs: pkgs.nixfmt-rfc-style);
    };
}
