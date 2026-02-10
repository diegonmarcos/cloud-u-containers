{ config, pkgs, ... }:

{
  home.username = "ubuntu";
  home.homeDirectory = "/home/ubuntu";
  home.stateVersion = "24.11";

  programs.home-manager.enable = true;

  home.packages = with pkgs; [
    # Secrets management
    sops
    age

    # JSON/YAML processing
    jq
    yq-go

    # File transfer
    rsync
    rclone

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
    gh

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
    iftop
  ];

  programs.git = {
    enable = true;
    userName = "Diego Marcos";
    userEmail = "diegonmarcos@gmail.com";
    extraConfig = {
      init.defaultBranch = "main";
      pull.rebase = false;
    };
  };

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
      dexec = "docker exec -it";
    };
    bashrcExtra = ''
      # Custom prompt with color
      PS1='\[\033[01;32m\]\u@oci-flex\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '

      # History settings
      export HISTSIZE=10000
      export HISTFILESIZE=20000
      export HISTCONTROL=ignoredups:erasedups

      # Age key for sops
      [ -f "$HOME/.config/sops/age/keys.txt" ] && export SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt"

      # WireGuard mesh IP
      export WIREGUARD_IP="10.0.0.2"
    '';
  };

  home.sessionVariables = {
    EDITOR = "vim";
    VISUAL = "vim";
  };

  xdg.enable = true;
}
