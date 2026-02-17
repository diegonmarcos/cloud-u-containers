{ config, pkgs, lib, ... }:

{
  home.file.".local/share/docker-service/docker.service".text = ''
    [Unit]
    Description=Docker Application Container Engine (nix)
    After=network-online.target
    Wants=network-online.target

    [Service]
    Type=notify
    ExecStart=__DOCKERD_PATH__
    ExecReload=/bin/kill -s HUP $MAINPID
    Restart=always
    RestartSec=5
    LimitNOFILE=infinity
    LimitNPROC=infinity
    LimitCORE=infinity
    Delegate=yes
    KillMode=process

    [Install]
    WantedBy=multi-user.target
  '';

  home.activation.dockerService = lib.hm.dag.entryAfter ["linkGeneration"] ''
    DOCKER_LOG="[docker-service]"

    # Find sudo (not in PATH during home-manager activation)
    SUDO=""
    for p in /usr/bin/sudo /run/wrappers/bin/sudo /usr/local/bin/sudo; do
      [ -x "$p" ] && SUDO="$p" && break
    done
    if [ -z "$SUDO" ]; then
      echo "$DOCKER_LOG WARNING: sudo not found — skipping docker service setup"
      exit 0
    fi

    # Find dockerd from nix profile
    DOCKERD=""
    for p in $HOME/.nix-profile/bin/dockerd /nix/var/nix/profiles/default/bin/dockerd /usr/bin/dockerd; do
      [ -x "$p" ] && DOCKERD="$p" && break
    done
    if [ -z "$DOCKERD" ]; then
      echo "$DOCKER_LOG WARNING: dockerd not found — skipping docker service setup"
      exit 0
    fi

    # Read template and inject dockerd path
    TEMPLATE="$HOME/.local/share/docker-service/docker.service"
    if [ ! -f "$TEMPLATE" ]; then
      echo "$DOCKER_LOG WARNING: template not found at $TEMPLATE"
      exit 0
    fi

    NEW_UNIT=$(sed "s|__DOCKERD_PATH__|$DOCKERD|" "$TEMPLATE")

    # Compare with current
    CURRENT=""
    if $SUDO test -f /etc/systemd/system/docker.service; then
      CURRENT=$($SUDO cat /etc/systemd/system/docker.service 2>/dev/null || true)
    fi

    if [ "$NEW_UNIT" = "$CURRENT" ]; then
      echo "$DOCKER_LOG docker.service unchanged — skipping"
    else
      echo "$DOCKER_LOG docker.service changed — deploying"
      echo "$NEW_UNIT" | $SUDO tee /etc/systemd/system/docker.service > /dev/null
      $SUDO systemctl daemon-reload
      if $SUDO systemctl is-active docker >/dev/null 2>&1; then
        $SUDO systemctl restart docker
        echo "$DOCKER_LOG Docker restarted"
      else
        $SUDO systemctl enable docker
        $SUDO systemctl start docker
        echo "$DOCKER_LOG Docker enabled and started"
      fi
    fi
  '';
}
