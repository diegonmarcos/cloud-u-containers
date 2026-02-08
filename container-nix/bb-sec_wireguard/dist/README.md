# WireGuard - Native Deployment

WireGuard runs NATIVELY on all VMs, not in Docker containers.
See b_infra/vm_*/1.os/wireguard-wg0.conf for actual configs.

## Mesh Topology

    GCP Hub (10.0.0.1) - 35.226.147.64:51820
        |
        +-- Oracle Flex  (10.0.0.2) - 144.24.196.72:51820
        +-- Oracle Micro1 (10.0.0.3) - 130.110.251.193:51820
        +-- Oracle Micro2 (10.0.0.4) - 129.151.228.66:51820
        +-- Local Machine (10.0.0.5) - dynamic IP

All peers connect to GCP Hub, which routes traffic between them.
