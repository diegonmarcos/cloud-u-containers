# ╔══════════════════════════════════════════════════════════════════╗
# ║ Port Enforcement — shared library for build.json port injection ║
# ║                                                                  ║
# ║ Import:                                                          ║
# ║   ports = import ../../_shared/lib/port-enforcement.nix {        ║
# ║     buildJsonPath = ../build.json;                               ║
# ║     cloudDataPath = ./build-<name>.json;                         ║
# ║     # ↑ per-service consolidated build file (replaces the legacy ║
# ║     # cloud-data-service-connections.json shared registry).      ║
# ║   };                                                             ║
# ║                                                                  ║
# ║ Usage with docker.mkService:                                     ║
# ║   portEnv = ports.envFor "app";                                  ║
# ║   # → { ROCKET_PORT = 8880; } or {} if no port_env declared     ║
# ║                                                                  ║
# ║ Usage for string-interpolation flakes:                           ║
# ║   config.port = ports.valueOf "app";                             ║
# ║   # → 8880 (integer) or null                                    ║
# ║                                                                  ║
# ║ Port formats (build.json "port_format" field):                   ║
# ║   "plain"  → 8880             (default, most apps)              ║
# ║   "colon"  → :8880            (Dozzle, Mattermost)              ║
# ║   "host"   → WG_IP:8880       (Ollama — requires cloudDataPath) ║
# ╚══════════════════════════════════════════════════════════════════╝

{ buildJsonPath, cloudDataPath ? null }:

let
  buildJson = builtins.fromJSON (builtins.readFile buildJsonPath);
  containers = buildJson.containers or {};

  # Resolve WG IP from cloud-data for "host" format
  svcName = buildJson.name or null;
  cloudServices = if cloudDataPath != null
    then (builtins.fromJSON (builtins.readFile cloudDataPath)).services or {}
    else {};
  wgIp = if svcName != null && cloudServices ? ${svcName}
    then cloudServices.${svcName}.ip
    else "127.0.0.1";  # safe fallback — never 0.0.0.0

  # Format a port value according to the container's port_format
  formatPort = c:
    let
      port = c.port;
      fmt = c.port_format or "plain";
    in
      if fmt == "colon" then ":${toString port}"
      else if fmt == "host" then "${wgIp}:${toString port}"
      else port;  # "plain" — raw integer

in {

  # ── envFor: port env attrset for docker.mkService { portEnv = ... } ──
  # Returns { ENV_VAR_NAME = formattedPort; } if port_env is declared, else {}
  envFor = containerKey:
    let
      c = containers.${containerKey} or {};
      portEnv = c.port_env or null;
      port = c.port or null;
    in
      if portEnv != null && port != null
      then { "${portEnv}" = formatPort c; }
      else {};

  # ── valueOf: raw port integer for string interpolation flakes ──
  # Returns the port number or null
  valueOf = containerKey:
    (containers.${containerKey} or {}).port or null;

  # ── allEnvs: merged port envs for ALL containers (multi-container services) ──
  # Returns combined attrset of all port envs (with formatting applied)
  allEnvs =
    builtins.foldl' (acc: key:
      let
        c = containers.${key};
        portEnv = c.port_env or null;
        port = c.port or null;
      in
        if portEnv != null && port != null
        then acc // { "${portEnv}" = formatPort c; }
        else acc
    ) {} (builtins.attrNames containers);

  # ── raw: expose the containers attrset for advanced use ──
  inherit containers;
}
