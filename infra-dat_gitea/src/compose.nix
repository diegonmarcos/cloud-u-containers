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
        # The ONE central working tree every agent container mounts.
        #
        # Gitea's own repositories under /data/gitea-repositories are pull
        # mirrors of GitHub: they refuse a push by design, so no agent can
        # ever work in them. Agents were therefore each doing a private
        # `git clone` from GitHub, which produced sixty-three independent
        # checkouts of the same repositories in one container — nobody could
        # see anybody else's work, and the same file was edited in parallel
        # with no way to notice.
        #
        # git-gh is the writable counterpart: real working clones whose
        # origin is still GitHub (that is the "gh" in the name, and why this
        # is not yet a migration to Gitea). It lives inside Gitea because
        # Gitea is the fleet's git host and this is git data; it is a
        # separate named volume rather than a directory inside gitea_data so
        # that a deploy which recreates the compose project cannot take the
        # working trees with it.
        #
        # Keeping two agents off the same file is the dispatcher's job, not
        # this mount's — the mount only guarantees there is one file to
        # collide on instead of sixty-three copies that silently diverge.
        "git_gh:/data/git-gh"
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
    # Pinned name, declared identically here and in user-ai_my-ai_claude-api.
    # Compose scopes an undeclared volume to its own project, so two projects
    # asking for "git_gh" would silently get two different volumes and the
    # single central tree would be two trees again. The explicit `name` is
    # what makes both projects resolve to the one docker volume.
    git_gh = { name = "cloud-git-gh"; };
  };
}
