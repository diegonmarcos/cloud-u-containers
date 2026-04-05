{
  description = "DBGate - Universal database manager for all cloud databases";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];
    buildJson = builtins.fromJSON (builtins.readFile ../build.json);
    ports = import ../../_shared/lib/port-enforcement.nix { buildJsonPath = ../build.json; };

    config = {
      domain = buildJson.domain;
      container_name = "dbgate";
      image = "dbgate/dbgate:latest";
      port = ports.valueOf "app";
      timezone = "Europe/Madrid";
    };

    title = "DBGate - Universal Database Manager";
    docker = import ../../_shared/docker.nix;

    ghcr-dbgate = docker.mkGhcrBuild {
      name = "dbgate";
      fromImage = config.image;
    };

    # ── Cloud-data database discovery ──────────────────────────────────
    # Read cloud-data-databases.json (staged into src/ by build.sh)
    # Filter to connectable engines (postgres, mariadb) with exposed ports
    dbData = builtins.fromJSON (builtins.readFile ./cloud-data-databases.json);

    # Filter: enabled, has a port, is postgres or mariadb, not archived services
    connectable = builtins.filter (db:
      db.enabled
      && db.port != null
      && (db.type == "postgres" || db.type == "mariadb")
      && db.service != "dbgate"
      && db.service != "nocodb"  # archived
    ) dbData.databases;

    # Generate a safe env var ID from service name (replace hyphens with underscores)
    mkId = service: builtins.replaceStrings ["-"] ["_"] service;

    # Map DB type to DBGate engine string
    engineFor = type:
      if type == "postgres" then "postgres@dbgate-plugin-postgres"
      else if type == "mariadb" then "mysql@dbgate-plugin-mysql"
      else "unknown";

    # Determine host: localhost if same VM as dbgate (oci-apps / oci-A1-f_0), else WG IP
    dbgateVm = "oci-A1-f_0";
    hostFor = db:
      if db.vm == dbgateVm then "localhost"
      else db.wg_ip;

    # Build the CONNECTIONS list (comma-separated IDs)
    connectionIds = builtins.map (db: mkId db.service) connectable;
    connectionsStr = builtins.concatStringsSep "," connectionIds;

    # Generate env var lines for one database
    # Uses explicit strings (not multiline '') to preserve indentation when interpolated
    mkDbEnv = db: let
      id = mkId db.service;
      host = hostFor db;
      user = db.user or "postgres";
      dbName = db.db or db.service;
      vmLabel = db.vm_alias or db.vm;
      i = "      ";  # 6 spaces — aligns with environment: values in final YAML
      q = "\"";        # YAML value quoting
      dollar = "$";    # escape for docker-compose variable substitution
    in builtins.concatStringsSep "\n" [
      "${i}LABEL_${id}: ${q}${db.service} (${db.type} @ ${vmLabel})${q}"
      "${i}SERVER_${id}: ${q}${host}${q}"
      "${i}PORT_${id}: ${q}${toString db.port}${q}"
      "${i}USER_${id}: ${q}${user}${q}"
      "${i}PASSWORD_${id}: ${q}${dollar}{PASSWORD_${id}}${q}"
      "${i}ENGINE_${id}: ${q}${engineFor db.type}${q}"
      "${i}DATABASE_${id}: ${q}${dbName}${q}"
      "${i}READONLY_${id}: ${q}1${q}"
    ];

    # Concatenate all DB env blocks (separated by blank line for readability)
    allDbEnvs = builtins.concatStringsSep "\n" (builtins.map mkDbEnv connectable);

    # Build compose YAML in parts to avoid Nix multiline string stripping issues
    # with interpolated multi-line content (allDbEnvs)
    composeHeader = ''
      # ╔══════════════════════════════════════════════════════════════════╗
      # ║ DO NOT EDIT — DECLARATIVE ENVIRONMENT — NIX FLAKES WAY         ║
      # ║ AUTO-GENERATED — DONT USE IMPERATIVE SOLUTIONS!!!              ║
      # ╠══════════════════════════════════════════════════════════════════╣
      # ║ Source: ~/git/cloud/a_solutions/bc-obs_dbgate/src/flake.nix    ║
      # ║ Rebuild: ~/git/cloud/a_solutions/bc-obs_dbgate/build.sh ship   ║
      # ╠══════════════════════════════════════════════════════════════════╣
      # ║ Database connections auto-generated from cloud-data-databases   ║
      # ║ Passwords loaded from .secrets (sops-decrypted)                ║
      # ╚══════════════════════════════════════════════════════════════════╝
      services:
        dbgate:
          image: ${ghcr-dbgate.image}
          build:
            context: .
            dockerfile_inline: |
              FROM ${config.image}
              LABEL org.opencontainers.image.source="https://github.com/diegonmarcos/cloud"
          container_name: ${config.container_name}
          restart: "no"
          network_mode: host
          env_file:
            - .secrets
          environment:
            PORT: "${toString config.port}"
            TZ: "${config.timezone}"
            # ── Connection registry ──
            CONNECTIONS: "${connectionsStr}"
            # ── Per-database connection config ──
    '';

    composeFooter = ''
          volumes:
            - dbgate_data:/root/.dbgate
          healthcheck:
            test: ["CMD", "wget", "-q", "--spider", "http://localhost:${toString config.port}/"]
            interval: 30s
            timeout: 10s
            retries: 3
            start_period: 15s
          deploy:
            resources:
              limits:
                memory: 256M
              reservations:
                memory: 64M

      volumes:
        dbgate_data:
          name: dbgate_data
    '';

    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml"
      (composeHeader + allDbEnvs + "\n" + composeFooter);

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

      dbTable = ''
        ## Connected Databases (${toString (builtins.length connectable)})
        | Service | Type | Host | Port | User | Database | VM |
        |---------|------|------|------|------|----------|----|
        ${builtins.concatStringsSep "" (builtins.map (db:
          "| ${db.service} | ${db.type} | ${hostFor db} | ${toString db.port} | ${db.user or "?"} | ${db.db or db.service} | ${db.vm_alias or "?"} |\n"
        ) connectable)}
      '';

      specMd = pkgs.writeText "spec.md" ''
        # ${title}
        ${section "Network" (domainKeys ++ portKeys)}
        ${section "Containers" (containerKeys ++ imageKeys)}
        ${section "Configuration" otherKeys}
        ${dbTable}
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
          *.sh)           lang="bash" ;;
          Dockerfile*)    lang="dockerfile" ;;
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
      defaultPkg = pkgs.runCommand "dbgate-configs" {} ''
        mkdir -p $out
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
      '';
    in {
      default = defaultPkg;
      docs = mkDocs pkgs defaultPkg;
    });
  };
}
