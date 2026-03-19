# ╔══════════════════════════════════════════════════════════════════╗
# ║ Template: Web app + PostgreSQL sidecar                          ║
# ║ Usage: templates.appDb { name; image; port; wgIp; db; ... }    ║
# ║                                                                  ║
# ║ Returns: { services, networks, volumes } ready for mkCompose    ║
# ╚══════════════════════════════════════════════════════════════════╝
#
# Covers: hedgedoc, etherpad, nocodb, and similar app+postgres pairs.
# The postgres service gets auto-healthcheck and the app depends on it.

docker:

{
  # Required
  name,                          # app service name (e.g. "hedgedoc")
  image,                         # app container image

  # Database
  db ? {},                       # override defaults below
  # db.image, db.user, db.name, db.container_name, db.service_name

  # Networking
  port ? null,                   # { host; container; }
  wgIp ? null,
  networkName ? "infra",
  networkExternal ? true,

  # App container
  container_name ? name,
  environment ? null,
  env_file ? [],
  volumes ? [],
  healthcheck ? null,

  # Optional overrides
  extraAppArgs ? {},
  extraDbArgs ? {},
  extraVolumes ? {},
}:

let
  # Database defaults
  dbServiceName = db.service_name or "${name}_postgres";
  dbContainerName = db.container_name or dbServiceName;
  dbImage = db.image or "postgres:16-alpine";
  dbUser = db.user or name;
  dbName = db.name or name;
  dbVolume = "${name}_postgres_data";

  portList = if port == null then []
    else if wgIp != null then [ "${wgIp}:${toString port.host}:${toString port.container}" ]
    else [ "${toString port.host}:${toString port.container}" ];

  networkDef = {
    ${networkName} = { external = networkExternal; }
      // (if networkExternal then { inherit (networkDef.${networkName}) name; } else {});
  } // { ${networkName} = { name = networkName; } // (if networkExternal then { external = true; } else {}); };

in {
  services.${name} = docker.mkService ({
    inherit name image container_name environment env_file volumes healthcheck;
    ports = portList;
    networks = [ networkName ];
    startAfter = [ dbServiceName ];
  } // extraAppArgs);

  services.${dbServiceName} = docker.mkService ({
    name = dbServiceName;
    image = dbImage;
    container_name = dbContainerName;
    volumes = [ "${dbVolume}:/var/lib/postgresql/data" ];
    environment = [
      "POSTGRES_USER=${dbUser}"
      "POSTGRES_PASSWORD=${dbUser}"
      "POSTGRES_DB=${dbName}"
      "PGDATA=/var/lib/postgresql/data/pgdata"
    ];
    networks = [ networkName ];
    healthcheck = {
      test = "['CMD-SHELL', 'pg_isready -U ${dbUser}']";
      interval = "10s";
      timeout = "5s";
      retries = 5;
    };
  } // extraDbArgs);

  networks.${networkName} = { external = networkExternal; }
    // (if networkExternal then { name = networkName; } else {});

  volumes = {
    ${dbVolume} = { driver = "local"; };
  } // extraVolumes;
}
