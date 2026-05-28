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

    def mailbox_set(self, create=None, update=None, destroy=None,
                    on_destroy_remove_emails=False):
        args = {"accountId": self.account_id}
        if create:
            args["create"] = create
        if update:
            args["update"] = update
        if destroy:
            args["destroy"] = destroy
        # JMAP: when False (default), destroying a non-empty Mailbox fails
        # with `mailboxHasEmail`. cleanup_stale moves emails to INBOX before
        # destroying — but stragglers (and any email visible only by the
        # mailbox's child) need the explicit override.
        if on_destroy_remove_emails:
            args["onDestroyRemoveEmails"] = True
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
    """Reconcile mailbox state with rules.

    Two-step:
      1. For each (expected_name, expected_parent_id) declared by the rules,
         look up the existing mailbox by NAME. If multiple mailboxes share
         the name, prefer the one already at expected_parent_id; otherwise
         pick the first and queue a parent-reassignment so the others get
         deduplicated by cleanup_stale next pass.
      2. Create the missing ones in a single Mailbox/set batch.

    Returns (name_to_id_at_correct_parent, full_mailbox_list).
    """
    existing = client.mailbox_get()

    # name → list of {id, parentId} so we can prefer the correctly-parented one.
    by_name = {}
    for mb in existing:
        by_name.setdefault(mb["name"], []).append(
            {"id": mb["id"], "parentId": mb.get("parentId")}
        )

    creates = {}
    updates = {}
    create_counter = 0

    def pick_or_create(expected_name, expected_parent_id, ref_prefix, sort_order):
        """Return mailbox id for (name, parent). Move stragglers if any."""
        candidates = by_name.get(expected_name, [])
        # Prefer one already at the expected parent.
        for c in candidates:
            if c["parentId"] == expected_parent_id:
                return c["id"]
        # Otherwise reparent the first candidate (cheap fix for the
        # legacy-parent-with-valid-child layout). Don't create a duplicate.
        if candidates:
            stray = candidates[0]
            updates[stray["id"]] = {"parentId": expected_parent_id}
            return stray["id"]
        # Truly missing — queue create.
        ref = f"{ref_prefix}_{create_counter}"
        creates[ref] = {
            "name": expected_name,
            "parentId": expected_parent_id,
            "sortOrder": sort_order,
        }
        return f"#{ref}"

    # Inbox folders — all at ROOT (parentId=None).
    inbox_folders = list(rules["folders"].values())
    for i, folder in enumerate(inbox_folders):
        pick_or_create(folder, None, "inbox", i + 1)
        create_counter += 1

    # Tag group parents (ROOT) + their subfolders.
    for gi, group in enumerate(rules["tags"]):
        group_name = group["name"]
        parent_ref_or_id = pick_or_create(group_name, None, "group", 10 + gi)
        create_counter += 1
        for ri, rule in enumerate(group["rules"]):
            group_num = group_name.split("-")[0]
            sub_name = f"{group_num}-{ri} {rule['flag']}"
            pick_or_create(sub_name, parent_ref_or_id, f"sub_{gi}", ri)
            create_counter += 1

    if creates or updates:
        if creates:
            logging.info("Creating %d mailboxes...", len(creates))
        if updates:
            logging.info("Reparenting %d misparented mailboxes...", len(updates))
        result = client.mailbox_set(create=creates or None,
                                    update=updates or None)
        if result.get("notCreated"):
            for ref, err in result["notCreated"].items():
                logging.warning("Failed to create %s: %s", ref, err)
        if result.get("notUpdated"):
            for mid, err in result["notUpdated"].items():
                logging.warning("Failed to reparent %s: %s", mid, err)

    # Always re-fetch — pick_or_create returned create-refs (`#ref_N`) for
    # missing ones; after the set call those refs resolve to real ids only
    # via a fresh Mailbox/get.
    existing = client.mailbox_get()
    name_to_id = {mb["name"]: mb["id"] for mb in existing}

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

    # Pass 1: mailboxes whose name isn't a current valid one (true orphans).
    stale = []
    for mb in mailboxes:
        if mb["name"] not in valid_names and mb.get("role") is None:
            stale.append(mb)

    # Pass 2: valid-name DUPLICATES. ensure_mailboxes returned
    # name_to_id keyed by name — that's the *canonical* mailbox id (the
    # one at the expected parent). Any other mailbox sharing the name is
    # a duplicate (e.g. the post-rename leftover sitting under a legacy
    # parent), which keeps the legacy parent un-destroyable via
    # `mailboxHasChild`. Mark them stale so they get moved-and-destroyed
    # in the same pass — that unblocks the legacy parent next poll.
    for mb in mailboxes:
        if (mb["name"] in valid_names
                and mb.get("role") is None
                and name_to_id.get(mb["name"]) != mb["id"]):
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

    # Build child-of map from the FULL mailbox list so we can deepest-first
    # delete and inherit stale-ness up the tree. A stale parent that still
    # has non-stale children (the legacy-parent-with-valid-emoji-child case
    # in oci-mail's Stalwart store) won't destroy until those children are
    # reparented to ROOT — `ensure_mailboxes` does that in the same poll
    # via the `pick_or_create` reparent path, so this loop just needs to
    # retry across polls until the children move.
    by_parent = {}
    for mb in mailboxes:
        by_parent.setdefault(mb.get("parentId"), []).append(mb["id"])

    def depth(mb_id, seen=None):
        if seen is None:
            seen = set()
        if mb_id in seen:
            return 0
        seen.add(mb_id)
        kids = by_parent.get(mb_id, [])
        return 1 + (max((depth(k, seen) for k in kids), default=0))

    # Deepest first — deletes leaves before parents within the same batch.
    for mb in sorted(stale, key=lambda m: -depth(m["id"])):
        # Two-phase: first try the polite destroy; on failure (typically
        # `mailboxHasEmail` or `mailboxHasChild`) retry with
        # onDestroyRemoveEmails=true. Only the email-flag is JMAP-standard;
        # if the child relationship is the blocker, we surface the error so
        # next poll picks it up after `ensure_mailboxes` reparents.
        try:
            result = client.mailbox_set(destroy=[mb["id"]])
        except Exception as e:
            logging.warning("Destroy call failed for %s: %s", mb["name"], e)
            continue

        if mb["id"] in (result.get("destroyed") or []):
            logging.info("Deleted stale: %s", mb["name"])
            continue

        not_destroyed = (result.get("notDestroyed") or {}).get(mb["id"])
        if not not_destroyed:
            # No success entry AND no failure entry — surface oddly-shaped
            # response rather than silently dropping it (the prior bug).
            logging.warning("Destroy returned no status for %s: %s",
                            mb["name"], result)
            continue

        reason = not_destroyed.get("type") or str(not_destroyed)
        if reason in ("mailboxHasEmail", "tooManyEmails"):
            try:
                retry = client.mailbox_set(destroy=[mb["id"]],
                                           on_destroy_remove_emails=True)
                if mb["id"] in (retry.get("destroyed") or []):
                    logging.info("Deleted stale (force-empty): %s", mb["name"])
                    continue
                logging.warning("Force-destroy failed for %s: %s",
                                mb["name"], retry.get("notDestroyed"))
            except Exception as e:
                logging.warning("Force-destroy call failed for %s: %s",
                                mb["name"], e)
        else:
            # `mailboxHasChild` / unknown — leave for next poll once
            # ensure_mailboxes has reparented the valid children to ROOT.
            logging.info("Skipping %s for now: %s (will retry next poll)",
                         mb["name"], reason)


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
    while True:
        try:
            client.discover()
            logging.info("Connected to %s as %s", JMAP_URL, user)
            reconnect_delay = 5

            while True:
                try:
                    name_to_id, mailboxes = ensure_mailboxes(client, rules)
                    # Run on every poll — cleanup is idempotent (no stale →
                    # no-op) and self-healing. Previously this was gated by
                    # `first_run`, so a single bad first poll permanently
                    # left orphans until the container restarted.
                    cleanup_stale(client, rules, name_to_id, mailboxes)
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
