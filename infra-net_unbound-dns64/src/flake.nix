{
  description = "Unbound DNS64 — NAT64 companion resolver for oci-analytics";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

  outputs = { self, nixpkgs }:
  let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];
    engine  = import ../../_shared/engine.nix;
    buildJson = builtins.fromJSON (builtins.readFile ../build.json);
    container = builtins.fromJSON (builtins.readFile ./build-unbound-dns64.json);

    # ── Shared NAT64 constant ────────────────────────────────────────────────
    # Real Oracle /96 carved from oci-analytics' /64 (2603:c026:c104:8f00::/64).
    # Search token: NAT64_PREFIX
    nat64Prefix = "2603:c026:c104:8f00:ff9b::/96";

    # ── Unbound DNS64 config ─────────────────────────────────────────────────
    # module-config must list dns64 before iterator so Unbound synthesises AAAA
    # records for A-only names.  Clients that receive a synthesised AAAA then
    # send IPv6 packets to the NAT64 prefix; Tayga translates them to IPv4.
    #
    # Access-control: closed to the world, open only to:
    #   • wg0 mesh  10.0.0.0/24
    #   • wg-public 10.1.0.0/24
    #   • OCI /64   2603:c026:c104:8f00::/64 (oci-analytics' Oracle block)
    unboundConf = ''
      # Managed by home-manager / nix flake (unbound-dns64) — do not edit
      server:
        verbosity: 1
        interface: ::0@53
        interface: 10.1.0.1@53

        # Module order: dns64 must run before iterator
        module-config: "dns64 iterator"

        dns64-prefix: ${nat64Prefix}

        # ── Access control — NOT an open resolver ──────────────────────────
        # Deny everything first, then explicitly allow trusted ranges.
        access-control: ::/0 refuse
        access-control: 127.0.0.0/8 allow
        access-control: 10.0.0.0/24 allow
        access-control: 10.1.0.0/24 allow
        # oci-analytics' real Oracle /64
        access-control: 2603:c026:c104:8f00::/64 allow

        do-ip4: yes
        do-ip6: yes
        do-udp: yes
        do-tcp: yes

        # Do not expose local network info
        hide-identity: yes
        hide-version: yes

        # Cache sizing for a small resolver
        msg-cache-size: 8m
        rrset-cache-size: 16m

        # Logging — structured, no timestamps (docker adds them)
        use-syslog: no
        log-queries: no

      # ── Forward zone — upstream is the internal Hickory DNS on wg0 ──────
      # Hickory handles .app / .db / diegonmarcos.com zones AND forwards
      # everything else to 1.1.1.1/8.8.8.8.  Using Hickory means WG-internal
      # FQDNs also resolve for NAT64 clients.
      forward-zone:
        name: "."
        forward-addr: 10.0.0.1@53
    '';

    templates = [
      { name = "unbound.conf"; text = unboundConf; }
    ];

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = engine {
        inherit pkgs buildJson container templates;
        srcDir = ./.;
        composeSpec = import ./compose.nix { inherit buildJson container; };
        title = "Unbound DNS64";
      };
    });
  };
}
