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

    # Mail-specific tools
    swaks  # SMTP testing
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

      # Mail-specific aliases
      mailogs = "docker logs -f mailu-front-1";
      mailqueue = "docker exec -it mailu-smtp-1 postqueue -p";

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
        echo -e '\033[1;31m[BLOCKED]\033[0m "$1" is disabled on this VM.'
        echo '  This environment is managed declaratively with Nix Home Manager.'
        echo '  Flake: git/cloud/a_solutions/home-manager/'
        echo '  To add packages: edit the .nix file, then deploy with:'
        echo '    ./build.sh switch'
        echo '  Do NOT install packages imperatively.'
        return 1
      }

      # Custom prompt
      PS1='\[\033[01;32m\]\u@oci-mail\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '

      # History settings
      export HISTSIZE=10000
      export HISTFILESIZE=20000
      export HISTCONTROL=ignoredups:erasedups

      # Age key for sops
      [ -f "$HOME/.config/sops/age/keys.txt" ] && export SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt"

      # WireGuard mesh IP
      export WIREGUARD_IP="10.0.0.3"
    '';
  };

  home.sessionVariables = {
    EDITOR = "vim";
    VISUAL = "vim";
  };

  xdg.enable = true;
}
