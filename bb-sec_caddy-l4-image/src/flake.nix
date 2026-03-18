{
  description = "Custom Caddy Docker image with L4 TCP proxy, ratelimit, Cloudflare DNS plugins";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];
  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = pkgs.runCommand "caddy-l4-image" {} ''
        mkdir -p $out
        cp ${./Dockerfile} $out/Dockerfile
      '';
    });
  };
}
