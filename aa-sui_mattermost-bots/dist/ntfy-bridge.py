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
TOPIC_SCANNER_URL = os.environ.get("TOPIC_SCANNER_URL", "http://10.0.0.1:8091")
MM_URL = os.environ["MM_URL"]
MM_ADMIN_EMAIL = os.environ["MM_ADMIN_EMAIL"]
MM_ADMIN_USERNAME = os.environ["MM_ADMIN_USERNAME"]
MM_ADMIN_PASSWORD = os.environ["MM_ADMIN_PASSWORD"]
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


def fetch_topics() -> list[str]:
    """Fetch active topics from the ntfy topic-scanner."""
    try:
        r = requests.get(TOPIC_SCANNER_URL, timeout=10)
        r.raise_for_status()
        topics = r.json().get("topics", [])
        if topics:
            return topics
    except Exception as e:
        log.warning("Failed to fetch topics from scanner: %s", e)
    return []


def subscribe_and_bridge() -> None:
    topics = fetch_topics()
    if not topics:
        log.warning("No topics from scanner, retrying in 30s...")
        time.sleep(30)
        return

    topic_str = ",".join(topics)
    url = f"{NTFY_URL}/{topic_str}/json"
    log.info("Subscribing to %d topics: %s", len(topics), topic_str[:120])

    with requests.get(url, stream=True, timeout=(10, None)) as resp:
        resp.raise_for_status()
        log.info("Connected to ntfy stream")
        last_topic_refresh = time.time()

        for line in resp.iter_lines(decode_unicode=True):
            if not line:
                # Check if we should refresh topics (every 5 min)
                if time.time() - last_topic_refresh > 300:
                    new_topics = fetch_topics()
                    if set(new_topics) != set(topics):
                        log.info("Topic list changed, reconnecting...")
                        return  # Will reconnect in main loop with new topics
                    last_topic_refresh = time.time()
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
