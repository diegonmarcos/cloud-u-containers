#!/usr/bin/env python3
"""IMAP inbox sorter for Maddy — dual-vector email organization.

Reads mail-rules.json (shared with Stalwart Sieve) and applies:
  A) Routing: copy to one of 6 emoji category folders (unread)
  B) Tags-as-folders: copy to B1-B8 subfolders (unread for B1-B6, read for B7-B8)
  INBOX: all emails stay here, auto-marked as read

Maddy has no Sieve/tag support — this script bridges the gap via IMAP protocol.
"""
import imaplib
import json
import email
import email.utils
import time
import os
import sys
import logging
import re
import ssl

logging.basicConfig(
    stream=sys.stdout, level=logging.INFO,
    format="%(asctime)s [sorter] %(message)s", datefmt="%H:%M:%S"
)

RULES_PATH = os.getenv("RULES_PATH", "/data/mail-rules.json")
IMAP_HOST = os.getenv("IMAP_HOST", "127.0.0.1")
IMAP_PORT = int(os.getenv("IMAP_PORT", "993"))
IMAP_SSL = os.getenv("IMAP_SSL", "true").lower() in ("true", "1", "yes")
POLL_INTERVAL = int(os.getenv("POLL_INTERVAL", "30"))
STARTUP_DELAY = int(os.getenv("STARTUP_DELAY", "15"))

# B7 and B8 are meta folders — copies marked as read
META_TAG_IDS = {"B7", "B8"}


def load_rules(path):
    with open(path) as f:
        return json.load(f)


def imap_connect():
    """Connect to IMAP with SSL and skip cert verification (self-signed)."""
    if IMAP_SSL:
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        return imaplib.IMAP4_SSL(IMAP_HOST, IMAP_PORT, ssl_context=ctx)
    return imaplib.IMAP4(IMAP_HOST, IMAP_PORT)


def match_routing(from_domain, rules):
    """Return folder name for first matching routing rule, or None."""
    for route in rules["routing"]:
        match = route["match"]
        if match["type"] == "from_domain" and from_domain in match["values"]:
            return route["folder"]
    return None


def match_tags(headers, msg_size, content_types, rules):
    """Return list of (group_name, flag, is_meta) for all matching tag rules."""
    matches = []
    from_addr = email.utils.parseaddr(headers.get("From", ""))[1].lower()
    from_domain = from_addr.split("@")[-1] if "@" in from_addr else ""
    account = rules.get("account", "")

    for group in rules.get("tags", []):
        group_name = group["name"]
        is_meta = group["id"] in META_TAG_IDS

        for rule in group.get("rules", []):
            matched = False
            rtype = rule["type"]

            if rtype == "from_domain":
                matched = from_domain in rule["values"]
            elif rtype == "from_address":
                matched = from_addr in rule["values"]
            elif rtype == "header_contains":
                header_val = headers.get(rule["header"], "").lower()
                matched = any(v.lower() in header_val for v in rule["values"])
            elif rtype == "header_exists":
                matched = rule["header"] in headers
            elif rtype == "size_over":
                matched = msg_size >= rule["bytes"]
            elif rtype == "self_sent":
                matched = from_addr == account
            elif rtype == "has_cc":
                matched = "CC" in headers
            elif rtype == "list_header":
                matched = "List-Unsubscribe" in headers
            elif rtype == "content_type":
                matched = rule["value"] in content_types

            if matched:
                # Sub-number within group for folder name (e.g. 1.0 Dev_context:42Berlin)
                rule_idx = group["rules"].index(rule)
                group_num = group["name"].split(".")[0] if "." in group["name"] else group["id"][-1]
                sub_folder = f"{group_num}.{rule_idx} {rule['flag']}"
                matches.append((group_name, sub_folder, rule["flag"], is_meta))

    return matches


def imap_utf7_encode(s):
    """Encode a Unicode string to modified UTF-7 for IMAP folder names."""
    result = []
    buf = ""
    for ch in s:
        if 0x20 <= ord(ch) <= 0x7e:
            if buf:
                encoded = buf.encode("utf-16-be")
                b64 = __import__("base64").b64encode(encoded).decode("ascii").rstrip("=")
                result.append("&" + b64.replace("/", ",") + "-")
                buf = ""
            if ch == "&":
                result.append("&-")
            else:
                result.append(ch)
        else:
            buf += ch
    if buf:
        encoded = buf.encode("utf-16-be")
        b64 = __import__("base64").b64encode(encoded).decode("ascii").rstrip("=")
        result.append("&" + b64.replace("/", ",") + "-")
    return "".join(result)


def ensure_folder(imap, folder):
    """Create IMAP folder if it doesn't exist (idempotent)."""
    encoded = imap_utf7_encode(folder)
    imap.create(f'"{encoded}"')


def get_content_types(imap, uid):
    """Fetch BODYSTRUCTURE and extract content types."""
    types = set()
    try:
        _, data = imap.uid("FETCH", uid, "(BODYSTRUCTURE)")
        if data and data[0]:
            body = data[0][0] if isinstance(data[0], tuple) else data[0]
            if isinstance(body, bytes):
                body = body.decode("utf-8", errors="replace")
            for match in re.findall(r'"([a-z]+/[a-z0-9.+_-]+)"', body.lower()):
                types.add(match)
    except Exception:
        pass
    return types


def sort_inbox(imap, rules):
    """Process unsorted messages in INBOX. Returns count of sorted messages."""
    imap.select("INBOX")
    _, data = imap.uid("SEARCH", None, "UNKEYWORD $Sorted")
    if not data[0]:
        return 0

    uids = data[0].split()
    count = 0

    for uid in uids:
        uid_str = uid.decode() if isinstance(uid, bytes) else uid

        # Fetch headers + size
        _, msg_data = imap.uid("FETCH", uid_str, "(RFC822.SIZE BODY.PEEK[HEADER])")
        if not msg_data or not msg_data[0] or not isinstance(msg_data[0], tuple):
            continue

        raw = msg_data[0]
        meta_line = raw[0].decode("utf-8", errors="replace") if isinstance(raw[0], bytes) else raw[0]
        header_bytes = raw[1] if len(raw) > 1 else b""

        # Extract size
        size_match = re.search(r"RFC822\.SIZE\s+(\d+)", meta_line)
        msg_size = int(size_match.group(1)) if size_match else 0

        # Parse headers
        headers = email.message_from_bytes(header_bytes)
        from_addr = email.utils.parseaddr(headers.get("From", ""))[1].lower()
        from_domain = from_addr.split("@")[-1] if "@" in from_addr else ""
        subject = headers.get("Subject", "")[:60]

        # Get content types for attachment matching
        content_types = get_content_types(imap, uid_str)

        # A) Route to category folder (unread copy)
        folder = match_routing(from_domain, rules)
        if not folder:
            folder = rules.get("routing_default", None)
        if folder:
            enc_folder = imap_utf7_encode(folder)
            ensure_folder(imap, folder)
            result = imap.uid("COPY", uid_str, f'"{enc_folder}"')
            if result[0] == "OK":
                count += 1

        # B) Tag folders (copies into B-group subfolders)
        tag_matches = match_tags(headers, msg_size, content_types, rules)
        for group_name, sub_folder, flag, is_meta in tag_matches:
            tag_folder = f"{group_name}/{sub_folder}"
            enc_tag = imap_utf7_encode(tag_folder)
            ensure_folder(imap, tag_folder)
            result = imap.uid("COPY", uid_str, f'"{enc_tag}"')
            if result[0] == "OK" and is_meta:
                # Mark meta copies (B7/B8) as read
                imap.select(f'"{enc_tag}"')
                _, last_data = imap.uid("SEARCH", None, "ALL")
                if last_data[0]:
                    last_uid = last_data[0].split()[-1]
                    last_uid_s = last_uid.decode() if isinstance(last_uid, bytes) else last_uid
                    imap.uid("STORE", last_uid_s, "+FLAGS", "(\\Seen)")
                imap.select("INBOX")

        # Mark INBOX original as read + sorted
        imap.uid("STORE", uid_str, "+FLAGS", "(\\Seen $Sorted)")

        if folder or tag_matches:
            tags_str = ", ".join(f for _, _, f, _ in tag_matches[:3])
            extra = f" +{len(tag_matches)-3}more" if len(tag_matches) > 3 else ""
            logging.info("%s -> %s [%s%s]", from_addr, folder or "INBOX", tags_str, extra)

    return count


def main():
    logging.info("Starting — delay %ds, poll every %ds", STARTUP_DELAY, POLL_INTERVAL)
    time.sleep(STARTUP_DELAY)

    rules = load_rules(RULES_PATH)
    user = rules["account"]
    password = os.environ.get("ME_PASSWORD", "")

    if not password:
        logging.error("ME_PASSWORD not set, exiting")
        sys.exit(1)

    logging.info("Connecting to %s:%d as %s", IMAP_HOST, IMAP_PORT, user)

    reconnect_delay = 5
    while True:
        try:
            imap = imap_connect()
            imap.login(user, password)
            logging.info("Connected and authenticated")
            reconnect_delay = 5

            while True:
                try:
                    sorted_count = sort_inbox(imap, rules)
                    if sorted_count:
                        logging.info("Sorted %d message(s)", sorted_count)
                except imaplib.IMAP4.abort:
                    logging.warning("IMAP connection lost, reconnecting...")
                    break
                except Exception as e:
                    logging.error("Sort error: %s", e)
                time.sleep(POLL_INTERVAL)

        except Exception as e:
            logging.error("Connection failed: %s (retry in %ds)", e, reconnect_delay)
            time.sleep(reconnect_delay)
            reconnect_delay = min(reconnect_delay * 2, 120)


if __name__ == "__main__":
    main()
