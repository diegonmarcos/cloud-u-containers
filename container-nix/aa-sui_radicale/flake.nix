{
  description = "Radicale Calendar/Contacts (CalDAV/CardDAV) - Docker Compose configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};

    config = {
      domain = "cal.diegonmarcos.com";
      container_name = "radicale";
      image = "tomsquest/docker-radicale:latest";
      port = 5232;
      timezone = "Europe/Madrid";
    };

    dockerCompose = pkgs.writeText "docker-compose.yml" ''
      version: "3.8"

      services:
        radicale:
          image: ${config.image}
          container_name: ${config.container_name}
          restart: unless-stopped
          environment:
            TZ: ${config.timezone}
          ports:
            - "${toString config.port}:5232"
          volumes:
            - ./data:/data
            - ./config:/config:ro
          networks:
            - proxy

      networks:
        proxy:
          external: true
    '';

    radicaleConfig = pkgs.writeText "config" ''
      [server]
      hosts = 0.0.0.0:5232

      [auth]
      type = htpasswd
      htpasswd_filename = /config/users
      htpasswd_encryption = bcrypt

      [storage]
      filesystem_folder = /data/collections

      [logging]
      level = info
    '';

    # Users file template (generate passwords with htpasswd)
    usersFile = pkgs.writeText "users" ''
      # Generate with: htpasswd -nB username
      # diego:$2y$05$CHANGE_ME_BCRYPT_HASH
    '';

  in {
    packages.${system} = {
      default = pkgs.runCommand "radicale-configs" {} ''
        mkdir -p $out/{data/collections,config}
        cp ${dockerCompose} $out/docker-compose.yml
        cp ${radicaleConfig} $out/config/config
        cp ${usersFile} $out/config/users
      '';
      docker-compose = dockerCompose;
      config = radicaleConfig;
    };

    devShells.${system}.default = pkgs.mkShell {
      packages = [ pkgs.docker-compose pkgs.apacheHttpd ]; # htpasswd is in apacheHttpd
    };
  };
}
