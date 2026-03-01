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
            - MM_SERVICESETTINGS_ENABLEBOTACCOUNTCREATION=true
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
            - bridge_data:/data
          entrypoint: ["/bin/sh", "-c", "pip install --quiet -r /app/requirements.txt && python /app/ntfy-bridge.py"]
          env_file:
            - .secrets
          environment:
            - NTFY_URL=${config.ntfy_url}
            - MM_URL=http://mattermost:8065
          depends_on:
            - mattermost

      volumes:
        bridge_data:
    '';

    # ── ntfy bridge script ──────────────────────────────────────
    mkBridge = pkgs: pkgs.writeText "ntfy-bridge.py" ''
      #!/usr/bin/env python3
      """
      ntfy -> Mattermost bridge (self-bootstrapping).
      On startup: creates admin user + bot via API (idempotent).
      Then subscribes to ALL ntfy topics and bridges messages.
      """
      import os
      import sys
      import json
      import time
      import re
      import logging
      import requests

      logging.basicConfig(
          level=logging.INFO,
          format="%(asctime)s [%(levelname)s] %(message)s",
          stream=sys.stdout,
      )
      log = logging.getLogger("ntfy-bridge")

      NTFY_URL = os.environ["NTFY_URL"]
      MM_URL = os.environ["MM_URL"]
      MM_ADMIN_EMAIL = os.environ["MM_ADMIN_EMAIL"]
      MM_ADMIN_USERNAME = os.environ["MM_ADMIN_USERNAME"]
      MM_ADMIN_PASSWORD = os.environ["MM_ADMIN_PASSWORD"]
      BEARER_TOKEN = os.environ.get("BEARER_TOKEN", "")

      NTFY_HEADERS = {"Authorization": f"Bearer {BEARER_TOKEN}"} if BEARER_TOKEN else {}
      BOT_USERNAME = "ntfy-bridge"
      BOT_DISPLAY = "ntfy Bridge"
      TOKEN_FILE = "/data/bot-token"

      # Set after bootstrap
      MM_HEADERS: dict[str, str] = {}
      channel_cache: dict[str, str] = {}
      team_id: str = ""


      def mm_raw(method: str, path: str, headers: dict, **kwargs) -> requests.Response:
          return requests.request(method, f"{MM_URL}/api/v4{path}", headers=headers, timeout=30, **kwargs)


      def mm_api(method: str, path: str, **kwargs) -> requests.Response:
          return mm_raw(method, path, MM_HEADERS, **kwargs)


      def wait_for_mattermost() -> None:
          log.info("Waiting for Mattermost at %s ...", MM_URL)
          for i in range(120):
              try:
                  r = requests.get(f"{MM_URL}/api/v4/system/ping", timeout=5)
                  if r.ok:
                      log.info("Mattermost is ready.")
                      return
              except requests.ConnectionError:
                  pass
              time.sleep(2)
          raise RuntimeError("Mattermost did not become ready in 240s")


      def bootstrap_admin() -> str:
          """Create admin user (idempotent). Returns session token."""
          # Try logging in first (already exists)
          r = mm_raw("POST", "/users/login", {}, json={
              "login_id": MM_ADMIN_USERNAME,
              "password": MM_ADMIN_PASSWORD,
          })
          if r.ok:
              token = r.headers.get("Token", "")
              log.info("Admin login OK (user exists)")
              return token

          # First user creation (no auth needed on fresh instance)
          r = mm_raw("POST", "/users", {}, json={
              "email": MM_ADMIN_EMAIL,
              "username": MM_ADMIN_USERNAME,
              "password": MM_ADMIN_PASSWORD,
          })
          if r.ok or r.status_code == 201:
              log.info("Admin user created: %s", MM_ADMIN_USERNAME)
          elif r.status_code == 400 and "already exists" in r.text.lower():
              log.info("Admin user already exists")
          else:
              log.error("Failed to create admin: %s %s", r.status_code, r.text[:300])
              r.raise_for_status()

          # Log in
          r = mm_raw("POST", "/users/login", {}, json={
              "login_id": MM_ADMIN_USERNAME,
              "password": MM_ADMIN_PASSWORD,
          })
          r.raise_for_status()
          return r.headers["Token"]


      def ensure_team(admin_headers: dict) -> str:
          """Ensure default team exists."""
          r = mm_raw("GET", "/teams", admin_headers)
          if r.ok and r.json():
              return r.json()[0]["id"]
          r = mm_raw("POST", "/teams", admin_headers, json={
              "name": "main",
              "display_name": "Main",
              "type": "O",
          })
          r.raise_for_status()
          tid = r.json()["id"]
          log.info("Created team: main (%s)", tid)
          return tid


      def bootstrap_bot(admin_headers: dict) -> str:
          """Create bot + access token (idempotent). Returns bot token."""
          # Check for cached token from previous run
          if os.path.exists(TOKEN_FILE):
              cached = open(TOKEN_FILE).read().strip()
              if cached:
                  # Verify it works
                  r = mm_raw("GET", "/users/me", {"Authorization": f"Bearer {cached}"})
                  if r.ok:
                      log.info("Using cached bot token from %s", TOKEN_FILE)
                      return cached

          # Find or create bot
          r = mm_raw("GET", f"/bots?include_deleted=false", admin_headers)
          bot_id = ""
          if r.ok:
              for bot in r.json():
                  if bot["username"] == BOT_USERNAME:
                      bot_id = bot["user_id"]
                      log.info("Bot exists: %s (%s)", BOT_USERNAME, bot_id)
                      break

          if not bot_id:
              r = mm_raw("POST", "/bots", admin_headers, json={
                  "username": BOT_USERNAME,
                  "display_name": BOT_DISPLAY,
                  "description": "Bridges ntfy notifications to Mattermost channels",
              })
              if r.ok or r.status_code == 201:
                  bot_id = r.json()["user_id"]
                  log.info("Created bot: %s (%s)", BOT_USERNAME, bot_id)
              else:
                  log.error("Failed to create bot: %s %s", r.status_code, r.text[:300])
                  r.raise_for_status()

          # Create access token for bot
          r = mm_raw("POST", f"/users/{bot_id}/tokens", admin_headers, json={
              "description": "ntfy-bridge auto-generated token",
          })
          r.raise_for_status()
          token = r.json()["token"]
          log.info("Created bot access token")

          # Cache token to persistent volume
          os.makedirs(os.path.dirname(TOKEN_FILE), exist_ok=True)
          with open(TOKEN_FILE, "w") as f:
              f.write(token)

          return token


      def add_bot_to_team(admin_headers: dict, bot_token: str, tid: str) -> None:
          """Ensure bot is a member of the team."""
          # Get bot user id
          r = mm_raw("GET", "/users/me", {"Authorization": f"Bearer {bot_token}"})
          if not r.ok:
              return
          bot_user_id = r.json()["id"]
          r = mm_raw("POST", f"/teams/{tid}/members", admin_headers, json={
              "team_id": tid,
              "user_id": bot_user_id,
          })
          if r.ok or r.status_code == 201:
              log.info("Bot added to team %s", tid)
          elif "already" in r.text.lower():
              log.info("Bot already in team")


      def bootstrap() -> str:
          """Full bootstrap: admin + team + bot. Returns bot token."""
          wait_for_mattermost()
          admin_token = bootstrap_admin()
          admin_headers = {"Authorization": f"Bearer {admin_token}"}

          global team_id
          team_id = ensure_team(admin_headers)

          bot_token = bootstrap_bot(admin_headers)
          add_bot_to_team(admin_headers, bot_token, team_id)

          return bot_token


      def sanitize_channel_name(topic: str) -> str:
          name = topic.lower().strip()
          name = re.sub(r"[^a-z0-9_-]", "-", name)
          name = re.sub(r"-+", "-", name).strip("-")
          return name[:64] or "ntfy-general"


      def get_or_create_channel(topic: str) -> str:
          if topic in channel_cache:
              return channel_cache[topic]

          channel_name = sanitize_channel_name(topic)

          resp = mm_api("GET", f"/teams/{team_id}/channels/name/{channel_name}")
          if resp.ok:
              channel_id = resp.json()["id"]
              channel_cache[topic] = channel_id
              return channel_id

          resp = mm_api("POST", "/channels", json={
              "team_id": team_id,
              "name": channel_name,
              "display_name": f"ntfy: {topic}",
              "purpose": f"Auto-mirrored from ntfy topic: {topic}",
              "type": "O",
          })
          if resp.ok:
              channel_id = resp.json()["id"]
              channel_cache[topic] = channel_id
              log.info("Created channel: %s -> %s", topic, channel_name)
              return channel_id

          if resp.status_code == 409:
              resp = mm_api("GET", f"/teams/{team_id}/channels/name/{channel_name}")
              resp.raise_for_status()
              channel_id = resp.json()["id"]
              channel_cache[topic] = channel_id
              return channel_id

          resp.raise_for_status()
          return ""


      def format_message(msg: dict) -> str:
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


      def post_to_mattermost(topic: str, msg: dict) -> None:
          channel_id = get_or_create_channel(topic)
          if not channel_id:
              log.error("Could not get channel for topic: %s", topic)
              return

          text = format_message(msg)
          resp = mm_api("POST", "/posts", json={
              "channel_id": channel_id,
              "message": text,
          })
          if resp.ok:
              log.info("Posted to %s: %.80s", topic, text.replace("\n", " "))
          else:
              log.error("Failed to post to %s: %s %s", topic, resp.status_code, resp.text[:200])


      def subscribe_and_bridge() -> None:
          url = f"{NTFY_URL}/*/json"
          log.info("Subscribing to %s", url)

          with requests.get(url, headers=NTFY_HEADERS, stream=True, timeout=None) as resp:
              resp.raise_for_status()
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
                  post_to_mattermost(topic, msg)


      def main() -> None:
          global MM_HEADERS

          bot_token = bootstrap()
          MM_HEADERS = {"Authorization": f"Bearer {bot_token}"}
          log.info("Bootstrap complete. Starting ntfy bridge loop.")

          backoff = 1
          while True:
              try:
                  subscribe_and_bridge()
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
