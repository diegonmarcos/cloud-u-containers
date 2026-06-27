# compose.nix — GHA self-hosted runner on oci-apps (ARM64).
# No port/proxy — purely outbound. Registers to build.json.gha.repo_url.
# Secrets: .secrets must contain ACCESS_TOKEN (GitHub classic PAT, repo scope).
{ buildJson, container }:

let
  app = buildJson.containers.app;
  gha = buildJson.gha;
in
{
  services = {
    gha-runner = {
      image = app.image;
      container_name = app.container_name;
      restart = "always";
      network_mode = "host";
      env_file = [ ".secrets" ];
      environment = {
        REPO_URL        = gha.repo_url;
        RUNNER_NAME     = gha.runner_name;
        LABELS          = gha.labels;
        RUNNER_WORKDIR  = gha.runner_workdir;
        RUNNER_SCOPE    = "repo";
        EPHEMERAL       = "false";
      };
      volumes = [
        "/var/run/docker.sock:/var/run/docker.sock"
        "./work:/tmp/runner/work"
      ];
      deploy.resources = {
        limits       = { memory = "4G"; cpus = "3.0"; };
        reservations = { memory = "256M"; };
      };
    };
  };
}
