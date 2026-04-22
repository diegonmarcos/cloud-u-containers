{
  description = "ntfy Push Notifications + syslog-bridge + github-rss — dist layout v2";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    # ── Data sources (declarative JSON) ────────────────────────────
    buildJson   = builtins.fromJSON (builtins.readFile ../build.json);
    cNtfy       = (builtins.fromJSON (builtins.readFile ./build-ntfy.json)).container;
    cSyslog     = (builtins.fromJSON (builtins.readFile ./build-syslog-bridge.json)).container;
    cGithubRss  = (builtins.fromJSON (builtins.readFile ./build-github-rss.json)).container;
    usersJson   = (builtins.fromJSON (builtins.readFile ./users.json)).users;

    engine = import ../../_shared/engine.nix;
    lib    = nixpkgs.lib;

    # ── users.json → init.sh @USER_BLOCKS@ ─────────────────────────
    # Each user becomes two shell lines: add (idempotent, may fail if
    # exists) + change-pass (updates if present). Role flag only for admins.
    mkUserBlock = u: let
      pw    = "$" + u.password_env;   # literal shell var reference
      role  = if u.role == "admin" then "--role=admin " else "";
    in
      "NTFY_PASSWORD=\"${pw}\" ntfy user add ${role}${u.username} 2>/dev/null || true\n"
      + "NTFY_PASSWORD=\"${pw}\" ntfy user change-pass ${u.username} 2>/dev/null || true";

    userBlocks = lib.concatMapStringsSep "\n" mkUserBlock usersJson;

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = engine {
        inherit pkgs buildJson;
        container = { container = cNtfy; };  # engine expects .container subkey
        srcDir = ./.;
        templates = [
          {
            name = "server.yml";
            vars = {
              DOMAIN = buildJson.domain;
              PORT   = toString buildJson.ports.app;
            };
          }
          {
            name = "init.sh";
            vars = {
              USER_BLOCKS = userBlocks;
            };
          }
        ];
        composeSpec = import ./compose.nix {
          inherit buildJson cNtfy cSyslog cGithubRss;
        };
        extraAssets = [
          ./code/syslog-to-ntfy.py
          ./code/github-rss-to-ntfy.py
          ./code/topic-scanner.py
        ];
        title = "ntfy Push Notifications + syslog-bridge + github-rss";
      };
    });
  };
}
