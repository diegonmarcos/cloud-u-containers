# ╔══════════════════════════════════════════════════════════════════╗
# ║ Template: Dockerfile-built service                              ║
# ║ Usage: templates.buildApp { name; port; wgIp; ... }            ║
# ║                                                                  ║
# ║ Returns: { services, networks, volumes } ready for mkCompose    ║
# ╚══════════════════════════════════════════════════════════════════╝
#
# Covers: alerts-api, orchestrator, c3-infra-mcp-api, c3-services-mcp-api,
#         google-workspace-mcp, mailu-mcp, mattermost-mcp, and similar
#         services built from a Dockerfile in the dist/ directory.

docker:

{
  # Required
  name,                          # service name

  # Build
  buildContext ? ".",             # path to Dockerfile context
  dockerfile ? null,             # explicit Dockerfile path (null = default)
  buildImage ? "${name}:local",  # image tag after build

  # Networking
  port ? null,                   # { host; container; }
  wgIp ? null,
  networkName ? "npm_default",   # default for build services
  networkExternal ? true,

  # Container
  container_name ? name,
  environment ? null,
  env_file ? [],
  volumes ? [],
  healthcheck ? null,

  # Resources
  memLimit ? null,
  memReservation ? null,
  cpuLimit ? null,

  # Optional overrides
  extraServiceArgs ? {},
  extraVolumes ? {},
}:

let
  buildVal = if dockerfile != null
    then { context = buildContext; inherit dockerfile; }
    else buildContext;

  portList = if port == null then []
    else if wgIp != null then [ "${wgIp}:${toString port.host}:${toString port.container}" ]
    else [ "${toString port.host}:${toString port.container}" ];

in {
  services.${name} = docker.mkService ({
    inherit name container_name environment env_file volumes healthcheck
            memLimit memReservation cpuLimit;
    image = buildImage;
    build = buildVal;
    ports = portList;
    networks = [ networkName ];
  } // extraServiceArgs);

  networks.${networkName} = { external = networkExternal; }
    // (if networkExternal then { name = networkName; } else {});

  volumes = extraVolumes;
}
