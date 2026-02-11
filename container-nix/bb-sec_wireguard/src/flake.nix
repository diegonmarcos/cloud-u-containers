# NOTE: Canonical topology is now home-manager/wireguard.nix
# This flake kept for bootstrap (initial key deploy) and key rotation only.
{
  description = "WireGuard VPN mesh - bootstrap and key rotation";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    # ── Mesh topology ────────────────────────────────────────────────────
    # Hub-and-spoke: all spokes connect to GCP hub, hub routes between them
    topology = {
      gcp-proxy = {
        address    = "10.0.0.1";
        endpoint   = "35.226.147.64";
        port       = 51820;
        publicKey  = "GGZzgZDrOwvw1Th8iKWKeOOBgh+UvAjnmdi1iE9E1Hk=";
        role       = "hub";
      };
      oci-flex = {
        address    = "10.0.0.2";
        endpoint   = "144.24.196.72";
        port       = 51820;
        publicKey  = "uUtpR3frleNgOQvQcPvC0y5vWWtmRpJnIvWrqx9gYQU=";
        role       = "spoke";
      };
      oci-mail = {
        address    = "10.0.0.3";
        endpoint   = "130.110.251.193";
        port       = 51820;
        publicKey  = "1E7ofexq/gHZXnLNXFvpm9O6qtZDJD40IfSpHZ7Pezc=";
        role       = "spoke";
      };
      oci-analytics = {
        address    = "10.0.0.4";
        endpoint   = "129.151.228.66";
        port       = 51820;
        publicKey  = "DJTyVo/SYUUDI45brx15mcWxdzXPlIL7+/Y3Cb8AuTA=";
        role       = "spoke";
      };
      mobile = {
        address    = "10.0.0.5";
        endpoint   = null;  # dynamic IP, no config generated
        port       = null;
        publicKey  = "9nL3UbbPUVeU1LeMOjFn1e7u5UQnQGClQY5YsKxmpwo=";
        role       = "client";
      };
    };

    lib = nixpkgs.lib;

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

    # Spoke [Interface] — simple, no forwarding
    mkSpokeInterface = vm: ''
      [Interface]
      Address = ${vm.address}/24
      ListenPort = ${toString vm.port}
      PrivateKey = __PRIVKEY__
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
    mkHubConfig = let
      hub = topology.gcp-proxy;
      peers = lib.filterAttrs (n: _: n != "gcp-proxy") topology;
    in mkHubInterface hub
       + lib.concatStrings (lib.mapAttrsToList mkPeer peers);

    # Spoke config: interface + hub peer only
    mkSpokeConfig = name: let
      spoke = topology.${name};
      hub = topology.gcp-proxy;
    in mkSpokeInterface spoke
       + mkPeer "gcp-proxy" hub;

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = pkgs.runCommand "wireguard-configs" {} ''
        mkdir -p $out

        cat > $out/wg0-gcp-proxy.conf <<'CONF'
        ${mkHubConfig}
        CONF

        cat > $out/wg0-oci-flex.conf <<'CONF'
        ${mkSpokeConfig "oci-flex"}
        CONF

        cat > $out/wg0-oci-mail.conf <<'CONF'
        ${mkSpokeConfig "oci-mail"}
        CONF

        cat > $out/wg0-oci-analytics.conf <<'CONF'
        ${mkSpokeConfig "oci-analytics"}
        CONF

        # Strip leading whitespace from heredocs
        for f in $out/wg0-*.conf; do
          sed -i 's/^        //' "$f"
        done
      '';
    });
  };
}
