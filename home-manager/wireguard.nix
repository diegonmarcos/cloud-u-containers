# WireGuard mesh configuration module for Home Manager
# Canonical topology — keys generated on-VM (private key never leaves machine)
{ vmName }:

{ config, lib, pkgs, ... }:

let
  # ── Mesh topology ──────────────────────────────────────────────────────
  # Hub-and-spoke: all spokes connect to GCP hub, hub routes between them
  topology = {
    gcp-proxy = {
      address   = "10.0.0.1";
      endpoint  = "35.226.147.64";
      port      = 51820;
      publicKey = "GGZzgZDrOwvw1Th8iKWKeOOBgh+UvAjnmdi1iE9E1Hk=";
      role      = "hub";
    };
    oci-flex = {
      address   = "10.0.0.2";
      endpoint  = "144.24.196.72";
      port      = 51820;
      publicKey = "uUtpR3frleNgOQvQcPvC0y5vWWtmRpJnIvWrqx9gYQU=";
      role      = "spoke";
    };
    oci-mail = {
      address   = "10.0.0.3";
      endpoint  = "130.110.251.193";
      port      = 51820;
      publicKey = "1E7ofexq/gHZXnLNXFvpm9O6qtZDJD40IfSpHZ7Pezc=";
      role      = "spoke";
    };
    oci-analytics = {
      address   = "10.0.0.4";
      endpoint  = "129.151.228.66";
      port      = 51820;
      publicKey = "DJTyVo/SYUUDI45brx15mcWxdzXPlIL7+/Y3Cb8AuTA=";
      role      = "spoke";
    };
    mobile = {
      address   = "10.0.0.5";
      endpoint  = null;
      port      = null;
      publicKey = "9nL3UbbPUVeU1LeMOjFn1e7u5UQnQGClQY5YsKxmpwo=";
      role      = "client";
    };
  };

  thisVm = topology.${vmName};

  # ── Config generators ────────────────────────────────────────────────

  # Hub [Interface] with iptables forwarding + masquerade
  mkHubInterface = vm: ''
    [Interface]
    Address = ${vm.address}/24
    ListenPort = ${toString vm.port}
    PrivateKey = __PRIVKEY__
    PostUp = iptables -I FORWARD -i wg0 -j ACCEPT; iptables -I FORWARD -o wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -s 10.0.0.0/24 -o wg0 -j MASQUERADE
    PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -D FORWARD -o wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -s 10.0.0.0/24 -o wg0 -j MASQUERADE
  '';

  # Spoke [Interface] — allow WireGuard traffic to reach Docker port mappings
  mkSpokeInterface = vm: ''
    [Interface]
    Address = ${vm.address}/24
    ListenPort = ${toString vm.port}
    PrivateKey = __PRIVKEY__
    PostUp = iptables -I FORWARD -i wg0 -j ACCEPT; iptables -I FORWARD -o wg0 -j ACCEPT
    PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -D FORWARD -o wg0 -j ACCEPT
  '';

  # [Peer] block for a given peer VM
  mkPeer = name: peer: ''

    [Peer]
    # ${name}
    PublicKey = ${peer.publicKey}
  '' + (if peer.endpoint != null then
    "Endpoint = ${peer.endpoint}:${toString peer.port}\n"
  else "") +
  (if peer.role == "client" then
    "AllowedIPs = ${peer.address}/32\n"
  else if peer.role == "hub" then
    "AllowedIPs = 10.0.0.0/24\n"
  else
    "AllowedIPs = ${peer.address}/32\n"
  ) + "PersistentKeepalive = 25\n";

  # Hub config: interface + ALL other peers
  mkHubConfig =
    let
      hub = topology.gcp-proxy;
      peers = lib.filterAttrs (n: _: n != "gcp-proxy") topology;
    in mkHubInterface hub
       + lib.concatStrings (lib.mapAttrsToList mkPeer peers);

  # Spoke config: interface + hub peer only
  mkSpokeConfig = name:
    let
      spoke = topology.${name};
      hub = topology.gcp-proxy;
    in mkSpokeInterface spoke
       + mkPeer "gcp-proxy" hub;

  # Select the right config for this VM
  wgTemplate =
    if thisVm.role == "hub" then mkHubConfig
    else mkSpokeConfig vmName;

in {
  home.sessionVariables.WIREGUARD_IP = thisVm.address;

  programs.bash.bashrcExtra = ''
    # WireGuard mesh IP (also in home.sessionVariables for login shells)
    export WIREGUARD_IP="${thisVm.address}"
  '';

  home.activation.wireguard = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    WG_CONF="/etc/wireguard/wg0.conf"
    WG_LOG_PREFIX="[wireguard]"

    # 1. Read existing private key
    PRIVKEY=""
    if [ -f "$WG_CONF" ]; then
      PRIVKEY=$(sudo grep -oP '(?<=PrivateKey = ).+' "$WG_CONF" 2>/dev/null || true)
    fi

    if [ -z "$PRIVKEY" ]; then
      echo "$WG_LOG_PREFIX No existing PrivateKey in $WG_CONF — generating new keypair"
      WG_BIN=""
      for p in /run/current-system/sw/bin/wg /usr/bin/wg /usr/local/bin/wg; do
        [ -x "$p" ] && WG_BIN="$p" && break
      done
      if [ -z "$WG_BIN" ]; then
        echo "$WG_LOG_PREFIX ERROR: wg (wireguard-tools) not found — cannot generate keypair"
        exit 1
      fi
      PRIVKEY=$($WG_BIN genkey)
      PUBKEY=$(echo "$PRIVKEY" | $WG_BIN pubkey)
      echo "$WG_LOG_PREFIX Generated new keypair for ${vmName}"
      echo "$WG_LOG_PREFIX PUBLIC KEY: $PUBKEY"
      echo "$WG_LOG_PREFIX *** Update wireguard.nix topology publicKey for ${vmName}, then redeploy all VMs ***"
      sudo mkdir -p /etc/wireguard
    fi

    # 2. Generate new config from template with injected key
    TEMPLATE=$(cat <<'WGTEMPLATE'
    ${wgTemplate}
    WGTEMPLATE
    )
    # Strip leading whitespace from heredoc
    TEMPLATE=$(echo "$TEMPLATE" | sed 's/^    //')
    NEW_CONF=$(echo "$TEMPLATE" | sed "s|__PRIVKEY__|$PRIVKEY|")

    # 3. Compare with current live config
    CURRENT=""
    if [ -f "$WG_CONF" ]; then
      CURRENT=$(sudo cat "$WG_CONF" 2>/dev/null || true)
    fi

    if [ "$NEW_CONF" = "$CURRENT" ]; then
      echo "$WG_LOG_PREFIX wg0.conf unchanged — skipping"
    else
      echo "$WG_LOG_PREFIX wg0.conf changed — deploying"
      echo "$NEW_CONF" | sudo tee "$WG_CONF" > /dev/null
      sudo chmod 600 "$WG_CONF"
      sudo chown root:root "$WG_CONF"
      if sudo systemctl is-active wg-quick@wg0 >/dev/null 2>&1; then
        sudo systemctl restart wg-quick@wg0
        echo "$WG_LOG_PREFIX wg-quick@wg0 restarted"
      else
        echo "$WG_LOG_PREFIX wg-quick@wg0 not active — config written, start manually"
      fi
    fi
  '';
}
