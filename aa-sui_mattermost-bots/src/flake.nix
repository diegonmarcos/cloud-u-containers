{
  description = "Mattermost - Team chat with ntfy bridge and C3 command bot";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    config = {
      container_name = "mattermost";
      postgres_container = "mattermost-postgres";
      bridge_container = "mattermost-bots";
      image = "ngrie/mattermost-team-edition-arm:10.11";
      c3_api = "http://c3-infra-mcp-api:8080";
      c3_port = 8887;
      postgres_image = "postgres:16-alpine";
      bridge_image = "python:3.12-slim";
      port = 8065;
      postgres_port = 5435;
      wg_ip = "10.0.0.6";
      ntfy_url = "http://10.0.0.1:8090";
      # Scraped from bc-obs_ntfy/src/topic-scanner.py CONFIGURED_TOPICS
      topics = builtins.concatStringsSep "," (import ./ntfy-topics.nix);
      timezone = "America/Chicago";
      ollama_url = "http://10.0.0.8:11434";
      ollama_model = "deepseek-r1:14b-qwen-distill-q8_0";
      ollama_vm = "gcp-t4";
    };

    title = "Mattermost Team Chat";

    # WireGuard IPs
    gcp = "10.0.0.1";
    flex0 = "10.0.0.6";

    # ── Docker Compose ──────────────────────────────────────────
    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      # ╔══════════════════════════════════════════════════════════════════╗
      # ║ DO NOT EDIT — DECLARATIVE ENVIRONMENT — NIX FLAKES WAY         ║
      # ║ AUTO-GENERATED — DONT USE IMPERATIVE SOLUTIONS!!!              ║
      # ╠══════════════════════════════════════════════════════════════════╣
      # ║ Source: ~/git/cloud/a_solutions/aa-sui_mattermost-bots/src/flake.nix ║
      # ║ Rebuild: ~/git/cloud/a_solutions/aa-sui_mattermost-bots/build.sh ship ║
      # ╚══════════════════════════════════════════════════════════════════╝
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
            - MM_SERVICESETTINGS_ENABLECOMMANDS=true
            - MM_SERVICESETTINGS_ENABLEBOTACCOUNTCREATION=true
            - MM_SERVICESETTINGS_ENABLEUSERACCESSTOKENS=true
            - MM_DISPLAYSETTINGS_EXPERIMENTALTIMEZONE=true
            - MM_LOCALIZATIONSETTINGS_DEFAULTCLIENTLOCALE=en
            - MM_DISPLAYSETTINGS_CLOCKFORMAT=24h
            - MM_SERVICESETTINGS_ALLOWEDUNTRUSTEDINTERNALCONNECTIONS=mattermost-bots
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

        mattermost-bots:
          image: ${config.bridge_image}
          container_name: ${config.bridge_container}
          restart: unless-stopped
          ports:
            - "${config.wg_ip}:${toString config.c3_port}:${toString config.c3_port}"
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
            - C3_API_URL=${config.c3_api}
            - OLLAMA_URL=${config.ollama_url}
            - OLLAMA_MODEL=${config.ollama_model}
            - OLLAMA_VM=${config.ollama_vm}
            - AUTHELIA_OIDC_CLIENT_ID=mattermost-cc
            - AUTHELIA_OIDC_CLIENT_SECRET=''${AUTHELIA_OIDC_MATTERMOST_SECRET}
            - AUTHELIA_TOKEN_URL=https://auth.diegonmarcos.com/api/oidc/token
          networks:
            - default
          depends_on:
            - mattermost
    '';

    # ── ntfy bridge script ──────────────────────────────────────
    mkBridge = pkgs: pkgs.writeText "ntfy-bridge.py" ''
      #!/usr/bin/env python3
      """
      Mattermost bots: ntfy bridge + C3 infrastructure bot.
      Bot 1: ntfy bridge — subscribes to ntfy topics, posts to channels via webhook.
      Bot 2: C3 bot — a proper bot account you can DM + /c3 slash command.
      """
      import os, sys, json, time, re, logging, threading, io, socket
      from http.server import HTTPServer, BaseHTTPRequestHandler
      from urllib.parse import parse_qs, urlparse
      import requests
      import websocket
      from PIL import Image, ImageDraw, ImageFont

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
      C3_API_URL = os.environ.get("C3_API_URL", "http://c3-infra-mcp-api:8080")


      def fetch_oidc_token():
          """Fetch OIDC token via client_credentials grant."""
          client_id = os.environ.get("AUTHELIA_OIDC_CLIENT_ID", "")
          client_secret = os.environ.get("AUTHELIA_OIDC_CLIENT_SECRET", "")
          token_url = os.environ.get("AUTHELIA_TOKEN_URL", "")
          if not (client_id and client_secret and token_url):
              return ""
          try:
              r = requests.post(token_url, auth=(client_id, client_secret),
                                data={"grant_type": "client_credentials", "scope": "authelia.bearer.authz"},
                                timeout=10)
              r.raise_for_status()
              token = r.json().get("access_token", "")
              if token:
                  log.info("OIDC token acquired via client_credentials (%d chars)", len(token))
              return token
          except Exception as e:
              log.warning("OIDC token fetch failed: %s", e)
              return ""


      C3_API_TOKEN = fetch_oidc_token() or os.environ.get("C3_API_TOKEN", "")
      OLLAMA_URL = os.environ.get("OLLAMA_URL", "http://10.0.0.8:11434")
      OLLAMA_MODEL = os.environ.get("OLLAMA_MODEL", "deepseek-r1:14b")
      OLLAMA_VM = os.environ.get("OLLAMA_VM", "gcp-t4")
      OLLAMA_WG_IP = urlparse(OLLAMA_URL).hostname  # e.g. "10.0.0.8"
      _ollama_contexts = {}  # channel_id -> [{"role": ..., "content": ...}]
      _c3_bot_headers = None  # set after c3-bot login, used by slash cmd gpu background


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


      def sanitize_channel(topic):
          name = re.sub(r"[^a-z0-9_-]", "-", topic.lower().strip())
          return re.sub(r"-+", "-", name).strip("-")[:64] or "ntfy-general"


      def sync_channels(headers, team_id):
          """Sync channels: create missing, delete removed. Returns (default_channel_id, ntfy_channel_ids)."""
          wanted = {sanitize_channel(t) for t in TOPICS.split(",")}
          ntfy_marker = "Mirrored from ntfy topic:"
          ntfy_channel_ids = []

          # Get existing channels
          r = mm_api("GET", f"/teams/{team_id}/channels?per_page=200", headers)
          r.raise_for_status()
          existing = {}
          default_channel_id = ""
          old_prefix = "ntfy: "
          for ch in r.json():
              is_ntfy = ntfy_marker in (ch.get("purpose") or "") or ch.get("display_name", "").startswith(old_prefix)
              if is_ntfy:
                  existing[ch["name"]] = ch["id"]
                  # Migrate old "ntfy: topic" display names to just "topic"
                  dn = ch.get("display_name", "")
                  if dn.startswith(old_prefix):
                      new_dn = dn[len(old_prefix):]
                      mm_api("PUT", f"/channels/{ch['id']}", headers, json={
                          "id": ch["id"], "display_name": new_dn,
                          "purpose": ch.get("purpose") or f"{ntfy_marker} {new_dn}",
                      })
                      log.info("Renamed channel display: %s -> %s", dn, new_dn)
              if ch["name"] == "town-square":
                  default_channel_id = ch["id"]

          # Create missing
          for topic in TOPICS.split(","):
              name = sanitize_channel(topic)
              if name not in existing:
                  r = mm_api("POST", "/channels", headers, json={
                      "team_id": team_id,
                      "name": name,
                      "display_name": topic,
                      "purpose": f"{ntfy_marker} {topic}",
                      "type": "O",
                  })
                  if r.ok:
                      log.info("Created channel: %s", name)
                      ntfy_channel_ids.append(r.json()["id"])
                  elif r.status_code == 409:
                      log.info("Channel exists: %s", name)
                  else:
                      log.warning("Failed to create %s: %s", name, r.text[:100])
              else:
                  ntfy_channel_ids.append(existing[name])

          # Delete removed
          for name, ch_id in existing.items():
              if name not in wanted:
                  r = mm_api("DELETE", f"/channels/{ch_id}", headers)
                  if r.ok:
                      log.info("Deleted channel: %s", name)
                  else:
                      log.warning("Failed to delete %s: %s", name, r.text[:100])

          log.info("Channel sync complete: %d wanted, %d existed", len(wanted), len(existing))
          return default_channel_id, ntfy_channel_ids


      def sync_sidebar_category(headers, user_id, team_id, ntfy_channel_ids):
          """Group all ntfy channels under an 'ntfy' sidebar category, remove them from default 'Channels'."""
          r = mm_api("GET", f"/users/{user_id}/teams/{team_id}/channels/categories", headers)
          if not r.ok:
              log.warning("Failed to get sidebar categories: %s", r.text[:100])
              return

          categories = r.json().get("categories", [])
          ntfy_cat = None
          channels_cat = None
          ntfy_set = set(ntfy_channel_ids)

          for cat in categories:
              if cat.get("display_name") == "ntfy":
                  ntfy_cat = cat
              if cat.get("type") == "channels":
                  channels_cat = cat

          sorted_ids = sorted(ntfy_channel_ids)

          # Remove ntfy channels from default "Channels" category
          if channels_cat:
              cleaned = [cid for cid in channels_cat.get("channel_ids", []) if cid not in ntfy_set]
              if len(cleaned) != len(channels_cat.get("channel_ids", [])):
                  mm_api("PUT", f"/users/{user_id}/teams/{team_id}/channels/categories/{channels_cat['id']}", headers, json={
                      "id": channels_cat["id"],
                      "user_id": user_id,
                      "team_id": team_id,
                      "display_name": channels_cat.get("display_name", "Channels"),
                      "type": "channels",
                      "channel_ids": cleaned,
                  })
                  log.info("Removed %d ntfy channels from default Channels category", len(channels_cat["channel_ids"]) - len(cleaned))

          if ntfy_cat:
              if set(ntfy_cat.get("channel_ids", [])) != set(sorted_ids):
                  r = mm_api("PUT", f"/users/{user_id}/teams/{team_id}/channels/categories/{ntfy_cat['id']}", headers, json={
                      "id": ntfy_cat["id"],
                      "user_id": user_id,
                      "team_id": team_id,
                      "display_name": "ntfy",
                      "type": "custom",
                      "sorting": "alpha",
                      "channel_ids": sorted_ids,
                  })
                  if r.ok:
                      log.info("Updated ntfy sidebar category with %d channels", len(sorted_ids))
                  else:
                      log.warning("Failed to update ntfy category: %s", r.text[:100])
              else:
                  log.info("ntfy sidebar category already up to date")
          else:
              r = mm_api("POST", f"/users/{user_id}/teams/{team_id}/channels/categories", headers, json={
                  "user_id": user_id,
                  "team_id": team_id,
                  "display_name": "ntfy",
                  "type": "custom",
                  "sorting": "alpha",
                  "channel_ids": sorted_ids,
              })
              if r.ok:
                  log.info("Created ntfy sidebar category with %d channels", len(sorted_ids))
              else:
                  log.warning("Failed to create ntfy category: %s", r.text[:100])


      def ensure_webhook(headers, default_channel_id):
          """Find or create incoming webhook. Returns webhook URL."""
          r = mm_api("GET", "/hooks/incoming?per_page=200", headers)
          if r.ok:
              for hook in r.json():
                  if hook.get("display_name") == "ntfy Bridge":
                      url = f"{MM_URL}/hooks/{hook['id']}"
                      log.info("Found existing webhook: %s", hook["id"])
                      return url

          r = mm_api("POST", "/hooks/incoming", headers, json={
              "channel_id": default_channel_id,
              "display_name": "ntfy Bridge",
              "description": "Bridges ntfy notifications to Mattermost channels",
          })
          r.raise_for_status()
          url = f"{MM_URL}/hooks/{r.json()['id']}"
          log.info("Created webhook: %s", r.json()["id"])
          return url


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


      # ── C3 Command Bot ──────────────────────────────────────────

      def c3_req(method, path, timeout=30):
          """Call C3 API. Returns parsed JSON or error dict."""
          try:
              headers = {}
              if C3_API_TOKEN:
                  headers["Authorization"] = f"Bearer {C3_API_TOKEN}"
              r = requests.request(method, f"{C3_API_URL}{path}", headers=headers, timeout=timeout)
              r.raise_for_status()
              return r.json()
          except Exception as e:
              return {"error": str(e)}


      def format_tier1(data):
          """Format tier1 health as markdown table."""
          items = data if isinstance(data, list) else data.get("results", [])
          if not items:
              return f"```\n{json.dumps(data, indent=2)}\n```"
          lines = ["| VM | Status |", "|:---|:---|"]
          for item in items:
              alias = item.get("alias", item.get("vm", "?"))
              up = ":white_check_mark: UP" if item.get("reachable") else ":x: DOWN"
              lines.append(f"| {alias} | {up} |")
          return "\n".join(lines)


      def format_tier3(data):
          """Format tier3 health as markdown table."""
          items = data if isinstance(data, list) else data.get("results", [])
          if not items:
              return f"```\n{json.dumps(data, indent=2)}\n```"
          lines = ["| VM | Mem | Disk | Containers |", "|:---|:---|:---|:---|"]
          for item in items:
              alias = item.get("alias", item.get("vm", "?"))
              res = item.get("resources", {})
              if isinstance(res, dict):
                  mem_used = res.get("memoryUsed", "?")
                  mem_total = res.get("memoryTotal", "?")
                  mem = f"{mem_used}/{mem_total}" if mem_used != "?" else "?"
                  disk = res.get("diskPercent", "?")
              else:
                  mem = "?"
                  disk = "?"
              ct = item.get("containers", [])
              ct_count = str(len(ct)) if isinstance(ct, list) else "?"
              up = ":white_check_mark:" if item.get("reachable") else ":x:"
              lines.append(f"| {up} {alias} | {mem} | {disk} | {ct_count} |")
          return "\n".join(lines)


      def _gpu_post(channel_id, root_id, bot_headers, msg):
          """Helper: post a message to channel, optionally in thread."""
          body = {"channel_id": channel_id, "message": msg}
          if root_id:
              body["root_id"] = root_id
          mm_api("POST", "/posts", bot_headers, json=body)

      def _gpu_background(channel_id, root_id, bot_headers):
          """Background thread: wake VM -> compose up -> poll until Ollama API responds."""
          try:
              # Step 1: Start VM
              log.info("GPU: step 1 — starting %s via C3 API", OLLAMA_VM)
              r = c3_req("POST", f"/vms/{OLLAMA_VM}/start")
              log.info("GPU: vm start response: %s", str(r)[:200])
              if "error" in r:
                  _gpu_post(channel_id, root_id, bot_headers, f":x: Failed to start {OLLAMA_VM}: {r['error']}")
                  return

              # Step 2: Poll until VM is reachable via WireGuard
              log.info("GPU: step 2 — polling VM reachability")
              vm_up = False
              for i in range(30):
                  time.sleep(5)
                  if _check_vm_reachable(OLLAMA_VM):
                      vm_up = True
                      log.info("GPU: VM reachable after %ds", (i+1)*5)
                      _gpu_post(channel_id, root_id, bot_headers, f":white_check_mark: {OLLAMA_VM} reachable after {(i+1)*5}s")
                      break
              if not vm_up:
                  log.warning("GPU: VM not reachable after 150s")
                  _gpu_post(channel_id, root_id, bot_headers, f":warning: {OLLAMA_VM} not reachable after 150s")
                  return

              # Step 3: Start ollama service (compose up, not just container start)
              log.info("GPU: step 3 — starting ollama service")
              r = c3_req("POST", f"/vms/{OLLAMA_VM}/services/ollama/start", timeout=60)
              log.info("GPU: service start response: %s", str(r)[:200])
              if "error" in r:
                  # Fallback: try container start
                  log.info("GPU: service start failed, trying container start")
                  r = c3_req("POST", f"/vms/{OLLAMA_VM}/containers/ollama/start")
                  log.info("GPU: container start response: %s", str(r)[:200])
              if "error" in r:
                  _gpu_post(channel_id, root_id, bot_headers, f":warning: Service start returned: {r['error'][:100]}")

              # Step 4: Poll until Ollama HTTP API responds
              log.info("GPU: step 4 — polling Ollama API at %s", OLLAMA_URL)
              _gpu_post(channel_id, root_id, bot_headers, ":hourglass: Waiting for Ollama API...")
              api_ready = False
              for i in range(24):
                  time.sleep(5)
                  try:
                      resp = requests.get(f"{OLLAMA_URL}/api/tags", timeout=5)
                      if resp.ok:
                          models = [m.get("name", "?") for m in resp.json().get("models", [])]
                          model_list = ", ".join(f"`{m}`" for m in models[:5]) if models else "none loaded"
                          log.info("GPU: Ollama API ready after %ds, models: %s", (i+1)*5, model_list)
                          _gpu_post(channel_id, root_id, bot_headers,
                              f":white_check_mark: Ollama API up after {(i+1)*5}s — loading model into GPU...")
                          api_ready = True
                          break
                  except Exception:
                      pass
              if not api_ready:
                  log.warning("GPU: Ollama API not responding after 120s")
                  _gpu_post(channel_id, root_id, bot_headers, f":warning: Ollama API not responding after 120s (container may still be loading)")
                  return

              # Step 5: Pre-warm model into GPU VRAM (first inference triggers loading)
              log.info("GPU: step 5 — pre-warming model %s", OLLAMA_MODEL)
              try:
                  r = requests.post(f"{OLLAMA_URL}/api/chat", json={
                      "model": OLLAMA_MODEL,
                      "messages": [{"role": "user", "content": "hi"}],
                      "stream": False,
                  }, timeout=300)
                  if r.ok:
                      log.info("GPU: model pre-warmed successfully")
                      _gpu_post(channel_id, root_id, bot_headers,
                          f":white_check_mark: **{OLLAMA_MODEL}** loaded and ready\n**Available:** {model_list}")
                  else:
                      log.warning("GPU: pre-warm returned %s", r.status_code)
                      _gpu_post(channel_id, root_id, bot_headers,
                          f":warning: Model pre-warm returned {r.status_code} — may need a retry")
              except Exception as e:
                  log.warning("GPU: pre-warm failed: %s", e)
                  _gpu_post(channel_id, root_id, bot_headers,
                      f":warning: Model pre-warm timed out — first chat may be slow")
          except Exception as e:
              log.exception("_gpu_background crashed")
              try:
                  _gpu_post(channel_id, root_id, bot_headers, f":x: GPU wake crashed: {e}")
              except Exception:
                  log.exception("Failed to post gpu crash to MM")

      def handle_gpu():
          """Immediate ack — actual wake runs in background thread."""
          return f":hourglass: Starting {OLLAMA_VM}... (polling in background)"


      def handle_c3_command(text):
          """Parse and route /c3 commands. Returns markdown response."""
          parts = text.strip().split()
          cmd = parts[0].lower() if parts else "help"
          args = parts[1:]

          if cmd == "status":
              return format_tier1(c3_req("GET", "/health/tier1"))

          elif cmd == "vms":
              return format_tier3(c3_req("GET", "/health/tier3", timeout=120))

          elif cmd == "wake" and args:
              data = c3_req("POST", f"/vms/{args[0]}/start")
              if "error" in data:
                  return f":x: {data['error']}"
              return f":rocket: Start requested for **{args[0]}**"

          elif cmd == "sleep" and args:
              data = c3_req("POST", f"/vms/{args[0]}/stop")
              if "error" in data:
                  return f":x: {data['error']}"
              return f":zzz: Stop requested for **{args[0]}**"

          elif cmd == "reset" and args:
              data = c3_req("POST", f"/vms/{args[0]}/reset")
              if "error" in data:
                  return f":x: {data['error']}"
              return f":arrows_counterclockwise: Reset requested for **{args[0]}**"

          elif cmd == "ps" and args:
              data = c3_req("GET", f"/health/deployed/{args[0]}")
              if isinstance(data, dict) and "error" in data:
                  return f":x: {data['error']}"
              # API returns [{vm, alias, containers: [...]}] — unwrap
              containers = []
              if isinstance(data, list):
                  for entry in data:
                      if isinstance(entry, dict) and "containers" in entry:
                          containers = entry.get("containers", [])
                          break
                      elif isinstance(entry, dict) and "name" in entry:
                          containers = data  # flat list fallback
                          break
              if containers:
                  lines = ["| Container | Status |", "|:---|:---|"]
                  for c in containers:
                      name = c.get("name", "?")
                      status = c.get("status", c.get("state", "?"))
                      lines.append(f"| {name} | {status} |")
                  return "\n".join(lines)
              return "No containers found"

          elif cmd == "start" and len(args) >= 2:
              data = c3_req("POST", f"/vms/{args[0]}/containers/{args[1]}/start")
              if "error" in data:
                  return f":x: {data['error']}"
              return f":white_check_mark: Started **{args[1]}** on **{args[0]}**"

          elif cmd == "stop" and len(args) >= 2:
              data = c3_req("POST", f"/vms/{args[0]}/containers/{args[1]}/stop")
              if "error" in data:
                  return f":x: {data['error']}"
              return f":octagonal_sign: Stopped **{args[1]}** on **{args[0]}**"

          elif cmd == "restart" and len(args) >= 2:
              data = c3_req("POST", f"/vms/{args[0]}/containers/{args[1]}/restart")
              if "error" in data:
                  return f":x: {data['error']}"
              return f":arrows_counterclockwise: Restarted **{args[1]}** on **{args[0]}**"

          elif cmd == "gpu":
              return handle_gpu()

          elif cmd == "model" and args:
              new_model = " ".join(args)
              try:
                  r = requests.get(f"{OLLAMA_URL}/api/tags", timeout=10)
                  r.raise_for_status()
                  available = [m.get("name", "") for m in r.json().get("models", [])]
                  if new_model not in available and f"{new_model}:latest" not in available:
                      return f":x: Model `{new_model}` not found.\n**Available:**\n" + "\n".join(f"- `{m}`" for m in available)
              except Exception:
                  pass
              global OLLAMA_MODEL
              OLLAMA_MODEL = new_model
              _ollama_contexts.clear()
              return f":brain: Ollama model set to **`{new_model}`**\nContext cleared for all channels."

          elif cmd == "model" and not args:
              return f":brain: Current model: **`{OLLAMA_MODEL}`**"

          elif cmd == "models":
              try:
                  r = requests.get(f"{OLLAMA_URL}/api/tags", timeout=10)
                  r.raise_for_status()
                  models = r.json().get("models", [])
                  lines = ["| Model | Size | Modified |", "|:---|:---|:---|"]
                  for m in models:
                      name = m.get("name", "?")
                      size = f"{m.get('size', 0) / 1e9:.1f}GB"
                      modified = m.get("modified_at", "?")[:10]
                      current = " :white_check_mark:" if name == OLLAMA_MODEL else ""
                      lines.append(f"| `{name}`{current} | {size} | {modified} |")
                  return "\n".join(lines)
              except Exception as e:
                  return f":x: Cannot reach Ollama: {e}"

          else:
              return (
                  "**C3 Infrastructure Commands**\n"
                  "_DM me directly or use `/c3` in any channel_\n\n"
                  "| Command | Description |\n"
                  "|:---|:---|\n"
                  "| `status` | All VMs UP/DOWN |\n"
                  "| `vms` | VMs with CPU/RAM/disk |\n"
                  "| `wake <vm>` | Start a VM |\n"
                  "| `sleep <vm>` | Stop a VM |\n"
                  "| `reset <vm>` | Force reset a VM |\n"
                  "| `ps <vm>` | List containers on VM |\n"
                  "| `start <vm> <c>` | Start a container |\n"
                  "| `stop <vm> <c>` | Stop a container |\n"
                  "| `restart <vm> <c>` | Restart a container |\n"
                  "| `gpu` | Wake GPU VM + start ollama |\n"
                  "| `model [name]` | Get/set Ollama model |\n"
                  "| `models` | List available Ollama models |\n"
                  "| `help` | Show this message |"
              )


      ACTION_URL = "http://mattermost-bots:${toString config.c3_port}/c3/action"

      def make_buttons(actions):
          """Build Mattermost interactive message buttons. actions = [(label, command), ...]"""
          return [{
              "name": cmd,
              "integration": {
                  "url": ACTION_URL,
                  "context": {"command": cmd},
              },
          } for label, cmd in actions]

      def help_attachments():
          """Help message with quick-action buttons."""
          return [{
              "text": "_Quick actions:_",
              "actions": make_buttons([
                  (":bar_chart: Status", "status"),
                  (":desktop_computer: VMs", "vms"),
                  (":rocket: GPU", "gpu"),
              ]),
          }]

      def status_attachments(data):
          """After showing status, offer wake/sleep buttons per VM."""
          items = data if isinstance(data, list) else data.get("results", [])
          actions = []
          for item in items:
              alias = item.get("alias", item.get("vm", "?"))
              if item.get("reachable"):
                  actions.append((f":zzz: {alias}", f"sleep {alias}"))
                  actions.append((f":page_facing_up: {alias}", f"ps {alias}"))
              else:
                  actions.append((f":rocket: {alias}", f"wake {alias}"))
          if actions:
              return [{"text": "_Actions:_", "actions": make_buttons(actions[:8])}]
          return []


      class C3CommandHandler(BaseHTTPRequestHandler):
          """HTTP handler for slash commands and interactive button callbacks."""
          def do_POST(self):
              length = int(self.headers.get("Content-Length", 0))
              body = self.rfile.read(length).decode()

              # Check if this is an interactive action callback (JSON) or slash command (form-encoded)
              if self.path == "/c3/action":
                  try:
                      payload = json.loads(body)
                      text = payload.get("context", {}).get("command", "help")
                  except json.JSONDecodeError:
                      text = "help"
              else:
                  params = parse_qs(body)
                  text = params.get("text", ["help"])[0]

              # Extract channel_id for background tasks (slash commands include it)
              if self.path == "/c3/action":
                  slash_channel_id = None
              else:
                  slash_channel_id = params.get("channel_id", [None])[0]

              log.info("C3 command: %s", text)
              try:
                  response = handle_c3_command(text)
                  attachments = []
                  cmd = text.strip().split()[0].lower() if text.strip() else "help"
                  if cmd in ("help", ""):
                      attachments = help_attachments()
                  elif cmd == "status":
                      raw = c3_req("GET", "/health/tier1")
                      attachments = status_attachments(raw)
              except Exception as e:
                  log.exception("C3 command error")
                  response = f":x: Error: {e}"
                  attachments = []

              resp = {"response_type": "in_channel", "text": response}
              if attachments:
                  resp["attachments"] = attachments

              if self.path == "/c3/action":
                  resp = {"update": {"message": response, "props": {"attachments": attachments}}}

              self.send_response(200)
              self.send_header("Content-Type", "application/json")
              self.end_headers()
              self.wfile.write(json.dumps(resp).encode())

              # Launch background polling for gpu via slash command
              if cmd == "gpu" and slash_channel_id and _c3_bot_headers:
                  threading.Thread(
                      target=_gpu_background,
                      args=(slash_channel_id, "", _c3_bot_headers),
                      daemon=True,
                  ).start()

          def log_message(self, fmt, *a):
              pass


      def register_slash_command(headers, team_id):
          """Register or update /c3 slash command."""
          cmd_data = {
              "team_id": team_id,
              "trigger": "c3",
              "method": "P",
              "url": "http://mattermost-bots:${toString config.c3_port}/c3",
              "display_name": "C3 Infrastructure",
              "description": "Control VMs and containers",
              "auto_complete": True,
              "auto_complete_hint": "[status|vms|wake|sleep|reset|ps|start|stop|restart|gpu|model|models|help]",
          }
          r = mm_api("GET", f"/commands?team_id={team_id}", headers)
          if r.ok:
              for cmd in r.json():
                  if cmd.get("trigger") == "c3":
                      cmd_data["id"] = cmd["id"]
                      r2 = mm_api("PUT", f"/commands/{cmd['id']}", headers, json=cmd_data)
                      if r2.ok:
                          log.info("Updated slash command /c3: %s", cmd["id"])
                      else:
                          log.warning("Failed to update /c3: %s", r2.text[:200])
                      return
          r = mm_api("POST", "/commands", headers, json=cmd_data)
          if r.ok or r.status_code == 201:
              log.info("Registered slash command /c3")
          else:
              log.warning("Failed to register /c3: %s", r.text[:200])


      # ── C3 Bot Account ───────────────────────────────────────────

      def create_bot(admin_headers, team_id):
          """Create or find c3-bot account, add to team. Returns (bot_user_id, bot_token) or (None, None)."""
          bot_user_id = None
          r = mm_api("GET", "/bots?include_deleted=false&per_page=200", admin_headers)
          if r.ok:
              for bot in r.json():
                  if bot.get("username") == "c3-bot":
                      bot_user_id = bot["user_id"]
                      log.info("Found existing c3-bot: %s", bot_user_id)
                      break

          if not bot_user_id:
              r = mm_api("POST", "/bots", admin_headers, json={
                  "username": "c3-bot",
                  "display_name": "C3",
                  "description": "Infrastructure control bot. DM me: status, vms, gpu, help",
              })
              if r.ok or r.status_code == 201:
                  bot_user_id = r.json()["user_id"]
                  log.info("Created c3-bot: %s", bot_user_id)
              else:
                  log.error("Failed to create c3-bot: %s", r.text[:200])
                  return None, None

          # Add bot to team
          mm_api("POST", f"/teams/{team_id}/members", admin_headers, json={
              "team_id": team_id, "user_id": bot_user_id,
          })
          log.info("Added c3-bot to team %s", team_id)

          # Create a fresh access token
          r = mm_api("POST", f"/users/{bot_user_id}/tokens", admin_headers, json={
              "description": "c3-bot runtime",
          })
          if not r.ok:
              log.error("Failed to create bot token: %s", r.text[:200])
              return bot_user_id, None
          bot_token = r.json()["token"]
          log.info("Created c3-bot access token")
          return bot_user_id, bot_token


      def add_bot_to_channels(headers, bot_user_id, channel_ids):
          """Add bot user to all specified channels."""
          for ch_id in channel_ids:
              r = mm_api("POST", f"/channels/{ch_id}/members", headers, json={"user_id": bot_user_id})
              if r.ok or r.status_code == 201:
                  pass
              elif "already" in r.text.lower():
                  pass
              else:
                  log.warning("Failed to add bot to channel %s: %s", ch_id, r.text[:100])
          log.info("Bot %s added to %d channels", bot_user_id[:8], len(channel_ids))


      def ws_listener(bot_user_id, bot_token):
          """WebSocket listener — responds to DMs and @mentions."""
          ws_url = MM_URL.replace("http://", "ws://").replace("https://", "wss://") + "/api/v4/websocket"
          bot_headers = {"Authorization": f"Bearer {bot_token}"}

          def on_message(ws, message):
              try:
                  data = json.loads(message)
              except json.JSONDecodeError:
                  return
              if data.get("event") != "posted":
                  return
              post_data = data.get("data", {})
              channel_type = post_data.get("channel_type", "")
              try:
                  post = json.loads(post_data["post"])
              except (KeyError, json.JSONDecodeError):
                  return
              if post.get("user_id") == bot_user_id:
                  return
              text = post.get("message", "").strip()
              if not text:
                  return

              # Determine if DM or @mention in channel/group DM
              is_dm = channel_type == "D"
              if not is_dm:
                  # In channels and group DMs, require explicit @c3-bot in text
                  if "@c3-bot" not in text.lower():
                      return
                  text = re.sub(r"@c3-bot\s*", "", text).strip()
                  if not text:
                      text = "help"

              channel_id = post["channel_id"]
              root_id = post.get("id", "") if not is_dm else ""
              log.info("C3 bot %s: %s", "DM" if is_dm else "mention", text[:80])
              try:
                  response = handle_c3_command(text)
                  props = {}
                  cmd = text.strip().split()[0].lower() if text.strip() else "help"
                  if cmd in ("help", ""):
                      props["attachments"] = help_attachments()
                  elif cmd == "status":
                      raw = c3_req("GET", "/health/tier1")
                      props["attachments"] = status_attachments(raw)
              except Exception as e:
                  log.exception("C3 bot error")
                  response = f":x: Error: {e}"
                  props = {}

              post_body = {
                  "channel_id": channel_id,
                  "message": response,
              }
              if props:
                  post_body["props"] = props
              if root_id:
                  post_body["root_id"] = root_id
              mm_api("POST", "/posts", bot_headers, json=post_body)

              # Launch background polling for gpu command
              if cmd == "gpu":
                  threading.Thread(
                      target=_gpu_background,
                      args=(channel_id, root_id, bot_headers),
                      daemon=True,
                  ).start()

          def on_open(ws):
              ws.send(json.dumps({
                  "seq": 1,
                  "action": "authentication_challenge",
                  "data": {"token": bot_token},
              }))
              log.info("C3 bot WebSocket connected")

          def on_error(ws, error):
              log.warning("C3 bot WebSocket error: %s", error)

          def on_close(ws, code, msg):
              log.warning("C3 bot WebSocket closed: %s %s", code, msg)

          while True:
              try:
                  ws = websocket.WebSocketApp(
                      ws_url,
                      on_message=on_message,
                      on_open=on_open,
                      on_error=on_error,
                      on_close=on_close,
                  )
                  ws.run_forever(ping_interval=30, ping_timeout=10, origin="https://chat.diegonmarcos.com")
              except Exception as e:
                  log.warning("C3 bot WebSocket failed: %s — retrying in 5s", e)
              time.sleep(5)


      def setup_c3_sidebar(admin_headers, user_id, team_id, bot_user_id):
          """Create DM channel with bot and put it in the C3 sidebar category."""
          # Create DM channel between admin and bot
          r = mm_api("POST", "/channels/direct", admin_headers, json=[user_id, bot_user_id])
          if not r.ok:
              log.warning("Failed to create DM with c3-bot: %s", r.text[:100])
              return
          dm_channel_id = r.json()["id"]
          log.info("DM channel with c3-bot: %s", dm_channel_id)

          # Find or create C3 sidebar category
          r = mm_api("GET", f"/users/{user_id}/teams/{team_id}/channels/categories", admin_headers)
          if not r.ok:
              return
          categories = r.json().get("categories", [])
          c3_cat = None
          dm_cat = None
          for cat in categories:
              if cat.get("display_name") == "C3":
                  c3_cat = cat
              if cat.get("type") == "direct_messages":
                  dm_cat = cat

          # Remove bot DM from Direct Messages category
          if dm_cat and dm_channel_id in dm_cat.get("channel_ids", []):
              cleaned = [cid for cid in dm_cat["channel_ids"] if cid != dm_channel_id]
              mm_api("PUT", f"/users/{user_id}/teams/{team_id}/channels/categories/{dm_cat['id']}", admin_headers, json={
                  "id": dm_cat["id"],
                  "user_id": user_id,
                  "team_id": team_id,
                  "display_name": dm_cat.get("display_name", "Direct Messages"),
                  "type": "direct_messages",
                  "channel_ids": cleaned,
              })
              log.info("Removed c3-bot DM from Direct Messages category")

          if c3_cat:
              if dm_channel_id not in c3_cat.get("channel_ids", []):
                  ids = c3_cat["channel_ids"] + [dm_channel_id]
                  mm_api("PUT", f"/users/{user_id}/teams/{team_id}/channels/categories/{c3_cat['id']}", admin_headers, json={
                      "id": c3_cat["id"],
                      "user_id": user_id,
                      "team_id": team_id,
                      "display_name": "C3",
                      "type": "custom",
                      "channel_ids": ids,
                  })
                  log.info("Added c3-bot DM to C3 sidebar category")
              else:
                  log.info("c3-bot DM already in C3 sidebar category")
          else:
              r = mm_api("POST", f"/users/{user_id}/teams/{team_id}/channels/categories", admin_headers, json={
                  "user_id": user_id,
                  "team_id": team_id,
                  "display_name": "C3",
                  "type": "custom",
                  "channel_ids": [dm_channel_id],
              })
              if r.ok:
                  log.info("Created C3 sidebar category with bot DM")
              else:
                  log.warning("Failed to create C3 category: %s", r.text[:100])

          # Send welcome message if DM is empty
          r = mm_api("GET", f"/channels/{dm_channel_id}/posts?per_page=1", admin_headers)
          if r.ok and not r.json().get("order"):
              bot_headers = {"Authorization": f"Bearer {admin_headers['Authorization'].split()[-1]}"}
              mm_api("POST", "/posts", {"Authorization": admin_headers["Authorization"]}, json={
                  "channel_id": dm_channel_id,
                  "message": handle_c3_command("help"),
                  "props": {"from_webhook": "true", "override_username": "c3-bot"},
              })


      # ── Claude User Accounts ──────────────────────────────────

      CLAUDE_USERS = [
          {"username": "claude-opus-ai", "display_name": "Claude Opus", "email": "claude-opus@diegonmarcos.com"},
          {"username": "claude-sonnet-ai", "display_name": "Claude Sonnet", "email": "claude-sonnet@diegonmarcos.com"},
          {"username": "claude-haiku-ai", "display_name": "Claude Haiku", "email": "claude-haiku@diegonmarcos.com"},
      ]

      def create_claude_users(admin_headers, team_id, all_channel_ids):
          """Create Claude AI user accounts (regular users) and add to team + channels."""
          password = os.environ.get("MM_CLAUDE_PASSWORD")
          if not password:
              log.warning("MM_CLAUDE_PASSWORD not set — skipping Claude user creation")
              return
          for info in CLAUDE_USERS:
              r = mm_api("GET", f"/users/username/{info['username']}", admin_headers)
              if r.ok:
                  uid = r.json()["id"]
                  log.info("Claude user exists: %s (%s)", info["username"], uid)
              else:
                  name_parts = info["display_name"].split()
                  r = mm_api("POST", "/users", admin_headers, json={
                      "email": info["email"],
                      "username": info["username"],
                      "password": password,
                      "first_name": name_parts[0],
                      "last_name": name_parts[1] if len(name_parts) > 1 else "",
                  })
                  if r.ok or r.status_code == 201:
                      uid = r.json()["id"]
                      log.info("Created Claude user: %s (%s)", info["username"], uid)
                  else:
                      log.warning("Failed to create %s: %s", info["username"], r.text[:100])
                      continue
              # Add to team
              mm_api("POST", f"/teams/{team_id}/members", admin_headers, json={
                  "team_id": team_id, "user_id": uid,
              })
              # Add to all channels
              for ch_id in all_channel_ids:
                  mm_api("POST", f"/channels/{ch_id}/members", admin_headers, json={"user_id": uid})
              log.info("Added %s to team + %d channels", info["username"], len(all_channel_ids))


      # ── Ollama AI ─────────────────────────────────────────────

      def _check_wg_reachable(ip, port=22, timeout=3):
          """Direct TCP socket check via WireGuard IP."""
          try:
              s = socket.create_connection((ip, port), timeout=timeout)
              s.close()
              return True
          except Exception:
              return False

      def _check_vm_reachable(vm):
          """Quick tier1 check with WG IP fallback for known VMs."""
          check = c3_req("GET", f"/health/tier1/{vm}")
          if isinstance(check, list):
              if any(v.get("reachable") for v in check):
                  return True
          elif isinstance(check, dict):
              if check.get("reachable", False):
                  return True
          # Fallback: direct WG socket check (handles stale public IPs on spot VMs)
          if vm == OLLAMA_VM and OLLAMA_WG_IP:
              wg_ok = _check_wg_reachable(OLLAMA_WG_IP)
              if wg_ok:
                  log.info("tier1 failed for %s but WG IP %s reachable", vm, OLLAMA_WG_IP)
              return wg_ok
          return False

      def ensure_ollama_up():
          """Quick check — returns (ok, message). Does NOT block/poll."""
          if not _check_vm_reachable(OLLAMA_VM):
              c3_req("POST", f"/vms/{OLLAMA_VM}/start")
              return False, f":hourglass: {OLLAMA_VM} is down — waking up..."
          # VM reachable — check if Ollama API actually responds
          try:
              resp = requests.get(f"{OLLAMA_URL}/api/tags", timeout=5)
              if resp.ok:
                  return True, ""
          except Exception:
              pass
          # VM up but Ollama not responding — try compose up
          c3_req("POST", f"/vms/{OLLAMA_VM}/services/ollama/start", timeout=30)
          return False, f":hourglass: {OLLAMA_VM} reachable but Ollama not responding — starting service..."

      def _ollama_wake_and_reply(channel_id, root_id, user_text, post_headers):
          """Background thread: wake VM -> compose up -> poll Ollama API -> chat."""
          def _post(msg):
              body = {"channel_id": channel_id, "message": msg}
              if root_id:
                  body["root_id"] = root_id
              mm_api("POST", "/posts", post_headers, json=body)

          try:
              # Step 1: Start VM
              log.info("OllamaWake: step 1 — starting %s", OLLAMA_VM)
              r = c3_req("POST", f"/vms/{OLLAMA_VM}/start")
              log.info("OllamaWake: vm start response: %s", str(r)[:200])

              # Step 2: Poll until VM reachable via WireGuard
              log.info("OllamaWake: step 2 — polling VM reachability")
              vm_up = False
              for i in range(30):
                  time.sleep(5)
                  if _check_vm_reachable(OLLAMA_VM):
                      vm_up = True
                      break
              if not vm_up:
                  log.warning("OllamaWake: VM not reachable after 150s")
                  _post(f":warning: {OLLAMA_VM} not reachable after 150s")
                  return
              log.info("OllamaWake: VM reachable after %ds", (i+1)*5)
              _post(f":white_check_mark: {OLLAMA_VM} reachable")

              # Step 3: Start ollama service (compose up)
              log.info("OllamaWake: step 3 — starting ollama service")
              r = c3_req("POST", f"/vms/{OLLAMA_VM}/services/ollama/start", timeout=60)
              log.info("OllamaWake: service start response: %s", str(r)[:200])
              if "error" in r:
                  log.info("OllamaWake: service start failed, trying container start")
                  c3_req("POST", f"/vms/{OLLAMA_VM}/containers/ollama/start")

              # Step 4: Poll until Ollama HTTP API responds
              log.info("OllamaWake: step 4 — polling Ollama API at %s", OLLAMA_URL)
              _post(":hourglass: Waiting for Ollama API...")
              ollama_ready = False
              for i in range(24):
                  time.sleep(5)
                  try:
                      resp = requests.get(f"{OLLAMA_URL}/api/tags", timeout=5)
                      if resp.ok:
                          ollama_ready = True
                          log.info("OllamaWake: Ollama ready after %ds", (i+1)*5)
                          _post(f":white_check_mark: Ollama ready after {(i+1)*5}s")
                          break
                  except Exception:
                      pass
              if not ollama_ready:
                  log.warning("OllamaWake: Ollama API not responding after 120s")
                  _post(f":warning: Ollama API not responding after 120s")
                  return

              # Step 5: Send the actual chat
              log.info("OllamaWake: step 5 — sending chat")
              response = ollama_chat(channel_id, user_text)
              _post(response)
          except Exception as e:
              log.exception("_ollama_wake_and_reply crashed")
              try:
                  _post(f":x: Ollama wake crashed: {e}")
              except Exception:
                  log.exception("Failed to post ollama crash to MM")


      def ollama_chat(channel_id, user_text):
          """Send message to Ollama, maintain 10-msg context per channel."""
          ctx = _ollama_contexts.setdefault(channel_id, [])
          ctx.append({"role": "user", "content": user_text})
          if len(ctx) > 10:
              ctx[:] = ctx[-10:]
          try:
              r = requests.post(f"{OLLAMA_URL}/api/chat", json={
                  "model": OLLAMA_MODEL,
                  "messages": ctx,
                  "stream": False,
              }, timeout=300)
              r.raise_for_status()
              content = r.json().get("message", {}).get("content", "")
              content = re.sub(r"<think>[\s\S]*?</think>", "", content).strip()
              ctx.append({"role": "assistant", "content": content})
              return content or "(empty response)"
          except Exception as e:
              return f":x: Ollama error: {e}"


      OLLAMA_AI_USERNAME = "ollama-14bq8-ai"

      def create_ollama_ai(admin_headers, team_id):
          """Create or find Ollama AI account. Returns (ai_user_id, ai_token) or (None, None)."""
          ai_user_id = None
          r = mm_api("GET", "/bots?include_deleted=false&per_page=200", admin_headers)
          if r.ok:
              for entry in r.json():
                  if entry.get("username") == OLLAMA_AI_USERNAME:
                      ai_user_id = entry["user_id"]
                      log.info("Found existing %s: %s", OLLAMA_AI_USERNAME, ai_user_id)
                      break
          if not ai_user_id:
              r = mm_api("POST", "/bots", admin_headers, json={
                  "username": OLLAMA_AI_USERNAME,
                  "display_name": "Ollama 14B-Q8 AI",
                  "description": "Chat with DeepSeek-R1 14B Q8 LLM. DM me or @mention. Commands: clear, model <name>, models, status",
              })
              if r.ok or r.status_code == 201:
                  ai_user_id = r.json()["user_id"]
                  log.info("Created %s: %s", OLLAMA_AI_USERNAME, ai_user_id)
              else:
                  log.error("Failed to create %s: %s", OLLAMA_AI_USERNAME, r.text[:200])
                  return None, None
          mm_api("POST", f"/teams/{team_id}/members", admin_headers, json={
              "team_id": team_id, "user_id": ai_user_id,
          })
          r = mm_api("POST", f"/users/{ai_user_id}/tokens", admin_headers, json={
              "description": f"{OLLAMA_AI_USERNAME} runtime",
          })
          if not r.ok:
              log.error("Failed to create %s token: %s", OLLAMA_AI_USERNAME, r.text[:200])
              return ai_user_id, None
          ai_token = r.json()["token"]
          log.info("Created %s access token", OLLAMA_AI_USERNAME)
          return ai_user_id, ai_token


      def ollama_ws_listener(ai_user_id, ai_token):
          """WebSocket listener for Ollama AI — DMs + @mentions."""
          ws_url = MM_URL.replace("http://", "ws://").replace("https://", "wss://") + "/api/v4/websocket"
          ai_headers = {"Authorization": f"Bearer {ai_token}"}

          def on_message(ws, message):
              try:
                  data = json.loads(message)
              except json.JSONDecodeError:
                  return
              if data.get("event") != "posted":
                  return
              post_data = data.get("data", {})
              channel_type = post_data.get("channel_type", "")
              try:
                  post = json.loads(post_data["post"])
              except (KeyError, json.JSONDecodeError):
                  return
              if post.get("user_id") == ai_user_id:
                  return
              text = post.get("message", "").strip()
              if not text:
                  return

              is_dm = channel_type == "D"
              if not is_dm:
                  # In channels and group DMs, require explicit @mention in text
                  if f"@{OLLAMA_AI_USERNAME}" not in text.lower():
                      return
                  text = re.sub(rf"@{re.escape(OLLAMA_AI_USERNAME)}\s*", "", text, flags=re.IGNORECASE).strip()
                  if not text:
                      text = "hello"

              channel_id = post["channel_id"]
              root_id = post.get("id", "") if not is_dm else ""
              log.info("%s %s: %s", OLLAMA_AI_USERNAME, "DM" if is_dm else "mention", text[:80])

              def _post_reply(msg):
                  body = {"channel_id": channel_id, "message": msg}
                  if root_id:
                      body["root_id"] = root_id
                  mm_api("POST", "/posts", ai_headers, json=body)

              cmd_lower = text.lower().strip()
              if cmd_lower == "clear":
                  _ollama_contexts.pop(channel_id, None)
                  _post_reply(":wastebasket: Context cleared")
              elif cmd_lower.startswith("model "):
                  global OLLAMA_MODEL
                  new_model = text[6:].strip()
                  OLLAMA_MODEL = new_model
                  _ollama_contexts.clear()
                  _post_reply(f":brain: Model set to **{new_model}** (context cleared)")
              elif cmd_lower == "models":
                  try:
                      r = requests.get(f"{OLLAMA_URL}/api/tags", timeout=30)
                      r.raise_for_status()
                      models = [m.get("name", "?") for m in r.json().get("models", [])]
                      _post_reply("**Available models:**\n" + "\n".join(f"- `{m}`" for m in models) if models else "No models found")
                  except Exception as e:
                      ok, wake_msg = ensure_ollama_up()
                      _post_reply(wake_msg if wake_msg else f":x: {e}")
              elif cmd_lower == "status":
                  reachable = _check_vm_reachable(OLLAMA_VM)
                  icon = ":white_check_mark:" if reachable else ":x:"
                  ctx_len = len(_ollama_contexts.get(channel_id, []))
                  _post_reply(f"{icon} **{OLLAMA_VM}** | Model: `{OLLAMA_MODEL}` | Context: {ctx_len} msgs")
              else:
                  # Chat request — may need to wake VM + run inference (slow)
                  # Run in background thread to not block WebSocket
                  def _handle_chat():
                      try:
                          ok, wake_msg = ensure_ollama_up()
                          if not ok:
                              # VM/Ollama not ready — full wake chain + chat
                              _post_reply(wake_msg)
                              _ollama_wake_and_reply(channel_id, root_id, text, ai_headers)
                              return
                          response = ollama_chat(channel_id, text)
                          _post_reply(response)
                      except Exception as e:
                          log.exception("_handle_chat crashed")
                          try:
                              _post_reply(f":x: Chat error: {e}")
                          except Exception:
                              log.exception("Failed to post chat crash to MM")
                  threading.Thread(target=_handle_chat, daemon=True).start()

          def on_open(ws):
              ws.send(json.dumps({
                  "seq": 1,
                  "action": "authentication_challenge",
                  "data": {"token": ai_token},
              }))
              log.info("%s WebSocket connected", OLLAMA_AI_USERNAME)

          def on_error(ws, error):
              log.warning("%s WebSocket error: %s", OLLAMA_AI_USERNAME, error)

          def on_close(ws, code, msg):
              log.warning("%s WebSocket closed: %s %s", OLLAMA_AI_USERNAME, code, msg)

          while True:
              try:
                  ws = websocket.WebSocketApp(
                      ws_url,
                      on_message=on_message,
                      on_open=on_open,
                      on_error=on_error,
                      on_close=on_close,
                  )
                  ws.run_forever(ping_interval=30, ping_timeout=10, origin="https://chat.diegonmarcos.com")
              except Exception as e:
                  log.warning("%s WebSocket failed: %s — retrying in 5s", OLLAMA_AI_USERNAME, e)
              time.sleep(5)


      def setup_ollama_sidebar(admin_headers, user_id, team_id, ai_user_id):
          """Create DM channel with Ollama AI and put it in the C3 sidebar category."""
          r = mm_api("POST", "/channels/direct", admin_headers, json=[user_id, ai_user_id])
          if not r.ok:
              log.warning("Failed to create DM with %s: %s", OLLAMA_AI_USERNAME, r.text[:100])
              return
          dm_channel_id = r.json()["id"]
          log.info("DM channel with %s: %s", OLLAMA_AI_USERNAME, dm_channel_id)

          r = mm_api("GET", f"/users/{user_id}/teams/{team_id}/channels/categories", admin_headers)
          if not r.ok:
              return
          categories = r.json().get("categories", [])
          c3_cat = None
          dm_cat = None
          for cat in categories:
              if cat.get("display_name") == "C3":
                  c3_cat = cat
              if cat.get("type") == "direct_messages":
                  dm_cat = cat

          if dm_cat and dm_channel_id in dm_cat.get("channel_ids", []):
              cleaned = [cid for cid in dm_cat["channel_ids"] if cid != dm_channel_id]
              mm_api("PUT", f"/users/{user_id}/teams/{team_id}/channels/categories/{dm_cat['id']}", admin_headers, json={
                  "id": dm_cat["id"], "user_id": user_id, "team_id": team_id,
                  "display_name": dm_cat.get("display_name", "Direct Messages"),
                  "type": "direct_messages", "channel_ids": cleaned,
              })

          if c3_cat:
              if dm_channel_id not in c3_cat.get("channel_ids", []):
                  ids = c3_cat["channel_ids"] + [dm_channel_id]
                  mm_api("PUT", f"/users/{user_id}/teams/{team_id}/channels/categories/{c3_cat['id']}", admin_headers, json={
                      "id": c3_cat["id"], "user_id": user_id, "team_id": team_id,
                      "display_name": "C3", "type": "custom", "channel_ids": ids,
                  })
                  log.info("Added %s DM to C3 sidebar category", OLLAMA_AI_USERNAME)
          else:
              mm_api("POST", f"/users/{user_id}/teams/{team_id}/channels/categories", admin_headers, json={
                  "user_id": user_id, "team_id": team_id,
                  "display_name": "C3", "type": "custom", "channel_ids": [dm_channel_id],
              })
              log.info("Created C3 sidebar category with %s DM", OLLAMA_AI_USERNAME)


      # ── Profile Icons ──────────────────────────────────────────

      def make_brain_svg(letter, color):
          """Generate a colored circle SVG with a letter overlay."""
          return f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 128 128">
        <circle cx="64" cy="64" r="60" fill="{color}"/>
        <text x="64" y="82" text-anchor="middle" font-size="64" font-family="Arial,sans-serif" font-weight="bold" fill="white">{letter}</text>
      </svg>"""

      def make_gear_svg(color):
          """Generate a colored circle SVG with a gear icon for bot."""
          return f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 128 128">
        <circle cx="64" cy="64" r="60" fill="{color}"/>
        <path d="M64 40a24 24 0 100 48 24 24 0 000-48zm0 38a14 14 0 110-28 14 14 0 010 28z" fill="white"/>
        <rect x="59" y="24" width="10" height="14" rx="2" fill="white"/>
        <rect x="59" y="90" width="10" height="14" rx="2" fill="white"/>
        <rect x="24" y="59" width="14" height="10" rx="2" fill="white"/>
        <rect x="90" y="59" width="14" height="10" rx="2" fill="white"/>
        <rect x="33" y="33" width="10" height="14" rx="2" fill="white" transform="rotate(45 38 40)"/>
        <rect x="85" y="81" width="10" height="14" rx="2" fill="white" transform="rotate(45 90 88)"/>
        <rect x="33" y="81" width="10" height="14" rx="2" fill="white" transform="rotate(-45 38 88)"/>
        <rect x="85" y="33" width="10" height="14" rx="2" fill="white" transform="rotate(-45 90 40)"/>
      </svg>"""

      def make_colored_png(letter, color, size=128):
          """Generate a simple colored PNG with a letter, using Pillow."""
          img = Image.new("RGB", (size, size), color)
          draw = ImageDraw.Draw(img)
          try:
              font = ImageFont.load_default(size=80)
          except TypeError:
              font = ImageFont.load_default()
          bbox = draw.textbbox((0, 0), letter, font=font)
          x = (size - (bbox[2] - bbox[0])) // 2
          y = (size - (bbox[3] - bbox[1])) // 2
          draw.text((x, y), letter, fill="white", font=font)
          buf = io.BytesIO()
          img.save(buf, format="PNG")
          return buf.getvalue()

      def set_account_icons(admin_headers, account_ids):
          """Set profile icons for all bot/AI accounts at bootstrap (PNG via /users/{id}/image)."""
          icons = {
              "c3-bot": ("#00B8D9", "C3"),
              OLLAMA_AI_USERNAME: ("#FF1744", "Q"),
              "claude-opus-ai": ("#FF6B35", "O"),
              "claude-sonnet-ai": ("#7B61FF", "S"),
              "claude-haiku-ai": ("#00C853", "H"),
          }
          for username, (color, letter) in icons.items():
              uid = account_ids.get(username)
              if not uid:
                  continue
              png_data = make_colored_png(letter, color)
              r = mm_api("POST", f"/users/{uid}/image", admin_headers,
                         files={"image": ("icon.png", png_data, "image/png")})
              if r.ok:
                  log.info("Set icon for %s", username)
              else:
                  log.warning("Failed to set icon for %s: %s", username, r.text[:100])


      def main():
          wait_for_mattermost()
          admin_token = bootstrap_admin()
          headers = {"Authorization": f"Bearer {admin_token}"}

          # Get admin user_id for sidebar category
          r = mm_api("GET", "/users/me", headers)
          r.raise_for_status()
          user_id = r.json()["id"]

          team_id = ensure_team(headers)
          default_ch, ntfy_channel_ids = sync_channels(headers, team_id)
          webhook_url = ensure_webhook(headers, default_ch)

          # Group ntfy channels under sidebar category
          sync_sidebar_category(headers, user_id, team_id, ntfy_channel_ids)

          # Register /c3 slash command and start HTTP server
          register_slash_command(headers, team_id)
          server = HTTPServer(("0.0.0.0", ${toString config.c3_port}), C3CommandHandler)
          threading.Thread(target=server.serve_forever, daemon=True).start()
          log.info("C3 command server listening on :${toString config.c3_port}")

          # Get ALL channels (public + private) for bot membership
          r = mm_api("GET", f"/teams/{team_id}/channels?per_page=200", headers)
          all_channel_ids = [ch["id"] for ch in r.json()] if r.ok else []

          # Also add bot to group DMs the admin is in
          r = mm_api("GET", f"/users/{user_id}/channels", headers)
          if r.ok:
              for ch in r.json():
                  if ch.get("type") == "G" and ch["id"] not in all_channel_ids:
                      all_channel_ids.append(ch["id"])

          # Create Claude user accounts
          create_claude_users(headers, team_id, all_channel_ids)

          # Create c3-bot account and start WebSocket DM listener
          bot_user_id, bot_token = create_bot(headers, team_id)
          if bot_user_id and bot_token:
              global _c3_bot_headers
              _c3_bot_headers = {"Authorization": f"Bearer {bot_token}"}
              add_bot_to_channels(headers, bot_user_id, all_channel_ids)
              threading.Thread(target=ws_listener, args=(bot_user_id, bot_token), daemon=True).start()
              setup_c3_sidebar(headers, user_id, team_id, bot_user_id)
              log.info("C3 bot ready — DM @c3-bot or use /c3")
          else:
              log.warning("C3 bot creation failed — slash command still works")

          # Create Ollama AI and start WebSocket listener
          ollama_user_id, ollama_token = create_ollama_ai(headers, team_id)
          if ollama_user_id and ollama_token:
              add_bot_to_channels(headers, ollama_user_id, all_channel_ids)
              threading.Thread(target=ollama_ws_listener, args=(ollama_user_id, ollama_token), daemon=True).start()
              setup_ollama_sidebar(headers, user_id, team_id, ollama_user_id)
              log.info("%s ready — DM @%s or @mention", OLLAMA_AI_USERNAME, OLLAMA_AI_USERNAME)
          else:
              log.warning("%s creation failed", OLLAMA_AI_USERNAME)

          # Set profile icons for bots and AI accounts
          account_ids = {}
          if bot_user_id:
              account_ids["c3-bot"] = bot_user_id
          if ollama_user_id:
              account_ids[OLLAMA_AI_USERNAME] = ollama_user_id
          for info in CLAUDE_USERS:
              r = mm_api("GET", f"/users/username/{info['username']}", headers)
              if r.ok:
                  account_ids[info["username"]] = r.json()["id"]
          set_account_icons(headers, account_ids)

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
      websocket-client>=1.6.0
      Pillow>=10.1.0
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
      defaultPkg = pkgs.runCommand "mattermost-bots-configs" {} ''
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
