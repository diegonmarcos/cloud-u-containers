{ config, pkgs, lib, ... }:

{
  imports = [ (import ./wireguard.nix { vmName = "gcp-proxy"; }) ];
  # Home Manager needs a bit of information about you and the paths it should manage
  home.username = "diego";
  home.homeDirectory = "/home/diego";

  # This value determines the Home Manager release that your configuration is compatible with
  home.stateVersion = "24.11";

  # Let Home Manager install and manage itself
  programs.home-manager.enable = true;

  # Essential development and deployment tools
  home.packages = with pkgs; [
    # Secrets management
    sops
    age

    # JSON/YAML processing
    jq
    yq-go  # yq (go implementation)

    # File transfer
    rsync
    rclone

    # Container tools (if not system-installed)
    # docker
    # docker-compose

    # Network tools
    curl
    wget
    netcat

    # System tools
    htop
    btop
    ncdu
    tree

    # Git and version control
    git
    gh  # GitHub CLI

    # Text processing
    ripgrep
    fd
    bat

    # Compression
    gzip
    unzip
    zip

    # Monitoring
    lsof
  ];

  # Git configuration
  programs.git = {
    enable = true;
    userName = "Diego Marcos";
    userEmail = "diegonmarcos@gmail.com";
    extraConfig = {
      init.defaultBranch = "main";
      pull.rebase = false;
    };
  };

  # Bash configuration
  programs.bash = {
    enable = true;
    shellAliases = {
      ll = "ls -lah";
      ".." = "cd ..";
      "..." = "cd ../..";
      dps = "docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'";
      dlogs = "docker logs -f";
      dstop = "docker stop";
      drestart = "docker restart";

      # Block imperative package managers
      apt = "_nix_block apt";
      apt-get = "_nix_block apt-get";
      dpkg = "_nix_block dpkg";
      npm = "_nix_block npm";
      yarn = "_nix_block yarn";
      pnpm = "_nix_block pnpm";
      pip = "_nix_block pip";
      pip3 = "_nix_block pip3";
      pipx = "_nix_block pipx";
      snap = "_nix_block snap";
      brew = "_nix_block brew";
      nix-env = "_nix_block nix-env";
    };
    bashrcExtra = ''
      # Block imperative package managers — use declarative Nix Home Manager
      _nix_block() {
        echo -e "\033[1;31m[BLOCKED]\033[0m \"$1\" is disabled on this VM."
        echo '  This environment is managed declaratively with Nix Home Manager.'
        echo '  Flake: git/cloud/a_solutions/home-manager/'
        echo '  To add packages: edit the .nix file, then deploy with:'
        echo '    ./build.sh switch'
        echo '  Do NOT install packages imperatively.'
        return 1
      }

      # Custom prompt
      PS1='\[\033[01;32m\]\u@gcp-proxy\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '

      # History settings
      export HISTSIZE=10000
      export HISTFILESIZE=20000
      export HISTCONTROL=ignoredups:erasedups

      # Age key for sops (if exists)
      [ -f "$HOME/.config/sops/age/keys.txt" ] && export SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt"
    '';
  };

  # Environment variables
  home.sessionVariables = {
    EDITOR = "vim";
    VISUAL = "vim";
  };

  # XDG directories
  xdg.enable = true;
}
