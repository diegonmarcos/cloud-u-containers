{
  description = "PostLite - SQLite REST API + PostgreSQL wire protocol";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    config = {};

    title = "PostLite";

    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      # ╔══════════════════════════════════════════════════════════════════╗
      # ║ DO NOT EDIT — DECLARATIVE ENVIRONMENT — NIX FLAKES WAY         ║
      # ║ AUTO-GENERATED — DONT USE IMPERATIVE SOLUTIONS!!!              ║
      # ╠══════════════════════════════════════════════════════════════════╣
      # ║ Source: ~/git/cloud/a_solutions/ca-dat_postlite/src/flake.nix   ║
      # ║ Rebuild: ~/git/cloud/a_solutions/ca-dat_postlite/build.sh ship  ║
      # ╚══════════════════════════════════════════════════════════════════╝
      # SQLite REST API servers (ws4sqlite + postlite)
      # Deployed on: gcp-E2-f_0 (35.226.147.64)
      # Access via WireGuard only (10.0.0.1:8880-8883, 5433-5436)

      services:
        sqlite-npm:
          image: germanorizzo/ws4sqlite:v0.16.6
          container_name: sqlite-npm
          restart: "no"  # container-init handles startup
          network_mode: host
          volumes:
            - /home/diego/npm/data:/data
          command: ["-port", "8880", "-db", "/data/database.sqlite?mode=ro"]

        sqlite-vaultwarden:
          image: germanorizzo/ws4sqlite:v0.16.6
          container_name: sqlite-vaultwarden
          restart: "no"  # container-init handles startup
          network_mode: host
          volumes:
            - /home/diego/vaultwarden/data:/data
          command: ["-port", "8881", "-db", "/data/db.sqlite3?mode=ro"]

        sqlite-ntfy:
          image: germanorizzo/ws4sqlite:v0.16.6
          container_name: sqlite-ntfy
          restart: "no"  # container-init handles startup
          network_mode: host
          volumes:
            - /home/diego/ntfy/cache:/data
          command: ["-port", "8882", "-db", "/data/cache.db?mode=ro"]

        sqlite-authelia:
          image: germanorizzo/ws4sqlite:v0.16.6
          container_name: sqlite-authelia
          restart: "no"  # container-init handles startup
          network_mode: host
          volumes:
            - /home/diego/authelia/config:/data
          command: ["-port", "8883", "-db", "/data/db.sqlite3?mode=ro"]

        postlite-npm:
          build:
            context: .
            dockerfile: Dockerfile
          image: ghcr.io/diegonmarcos/postlite:latest
          container_name: postlite-npm
          restart: "no"  # container-init handles startup
          network_mode: host
          volumes:
            - /home/diego/npm/data:/data
          command: ["-addr", ":5433", "-data-dir", "/data"]

        postlite-vaultwarden:
          image: ghcr.io/diegonmarcos/postlite:latest
          container_name: postlite-vaultwarden
          restart: "no"  # container-init handles startup
          network_mode: host
          volumes:
            - /home/diego/vaultwarden/data:/data
          command: ["-addr", ":5434", "-data-dir", "/data"]

        postlite-ntfy:
          image: ghcr.io/diegonmarcos/postlite:latest
          container_name: postlite-ntfy
          restart: "no"  # container-init handles startup
          network_mode: host
          volumes:
            - /home/diego/ntfy/cache:/data
          command: ["-addr", ":5435", "-data-dir", "/data"]

        postlite-authelia:
          image: ghcr.io/diegonmarcos/postlite:latest
          container_name: postlite-authelia
          restart: "no"  # container-init handles startup
          network_mode: host
          volumes:
            - /home/diego/authelia/config:/data
          command: ["-addr", ":5436", "-data-dir", "/data"]
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
      defaultPkg = pkgs.runCommand "postlite-configs" {} ''
        mkdir -p $out
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
        cp ${./Dockerfile} $out/Dockerfile
      '';
    in {
      default = defaultPkg;
      docs = mkDocs pkgs defaultPkg;
    });
  };
}
