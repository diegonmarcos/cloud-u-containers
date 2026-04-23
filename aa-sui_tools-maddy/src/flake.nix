{
  description = "Maddy Mail Server — declarative all-in-one SMTP/IMAP (dist layout v2, flake as orchestrator)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    # ── Data sources (declarative JSON) ────────────────────────────
    buildJson = builtins.fromJSON (builtins.readFile ../build.json);
    container = builtins.fromJSON (builtins.readFile ./build-maddy.json);

    engine = import ../../_shared/engine.nix;
    lib    = nixpkgs.lib;

    # base_domain derived from service domain: "mail.example.com" → "example.com"
    base_domain =
      lib.concatStringsSep "." (lib.drop 1 (lib.splitString "." buildJson.domain));

    # Per-port bind addresses: reads extra_ports[].bind from build.json and
    # generates BIND_465, BIND_587, BIND_993, BIND_143 etc. for template substitution.
    # Fallback to 0.0.0.0 if a port has no bind (backward-compatible).
    bindVars = builtins.listToAttrs (
      map (ep: { name = "BIND_${toString ep.port}"; value = ep.bind or "0.0.0.0"; })
          (buildJson.containers.app.extra_ports or [])
    );

    maddyConfVars = bindVars // {
      DOMAIN         = base_domain;
      MAIL_DOMAIN    = buildJson.domain;
      OCI_RELAY_HOST = buildJson.oci_relay.host;
      OCI_RELAY_PORT = buildJson.oci_relay.port;
    };

    initShVars = {
      BASE_DOMAIN = base_domain;
    };

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = engine {
        inherit pkgs buildJson container;
        srcDir = ./.;
        templates = [
          { name = "init.sh";       vars = initShVars; }
          { name = "maddy.conf.tpl"; vars = maddyConfVars; }
        ];
        # mail-filter.sh / mail-rules.json bind-mounted from dist/assets/;
        # cleanup-stale-mailboxes.sh + dedupe-inbox.sh run via lifecycle.ssh_run
        # on the VM host (see build.json#lifecycle).
        extraAssets = [
          ./mail-filter.sh
          ./mail-rules.json
          ./cleanup-stale-mailboxes.sh
          ./dedupe-inbox.sh
          ./dedupe-folders.sh
        ];
        composeSpec = import ./compose.nix { inherit buildJson container base_domain; };
        title = "Maddy Mail Server";
      };
    });
  };
}
