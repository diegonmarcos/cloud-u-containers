# compose.nix — pure attrset describing docker-compose.yml for languagetool.
# engine.nix serialises it via lib.generators.toYAML, merging compose-defaults.json.
#
# LanguageTool runs in rules-only mode (no n-grams).
#
# N-GRAMS (DEFERRED — ~24 GB data):
#   To enable: add volume "ngrams:/ngrams:ro" + env languageModel="/ngrams".
#   Download: https://languagetool.org/download/ngram-data/  (one .zip per language)
#   Install on oci-apps: extract to /opt/languagetool/ngrams/<lang>/, declare named volume.
{ buildJson, container }:

let
  app = buildJson.containers.app;
in
{
  services = {
    languagetool = {
      image          = app.image;
      container_name = app.container_name;
      env_file       = [];
      environment = {
        # Java heap cap — keeps the JVM within the container mem_limit.
        Java_Xmx = "2g";
        # N-GRAMS HOOK (disabled):
        # languageModel = "/ngrams";
      };
      ports = [ "${toString app.port}:${toString app.port}" ];
      volumes = app.volumes;
      deploy = {
        resources = {
          limits = {
            memory = app.resources.mem_limit;
          };
          reservations = {
            memory = app.resources.mem_reservation;
          };
        };
      };
      logging = {
        driver = "json-file";
        options = {
          max-size = "1m";
          max-file = "3";
        };
      };
    };
  };

  volumes = {
    languagetool_data = {};
    # N-GRAMS HOOK (disabled):
    # ngrams = {
    #   driver = "local";
    #   driver_opts = {
    #     type  = "none";
    #     o     = "bind";
    #     device = "/opt/languagetool/ngrams";
    #   };
    # };
  };
}
