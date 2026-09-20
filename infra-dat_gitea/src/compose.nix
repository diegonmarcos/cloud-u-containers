# compose.nix — docker-compose spec for gitea (Type B wrap-upstream)
# engine.nix serialises this attrset via lib.generators.toYAML and merges
# compose-defaults.json into every service.
{ buildJson, container }:

let
  app = buildJson.containers.app;
  giteaConfig = buildJson.gitea;
  portHttp = buildJson.ports.app;
  portSsh  = buildJson.ssh_port;
  domain   = buildJson.domain;

  binariesImage = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";
in
{
  services = {
    gitea = {
      image = binariesImage;
      container_name = app.container_name;
      network_mode = "host";
      env_file = [ ".secrets" ];
      environment = {
        SSH_PORT                                     = toString portSsh;
        SSH_LISTEN_PORT                              = toString portSsh;
        GITEA__server__HTTP_PORT                     = toString portHttp;
        GITEA__server__SSH_PORT                      = toString portSsh;
        GITEA__server__SSH_LISTEN_PORT               = toString portSsh;
        GITEA__server__SSH_LISTEN_HOST               = buildJson.ssh_listen_host;
        GITEA__server__DISABLE_SSH                   = "false";
        GITEA__server__ROOT_URL                      = "https://${domain}";
        GITEA__server__SSH_DOMAIN                    = domain;
        GITEA__mirror__DEFAULT_INTERVAL              = giteaConfig.mirror_interval;
        GITEA__repository__ENABLE_PUSH_CREATE_USER   = "true";
        GITEA__repository__ENABLE_PUSH_CREATE_ORG    = "true";
      };
      volumes = [
        "gitea_data:/data"
        # DELIBERATELY NOT MOUNTED HERE: cloud-git-gh, the agents' shared
        # working tree. It used to be mounted at /data/git-gh, and that mount
        # was the root writer.
        #
        # Gitea never used it. Every reference to /data/git-gh in this repo is
        # a COMMENT — Gitea serves its own repositories out of
        # /data/gitea-repositories and has no code path that reads or writes
        # /data/git-gh. The mount existed for filing reasons alone ("Gitea is
        # the fleet's git host and this is git data").
        #
        # What it cost: this container sets no `user` and the Gitea image
        # inits its supervision tree as root, so it was the ONLY root-capable
        # process holding the agents' tree read-write. Measured 2026-09-20:
        # 260 root-owned entries across four repos — cloud-data-my-ai-memory
        # (247, including .git/config, .git/HEAD, ~117 object fanout dirs, all
        # of c_tasks/ and the whole a_sessions/galaxy/ tree), cloud-infra (8),
        # cloud-data (4), cloud-u-linux (1). Agents run as uid 10001 and
        # cannot write root-owned paths, so their commits failed deep inside a
        # subprocess with "insufficient permission for adding an object" and
        # the turn still reported success. That is why the c_tasks backlog
        # went stale and why #540's session sync kept failing on
        # a_sessions/galaxy — not a sync bug, a permission denial nobody saw.
        #
        # The chown is the repair; removing this mount is the fix. Do not add
        # it back: Gitea gains nothing from it and is the one process here
        # that can poison the tree for everyone else.
        "/etc/timezone:/etc/timezone:ro"
        "/etc/localtime:/etc/localtime:ro"
      ];
      healthcheck = {
        test = [ "CMD" "curl" "-f" "http://localhost:${toString portHttp}/" ];
        interval = "30s";
        timeout = "10s";
        retries = 3;
      };
    };
  };
  volumes = {
    gitea_data = {};
    # git_gh is gone on purpose — see the volumes list above. Declaring a
    # volume this project no longer mounts would be dead code that invites
    # someone to "restore the missing mount". The pinned-name declaration
    # still lives in user-ai_my-ai_claude-api and _shared/engine.nix, which
    # are the projects that actually use the tree.
  };
}
