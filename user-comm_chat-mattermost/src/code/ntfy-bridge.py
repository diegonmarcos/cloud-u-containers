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

# Sidebar category display names — data-driven from build.json#sidebar_categories,
# injected as MM_SIDEBAR_CATEGORIES (JSON) by compose.nix. Defaults match the
# established layout so the bridge still works if the env var is absent.
_CATS = json.loads(os.environ.get("MM_SIDEBAR_CATEGORIES") or "{}")
CAT_NTFY     = _CATS.get("ntfy", "NTFY")
CAT_AGENTS   = _CATS.get("agents", "AGENTS")
CAT_PROJECTS = _CATS.get("default_channels", "Projects")


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

# C3 slash-command HTTP server bind + URL config (env-driven; set by compose)
C3_BIND_IP = os.environ.get("C3_BIND_IP", "0.0.0.0")
C3_PORT = int(os.environ.get("C3_PORT", "8887"))
C3_ACTION_URL = os.environ.get("C3_ACTION_URL", f"http://mattermost-bots:{C3_PORT}/c3/action")
C3_SLASH_URL = os.environ.get("C3_SLASH_URL", f"http://mattermost-bots:{C3_PORT}/c3")
_c3_bot_headers = None  # set after c3-bot login, used by slash cmd gpu background


def mm_api(method, path, headers, timeout=30, **kwargs):
    return requests.request(method, f"{MM_URL}/api/v4{path}", headers=headers, timeout=timeout, **kwargs)


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

    log.info("Admin login failed (%d), attempting user creation...", r.status_code)
    r = mm_api("POST", "/users", {}, json={
        "email": MM_ADMIN_EMAIL,
        "username": MM_ADMIN_USERNAME,
        "password": MM_ADMIN_PASSWORD,
    })
    err_text = r.text.lower()
    if not (r.ok or r.status_code == 201):
        if "already exists" in err_text or "no_open_server" in err_text or r.status_code == 403:
            log.warning("User creation blocked (%d): %s", r.status_code, r.text[:200])
        else:
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
        if cat.get("display_name") == CAT_NTFY:
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
                "display_name": CAT_NTFY,
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
            "| `help` | Show this message |"
        )


ACTION_URL = C3_ACTION_URL

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

    def log_message(self, fmt, *a):
        pass


def register_slash_command(headers, team_id):
    """Register or update /c3 slash command."""
    cmd_data = {
        "team_id": team_id,
        "trigger": "c3",
        "method": "P",
        "url": C3_SLASH_URL,
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
        if cat.get("display_name") == CAT_AGENTS:
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
                "display_name": CAT_AGENTS,
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
            "display_name": CAT_AGENTS,
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

def create_claude_users(admin_headers, team_id, all_channel_ids, ntfy_channel_ids=None):
    """Create Claude AI user accounts (regular users) and add to team + channels + sidebar categories."""
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
        # Set up ntfy sidebar category for this Claude user
        if ntfy_channel_ids:
            sync_sidebar_category(admin_headers, uid, team_id, ntfy_channel_ids)


def create_hai_ai(admin_headers, team_id):
    """Create or find HAI AI bot account (no WS listener — rig-agentic-hai handles its own).
    Returns (bot_user_id, bot_token) or (None, None)."""
    bot_user_id = None
    r = mm_api("GET", "/bots?include_deleted=false&per_page=200", admin_headers)
    if r.ok:
        for entry in r.json():
            if entry.get("username") == HAI_AI_USERNAME:
                bot_user_id = entry["user_id"]
                log.info("Found existing %s: %s", HAI_AI_USERNAME, bot_user_id)
                break
    if not bot_user_id:
        r = mm_api("POST", "/bots", admin_headers, json={
            "username": HAI_AI_USERNAME,
            "display_name": "HAI Agent (Qwen 1.5B)",
            "description": "Lightweight infra agent with strict guardrails. DM me or @mention. Always on (CPU, oci-apps).",
        })
        if r.ok or r.status_code == 201:
            bot_user_id = r.json()["user_id"]
            log.info("Created %s: %s", HAI_AI_USERNAME, bot_user_id)
        else:
            log.error("Failed to create %s: %s", HAI_AI_USERNAME, r.text[:200])
            return None, None
    mm_api("POST", f"/teams/{team_id}/members", admin_headers, json={
        "team_id": team_id, "user_id": bot_user_id,
    })
    r = mm_api("POST", f"/users/{bot_user_id}/tokens", admin_headers, json={
        "description": f"{HAI_AI_USERNAME} runtime",
    })
    if not r.ok:
        log.error("Failed to create %s token: %s", HAI_AI_USERNAME, r.text[:200])
        return bot_user_id, None
    bot_token = r.json()["token"]
    log.info("Created %s access token: %s", HAI_AI_USERNAME, bot_token)
    return bot_user_id, bot_token


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
        HAI_AI_USERNAME: ("#00BCD4", "H"),
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


def ensure_agents_llm_config(headers):
    """Wire LLM backends into the mattermost-ai Agents plugin via config API.
    Idempotent — skips PUT if the stored backends already match. Runs before
    the ntfy bridge loop so every bots-container restart re-verifies the config."""
    backends_json = os.environ.get("MM_AGENTS_LLM_BACKENDS")
    if not backends_json:
        return
    backends = json.loads(backends_json)
    r = mm_api("GET", "/config", headers)
    if not r.ok:
        log.warning("ensure_agents_llm_config: cannot GET config: %s", r.text[:100])
        return
    cfg = r.json()
    cur = (cfg.get("PluginSettings") or {}).get("Plugins", {}).get("mattermost-ai", {}).get("llmBackends", [])
    if cur == backends:
        log.info("Agents plugin LLM backends already up-to-date")
        return
    cfg.setdefault("PluginSettings", {}).setdefault("Plugins", {}).setdefault("mattermost-ai", {})["llmBackends"] = backends
    r = mm_api("PUT", "/config", headers, timeout=120, json=cfg)
    if r.ok:
        log.info("Agents plugin LLM backends configured (%d backend(s))", len(backends))
    else:
        log.warning("Agents plugin LLM backends config failed: %s", r.text[:200])


def reconcile_categories(headers, user_id, team_id):
    """Migrate existing sidebar category names to the configured set, in place
    (by id, so channel membership/history is preserved): ntfy→NTFY, C3→AGENTS,
    and the default 'Channels' category → Projects. Idempotent — a no-op once
    names already match. Runs before the create-if-missing steps so they look
    up (and extend) the renamed categories instead of spawning duplicates."""
    r = mm_api("GET", f"/users/{user_id}/teams/{team_id}/channels/categories", headers)
    if not r.ok:
        log.warning("reconcile_categories: cannot list categories: %s", r.text[:100])
        return
    renames = {"ntfy": CAT_NTFY, "C3": CAT_AGENTS}
    for cat in r.json().get("categories", []):
        cur = cat.get("display_name")
        target = renames.get(cur)
        if target is None and cat.get("type") == "channels":
            target = CAT_PROJECTS
        if not target or target == cur:
            continue
        body = dict(cat)
        body["display_name"] = target
        rr = mm_api("PUT", f"/users/{user_id}/teams/{team_id}/channels/categories/{cat['id']}", headers, json=body)
        if rr.ok:
            log.info("Reconciled sidebar category %r -> %r", cur, target)
        else:
            log.warning("Failed to rename category %r -> %r: %s", cur, target, rr.text[:100])


def main():
    wait_for_mattermost()
    admin_token = bootstrap_admin()
    headers = {"Authorization": f"Bearer {admin_token}"}

    # Get admin user_id for sidebar category
    r = mm_api("GET", "/users/me", headers)
    r.raise_for_status()
    user_id = r.json()["id"]

    team_id = ensure_team(headers)
    # Rename any pre-existing categories to the configured set before the
    # create-if-missing steps below look them up (ntfy→NTFY, C3→AGENTS, Channels→Projects).
    reconcile_categories(headers, user_id, team_id)
    # Wire claude-superset-api as the Agents plugin LLM backend (idempotent).
    ensure_agents_llm_config(headers)
    default_ch, ntfy_channel_ids = sync_channels(headers, team_id)
    webhook_url = ensure_webhook(headers, default_ch)

    # Group ntfy channels under sidebar category
    sync_sidebar_category(headers, user_id, team_id, ntfy_channel_ids)

    # Register /c3 slash command and start HTTP server
    register_slash_command(headers, team_id)
    server = HTTPServer((C3_BIND_IP, C3_PORT), C3CommandHandler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    log.info("C3 command server listening on %s:%d", C3_BIND_IP, C3_PORT)

    # Get ALL channels (public + private) for bot membership
    r = mm_api("GET", f"/teams/{team_id}/channels?per_page=200", headers)
    all_channel_ids = [ch["id"] for ch in r.json()] if r.ok else []

    # Also add bot to group DMs the admin is in
    r = mm_api("GET", f"/users/{user_id}/channels", headers)
    if r.ok:
        for ch in r.json():
            if ch.get("type") == "G" and ch["id"] not in all_channel_ids:
                all_channel_ids.append(ch["id"])

    # Create Claude user accounts (with ntfy sidebar categories)
    create_claude_users(headers, team_id, all_channel_ids, ntfy_channel_ids)

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

    # Create HAI AI bot account (no WS listener — rig-agentic-hai handles its own)
    hai_user_id, hai_token = create_hai_ai(headers, team_id)
    if hai_user_id:
        add_bot_to_channels(headers, hai_user_id, all_channel_ids)
        log.info("%s ready — token logged above, add to rig-agentic-hai secrets.yaml", HAI_AI_USERNAME)
    else:
        log.warning("%s creation failed", HAI_AI_USERNAME)

    # Set profile icons for bots and AI accounts
    account_ids = {}
    if bot_user_id:
        account_ids["c3-bot"] = bot_user_id
    if hai_user_id:
        account_ids[HAI_AI_USERNAME] = hai_user_id
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
