# compose.nix — GHA self-hosted runner on oci-apps (ARM64).
# No port/proxy — purely outbound. Registers to build.json.gha.repo_url.
# ACCESS_TOKEN: GitHub classic PAT (repo scope) in src/secrets.yaml (sops).
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
      # Data-driven limits (build.json containers.app). octocode FastEmbed+GraphRAG
      # needs well over 4G — 4G OOM-killed the index (rc=137). cpus caps it at 3 of
      # 4 cores so the indexer can never starve the host (freeze-safety in-container).
      deploy.resources = {
        limits       = { memory = app.mem_limit or "16G"; cpus = app.cpus or "3.0"; };
        reservations = { memory = "256M"; };
      };
    };
  };
}
