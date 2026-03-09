{
  description = "HedgeDoc - Collaborative markdown editor (notes.diegonmarcos.com)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    config = {
      domain = "notes.diegonmarcos.com";
      container_name = "hedgedoc_app";
      image = "quay.io/hedgedoc/hedgedoc:latest";
      db_container = "hedgedoc_postgres";
      db_image = "postgres:16-alpine";
      port = 3010;
      db_user = "hedgedoc";
      db_name = "hedgedoc";
    };

    title = "HedgeDoc - Collaborative markdown editor (notes.diegonmarcos.com)";

    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      # HedgeDoc - Collaborative markdown editor
      # Real-time collaboration on markdown documents
      # Deployed on: oci-A1-f_1 (Oracle Flex)

      services:
        hedgedoc:
          image: ${config.image}
          container_name: ${config.container_name}
          restart: unless-stopped
          ports:
            - "${toString config.port}:3000"
          depends_on:
            hedgedoc_postgres:
              condition: service_healthy
          volumes:
            - hedgedoc_uploads:/hedgedoc/public/uploads
          environment:
            - CMD_DB_URL=postgres://${config.db_user}:${config.db_user}@${config.db_container}:5432/${config.db_name}
            - CMD_DOMAIN=${config.domain}
            - CMD_PROTOCOL_USESSL=true
            - CMD_URL_ADDPORT=false
            - CMD_ALLOW_ANONYMOUS=true
            - CMD_ALLOW_ANONYMOUS_EDITS=true
            - CMD_ALLOW_FREEURL=true
            - CMD_DEFAULT_PERMISSION=freely
            - CMD_SESSION_SECRET=hedgedoc-secret-change-me
            - CMD_EMAIL=true
            - CMD_ALLOW_EMAIL_REGISTER=true
          networks:
            - dev_network
          healthcheck:
            test: ['CMD', 'wget', '-q', '--spider', 'http://localhost:3000/status']
            interval: 30s
            timeout: 10s
            retries: 5
            start_period: 30s

        hedgedoc_postgres:
          image: ${config.db_image}
          container_name: ${config.db_container}
          restart: unless-stopped
          volumes:
            - postgres_data:/var/lib/postgresql/data
          environment:
            - POSTGRES_USER=${config.db_user}
            - POSTGRES_PASSWORD=${config.db_user}
            - POSTGRES_DB=${config.db_name}
            - PGDATA=/var/lib/postgresql/data/pgdata
          networks:
            - dev_network
          healthcheck:
            test: ['CMD-SHELL', 'pg_isready -U ${config.db_user}']
            interval: 10s
            timeout: 5s
            retries: 5

      networks:
        dev_network:
          external: true
          name: dev_network

      volumes:
        hedgedoc_uploads:
          driver: local
        postgres_data:
          driver: local
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
      defaultPkg = pkgs.runCommand "hedgedoc-configs" {} ''
        mkdir -p $out
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
      '';
    in {
      default = defaultPkg;
      docs = mkDocs pkgs defaultPkg;
    });
  };
}
