# ╔══════════════════════════════════════════════════════════════════╗
# ║ Shared Docker Compose policy module for cloud services          ║
# ║ Import: let docker = import ../../_shared/docker.nix;           ║
# ║                                                                  ║
# ║ Provides:                                                        ║
# ║   docker.mkService { ... }   → YAML string for one service      ║
# ║   docker.mkCompose { ... }   → complete docker-compose.yml text  ║
# ║   docker.mkDocs { ... }      → mdBook documentation package      ║
# ║   docker.banner "path"       → DO NOT EDIT header comment        ║
# ╚══════════════════════════════════════════════════════════════════╝
#
# Design:
#   - Policies (logging, cap_drop, security_opt, stop_grace_period) are
#     injected automatically. Each can be disabled per-service via escape hatches.
#   - Port binding is validated: must use WireGuard IP or 127.0.0.1 unless
#     allowPublicPorts = true.
#   - YAML is generated via string interpolation (same as existing flakes).

let
  # ── Indentation constants ─────────────────────────────────────
  # YAML indentation: 2 spaces per level
  # Level 0: top-level keys (services:, networks:, volumes:)
  # Level 1: service name (  vaultwarden:)
  # Level 2: service properties (    image:)
  # Level 3: nested properties (      - item)
  i2 = "    ";   # level 2 — service properties
  i3 = "      "; # level 3 — nested under properties

  # ── Helpers ─────────────────────────────────────────────────────

  # Render environment as YAML — supports both map { K = "V"; } and list [ "K=V" ]
  renderEnv = env:
    if builtins.isList env then
      "${i2}environment:\n" + builtins.concatStringsSep "\n" (map (e: "${i3}- ${e}") env)
    else if builtins.isAttrs env then
      "${i2}environment:\n" + builtins.concatStringsSep "\n"
        (builtins.attrValues (builtins.mapAttrs (k: v: "${i3}${k}: ${toString v}") env))
    else "";

  # Render depends_on with conditions
  renderDependsOn = deps:
    if deps == {} then ""
    else "${i2}depends_on:\n" + builtins.concatStringsSep "\n"
      (builtins.attrValues (builtins.mapAttrs (name: val:
        if builtins.isAttrs val then
          "${i3}${name}:\n${i3}  condition: ${val.condition}"
        else
          "${i3}${name}:\n${i3}  condition: service_started"
      ) deps));

  # Validate port bindings — must NOT start with "0.0.0.0:" unless allowPublicPorts
  validatePorts = allowPublic: ports:
    let
      check = p:
        if allowPublic then true
        else if builtins.isString p then
          let
            isPublic = builtins.match "0\\.0\\.0\\.0:.*" p != null;
          in
            if isPublic then builtins.throw "Port binding '${p}' uses 0.0.0.0 — use WireGuard IP or set allowPublicPorts = true"
            else true
        else true;
    in builtins.all check ports;

in {

  # ══════════════════════════════════════════════════════════════════
  # banner: DO NOT EDIT header for generated files
  # ══════════════════════════════════════════════════════════════════

  banner = sourcePath:
    "# ╔══════════════════════════════════════════════════════════════════╗\n"
    + "# ║ DO NOT EDIT — DECLARATIVE ENVIRONMENT — NIX FLAKES WAY         ║\n"
    + "# ║ AUTO-GENERATED — DONT USE IMPERATIVE SOLUTIONS!!!              ║\n"
    + "# ╠══════════════════════════════════════════════════════════════════╣\n"
    + "# ║ Source: ${sourcePath}\n"
    + "# ║ Rebuild: build.sh ship\n"
    + "# ╚══════════════════════════════════════════════════════════════════╝";

  # ══════════════════════════════════════════════════════════════════
  # mkService: generate YAML block for a single docker-compose service
  # ══════════════════════════════════════════════════════════════════
  #
  # Returns a string of YAML (indented 4 spaces for service body).
  # Caller places it under `services:` → `<name>:`.

  mkService = {
    # Required
    name,
    image ? null,             # null if using build: context

    # Build (for services built from Dockerfile)
    build ? null,             # string (context path) or attrset { context; dockerfile; }

    # Container identity
    container_name ? name,
    entrypoint ? null,        # string or list — overrides image ENTRYPOINT
    command ? null,           # string or list — overrides image CMD

    # Networking
    ports ? [],               # list of "ip:host:container" strings
    networks ? [],
    expose ? [],              # internal-only ports

    # Health
    healthcheck ? null,       # { test, interval, timeout, retries, start_period }

    # Data
    volumes ? [],
    environment ? null,       # attrset { K = "V"; } or list [ "K=V" ]
    env_file ? [],

    # Dependencies
    depends_on ? {},          # { service_name = { condition = "service_healthy"; }; }
    startAfter ? [],          # list of service names — auto-generates depends_on with service_healthy

    # Resource limits (Docker Compose v2 deploy syntax)
    memLimit ? null,          # e.g. "256M"
    memReservation ? null,    # e.g. "128M"
    cpuLimit ? null,          # e.g. "0.5"

    # Security escape hatches
    skipCapDrop ? false,      # true = don't add cap_drop: ALL (e.g. Mailu)
    capAdd ? [],              # explicit capabilities to add back
    user ? null,              # e.g. "1000:1000" — opt-in per service
    allowPublicPorts ? false, # true = allow 0.0.0.0 port bindings
    skipReadOnly ? false,     # true = don't set read_only (services that write to root fs)
    tmpfs ? [ "/tmp" ],       # tmpfs mounts for read_only containers (override if needed)

    # Policy overrides
    restart ? "unless-stopped",
    stopGracePeriod ? "30s",
    pidsLimit ? 256,          # max processes per container (0 = no limit)
    dns ? [],                 # DNS servers — e.g. ["10.0.0.1"] for Hickory
    skipLogging ? false,      # true = don't inject logging config
    skipSecurity ? false,     # true = don't inject security_opt + cap_drop

    # Raw escape hatch — appended verbatim inside the service block
    extraYaml ? "",
  }:
    let
      _ = validatePorts allowPublicPorts ports;

      # ── Image or build ──
      imageLine = if image != null then "${i2}image: ${image}" else "";
      buildLines =
        if build == null then ""
        else if builtins.isString build then "${i2}build: ${build}"
        else "${i2}build:\n${i3}context: ${build.context}"
          + (if build ? dockerfile then "\n${i3}dockerfile: ${build.dockerfile}" else "");

      # ── Ports ──
      portLines = if ports == [] then ""
        else "${i2}ports:\n" + builtins.concatStringsSep "\n" (map (p: "${i3}- \"${p}\"") ports);

      # ── Expose ──
      exposeLines = if expose == [] then ""
        else "${i2}expose:\n" + builtins.concatStringsSep "\n" (map (p: "${i3}- \"${toString p}\"") expose);

      # ── Networks ──
      networkLines = if networks == [] then ""
        else "${i2}networks:\n" + builtins.concatStringsSep "\n" (map (n: "${i3}- ${n}") networks);

      # ── Volumes ──
      volumeLines = if volumes == [] then ""
        else "${i2}volumes:\n" + builtins.concatStringsSep "\n" (map (v: "${i3}- ${v}") volumes);

      # ── Environment ──
      envLines = if environment == null then "" else renderEnv environment;

      # ── Env file ──
      envFileLines = if env_file == [] then ""
        else "${i2}env_file:\n" + builtins.concatStringsSep "\n" (map (f: "${i3}- ${f}") env_file);

      # ── Depends on (merge explicit depends_on + startAfter chain) ──
      startAfterDeps = builtins.listToAttrs (map (svc: {
        name = svc;
        value = { condition = "service_healthy"; };
      }) startAfter);
      mergedDeps = startAfterDeps // depends_on;  # explicit depends_on wins on conflict
      dependsLines = renderDependsOn mergedDeps;

      # ── Healthcheck ──
      healthLines = if healthcheck == null then ""
        else "${i2}healthcheck:\n${i3}test: ${healthcheck.test}\n${i3}interval: ${healthcheck.interval or "30s"}\n${i3}timeout: ${healthcheck.timeout or "10s"}\n${i3}retries: ${toString (healthcheck.retries or 3)}"
          + (if healthcheck ? start_period then "\n${i3}start_period: ${healthcheck.start_period}" else "");

      # ── Resource limits (deploy.resources syntax — Compose v2) ──
      # pids_limit goes here too (not top-level, which conflicts with deploy)
      hasLimits = memLimit != null || cpuLimit != null || pidsLimit != 0;
      hasReservations = memReservation != null;
      deployLines = if !hasLimits && !hasReservations then ""
        else "${i2}deploy:\n${i3}resources:"
          + (if hasLimits then "\n${i3}  limits:"
            + (if memLimit != null then "\n${i3}    memory: ${memLimit}" else "")
            + (if cpuLimit != null then "\n${i3}    cpus: \"${cpuLimit}\"" else "")
            + (if pidsLimit != 0 then "\n${i3}    pids: ${toString pidsLimit}" else "")
            else "")
          + (if hasReservations then "\n${i3}  reservations:"
            + (if memReservation != null then "\n${i3}    memory: ${memReservation}" else "")
            else "");

      # ── POLICIES (auto-injected) ──

      restartLine = "${i2}restart: ${restart}";
      stopLine = "${i2}stop_grace_period: ${stopGracePeriod}";

      # read_only + tmpfs (writable scratch dirs for read-only containers)
      readOnlyLine = if skipReadOnly then "" else "${i2}read_only: true";
      tmpfsLines = if skipReadOnly || tmpfs == [] then ""
        else "${i2}tmpfs:\n" + builtins.concatStringsSep "\n" (map (t: "${i3}- ${t}") tmpfs);

      # ulimits (file descriptor cap)
      ulimitsLines = "${i2}ulimits:\n${i3}nofile:\n${i3}  soft: 65536\n${i3}  hard: 65536";

      # DNS (force internal resolver)
      dnsLines = if dns == [] then ""
        else "${i2}dns:\n" + builtins.concatStringsSep "\n" (map (d: "${i3}- ${d}") dns);

      loggingLines = if skipLogging then ""
        else "${i2}logging:\n${i3}driver: \"json-file\"\n${i3}options:\n${i3}  max-size: \"10m\"\n${i3}  max-file: \"3\"";

      securityLines = if skipSecurity then ""
        else "${i2}security_opt:\n${i3}- no-new-privileges:true"
          + (if !skipCapDrop then "\n${i2}cap_drop:\n${i3}- ALL" else "")
          + (if capAdd != [] then "\n${i2}cap_add:\n" + builtins.concatStringsSep "\n" (map (c: "${i3}- ${c}") capAdd) else "");

      userLine = if user != null then "${i2}user: \"${user}\"" else "";

      # entrypoint / command
      entrypointLine = if entrypoint == null then ""
        else if builtins.isList entrypoint then "${i2}entrypoint: [${builtins.concatStringsSep ", " (map (e: "\"${e}\"") entrypoint)}]"
        else "${i2}entrypoint: ${entrypoint}";
      commandLine = if command == null then ""
        else "${i2}command: ${command}";

      # Collect all non-empty sections
      sections = builtins.filter (s: s != "") [
        imageLine
        buildLines
        "${i2}container_name: ${container_name}"
        entrypointLine
        commandLine
        restartLine
        stopLine
        readOnlyLine
        tmpfsLines
        ulimitsLines
        dnsLines
        envFileLines
        envLines
        portLines
        exposeLines
        dependsLines
        volumeLines
        networkLines
        healthLines
        deployLines
        loggingLines
        securityLines
        userLine
        (if extraYaml != "" then extraYaml else "")
      ];

    in builtins.concatStringsSep "\n" sections;


  # ══════════════════════════════════════════════════════════════════
  # mkCompose: generate a complete docker-compose.yml
  # ══════════════════════════════════════════════════════════════════

  mkCompose = pkgs: {
    banner ? "",               # header comment (use docker.banner)
    services ? {},             # { name = mkService-result-string; ... }
    networks ? {},             # { name = { external = true; name = "..."; }; }
    volumes ? {},              # { name = { driver = "local"; }; }
    extraTopLevel ? "",        # raw YAML appended at top level
  }:
    let
      # Render services — each is "  name:\n    property: value\n..."
      serviceBlock = builtins.concatStringsSep "\n\n" (
        builtins.attrValues (builtins.mapAttrs (name: yaml:
          "  ${name}:\n${yaml}"
        ) services)
      );

      # Render networks
      networkBlock = if networks == {} then ""
        else "\nnetworks:\n" + builtins.concatStringsSep "\n" (
          builtins.attrValues (builtins.mapAttrs (name: cfg:
            let
              ext = if cfg.external or false then "\n    external: true" else "";
              nm = if cfg ? name then "\n    name: ${cfg.name}" else "";
              drv = if cfg ? driver then "\n    driver: ${cfg.driver}" else "";
            in "  ${name}:${ext}${nm}${drv}"
          ) networks)
        );

      # Render volumes
      volumeBlock = if volumes == {} then ""
        else "\nvolumes:\n" + builtins.concatStringsSep "\n" (
          builtins.attrValues (builtins.mapAttrs (name: cfg:
            let
              drv = if cfg ? driver then "\n    driver: ${cfg.driver}" else "";
            in "  ${name}:${drv}"
          ) volumes)
        );

      # Build complete YAML via plain concatenation (no ''...'' indent stripping)
      yaml = banner
        + "\nservices:\n"
        + serviceBlock
        + networkBlock
        + volumeBlock
        + (if extraTopLevel != "" then "\n${extraTopLevel}" else "")
        + "\n";

    in pkgs.writeText "docker-compose.yml" yaml;


  # ══════════════════════════════════════════════════════════════════
  # mkDocs: generate mdBook documentation (extracted from per-flake pattern)
  # ══════════════════════════════════════════════════════════════════

  mkDocs = pkgs: {
    title,
    config,
    defaultPkg,
    docsPath ? null,    # path to ./docs directory (null if none)
  }:
    let
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

      hasNarrative = docsPath != null && pathExists docsPath;
      narrativeFiles = if hasNarrative
        then filter (f: hasSuffix ".md" f) (attrNames (readDir docsPath))
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
      ${optionalString hasNarrative "cp ${docsPath}/*.md build/src/ 2>/dev/null || true"}

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
}
