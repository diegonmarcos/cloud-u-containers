{
  description = "cloud-infra MCP server for Claude Code — containerized with debian-slim";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    config = {
      container_name = "cloud-infra-mcp";
      image = "cloud-infra-mcp:latest";
    };

    title = "cloud-infra MCP server for Claude Code — containerized with debian-slim";

    # podman-compose.yml — stdio MCP server with host volume mounts (runs in Podman on Termux)
    mkDockerCompose = pkgs: pkgs.writeText "podman-compose.yml" ''
      services:
        mcp-server:
          build: .
          container_name: ${config.container_name}
          image: ${config.image}
          stdin_open: true
          environment:
            - HOME=''${HOME}
          volumes:
            - ''${HOME}/git:''${HOME}/git:ro
            - ''${HOME}/.ssh:''${HOME}/.ssh:ro
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
      defaultPkg = pkgs.runCommand "mcp-server-skills" {} ''
        mkdir -p $out/src/tools $out/src/utils $out/src/resources $out/src/prompts
        mkdir -p $out/skills/official $out/skills/community

        # Container files (Podman on Termux)
        cp ${mkDockerCompose pkgs} $out/podman-compose.yml
        cp ${./Dockerfile} $out/Dockerfile

        # TypeScript source — root files
        cp ${./index.ts} $out/src/index.ts
        cp ${./types.ts} $out/src/types.ts
        cp ${./config.ts} $out/src/config.ts

        # TypeScript source — tools/
        for f in ${./tools}/*.ts; do
          cp "$f" "$out/src/tools/$(basename "$f")"
        done

        # TypeScript source — utils/
        for f in ${./utils}/*.ts; do
          cp "$f" "$out/src/utils/$(basename "$f")"
        done

        # TypeScript source — resources/ and prompts/
        cp ${./resources/index.ts} $out/src/resources/index.ts
        cp ${./prompts/index.ts} $out/src/prompts/index.ts

        # Skill files — reference docs only (SKILL.md content migrated to MCP prompts)
        cp ${./skills/skills.md} $out/skills/skills.md
        cp ${./skills/skills_claude.md} $out/skills/skills_claude.md
        cp ${./skills/skills_front.md} $out/skills/skills_front.md
        cp ${./skills/skills_claude_front.md} $out/skills/skills_claude_front.md

        # Skill files — community + official templates (senior/junior removed — migrated to MCP prompts)
        for f in ${./skills/official}/*; do
          cp "$f" "$out/skills/official/$(basename "$f")"
        done
        for f in ${./skills/community}/*; do
          cp "$f" "$out/skills/community/$(basename "$f")"
        done
      '';
    in {
      default = defaultPkg;
      docs = mkDocs pkgs defaultPkg;
    });
  };
}
