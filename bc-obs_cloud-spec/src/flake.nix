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

      site = pkgs.runCommand "cloud-spec-site" {
        nativeBuildInputs = [ pkgs.mdbook ];
      } ''
        mkdir -p build/src
        cp -r ${./docs}/* build/src/
        cp ${./book.toml} build/book.toml
        cd build && mdbook build -d $out
      '';

      compose = pkgs.writeText "docker-compose.yml" ''
        services:
          cloud-spec:
            image: busybox:latest
            container_name: cloud-spec
            restart: unless-stopped
            command: busybox httpd -f -p 3080 -h /srv
            volumes:
              - ./site:/srv:ro
            ports:
              - "127.0.0.1:3080:3080"
      '';

    in {
      default = pkgs.runCommand "cloud-spec" {} ''
        mkdir -p $out
        cp -r ${site}/* $out/
        # Flatten: move html/ contents to site/ for compose mount
        mkdir -p $out/site
        if [ -d ${site}/html ]; then
          cp -r ${site}/html/* $out/site/
        else
          cp -r ${site}/* $out/site/
        fi
        cp ${compose} $out/docker-compose.yml
      '';
    });
  };
}
