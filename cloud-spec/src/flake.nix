{
  description = "Unified Cloud Documentation Portal";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];
  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = pkgs.runCommand "cloud-spec-portal" {
        nativeBuildInputs = [ pkgs.mdbook ];
      } ''
        mkdir -p build/src
        cp -r ${./docs}/* build/src/
        cp ${./book.toml} build/book.toml
        cd build && mdbook build -d $out
      '';
    });
  };
}
