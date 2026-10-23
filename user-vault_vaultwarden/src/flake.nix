{
  description = "Vaultwarden (Bitwarden-compatible) Password Manager — dist layout v2 (flake as orchestrator)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    # ── Data sources (declarative JSON) ────────────────────────────
    buildJson = builtins.fromJSON (builtins.readFile ../build.json);
    container = builtins.fromJSON (builtins.readFile ./build-vaultwarden.json);

    engine = import ../../_shared/engine.nix;
    lib    = nixpkgs.lib;

    # base_domain derived from service domain: "vault.example.com" → "example.com"
    base_domain =
      lib.concatStringsSep "." (lib.drop 1 (lib.splitString "." buildJson.domain));

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = engine {
        inherit pkgs buildJson container;
        srcDir = ./.;
        templates = [
          # Renders dist/configs/init.sh from templates/init.sh.tpl with
          # @BASE_DOMAIN@ substituted. Mounted at /config/init.sh and run as the
          # container entrypoint (see compose.nix) to assert the operator's
          # verified_at on every boot — mirrors bb-sec_authelia.
          { name = "init.sh"; vars = { BASE_DOMAIN = base_domain; }; }
          # Cloud Vault brand (#1139): brand.sh patches a tmpfs copy of the web vault;
          # brand/ is TEMPLATES_FOLDER (scss, admin and email overrides) plus the artwork.
          { name = "brand.sh"; }
          { name = "brand/icon.svg"; }
          { name = "brand/logo.svg"; }
          { name = "brand/logo-white.svg"; }
          { name = "brand/i16.png.b64"; }
          { name = "brand/i32.png.b64"; }
          { name = "brand/i150.png.b64"; }
          { name = "brand/i180.png.b64"; }
          { name = "brand/i192.png.b64"; }
          { name = "brand/i512.png.b64"; }
          { name = "brand/scss/user.vaultwarden.scss.hbs"; }
          { name = "brand/admin/base.hbs"; }
          { name = "brand/email/email_header.hbs"; }
          { name = "brand/email/email_footer_text.hbs"; }
        ];
        composeSpec = import ./compose.nix { inherit buildJson container base_domain; };
        title = "Vaultwarden Password Manager";
      };
    });
  };
}
