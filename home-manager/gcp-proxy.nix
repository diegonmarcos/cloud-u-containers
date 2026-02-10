{ config, pkgs, ... }:

{
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
    };
    bashrcExtra = ''
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
