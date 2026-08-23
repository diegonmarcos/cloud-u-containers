#!/usr/bin/env python3
"""JMAP-native email sorter for Stalwart — dynamic filter views.

Routing is owned by the native Sieve (_shared/lib/mail-rules.nix::toSieve):
each inbound email lands in INBOX (read) + exactly one numeric 1*-9*
category folder as an UNREAD copy. This sorter does NOT route or set $seen.

Instead it maintains dynamic cross-cutting filter folders A*/B*/C*/D*
(size / time / read-state / attachment) over the emails living in the
numeric folders, using JMAP multi-mailbox membership (add the existing
message into the filter mailbox — no copies, no keyword changes). Each
poll re-evaluates and adds AND removes membership so time/read windows
stay current.

Uses JMAP mailboxIds (email in multiple mailboxes, no copies).
Uses JMAP parentId + sortOrder for folder hierarchy.
"""
import re
import json
import os
import sys
import ssl
import time
import logging
import datetime
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

    def email_get(self, ids, properties=None):
        props = properties or ["from", "subject", "size", "mailboxIds",
                               "keywords", "bodyStructure"]
        resp = self.call([["Email/get", {
            "accountId": self.account_id,
            "ids": ids,
            "properties": props,
        }, "0"]])
        return resp[0][1].get("list", [])

    def email_set(self, updates):
        resp = self.call([["Email/set", {
            "accountId": self.account_id,
            "update": updates,
        }, "0"]])
        return resp[0][1]

    # JMAP servers cap `limit` server-side, so this is a page size, not a total.
    PAGE = 500

    def email_query_in(self, mailbox_ids, limit=None):
        """Return the union of email ids that live in ANY of mailbox_ids.

        Uses an `inMailboxOtherThan`-free OR filter so Stalwart returns
        every message present in at least one source (numeric 1*-9*) folder.

        Pages until the result set is exhausted. The previous implementation
        issued a single query with limit=2000 and never read `total`, so once
        the store grew past 2000 messages it silently sorted a prefix and
        reported success -- mail simply stopped being filed with no error.
        `limit` (None = all) is retained as an explicit cap for callers that
        want one.
        """
        if not mailbox_ids:
            return []
        if len(mailbox_ids) == 1:
            flt = {"inMailbox": mailbox_ids[0]}
        else:
            flt = {"operator": "OR",
                   "conditions": [{"inMailbox": m} for m in mailbox_ids]}

        ids, position, total = [], 0, None
        while True:
            want = self.PAGE if limit is None else min(self.PAGE, limit - len(ids))
            if want <= 0:
                break
            resp = self.call([["Email/query", {
                "accountId": self.account_id,
                "filter": flt,
                "sort": [{"property": "receivedAt", "isAscending": False}],
                "position": position,
                "limit": want,
            }, "0"]])
            page = resp[0][1].get("ids", [])
            if total is None:
                total = resp[0][1].get("total")
            ids.extend(page)
            # Short page means we reached the end; empty page guards against a
            # server that ignores `position` (would otherwise loop forever).
            if len(page) < want or not page:
                break
            position += len(page)

        # Truncation must never be silent again.
        if limit is not None and total is not None and total > len(ids):
            logging.warning("Email/query truncated by caller limit: fetched %d of %s", len(ids), total)
        elif total is not None and total != len(ids):
            logging.warning("Email/query count mismatch: fetched %d, server total %s", len(ids), total)
        return ids


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

    # Visual section-header folders (flat ROOT siblings, NOT parents) —
    # `mail-rules-general.json::folders_ui`. They sort alphabetically
    # just before each numeric block (10 _ ADMIN < 11 ..., etc) so
    # users get the same grouped layout Maddy ships. Not routing
    # targets; not referenced by any sieve rule.
    for j, label in enumerate(rules.get("folders_ui") or []):
        pick_or_create(label, None, "section", 100 + j)
        create_counter += 1

    # Dynamic filter views — flat ROOT mailboxes (section headers +
    # one folder per view). Membership is maintained by maintain_filters
    # via JMAP multi-mailbox; here we only ensure the mailboxes exist.
    filters = rules.get("filters") or {}
    for k, label in enumerate(filters.get("section_headers") or []):
        pick_or_create(label, None, "filtersec", 200 + k)
        create_counter += 1
    for vi, view in enumerate(filters.get("views") or []):
        pick_or_create(view["folder"], None, "filterview", 300 + vi)
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


# ── Dynamic cross-cutting filter views ───────────────────────────────
#
# Routing is now owned entirely by the native Sieve (see _shared/lib/
# mail-rules.nix::toSieve): every inbound email lands in INBOX (read) plus
# exactly one numeric 1*-9* category folder as an UNREAD copy. The sorter
# no longer routes or sets $seen.
#
# Instead it maintains DYNAMIC cross-cutting filter folders A*/B*/C*/D*
# over the emails that live in the numeric folders, using JMAP
# multi-mailbox membership (add the existing message into the filter
# mailbox; NO new copies; NO $seen/$Sorted changes). Re-evaluated every
# poll so time/read windows stay current (membership added AND removed).


def _has_attachment(em):
    """True if the email has a real (non-inline) attachment.

    Prefers JMAP's `hasAttachment` property when present; falls back to
    walking bodyStructure for a part with a disposition of "attachment"
    or a filename.
    """
    if "hasAttachment" in em:
        return bool(em.get("hasAttachment"))
    return bool(_attachment_types(em))


def _attachment_types(em):
    """Collect the set of MIME `type`s of attachment parts in bodyStructure."""
    types = set()

    def walk(part):
        if not isinstance(part, dict):
            return
        disp = (part.get("disposition") or "").lower()
        name = part.get("name")
        if disp == "attachment" or name:
            t = part.get("type")
            if t:
                types.add(t.lower())
        for sub in part.get("subParts") or []:
            walk(sub)

    walk(em.get("bodyStructure") or {})
    return types


def _email_matches(em, predicate, now):
    """Evaluate a single filter predicate against an Email/get object."""
    ptype = predicate.get("type")
    size = em.get("size") or 0

    # Size views must tile the axis exactly once. All three are half-open
    # [lo, hi) so a message on a boundary lands in exactly one bucket.
    # size_range used to be fully closed, so a message of exactly max bytes
    # (10485760) matched both "Medium" [1MB,10MB] and "Large" [10MB,inf) and
    # was filed into two folders.
    if ptype == "size_min":
        return size >= predicate["bytes"]
    if ptype == "size_max":
        return size < predicate["bytes"]
    if ptype == "size_range":
        return predicate["min"] <= size < predicate["max"]
    if ptype == "newer_than_hours":
        ts = _parse_iso8601(em.get("receivedAt"))
        if ts is None:
            return False
        return (now - ts) <= predicate["hours"] * 3600
    if ptype == "unread":
        return not (em.get("keywords") or {}).get("$seen", False)
    if ptype == "has_attachment":
        return _has_attachment(em)
    if ptype == "attach_type":
        wanted = {v.lower() for v in predicate.get("values") or []}
        return bool(wanted & _attachment_types(em))
    return False


def _parse_iso8601(value):
    """Parse a JMAP UTCDate (RFC3339, e.g. 2026-06-18T10:20:30Z) to epoch."""
    if not value:
        return None
    v = value.strip()
    # Normalise trailing Z to +00:00 for fromisoformat (Py 3.7+ chokes on Z).
    if v.endswith("Z"):
        v = v[:-1] + "+00:00"
    try:
        dt = datetime.datetime.fromisoformat(v)
        return dt.timestamp()
    except Exception:
        return None


def apply_renames(client, rules, mailboxes):
    """One-time in-place mailbox renames (old name -> new name) from
    rules.folder_renames.map. Idempotent: rename only when the old name exists
    AND the new name does not. JMAP Mailbox/set name-update preserves the
    mailbox's emails + children — the whole point vs create-new + reap-old."""
    renames = (rules.get("folder_renames") or {}).get("map") or {}
    if not renames:
        return
    by_name = {mb["name"]: mb["id"] for mb in mailboxes}
    updates = {}
    for old_name, new_name in renames.items():
        old_id = by_name.get(old_name)
        if old_id and new_name not in by_name:
            updates[old_id] = {"name": new_name}
    if not updates:
        return
    logging.info("Renaming %d mailbox(es) in place (keep emails)...", len(updates))
    result = client.mailbox_set(update=updates)
    for mid, err in (result.get("notUpdated") or {}).items():
        logging.warning("Rename failed %s: %s", mid, err)


def maintain_filters(client, rules, name_to_id, mailboxes):
    """Reconcile dynamic A*/B*/C*/D* filter-view mailbox membership.

    For each view: compute the matching email set from its predicate over
    the emails living in the numeric (source) folders, then add the view
    mailbox to matching emails' mailboxIds and remove it from emails that
    no longer match. Email/set mailboxIds-only — never touches keywords.
    """
    filters = rules.get("filters") or {}
    views = filters.get("views") or []
    if not views:
        return 0

    src_re = re.compile(filters.get("source_folder_regex", "^[0-9]"))

    # 1. Source mailbox ids = mailboxes whose NAME matches the regex.
    source_ids = [mb["id"] for mb in mailboxes if src_re.search(mb["name"])]
    if not source_ids:
        return 0

    # View folder name → mailbox id (skip views whose mailbox isn't created).
    view_ids = {}
    for view in views:
        mid = name_to_id.get(view["folder"])
        if mid:
            view_ids[view["folder"]] = mid
    if not view_ids:
        return 0
    view_id_set = set(view_ids.values())

    # 2. Union of emails in any source folder.
    email_ids = client.email_query_in(source_ids)
    if not email_ids:
        email_ids = []

    now = time.time()
    updates = {}

    for batch_start in range(0, len(email_ids), BATCH_SIZE):
        batch_ids = email_ids[batch_start:batch_start + BATCH_SIZE]
        emails = client.email_get(batch_ids, properties=[
            "size", "receivedAt", "keywords", "mailboxIds",
            "hasAttachment", "bodyStructure",
        ])

        for em in emails:
            current = dict(em.get("mailboxIds") or {})
            desired = dict(current)

            for view in views:
                vid = view_ids.get(view["folder"])
                if not vid:
                    continue
                if _email_matches(em, view["predicate"], now):
                    desired[vid] = True
                elif vid in desired:
                    del desired[vid]

            # Only emit an update if a VIEW-mailbox bit changed. Compare the
            # restriction of current/desired to the view mailbox set so we
            # never rewrite non-view membership (numeric folders, INBOX).
            cur_views = {m for m in current if m in view_id_set}
            des_views = {m for m in desired if m in view_id_set}
            if cur_views != des_views:
                updates[em["id"]] = {"mailboxIds": desired}

    total = 0
    if updates:
        items = list(updates.items())
        for batch_start in range(0, len(items), BATCH_SIZE):
            chunk = dict(items[batch_start:batch_start + BATCH_SIZE])
            result = client.email_set(chunk)
            total += len(result.get("updated", {}))
            errors = result.get("notUpdated", {})
            if errors:
                for eid, err in list(errors.items())[:3]:
                    logging.warning("Filter update failed %s: %s", eid, err)

    if total:
        logging.info("Filter views: updated membership on %d emails", total)
    return total


def cleanup_stale(client, rules, name_to_id, mailboxes):
    """Delete old non-emoji, non-numbered folders."""
    valid_names = set()
    # Inbox folders
    for f in rules["folders"].values():
        valid_names.add(f)
    # Visual section headers (folders_ui — flat siblings, Maddy-equivalent)
    for f in rules.get("folders_ui") or []:
        valid_names.add(f)
    # Dynamic filter views + their section headers (flat ROOT siblings)
    filters = rules.get("filters") or {}
    for f in filters.get("section_headers") or []:
        valid_names.add(f)
    for view in filters.get("views") or []:
        valid_names.add(view["folder"])
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
    password = os.environ.get("ME_PASSWORD", "") or os.environ.get("ADMIN_PASSWORD", "")

    if not password:
        logging.error("No password set (ME_PASSWORD or ADMIN_PASSWORD), exiting")
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
                    # One-time in-place renames first (old->new name), so a
                    # renamed folder keeps its emails instead of being recreated
                    # empty + the old reaped by cleanup_stale. Idempotent.
                    apply_renames(client, rules, client.mailbox_get())
                    name_to_id, mailboxes = ensure_mailboxes(client, rules)
                    # Run on every poll — cleanup is idempotent (no stale →
                    # no-op) and self-healing. Previously this was gated by
                    # `first_run`, so a single bad first poll permanently
                    # left orphans until the container restarted.
                    cleanup_stale(client, rules, name_to_id, mailboxes)
                    # Routing is owned by the Sieve. The sorter now only
                    # maintains dynamic A*/B*/C*/D* filter views over the
                    # emails in the numeric folders (membership add/remove,
                    # no $seen/$Sorted, no copies).
                    maintain_filters(client, rules, name_to_id, mailboxes)
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
