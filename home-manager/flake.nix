{
  description = "Home Manager configurations for cloud VMs";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
    home-manager = {
      url = "github:nix-community/home-manager/release-24.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, home-manager }: {
    # gcp-proxy (35.226.147.64) - e2-micro, 1GB RAM, Ubuntu
    homeConfigurations."diego@gcp-proxy" = home-manager.lib.homeManagerConfiguration {
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
      modules = [ ./gcp-proxy.nix ];
    };

    # oci-flex-0 (82.70.229.129) - Ampere ARM, 3 OCPUs / 16GB, Ubuntu
    homeConfigurations."ubuntu@oci-flex-0" = home-manager.lib.homeManagerConfiguration {
      pkgs = nixpkgs.legacyPackages.aarch64-linux;
      modules = [ ./oci-flex-0.nix ];
    };

    # oci-flex-1 (144.24.196.72) - Ampere ARM, 1 OCPU / 8GB, Ubuntu (Wake-on-Demand)
    homeConfigurations."ubuntu@oci-flex-1" = home-manager.lib.homeManagerConfiguration {
      pkgs = nixpkgs.legacyPackages.aarch64-linux;
      modules = [ ./oci-flex-1.nix ];
    };

    # oci-mail (130.110.251.193) - x86_64, 1GB RAM, Ubuntu
    homeConfigurations."ubuntu@oci-mail" = home-manager.lib.homeManagerConfiguration {
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
      modules = [ ./oci-mail.nix ];
    };

    # oci-analytics (129.151.228.66) - e2-micro, 1GB RAM, Ubuntu
    homeConfigurations."ubuntu@oci-analytics" = home-manager.lib.homeManagerConfiguration {
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
      modules = [ ./oci-analytics.nix ];
    };
  };
}
