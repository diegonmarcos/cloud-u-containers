#!/usr/bin/env python3
"""IMAP inbox sorter for Maddy — copies messages to category folders.

Reads mail-rules.json (shared with Stalwart Sieve) and applies:
  A) Routing: copy to category folder (unread), mark INBOX original as read
  B) Meta: copy to _Meta/ folders (marked read) for size/attachment views

Maddy has no Sieve support — this script bridges the gap via IMAP protocol.
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

logging.basicConfig(
    stream=sys.stdout, level=logging.INFO,
    format="%(asctime)s [sorter] %(message)s", datefmt="%H:%M:%S"
)

RULES_PATH = os.getenv("RULES_PATH", "/data/mail-rules.json")
IMAP_HOST = os.getenv("IMAP_HOST", "127.0.0.1")
IMAP_PORT = int(os.getenv("IMAP_PORT", "143"))
POLL_INTERVAL = int(os.getenv("POLL_INTERVAL", "30"))
STARTUP_DELAY = int(os.getenv("STARTUP_DELAY", "15"))

# Meta folders get copies marked as read (they're reference views, not primary)
META_TAG_IDS = {"B7", "B8"}


def load_rules(path):
    with open(path) as f:
        return json.load(f)


def match_routing(from_domain, rules):
    """Return folder name for first matching routing rule, or None."""
    for route in rules["routing"]:
        match = route["match"]
        if match["type"] == "from_domain" and from_domain in match["values"]:
            return route["folder"]
    return None


def match_header_routing(headers, rules):
    """Check header_contains routing rules (Career subject matching etc.)."""
    for group in rules.get("tags", []):
        for rule in group.get("rules", []):
            if rule["type"] == "header_contains":
                header_val = headers.get(rule["header"], "").lower()
                for val in rule["values"]:
                    if val.lower() in header_val:
                        return None  # Tags only, no folder routing from header matches
    return None


def match_meta_folders(msg_size, content_types, rules):
    """Return list of meta folder paths for size/attachment matches."""
    folders = []
    for group in rules.get("tags", []):
        if group["id"] not in META_TAG_IDS:
            continue
        for rule in group.get("rules", []):
            if rule["type"] == "size_over":
                if msg_size >= rule["bytes"]:
                    tag = rule["flag"].replace(":", "/").replace("+", "plus")
                    folders.append("_Meta/" + tag)
            elif rule["type"] == "content_type":
                if rule["value"] in content_types:
                    tag = rule["flag"].replace(":", "/")
                    folders.append("_Meta/" + tag)
    return folders


def ensure_folder(imap, folder):
    """Create IMAP folder if it doesn't exist (idempotent)."""
    # IMAP folder separator is usually "."
    imap.create(folder)  # silently fails if exists


def get_content_types(imap, uid):
    """Fetch BODYSTRUCTURE and extract content types."""
    types = set()
    try:
        _, data = imap.uid("FETCH", uid, "(BODYSTRUCTURE)")
        if data and data[0]:
            body = data[0][0] if isinstance(data[0], tuple) else data[0]
            if isinstance(body, bytes):
                body = body.decode("utf-8", errors="replace")
            # Extract content types from BODYSTRUCTURE response
            for match in re.findall(r'"([a-z]+/[a-z0-9.+_-]+)"', body.lower()):
                types.add(match)
    except Exception:
        pass
    return types


def sort_inbox(imap, rules):
    """Process unsorted messages in INBOX. Returns count of sorted messages."""
    imap.select("INBOX")
    # Search for messages without our custom flag $Sorted
    _, data = imap.uid("SEARCH", None, "UNKEYWORD $Sorted")
    if not data[0]:
        return 0

    uids = data[0].split()
    count = 0

    for uid in uids:
        uid_str = uid.decode() if isinstance(uid, bytes) else uid

        # Fetch headers + size
        _, msg_data = imap.uid("FETCH", uid_str, "(RFC822.SIZE BODY.PEEK[HEADER])")
        if not msg_data or not msg_data[0]:
            continue

        # Parse response — format: (b'UID FLAGS...', header_bytes)
        raw = msg_data[0]
        if isinstance(raw, tuple):
            meta_line = raw[0].decode("utf-8", errors="replace") if isinstance(raw[0], bytes) else raw[0]
            header_bytes = raw[1] if len(raw) > 1 else b""
        else:
            continue

        # Extract size from response
        size_match = re.search(r"RFC822\.SIZE\s+(\d+)", meta_line)
        msg_size = int(size_match.group(1)) if size_match else 0

        # Parse headers
        headers = email.message_from_bytes(header_bytes)
        from_addr = email.utils.parseaddr(headers.get("From", ""))[1].lower()
        from_domain = from_addr.split("@")[-1] if "@" in from_addr else ""

        # A) Route to category folder
        folder = match_routing(from_domain, rules)
        if folder:
            ensure_folder(imap, folder)
            result = imap.uid("COPY", uid_str, folder)
            if result[0] == "OK":
                count += 1
                logging.info("Copied to %s: %s (%s)", folder, from_addr, headers.get("Subject", "")[:50])

        # B) Meta folders (size/attachments)
        content_types = get_content_types(imap, uid_str)
        meta_folders = match_meta_folders(msg_size, content_types, rules)
        for mf in meta_folders:
            ensure_folder(imap, mf)
            result = imap.uid("COPY", uid_str, mf)
            if result[0] == "OK":
                # Mark meta copy as read — select meta folder, find last message, mark read
                imap.select(mf)
                _, last_data = imap.uid("SEARCH", None, "ALL")
                if last_data[0]:
                    last_uid = last_data[0].split()[-1]
                    imap.uid("STORE", last_uid.decode() if isinstance(last_uid, bytes) else last_uid,
                             "+FLAGS", "(\\Seen)")
                imap.select("INBOX")

        # Mark INBOX original as read + flag as sorted
        imap.uid("STORE", uid_str, "+FLAGS", "(\\Seen $Sorted)")

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
            imap = imaplib.IMAP4(IMAP_HOST, IMAP_PORT)
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
