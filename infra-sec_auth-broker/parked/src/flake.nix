{
  description = "Auth broker (oauth2-proxy) -- Google + GitHub sign-in, owner email only (#1066)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];
    buildJson = builtins.fromJSON (builtins.readFile ../build.json);
    container = buildJson;
    engine = import ../../_shared/engine.nix;
    lib = nixpkgs.lib;
    # The allowlist file is rendered from build.json -- the single source.
    allowedEmails = lib.concatStringsSep "\n" buildJson.auth_broker.allowed_emails + "\n";
  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = engine {
        inherit pkgs buildJson container;
        srcDir      = ./.;
        templates   = [ { name = "allowed-emails.txt"; text = allowedEmails; } ];
        composeSpec = import ./compose.nix { inherit buildJson container; };
        title       = "Auth broker";
      };
    });
  };
}
