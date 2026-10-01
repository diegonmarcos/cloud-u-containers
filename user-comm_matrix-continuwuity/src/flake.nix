{
  description = "Continuwuity Matrix homeserver (conduwuit fork) — dist layout v2 (flake as orchestrator)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    # ── Data sources (declarative JSON) ────────────────────────────
    buildJson = builtins.fromJSON (builtins.readFile ../build.json);
    container = builtins.fromJSON (builtins.readFile ./build-continuwuity.json);

    engine = import ../../_shared/engine.nix;
    lib    = nixpkgs.lib;

    # base_domain derived from service domain: "matrix.example.com" → "example.com"
    base_domain =
      lib.concatStringsSep "." (lib.drop 1 (lib.splitString "." buildJson.domain));

    # Appservice registrations this homeserver installs at startup. Each entry
    # names a bridge's service dir; its registration is the file that bridge's
    # own deploy renders from ITS sops pair (mautrix pre-hook → data/), so the
    # tokens are declared once and never copied here.
    registrations = map (d:
      (builtins.fromJSON (builtins.readFile (../.. + "/${d}/build.json"))).deploy.remote_path
        + "/data/registration.yaml"
    ) (buildJson.appservices or []);

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = engine {
        inherit pkgs buildJson container;
        srcDir = ./.;
        templates = [
          { name = "appservice-registrations.list";
            text = lib.concatMapStrings (r: r + "\n") registrations; }
        ];
        extraAssets = [ ./assets/compose-pre-hook.sh ];
        composeSpec = import ./compose.nix { inherit buildJson container base_domain; };
        title = "Continuwuity Matrix Homeserver";
      };
    });
  };
}
