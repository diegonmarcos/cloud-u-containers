# cloud-builder.nix — Home Manager module for the CI/CD builder image
# Reads configJson via extraSpecialArgs (from config.json deps section)
# Produces identical package set as devShells.default
{ config, pkgs, lib, configJson, ... }:

let
  sysDeps = configJson.deps.system;
  buildDeps = configJson.deps.build or {};
  optDeps = configJson.deps.optional;
  nodeDeps = configJson.deps.node.required or [];

  # Map config.json nix package names to actual nixpkgs attributes
  # Handles dotted paths like "nodePackages.typescript"
  resolvePkg = nixStr:
    if nixStr == null then null
    else if builtins.match ".*\\..*" nixStr != null then
      let parts = builtins.split "\\." nixStr;
      in pkgs.${builtins.elemAt parts 0}.${builtins.elemAt parts 2}
    else pkgs.${nixStr};

  # Collect all nix packages from system + build + optional deps
  collectPkgs =
    let
      extract = attrs: builtins.filter (p: p != null) (
        builtins.attrValues (builtins.mapAttrs (_: v: resolvePkg (v.nix or null)) attrs)
      );
    in extract sysDeps ++ extract buildDeps ++ extract optDeps;

  nodejs = pkgs.nodejs_20;

in {
  home.username = "root";
  home.homeDirectory = "/root";
  home.stateVersion = "24.11";
  programs.home-manager.enable = true;

  home.packages = collectPkgs ++ (with pkgs; [
    # Container tools (not in config.json but needed by builder)
    docker-client
    docker-compose
    docker-buildx

    # Shell
    fish
    bash
    # Note: nix itself is installed by the Dockerfile base layer, NOT here
    # Adding it here causes profile conflicts with nix-env-installed nix
  ]);

  # Fish shell
  programs.fish = {
    enable = true;
    interactiveShellInit = ''
      set -gx NODE_PATH "$HOME/.node_modules/node_modules"
      fish_add_path "$HOME/.node_modules/node_modules/.bin"
    '';
  };

  # Git
  programs.git = {
    enable = true;
    extraConfig = {
      safe.directory = "*";
    };
  };

  # npm global packages — installed at activation time
  home.activation.installNodeDeps = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    NM_DIR="$HOME/.node_modules"
    mkdir -p "$NM_DIR"
    export PATH="${nodejs}/bin:$PATH"
    PKGS="${builtins.concatStringsSep " " nodeDeps}"
    if [ -n "$PKGS" ]; then
      cd "$NM_DIR"
      NEEDS_INSTALL=false
      for pkg in $PKGS; do
        [ ! -d "node_modules/$pkg" ] && NEEDS_INSTALL=true && break
      done
      if [ "$NEEDS_INSTALL" = "true" ]; then
        ${nodejs}/bin/npm install --silent $PKGS 2>/dev/null || true
      fi
      cd - >/dev/null
    fi
  '';

  home.sessionVariables = {
    NODE_PATH = "$HOME/.node_modules/node_modules";
    SOPS_AGE_KEY_FILE = "$HOME/.config/sops/age/keys.txt";
  };

  home.sessionPath = [
    "$HOME/.node_modules/node_modules/.bin"
    "$HOME/.nix-profile/bin"
  ];
}
