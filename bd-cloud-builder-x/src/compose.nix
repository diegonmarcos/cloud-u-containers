# compose.nix — docker-compose spec for cloud-builder-x (CI/CD builder image).
# This service is on-demand: the compose spec is only used when the builder
# image is launched as a persistent container on oci-apps. engine.nix
# serialises this attrset via lib.generators.toYAML and merges
# compose-defaults.json into every service.
{ buildJson, container }:

let
  app = buildJson.containers.app;
  binariesImage = "${buildJson.registry}/cloud-builder-x-deb-nixhm:latest";
in
{
  services = {
    cloud-builder = {
      image = binariesImage;
      container_name = app.container_name;
      network_mode = "host";
      volumes = [
        "/var/run/docker.sock:/var/run/docker.sock"
        "\${HOME}/.ssh:/mnt/host-ssh:ro"
        "\${HOME}/.config/sops:/mnt/host-sops:ro"
        "\${HOME}/.config/gh:/mnt/host-gh:ro"
        "\${HOME}/git/vault/A0_keys/providers/github:/home/diego/git/vault/A0_keys/providers/github:ro"
        "\${HOME}/.docker/config.json:/root/.docker/config.json:ro"
      ];
      environment = [
        "GITHUB_TOKEN"
        "GITHUB_ACTOR"
        "GITHUB_ACTIONS"
        "GITHUB_EVENT_NAME"
        "GITHUB_REPOSITORY"
        "GITHUB_RUN_ID"
        "GITHUB_SHA"
        "SSH_KEY"
        "SSH_HOST"
        "SSH_USER"
        "SSH_ALIAS"
        "SOPS_AGE_KEY"
        "WG_PRIVATE_KEY"
        "CHANGED_DIRS"
        "OCI_SSH_KEY"
        "GCP_PROXY_SSH_KEY"
        "GCP_T4_SSH_KEY"
      ];
      deploy.resources = {
        limits       = { memory = "2G"; cpus = "2.0"; };
        reservations = { memory = "256M"; };
      };
    };
  };
}
