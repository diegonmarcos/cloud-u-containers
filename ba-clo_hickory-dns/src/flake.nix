{
  description = "Hickory DNS - Internal DNS server for WireGuard mesh (.internal zone)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    config = {};

    title = "Hickory DNS";

    # ── Service registry (single source of truth) ──────────────────────
    services = {
      # gcp-proxy (10.0.0.1)
      caddy    = { ip = "10.0.0.1"; desc = "Reverse proxy"; };
      auth     = { ip = "10.0.0.1"; desc = "Authelia 2FA"; };
      vault    = { ip = "10.0.0.1"; desc = "Vaultwarden"; };
      api      = { ip = "10.0.0.1"; desc = "API gateway"; };
      ntfy     = { ip = "10.0.0.1"; desc = "Push notifications"; };
      dns      = { ip = "10.0.0.1"; desc = "Hickory DNS"; };

      # oci-apps (10.0.0.6)
      photos   = { ip = "10.0.0.6"; desc = "PhotoPrism"; };
      db       = { ip = "10.0.0.6"; desc = "NocoDB"; };
      ide      = { ip = "10.0.0.6"; desc = "Code Server"; };
      affine   = { ip = "10.0.0.6"; desc = "AFFiNE"; };

      # oci-mail (10.0.0.3)
      mail     = { ip = "10.0.0.3"; desc = "Mailu"; };
      sync     = { ip = "10.0.0.3"; desc = "Syncthing"; };
      cal      = { ip = "10.0.0.3"; desc = "Radicale"; };

      # oci-analytics (10.0.0.4)
      matomo   = { ip = "10.0.0.4"; desc = "Matomo analytics"; };
      windmill = { ip = "10.0.0.4"; desc = "Windmill workflows"; };
    };

    # VM reverse map for PTR records
    vms = {
      "1" = "gcp-proxy";
      "3" = "oci-mail";
      "4" = "oci-analytics";
      "6" = "oci-apps";
    };

    # ── Zone file generators ───────────────────────────────────────────
    mkForwardZone = pkgs: let
      records = builtins.concatStringsSep "\n" (
        nixpkgs.lib.mapAttrsToList (name: svc:
          "${name}          IN  A     ${svc.ip}    ; ${svc.desc}"
        ) services
      );
    in pkgs.writeText "internal.zone" ''
      $TTL 3600
      @   IN  SOA   dns.internal. admin.internal. (
                    2026021601  ; serial (YYYYMMDDNN)
                    3600        ; refresh
                    900         ; retry
                    604800      ; expire
                    300 )       ; negative cache TTL

          IN  NS    dns.internal.

      ; ── Service A records ──
      ${records}

      ; ── Wildcard (unmatched → Caddy) ──
      *            IN  A     10.0.0.1
    '';

    mkReverseZone = pkgs: let
      ptrRecords = builtins.concatStringsSep "\n" (
        nixpkgs.lib.mapAttrsToList (octet: hostname:
          "${octet}    IN  PTR   ${hostname}.internal."
        ) vms
      );
    in pkgs.writeText "0.0.10.in-addr.arpa.zone" ''
      $TTL 3600
      @   IN  SOA   dns.internal. admin.internal. (
                    2026021601  ; serial
                    3600        ; refresh
                    900         ; retry
                    604800      ; expire
                    300 )       ; negative cache TTL

          IN  NS    dns.internal.

      ; ── PTR records ──
      ${ptrRecords}
    '';

    # ── Hickory DNS named.toml ─────────────────────────────────────────
    mkNamedToml = pkgs: pkgs.writeText "named.toml" ''
      listen_addrs_ipv4 = ["0.0.0.0"]
      listen_port = 53
      directory = "/var/named"

      [[zones]]
      zone = "internal"
      zone_type = "Primary"
      file = "internal.zone"

      [[zones]]
      zone = "0.0.10.in-addr.arpa"
      zone_type = "Primary"
      file = "0.0.10.in-addr.arpa.zone"

      [[zones]]
      zone = "."
      zone_type = "External"

      [zones.stores]
      type = "forward"
      name_servers = [
          { socket_addr = "1.1.1.1:53", protocol = "udp" },
          { socket_addr = "1.0.0.1:53", protocol = "udp" },
          { socket_addr = "8.8.8.8:53", protocol = "udp" },
          { socket_addr = "8.8.4.4:53", protocol = "udp" }
      ]
    '';

    # ── Docker Compose ─────────────────────────────────────────────────
    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      services:
        hickory-dns:
          image: hickorydns/hickory-dns:latest
          container_name: hickory-dns
          restart: unless-stopped
          ports:
            - "10.0.0.1:53:53/tcp"
            - "10.0.0.1:53:53/udp"
          volumes:
            - ./config/named.toml:/etc/named.toml:ro
            - ./zones:/var/named:ro
          dns:
            - 1.1.1.1
            - 8.8.8.8
          deploy:
            resources:
              limits:
                memory: 64M
    '';


    # ── Documentation ────────────────────────────────────────────────────
    mkDocs = pkgs: defaultPkg: let
      inherit (pkgs.lib) concatMapStrings hasSuffix optionalString filter subtractLists removeSuffix;
      inherit (builtins) attrNames readDir pathExists;

      portKeys = filter (k: hasSuffix "_port" k || k == "port") (attrNames config);
      imageKeys = filter (k: hasSuffix "_image" k || k == "image") (attrNames config);
      containerKeys = filter (k: hasSuffix "_container" k || k == "container_name") (attrNames config);
      domainKeys = filter (k: k == "domain" || k == "base_domain") (attrNames config);
      otherKeys = subtractLists (portKeys ++ imageKeys ++ containerKeys ++ domainKeys) (attrNames config);

      row = k: let
        v = config.${k};
        vs = if builtins.isBool v then (if v then "true" else "false")
             else if builtins.isAttrs v || builtins.isList v then builtins.toJSON v
             else toString v;
      in "| `${k}` | `${vs}` |\n";
      section = heading: keys: optionalString (keys != []) ''
        ## ${heading}
        | Key | Value |
        |-----|-------|
        ${concatMapStrings row keys}
      '';

      hasNarrative = pathExists ./docs;
      narrativeFiles = if hasNarrative
        then filter (f: hasSuffix ".md" f) (attrNames (readDir ./docs))
        else [];

      specMd = pkgs.writeText "spec.md" ''
        # ${title}
        ${section "Network" (domainKeys ++ portKeys)}
        ${section "Containers" (containerKeys ++ imageKeys)}
        ${section "Configuration" otherKeys}
      '';

      summaryMd = pkgs.writeText "SUMMARY.md" ''
        # Summary
        - [Specification](./spec.md)
        - [Generated Configs](./configs.md)
        ${concatMapStrings (f: "- [${removeSuffix ".md" f}](./${f})\n") narrativeFiles}
      '';

      bookToml = pkgs.writeText "book.toml" ''
        [book]
        title = "${title}"
        [output.html]
        default-theme = "ayu"
      '';
    in pkgs.runCommand "docs" {
      nativeBuildInputs = [ pkgs.mdbook pkgs.file ];
    } ''
      mkdir -p build/src
      cp ${bookToml} build/book.toml
      cp ${summaryMd} build/src/SUMMARY.md
      cp ${specMd} build/src/spec.md
      ${optionalString hasNarrative "cp ${./docs}/*.md build/src/ 2>/dev/null || true"}

      # Generate configs.md from packages.default output
      echo "# Generated Configuration Files" > build/src/configs.md
      echo "" >> build/src/configs.md
      echo 'These files are produced by nix build and deployed to the VM.' >> build/src/configs.md
      echo "" >> build/src/configs.md
      find ${defaultPkg} -type f | sort | while read -r f; do
        relpath="''${f#${defaultPkg}/}"
        case "$relpath" in
          .secrets|*.secrets|*.lock|*.png|*.jpg|*.gif|*.ico|*.woff*|*.ttf|*.eot) continue ;;
        esac
        case "$relpath" in
          *.yml|*.yaml)   lang="yaml" ;;
          *.json)         lang="json" ;;
          *.toml)         lang="toml" ;;
          *.py)           lang="python" ;;
          *.sh)           lang="bash" ;;
          *.js|*.ts)      lang="javascript" ;;
          *.tf)           lang="hcl" ;;
          *.conf|*.cnf)   lang="ini" ;;
          *.html)         lang="html" ;;
          *.sql)          lang="sql" ;;
          *.zone)         lang="dns" ;;
          Dockerfile*)    lang="dockerfile" ;;
          Caddyfile*)     lang="caddy" ;;
          *)              lang="" ;;
        esac
        if file -b --mime-type "$f" | grep -q "^text/"; then
          echo '## '"$relpath" >> build/src/configs.md
          echo "" >> build/src/configs.md
          echo "~~~$lang" >> build/src/configs.md
          cat "$f" >> build/src/configs.md
          echo "" >> build/src/configs.md
          echo '~~~' >> build/src/configs.md
          echo "" >> build/src/configs.md
        fi
      done

      cd build && mdbook build -d $out
    '';

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in let
      defaultPkg = pkgs.runCommand "hickory-dns-configs" {} ''
        mkdir -p $out/config $out/zones
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
        cp ${mkNamedToml pkgs} $out/config/named.toml
        cp ${mkForwardZone pkgs} $out/zones/internal.zone
        cp ${mkReverseZone pkgs} $out/zones/0.0.10.in-addr.arpa.zone
      '';
    in {
      default = defaultPkg;
      docs = mkDocs pkgs defaultPkg;
    });
  };
}
