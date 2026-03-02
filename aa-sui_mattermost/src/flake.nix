{
  description = "Mattermost - Team chat with ntfy bridge and AI agents";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    config = {
      container_name = "mattermost";
      postgres_container = "mattermost-postgres";
      bridge_container = "mattermost-ntfy-bridge";
      image = "ngrie/mattermost-team-edition-arm:10.11";
      postgres_image = "postgres:16-alpine";
      bridge_image = "python:3.12-slim";
      port = 8065;
      postgres_port = 5432;
      wg_ip = "10.0.0.6";
      ntfy_url = "http://10.0.0.1:8090";
      topics = "cicd_deploy-digest,infra_mesh-health,infra_endpoints,infra_dns,infra_resources,infra_containers,ops_summary,ops_backups,ops_cron,security_audit,security_tls,security_connections,security_yara,vcs_commits,vcs_pull-requests,vcs_issues-releases";
      timezone = "America/Chicago";
    };

    title = "Mattermost Team Chat";

    # WireGuard IPs
    gcp = "10.0.0.1";
    flex0 = "10.0.0.6";

    # ── Docker Compose ──────────────────────────────────────────
    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      services:
        mattermost:
          image: ${config.image}
          container_name: ${config.container_name}
          restart: unless-stopped
          ports:
            - "${config.wg_ip}:${toString config.port}:8065"
          volumes:
            - ./data/mattermost/config:/mattermost/config
            - ./data/mattermost/data:/mattermost/data
            - ./data/mattermost/logs:/mattermost/logs
            - ./data/mattermost/plugins:/mattermost/plugins
            - ./data/mattermost/client-plugins:/mattermost/client/plugins
          env_file:
            - .secrets
          environment:
            - TZ=${config.timezone}
            - MM_SQLSETTINGS_DRIVERNAME=postgres
            - MM_SERVICESETTINGS_SITEURL=https://chat.diegonmarcos.com
            - MM_SERVICESETTINGS_LISTENADDRESS=:8065
            - MM_PLUGINSETTINGS_ENABLEUPLOADS=true
            - MM_SERVICESETTINGS_ENABLEINCOMINGWEBHOOKS=true
            - MM_SERVICESETTINGS_ENABLEUSERACCESSTOKENS=true
          depends_on:
            postgres:
              condition: service_healthy
        postgres:
          image: ${config.postgres_image}
          container_name: ${config.postgres_container}
          restart: unless-stopped
          volumes:
            - ./data/postgres:/var/lib/postgresql/data
          env_file:
            - .secrets
          environment:
            - POSTGRES_DB=mattermost
            - POSTGRES_USER=mattermost
          healthcheck:
            test: ["CMD-SHELL", "pg_isready -U mattermost -d mattermost"]
            interval: 10s
            timeout: 5s
            retries: 5

        ntfy-bridge:
          image: ${config.bridge_image}
          container_name: ${config.bridge_container}
          restart: unless-stopped
          volumes:
            - ./ntfy-bridge.py:/app/ntfy-bridge.py:ro
            - ./requirements-bridge.txt:/app/requirements.txt:ro
          entrypoint: ["/bin/sh", "-c", "pip install --quiet -r /app/requirements.txt && python /app/ntfy-bridge.py"]
          env_file:
            - .secrets
          environment:
            - NTFY_URL=${config.ntfy_url}
            - TOPICS=${config.topics}
            - MM_URL=http://mattermost:8065
          depends_on:
            - mattermost
    '';

    # ── ntfy bridge script ──────────────────────────────────────
    mkBridge = pkgs: pkgs.writeText "ntfy-bridge.py" ''
      #!/usr/bin/env python3
      """
      ntfy -> Mattermost bridge via incoming webhooks.
      On startup: creates admin user + incoming webhook (idempotent).
      Then subscribes to configured ntfy topics and posts via webhook.
      """
      import os, sys, json, time, re, logging
      import requests

      logging.basicConfig(
          level=logging.INFO,
          format="%(asctime)s [%(levelname)s] %(message)s",
          stream=sys.stdout,
      )
      log = logging.getLogger("ntfy-bridge")

      NTFY_URL = os.environ["NTFY_URL"]
      TOPICS = os.environ["TOPICS"]
      MM_URL = os.environ["MM_URL"]
      MM_ADMIN_EMAIL = os.environ["MM_ADMIN_EMAIL"]
      MM_ADMIN_USERNAME = os.environ["MM_ADMIN_USERNAME"]
      MM_ADMIN_PASSWORD = os.environ["MM_ADMIN_PASSWORD"]


      def mm_api(method, path, headers, **kwargs):
          return requests.request(method, f"{MM_URL}/api/v4{path}", headers=headers, timeout=30, **kwargs)


      def wait_for_mattermost():
          log.info("Waiting for Mattermost at %s ...", MM_URL)
          for _ in range(120):
              try:
                  r = requests.get(f"{MM_URL}/api/v4/system/ping", timeout=5)
                  if r.ok:
                      log.info("Mattermost is ready.")
                      return
              except requests.ConnectionError:
                  pass
              time.sleep(2)
          raise RuntimeError("Mattermost did not become ready in 240s")


      def bootstrap_admin():
          """Create admin user (idempotent). Returns session token."""
          r = mm_api("POST", "/users/login", {}, json={
              "login_id": MM_ADMIN_USERNAME, "password": MM_ADMIN_PASSWORD,
          })
          if r.ok:
              log.info("Admin login OK (user exists)")
              return r.headers.get("Token", "")

          r = mm_api("POST", "/users", {}, json={
              "email": MM_ADMIN_EMAIL,
              "username": MM_ADMIN_USERNAME,
              "password": MM_ADMIN_PASSWORD,
          })
          if not (r.ok or r.status_code == 201) and "already exists" not in r.text.lower():
              r.raise_for_status()
          log.info("Admin user created/exists: %s", MM_ADMIN_USERNAME)

          r = mm_api("POST", "/users/login", {}, json={
              "login_id": MM_ADMIN_USERNAME, "password": MM_ADMIN_PASSWORD,
          })
          r.raise_for_status()
          return r.headers["Token"]


      def ensure_team(headers):
          """Ensure default team exists. Returns team_id."""
          r = mm_api("GET", "/teams", headers)
          if r.ok and r.json():
              return r.json()[0]["id"]
          r = mm_api("POST", "/teams", headers, json={
              "name": "main", "display_name": "Main", "type": "O",
          })
          r.raise_for_status()
          tid = r.json()["id"]
          log.info("Created team: main (%s)", tid)
          return tid


      def ensure_webhook(headers, team_id):
          """Find or create incoming webhook. Returns webhook URL."""
          r = mm_api("GET", f"/teams/{team_id}/channels/name/town-square", headers)
          r.raise_for_status()
          channel_id = r.json()["id"]

          r = mm_api("GET", "/hooks/incoming?per_page=200", headers)
          if r.ok:
              for hook in r.json():
                  if hook.get("display_name") == "ntfy Bridge":
                      url = f"{MM_URL}/hooks/{hook['id']}"
                      log.info("Found existing webhook: %s", hook["id"])
                      return url

          r = mm_api("POST", "/hooks/incoming", headers, json={
              "channel_id": channel_id,
              "display_name": "ntfy Bridge",
              "description": "Bridges ntfy notifications to Mattermost channels",
          })
          r.raise_for_status()
          url = f"{MM_URL}/hooks/{r.json()['id']}"
          log.info("Created webhook: %s", r.json()["id"])
          return url


      def sanitize_channel(topic):
          name = re.sub(r"[^a-z0-9_-]", "-", topic.lower().strip())
          return re.sub(r"-+", "-", name).strip("-")[:64] or "ntfy-general"


      def format_message(msg):
          title = msg.get("title", "")
          body = msg.get("message", "")
          priority = msg.get("priority", 3)
          tags = msg.get("tags", [])
          parts = []
          if priority >= 4:
              parts.append("**ALERT**")
          if title:
              parts.append(f"**{title}**")
          if body:
              parts.append(body)
          if tags:
              parts.append(f"_Tags: {', '.join(tags)}_")
          return "\n".join(parts) or "(empty notification)"


      def subscribe_and_bridge(webhook_url):
          url = f"{NTFY_URL}/{TOPICS}/json"
          topic_list = TOPICS.split(",")
          log.info("Subscribing to %d topics: %s", len(topic_list), TOPICS[:120])

          with requests.get(url, stream=True, timeout=(10, None)) as resp:
              resp.raise_for_status()
              log.info("Connected to ntfy stream")
              for line in resp.iter_lines(decode_unicode=True):
                  if not line:
                      continue
                  try:
                      msg = json.loads(line)
                  except json.JSONDecodeError:
                      continue
                  if msg.get("event") != "message":
                      continue
                  topic = msg.get("topic", "unknown")
                  log.info("Received [%s]: %s", topic, msg.get("message", "")[:80])
                  try:
                      requests.post(webhook_url, json={
                          "channel": sanitize_channel(topic),
                          "text": format_message(msg),
                          "username": "ntfy",
                      }, timeout=10)
                  except Exception as e:
                      log.error("Failed to post to %s: %s", topic, e)


      def main():
          wait_for_mattermost()
          admin_token = bootstrap_admin()
          headers = {"Authorization": f"Bearer {admin_token}"}
          team_id = ensure_team(headers)
          webhook_url = ensure_webhook(headers, team_id)
          log.info("Bootstrap complete. Starting ntfy bridge loop.")

          backoff = 1
          while True:
              try:
                  subscribe_and_bridge(webhook_url)
              except requests.exceptions.ConnectionError as e:
                  log.warning("Connection lost: %s -- retrying in %ds", e, backoff)
              except requests.exceptions.HTTPError as e:
                  log.error("HTTP error: %s -- retrying in %ds", e, backoff)
              except Exception as e:
                  log.exception("Unexpected error: %s -- retrying in %ds", e, backoff)
              time.sleep(backoff)
              backoff = min(backoff * 2, 300)


      if __name__ == "__main__":
          main()
    '';

    # ── Init dirs (compose pre_hook) ──────────────────────────────
    mkInitDirs = pkgs: pkgs.writeText "init-dirs.sh" ''
      #!/bin/sh
      # Mattermost runs as uid 2000 inside the container
      MM_UID=2000
      MM_GID=2000
      for dir in data/mattermost/config data/mattermost/data data/mattermost/logs data/mattermost/plugins data/mattermost/client-plugins data/postgres; do
        mkdir -p "$dir"
      done
      sudo chown -R $MM_UID:$MM_GID data/mattermost
    '';

    # ── Bridge requirements ─────────────────────────────────────
    mkRequirements = pkgs: pkgs.writeText "requirements-bridge.txt" ''
      requests>=2.31.0
    '';

    # ── Documentation ────────────────────────────────────────────────────
    mkDocs = pkgs: defaultPkg: let
      inherit (pkgs.lib) concatMapStrings hasSuffix optionalString filter subtractLists removeSuffix;
      inherit (builtins) attrNames readDir pathExists;

      portKeys = filter (k: hasSuffix "_port" k || k == "port") (attrNames config);
      imageKeys = filter (k: hasSuffix "_image" k || k == "image") (attrNames config);
      containerKeys = filter (k: hasSuffix "_container" k || k == "container_name") (attrNames config);
      domainKeys = filter (k: k == "domain" || k == "base_domain") (attrNames config);
      otherKeys = subtractLists (portKeys ++ imageKeys ++ containerKeys ++ domainKeys) (attrNames config);

      row = k: let
        v = config.${k};
        vs = if builtins.isBool v then (if v then "true" else "false")
             else if builtins.isAttrs v || builtins.isList v then builtins.toJSON v
             else toString v;
      in "| `${k}` | `${vs}` |\n";
      section = heading: keys: optionalString (keys != []) ''
        ## ${heading}
        | Key | Value |
        |-----|-------|
        ${concatMapStrings row keys}
      '';

      hasNarrative = pathExists ./docs;
      narrativeFiles = if hasNarrative
        then filter (f: hasSuffix ".md" f) (attrNames (readDir ./docs))
        else [];

      specMd = pkgs.writeText "spec.md" ''
        # ${title}
        ${section "Network" (domainKeys ++ portKeys)}
        ${section "Containers" (containerKeys ++ imageKeys)}
        ${section "Configuration" otherKeys}
      '';

      summaryMd = pkgs.writeText "SUMMARY.md" ''
        # Summary
        - [Specification](./spec.md)
        - [Generated Configs](./configs.md)
        ${concatMapStrings (f: "- [${removeSuffix ".md" f}](./${f})\n") narrativeFiles}
      '';

      bookToml = pkgs.writeText "book.toml" ''
        [book]
        title = "${title}"
        [output.html]
        default-theme = "ayu"
      '';
    in pkgs.runCommand "docs" {
      nativeBuildInputs = [ pkgs.mdbook pkgs.file ];
    } ''
      mkdir -p build/src
      cp ${bookToml} build/book.toml
      cp ${summaryMd} build/src/SUMMARY.md
      cp ${specMd} build/src/spec.md
      ${optionalString hasNarrative "cp ${./docs}/*.md build/src/ 2>/dev/null || true"}

      echo "# Generated Configuration Files" > build/src/configs.md
      echo "" >> build/src/configs.md
      echo 'These files are produced by nix build and deployed to the VM.' >> build/src/configs.md
      echo "" >> build/src/configs.md
      find ${defaultPkg} -type f | sort | while read -r f; do
        relpath="''${f#${defaultPkg}/}"
        case "$relpath" in
          .secrets|*.secrets|*.lock|*.png|*.jpg|*.gif|*.ico|*.woff*|*.ttf|*.eot) continue ;;
        esac
        case "$relpath" in
          *.yml|*.yaml)   lang="yaml" ;;
          *.json)         lang="json" ;;
          *.toml)         lang="toml" ;;
          *.py)           lang="python" ;;
          *.sh)           lang="bash" ;;
          *.js|*.ts)      lang="javascript" ;;
          *.tf)           lang="hcl" ;;
          *.conf|*.cnf)   lang="ini" ;;
          *.html)         lang="html" ;;
          *.sql)          lang="sql" ;;
          *.zone)         lang="dns" ;;
          Dockerfile*)    lang="dockerfile" ;;
          Caddyfile*)     lang="caddy" ;;
          *)              lang="" ;;
        esac
        if file -b --mime-type "$f" | grep -q "^text/"; then
          echo '## '"$relpath" >> build/src/configs.md
          echo "" >> build/src/configs.md
          echo "~~~$lang" >> build/src/configs.md
          cat "$f" >> build/src/configs.md
          echo "" >> build/src/configs.md
          echo '~~~' >> build/src/configs.md
          echo "" >> build/src/configs.md
        fi
      done

      cd build && mdbook build -d $out
    '';

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in let
      defaultPkg = pkgs.runCommand "mattermost-configs" {} ''
        mkdir -p $out
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
        cp ${mkBridge pkgs} $out/ntfy-bridge.py
        cp ${mkRequirements pkgs} $out/requirements-bridge.txt
        cp ${mkInitDirs pkgs} $out/init-dirs.sh
        chmod +x $out/init-dirs.sh
      '';
    in {
      default = defaultPkg;
      docs = mkDocs pkgs defaultPkg;
    });
  };
}
