{
  description = "mautrix-whatsapp bridge for Continuwuity — dist layout v2 (flake as orchestrator)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    buildJson = builtins.fromJSON (builtins.readFile ../build.json);
    container = builtins.fromJSON (builtins.readFile ./build-mautrix-whatsapp.json);

    engine = import ../../_shared/engine.nix;
    lib    = nixpkgs.lib;

    base_domain = "diegonmarcos.com";

    svc  = container.services;
    self_ = svc."matrix-mautrix-whatsapp";
    hs    = svc."matrix-continuwuity";

    # Non-secret substitution vars. Tokens stay as ${AS_TOKEN}/${HS_TOKEN}
    # placeholders in the .tpl — injected from .secrets by the pre_hook at
    # deploy, never baked into the committed dist/configs output.
    vars = {
      HOMESERVER_ADDRESS  = "http://${hs.ip}:${toString hs.ports.app}";
      DOMAIN              = base_domain;
      APPSERVICE_ADDRESS  = "http://${self_.ip}:${toString buildJson.ports.app}";
      APPSERVICE_HOSTNAME = self_.ip;
      APPSERVICE_PORT     = toString buildJson.ports.app;
      ADMIN_USER          = "@diego:${base_domain}";
      DB_URI              = "file:/data/mautrix-whatsapp.db?_txlock=immediate";
    };

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = engine {
        inherit pkgs buildJson container;
        srcDir = ./.;
        templates = [
          { name = "config.yaml";       inherit vars; }
          { name = "registration.yaml"; inherit vars; }
        ];
        extraAssets = [ ./assets/compose-pre-hook.sh ];
        composeSpec = import ./compose.nix { inherit buildJson container base_domain; };
        title = "mautrix-whatsapp Bridge";
      };
    });
  };
}
