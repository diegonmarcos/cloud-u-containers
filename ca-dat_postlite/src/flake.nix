{
  description = "PostLite - SQLite REST API + PostgreSQL wire protocol";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    # Data-driven from build.json: bind_host (WG IP), ports, image, name.
    # Tier-3 fix: ALL listeners bound to bind_host (WG-only), never bare ":PORT".
    buildJson = builtins.fromJSON (builtins.readFile ./build.json);
    image     = "${buildJson.docker.registry}/${buildJson.docker.image}:latest";
    bindHost  = buildJson.bind_host;
    p         = buildJson.ports;

    # postlite binary CLI: -addr <host:port> -data-dir <dir>
    # NOTE: legacy `-port` / `-db` flags do not exist on benbjohnson/postlite;
    # the 4 sqlite-* services were latently broken. They now use the only valid
    # binary flag (-addr), bound to bind_host:port from build.json.
    sqliteServices = [
      { name = "sqlite-npm";          port = p.npm_rest;         dataDir = "/home/diego/npm/data"; }
      { name = "sqlite-vaultwarden";  port = p.vaultwarden_rest; dataDir = "/home/diego/vaultwarden/data"; }
      { name = "sqlite-ntfy";         port = p.ntfy_rest;        dataDir = "/home/diego/ntfy/cache"; }
      { name = "sqlite-authelia";     port = p.authelia_rest;    dataDir = "/home/diego/authelia/config"; }
    ];

    postliteServices = [
      { name = "postlite-npm";         port = p.npm_pg;         dataDir = "/home/diego/npm/data"; }
      { name = "postlite-vaultwarden"; port = p.vaultwarden_pg; dataDir = "/home/diego/vaultwarden/data"; }
      { name = "postlite-ntfy";        port = p.ntfy_pg;        dataDir = "/home/diego/ntfy/cache"; }
      { name = "postlite-authelia";    port = p.authelia_pg;    dataDir = "/home/diego/authelia/config"; }
    ];

    inherit (nixpkgs.lib) concatMapStrings;

    # YAML rendered as plain string with explicit indentation.
    # 2 spaces = service name (child of `services:`); 4 spaces = service body.
    renderService = svc:
      "  ${svc.name}:\n"
      + "    image: ${image}\n"
      + "    container_name: ${svc.name}\n"
      + "    restart: \"no\"  # container-init handles startup\n"
      + "    network_mode: host\n"
      + "    volumes:\n"
      + "      - ${svc.dataDir}:/data\n"
      + "    command: [\"-addr\", \"${bindHost}:${toString svc.port}\", \"-data-dir\", \"/data\"]\n"
      + "\n";

    servicesBlock = concatMapStrings renderService (sqliteServices ++ postliteServices);

    composeHeader =
      "# DO NOT EDIT - DECLARATIVE ENVIRONMENT - NIX FLAKES WAY\n"
    + "# AUTO-GENERATED - DONT USE IMPERATIVE SOLUTIONS!!!\n"
    + "# Source : ~/git/cloud/a_solutions/ca-dat_postlite/src/flake.nix\n"
    + "# Rebuild: ~/git/cloud/a_solutions/ca-dat_postlite/build.sh ship\n"
    + "# SQLite PostgreSQL wire-protocol proxies (postlite)\n"
    + "# Deployed on: gcp-E2-f_0 - bind_host=${bindHost} (WireGuard only)\n"
    + "# Tier-3: NO bare \":PORT\" listeners; all bound to ${bindHost}.\n"
    + "\n"
    + "services:\n";

    config = {};

    title = "PostLite";

    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" (composeHeader + servicesBlock);


    # -- Documentation -----------------------------------------------------
    mkDocs = pkgs: defaultPkg: let
      inherit (pkgs.lib) hasSuffix optionalString filter subtractLists removeSuffix;
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
