# ╔══════════════════════════════════════════════════════════════════╗
# ║ Template: Single-container web app                              ║
# ║ Usage: templates.app { name; image; port; wgIp; ... }          ║
# ║                                                                  ║
# ║ Returns: { services, networks, volumes } ready for mkCompose    ║
# ╚══════════════════════════════════════════════════════════════════╝
#
# Covers: vaultwarden, code-server, filebrowser, grist, radicale,
#         dozzle, revealmd, and similar single-container services.

docker:

{
  # Required
  name,                          # service name (e.g. "vaultwarden")
  image,                         # container image

  # Networking
  port ? null,                   # { host = 3015; container = 80; } or null
  wgIp ? null,                   # WireGuard IP (e.g. "10.0.0.6") — required if port is set
  networkName ? "dev_network",   # docker network to join
  networkExternal ? true,        # is it an external network?

  # Container
  container_name ? name,
  environment ? null,
  env_file ? [],
  volumes ? [],

  # Health
  healthcheck ? null,

  # Optional overrides (passed through to mkService)
  extraServiceArgs ? {},

  # Compose-level extras
  extraVolumes ? {},             # named volumes { vol_name = { driver = "local"; }; }
}:

let
  portList = if port == null then []
    else if wgIp != null then [ "${wgIp}:${toString port.host}:${toString port.container}" ]
    else [ "${toString port.host}:${toString port.container}" ];

  networkDef = {
    ${networkName} = { external = networkExternal; }
      // (if networkExternal then { name = networkName; } else {});
  };
in {
  services.${name} = docker.mkService ({
    inherit name image container_name environment env_file volumes healthcheck;
    ports = portList;
    networks = [ networkName ];
  } // extraServiceArgs);

  networks = networkDef;
  volumes = extraVolumes;
}
