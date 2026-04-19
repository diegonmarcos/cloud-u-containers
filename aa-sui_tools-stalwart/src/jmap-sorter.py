#!/usr/bin/env python3
"""JMAP-native email sorter for Stalwart — dual-vector organization.

Reads mail-rules.json and applies via JMAP API:
  A) Routing: move to emoji inbox folders
  B) Tags: set JMAP keywords + place in numbered tag subfolders
  INBOX emails marked $Sorted after processing

Uses JMAP mailboxIds (email in multiple mailboxes, no copies).
Uses JMAP keywords (native tags, like Gmail labels).
Uses JMAP parentId + sortOrder for folder hierarchy.
"""
import json
import os
import sys
import ssl
import time
import logging
import email.utils
import urllib.request
import urllib.error
from base64 import b64encode

logging.basicConfig(
    stream=sys.stdout, level=logging.INFO,
    format="%(asctime)s [jmap-sorter] %(message)s", datefmt="%H:%M:%S"
)

JMAP_URL = os.getenv("JMAP_URL", "https://localhost:2443")
RULES_PATH = os.getenv("RULES_PATH", "/data/mail-rules.json")
POLL_INTERVAL = int(os.getenv("POLL_INTERVAL", "30"))
STARTUP_DELAY = int(os.getenv("STARTUP_DELAY", "20"))
BATCH_SIZE = 100  # emails per Email/set call

# B7 and B8 are meta — emails in these folders get $seen
META_TAG_IDS = {"B7", "B8"}


def load_rules(path):
    with open(path) as f:
        return json.load(f)


class JMAPClient:
    def __init__(self, base_url, user, password):
        self.base_url = base_url
        self.api_url = f"{base_url}/jmap/"
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        self.ssl_ctx = ctx
        creds = b64encode(f"{user}:{password}".encode()).decode()
        self.headers = {
            "Authorization": f"Basic {creds}",
            "Content-Type": "application/json",
        }
        self.account_id = None

    def _request(self, url, data=None):
        body = json.dumps(data).encode() if data else None
        req = urllib.request.Request(url, data=body, headers=self.headers)
        resp = urllib.request.urlopen(req, context=self.ssl_ctx, timeout=30)
        return json.loads(resp.read())

    def discover(self):
        session = self._request(f"{self.base_url}/jmap/session")
        self.account_id = session["primaryAccounts"]["urn:ietf:params:jmap:mail"]
        logging.info("Account ID: %s", self.account_id)
        return self.account_id

    def call(self, method_calls):
        payload = {
            "using": ["urn:ietf:params:jmap:core", "urn:ietf:params:jmap:mail"],
            "methodCalls": method_calls,
        }
        result = self._request(self.api_url, payload)
        return result["methodResponses"]

    def mailbox_get(self):
        resp = self.call([["Mailbox/get", {"accountId": self.account_id}, "0"]])
        return resp[0][1]["list"]

    def mailbox_set(self, create=None, update=None, destroy=None):
        args = {"accountId": self.account_id}
        if create:
            args["create"] = create
        if update:
            args["update"] = update
        if destroy:
            args["destroy"] = destroy
        resp = self.call([["Mailbox/set", args, "0"]])
        return resp[0][1]

    def email_query(self, inbox_id, limit=500):
        """Find unsorted emails in INBOX."""
        resp = self.call([["Email/query", {
            "accountId": self.account_id,
            "filter": {
                "inMailbox": inbox_id,
                "notKeyword": "$Sorted",
            },
            "sort": [{"property": "receivedAt", "isAscending": False}],
            "limit": limit,
        }, "0"]])
        return resp[0][1].get("ids", [])

    def email_get(self, ids):
        resp = self.call([["Email/get", {
            "accountId": self.account_id,
            "ids": ids,
            "properties": ["from", "subject", "size", "mailboxIds", "keywords",
                           "bodyStructure"],
        }, "0"]])
        return resp[0][1].get("list", [])

    def email_set(self, updates):
        resp = self.call([["Email/set", {
            "accountId": self.account_id,
            "update": updates,
        }, "0"]])
        return resp[0][1]


def match_routing(from_domain, rules):
    for route in rules["routing"]:
        if route["match"]["type"] == "from_domain" and from_domain in route["match"]["values"]:
            return route["folder"]
    return rules.get("routing_default")


def match_tags(from_addr, from_domain, subject, size, rules):
    """Return list of (group_id, group_name, rule_idx, flag, is_meta)."""
    matches = []
    account = rules.get("account", "")

    for group in rules.get("tags", []):
        is_meta = group["id"] in META_TAG_IDS
        for idx, rule in enumerate(group.get("rules", [])):
            matched = False
            rtype = rule["type"]

            if rtype == "from_domain":
                matched = from_domain in rule["values"]
            elif rtype == "from_address":
                matched = from_addr in rule["values"]
            elif rtype == "header_contains":
                if rule["header"].lower() in ("subject",):
                    matched = any(v.lower() in subject.lower() for v in rule["values"])
                elif rule["header"].lower() in ("from",):
                    matched = any(v.lower() in from_addr.lower() for v in rule["values"])
                elif rule["header"].lower() in ("precedence",):
                    pass  # Can't check Precedence via JMAP Email/get easily
            elif rtype == "header_exists":
                pass  # JMAP Email/get doesn't expose arbitrary headers
            elif rtype == "size_over":
                matched = size >= rule["bytes"]
            elif rtype == "self_sent":
                matched = from_addr == account
            elif rtype == "has_cc":
                pass  # Would need cc property
            elif rtype == "list_header":
                pass  # Would need headers property
            elif rtype == "content_type":
                pass  # Would need bodyStructure parsing

            if matched:
                group_num = group["name"].split("-")[0]
                sub_name = f"{group_num}-{idx} {rule['flag']}"
                matches.append((group["id"], group["name"], sub_name, rule["flag"], is_meta))

    return matches


def ensure_mailboxes(client, rules):
    """Create all required mailboxes, return name→id map."""
    existing = client.mailbox_get()
    name_to_id = {}
    id_to_name = {}
    for mb in existing:
        name_to_id[mb["name"]] = mb["id"]
        id_to_name[mb["id"]] = mb["name"]

    creates = {}
    create_counter = 0

    # 7 inbox folders
    inbox_folders = list(rules["folders"].values())
    for i, folder in enumerate(inbox_folders):
        if folder not in name_to_id:
            ref = f"inbox_{create_counter}"
            creates[ref] = {"name": folder, "parentId": None, "sortOrder": i + 1}
            create_counter += 1

    # 8 tag group parent folders + subfolders
    for gi, group in enumerate(rules["tags"]):
        group_name = group["name"]
        if group_name not in name_to_id:
            ref = f"group_{gi}"
            creates[ref] = {"name": group_name, "parentId": None, "sortOrder": 10 + gi}
            create_counter += 1

            # Create subfolders with reference to parent
            for ri, rule in enumerate(group["rules"]):
                group_num = group_name.split("-")[0]
                sub_name = f"{group_num}-{ri} {rule['flag']}"
                sub_ref = f"sub_{gi}_{ri}"
                creates[sub_ref] = {
                    "name": sub_name,
                    "parentId": f"#{ref}",
                    "sortOrder": ri,
                }
                create_counter += 1
        else:
            # Parent exists, check subfolders
            parent_id = name_to_id[group_name]
            for ri, rule in enumerate(group["rules"]):
                group_num = group_name.split("-")[0]
                sub_name = f"{group_num}-{ri} {rule['flag']}"
                if sub_name not in name_to_id:
                    sub_ref = f"sub_{gi}_{ri}"
                    creates[sub_ref] = {
                        "name": sub_name,
                        "parentId": parent_id,
                        "sortOrder": ri,
                    }
                    create_counter += 1

    if creates:
        logging.info("Creating %d mailboxes...", len(creates))
        result = client.mailbox_set(create=creates)
        created = result.get("created", {})
        for ref, mb_data in created.items():
            # Re-fetch to get names
            pass
        if result.get("notCreated"):
            for ref, err in result["notCreated"].items():
                logging.warning("Failed to create %s: %s", ref, err)

        # Re-fetch all mailboxes after creation
        existing = client.mailbox_get()
        name_to_id = {}
        for mb in existing:
            full_name = mb["name"]
            name_to_id[full_name] = mb["id"]

    return name_to_id, existing


def find_inbox_id(mailboxes):
    for mb in mailboxes:
        if mb.get("role") == "inbox" or mb["name"] == "INBOX":
            return mb["id"]
    return None


def sort_emails(client, rules, name_to_id, mailboxes):
    """Process unsorted emails in INBOX."""
    inbox_id = find_inbox_id(mailboxes)
    if not inbox_id:
        logging.error("No INBOX found")
        return 0

    email_ids = client.email_query(inbox_id)
    if not email_ids:
        return 0

    logging.info("Processing %d unsorted emails...", len(email_ids))

    # Process in batches
    total = 0
    for batch_start in range(0, len(email_ids), BATCH_SIZE):
        batch_ids = email_ids[batch_start:batch_start + BATCH_SIZE]
        emails = client.email_get(batch_ids)

        updates = {}
        for em in emails:
            from_list = em.get("from") or [{}]
            from_addr = (from_list[0].get("email") or "").lower()
            from_domain = from_addr.split("@")[-1] if "@" in from_addr else ""
            subject = em.get("subject") or ""
            size = em.get("size") or 0

            # A) Routing
            folder = match_routing(from_domain, rules)
            folder_id = name_to_id.get(folder) if folder else None

            # B) Tags
            tag_matches = match_tags(from_addr, from_domain, subject, size, rules)

            # Build mailboxIds: INBOX + routing folder + tag subfolders
            new_mailbox_ids = {inbox_id: True}
            if folder_id:
                new_mailbox_ids[folder_id] = True

            # Build keywords
            new_keywords = dict(em.get("keywords") or {})
            new_keywords["$seen"] = True
            new_keywords["$Sorted"] = True

            for group_id, group_name, sub_name, flag, is_meta in tag_matches:
                new_keywords[flag] = True
                sub_id = name_to_id.get(sub_name)
                if sub_id:
                    new_mailbox_ids[sub_id] = True

            updates[em["id"]] = {
                "mailboxIds": new_mailbox_ids,
                "keywords": new_keywords,
            }

        if updates:
            result = client.email_set(updates)
            updated = len(result.get("updated", {}))
            errors = result.get("notUpdated", {})
            total += updated
            if errors:
                for eid, err in list(errors.items())[:3]:
                    logging.warning("Update failed %s: %s", eid, err)

    logging.info("Sorted %d emails", total)
    return total


def cleanup_stale(client, rules, name_to_id, mailboxes):
    """Delete old non-emoji, non-numbered folders."""
    valid_names = set()
    # Inbox folders
    for f in rules["folders"].values():
        valid_names.add(f)
    # Tag groups + subfolders
    for group in rules["tags"]:
        valid_names.add(group["name"])
        for ri, rule in enumerate(group["rules"]):
            group_num = group["name"].split("-")[0]
            valid_names.add(f"{group_num}-{ri} {rule['flag']}")
    # System folders
    valid_names.update({"INBOX", "Sent", "Drafts", "Trash", "Junk", "Archive",
                        "Sent Items", "Deleted Items", "Junk Mail", "Outbox", "Templates"})

    stale = []
    for mb in mailboxes:
        if mb["name"] not in valid_names and mb.get("role") is None:
            stale.append(mb)

    if not stale:
        return

    logging.info("Found %d stale folders to clean", len(stale))
    # Move emails from stale folders to INBOX first, then delete
    inbox_id = find_inbox_id(mailboxes)
    for mb in stale:
        # Query emails in this folder
        try:
            resp = client.call([["Email/query", {
                "accountId": client.account_id,
                "filter": {"inMailbox": mb["id"]},
                "limit": 500,
            }, "0"]])
            eids = resp[0][1].get("ids", [])
            if eids:
                # Add INBOX to mailboxIds for each email
                emails = client.email_get(eids)
                updates = {}
                for em in emails:
                    mids = dict(em.get("mailboxIds") or {})
                    mids[inbox_id] = True
                    if mb["id"] in mids:
                        del mids[mb["id"]]
                    updates[em["id"]] = {"mailboxIds": mids}
                if updates:
                    client.email_set(updates)
        except Exception as e:
            logging.warning("Error moving emails from %s: %s", mb["name"], e)

    # Delete stale folders (deepest first by checking parentId)
    children = [mb for mb in stale if mb.get("parentId")]
    parents = [mb for mb in stale if not mb.get("parentId")]
    for mb in children + parents:
        try:
            client.mailbox_set(destroy=[mb["id"]])
            logging.info("Deleted stale: %s", mb["name"])
        except Exception as e:
            logging.warning("Failed to delete %s: %s", mb["name"], e)


def main():
    logging.info("Starting JMAP sorter — delay %ds, poll every %ds", STARTUP_DELAY, POLL_INTERVAL)
    time.sleep(STARTUP_DELAY)

    rules = load_rules(RULES_PATH)
    user = rules["account"]
    password = os.environ.get("ADMIN_PASSWORD", "") or os.environ.get("ME_PASSWORD", "")

    if not password:
        logging.error("No password set (ADMIN_PASSWORD or ME_PASSWORD), exiting")
        sys.exit(1)

    client = JMAPClient(JMAP_URL, user, password)

    reconnect_delay = 5
    first_run = True
    while True:
        try:
            client.discover()
            logging.info("Connected to %s as %s", JMAP_URL, user)
            reconnect_delay = 5

            while True:
                try:
                    name_to_id, mailboxes = ensure_mailboxes(client, rules)

                    if first_run:
                        cleanup_stale(client, rules, name_to_id, mailboxes)
                        first_run = False

                    sort_emails(client, rules, name_to_id, mailboxes)
                except urllib.error.URLError as e:
                    logging.warning("Connection lost: %s, reconnecting...", e)
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
