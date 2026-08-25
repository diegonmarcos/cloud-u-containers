# ╔══════════════════════════════════════════════════════════════════╗
# ║ mail-rules.nix — canonical → engine-specific derivation library  ║
# ║                                                                  ║
# ║ Source of truth:                                                 ║
# ║   mail-rules-general.json       (universal, language-neutral)    ║
# ║   mail-rules-profile-<id>.json  (overlay, region/identity)       ║
# ║                                                                  ║
# ║ Outputs:                                                         ║
# ║   toSieve   merged            → String (Stalwart Sieve script)   ║
# ║   toMaddyJson merged          → Attrs (→ builtins.toJSON)        ║
# ║                                                                  ║
# ║ Degradation: every rule declares engines.<engine> ∈              ║
# ║   full | route_only | tag_only | drop                            ║
# ║                                                                  ║
# ║ Import:                                                          ║
# ║   mailRules = import ../../_shared/lib/mail-rules.nix { inherit lib; };
# ║   merged    = mailRules.loadAndMerge {                           ║
# ║                 generalPath = ./mail-rules-general.json;         ║
# ║                 profilePath = ./mail-rules-profile-diego.json;   ║
# ║               };                                                 ║
# ║   sieve     = mailRules.toSieve merged;                          ║
# ║   maddyJson = mailRules.toMaddyJson merged;                      ║
# ╚══════════════════════════════════════════════════════════════════╝

{ lib }:

let
  inherit (builtins) readFile fromJSON toJSON length elem attrNames hasAttr;
  inherit (lib) concatStringsSep concatMapStringsSep filter sort optional optionals optionalAttrs;

  # ── Loading & merging ─────────────────────────────────────────────

  # Load a file path as parsed JSON, with sensible default for missing profile.
  loadJson = path: fromJSON (readFile path);

  # Merge general + (optional) profile overlay into a single canonical attrset.
  #   - folders, inbox_copy, routing_default, cleanup: profile wins if set
  #   - sieve_require: union
  #   - predicates: union, profile wins on id collision
  #   - rules: concat, profile appended (profile wins on id if we de-dup later)
  #   - account: profile defines this
  merge = { general, profile ? null }:
    let p = if profile == null then {} else profile;
    in {
      schema_version   = general.schema_version or 2;
      account          = p.account or general.account or "";
      sieve_require    = lib.unique ((general.sieve_require or []) ++ (p.sieve_require or []));
      folders          = (general.folders or {}) // (p.folders_extend or {}) // (p.folders or {});
      # Two-level folder groups (e.g. "31 Cloud - Reports & CI" with GH
      # Workflows / Cloud Reports / Rss Notifications as real children) --
      # a parent + named children, unlike the flat `folders` map above which
      # is all ROOT-level. Concat, not merge-by-key: a profile can add a
      # whole extra group but there's no per-group override story yet.
      folder_groups    = (general.folder_groups or []) ++ (p.folder_groups or []);
      # Visual section-header siblings (flat ROOT mailboxes, NOT parents).
      # Carried through merge so toLegacyJson can hand them to jmap-sorter.
      folders_ui       = lib.unique ((general.folders_ui or []) ++ (p.folders_ui or []));
      routing_default  = p.routing_default or general.routing_default or "others";
      inbox_copy       = p.inbox_copy or general.inbox_copy or { enabled = false; flags = []; };
      cleanup          = p.cleanup or general.cleanup or {};
      # Dynamic cross-cutting filter views (size/time/state/attachment).
      # Carried through merge so toLegacyJson can hand them to jmap-sorter,
      # which maintains them via JMAP multi-mailbox membership each poll.
      filters          = p.filters or general.filters or { views = []; section_headers = []; };
      # One-time in-place mailbox renames (old->new), applied by jmap-sorter
      # before ensure/cleanup so renamed folders keep their emails.
      folder_renames   = p.folder_renames or general.folder_renames or { map = {}; };
      predicates       = (general.predicates or {}) // (p.predicates or {});
      rules            = (general.rules or []) ++ (p.rules or []);
    };

  # Convenience: load both files in one call.
  loadAndMerge = { generalPath, profilePath ? null }:
    merge {
      general = loadJson generalPath;
      profile = if profilePath == null then null else loadJson profilePath;
    };

  # ── Predicate resolution (expand refs, recurse into combinators) ──

  resolvePredicate = predicates: pred:
    if hasAttr "ref" pred then
      resolvePredicate predicates predicates.${pred.ref}
    else if hasAttr "any_of" pred then
      { any_of = map (resolvePredicate predicates) pred.any_of; }
    else if hasAttr "all_of" pred then
      { all_of = map (resolvePredicate predicates) pred.all_of; }
    else if hasAttr "not" pred then
      { not = resolvePredicate predicates pred.not; }
    else
      pred;

  # ── Sieve compilation ─────────────────────────────────────────────

  # Render a list of string values as a Sieve value-list:
  #   one → "x"          many → ["x", "y"]
  sieveList = vs:
    if length vs == 1 then ''"${builtins.head vs}"''
    else ''[${concatMapStringsSep ", " (v: ''"${v}"'') vs}]'';

  # Atom → Sieve test expression. Account passed through for self_sent.
  sieveAtom = account: p:
    let t = p.type; in
    if      t == "from_domain"        then ''address :domain :is "From" ${sieveList p.values}''
    else if t == "from_domain_suffix" then ''address :domain :matches "From" ${sieveList (map (v: "*" + v) p.values)}''
    else if t == "from_address"       then ''address :is "From" ${sieveList p.values}''
    else if t == "to_contains"        then ''address :contains "To" ${sieveList p.values}''
    else if t == "reply_to_contains"  then ''address :contains "Reply-To" ${sieveList p.values}''
    else if t == "header_contains"    then ''header :contains "${p.header}" ${sieveList p.values}''
    else if t == "header_regex"       then ''header :regex "${p.header}" "${p.regex}"''
    else if t == "header_exists"      then ''exists "${p.header}"''
    else if t == "subject_contains"   then ''header :contains "Subject" ${sieveList p.values}''
    else if t == "list_id_contains"   then ''header :contains "List-Id" ${sieveList p.values}''
    else if t == "body_contains"      then ''body :text :contains ${sieveList p.values}''
    else if t == "size_over"          then "size :over ${toString p.bytes}"
    else if t == "size_under"         then "size :under ${toString p.bytes}"
    else if t == "content_type"       then
      # :anychild only accepts a single value per call; anyof many calls when needed.
      let mk = ct: ''header :mime :anychild :contenttype "Content-Type" "${ct}"'';
      in if length p.values == 1 then mk (builtins.head p.values)
         else "anyof(${concatMapStringsSep ", " mk p.values})"
    else if t == "has_cc"             then ''exists "Cc"''
    else if t == "has_bcc"            then ''exists "Bcc"''
    else if t == "list_header"        then ''exists ["List-Id", "List-Unsubscribe"]''
    else if t == "self_sent"          then ''address :is "From" "${account}"''
    else if t == "spf_pass"           then ''header :contains "Received-SPF" "pass"''
    else if t == "dkim_pass"          then ''header :contains "Authentication-Results" "dkim=pass"''
    else "false /* unsupported: ${t} */";

  # Resolved predicate → Sieve test (combinators handled here).
  sieveTest = account: p:
    if hasAttr "any_of" p then "anyof(${concatMapStringsSep ", " (sieveTest account) p.any_of})"
    else if hasAttr "all_of" p then "allof(${concatMapStringsSep ", " (sieveTest account) p.all_of})"
    else if hasAttr "not" p then "not ${sieveTest account p.not}"
    else sieveAtom account p;

  # Stable priority sort (Nix lib.sort is not stable; add index as tiebreak).
  sortByPriority = rules:
    let indexed = lib.imap0 (i: r: r // { __i = i; }) rules;
        sorted = sort (a: b:
          let pa = a.priority or 500; pb = b.priority or 500;
          in if pa == pb then a.__i < b.__i else pa < pb
        ) indexed;
    in map (r: removeAttrs r ["__i"]) sorted;

  # Emission strategy for INBOX-copy semantics:
  #   1. tag/meta rules first — all matching addflag's accumulate onto the
  #      shared flag list, visible to every subsequent fileinto AND to the
  #      implicit keep.
  #   2. route rules next — each emits `addflag <cat-flags>; fileinto :copy
  #      :create <folder>; [addflag \Seen;] stop;`.  The \Seen only becomes
  #      effective AFTER the category fileinto, so only the implicit keep
  #      to INBOX picks it up — category copies stay unread.
  #   3. fallback — `fileinto :copy :create <default>; [addflag \Seen;]`.
  #      Reached when no route matched.  No stop; implicit keep still fires.
  #   4. implicit keep at script end delivers to INBOX with all accumulated
  #      flags (= every matching tag + \Seen).

  # Flags the engines.stalwart mode permits this rule to emit.
  # Flat folder-name lookup for `copy_to` resolution: the ROOT-level
  # `folders` map plus every folder_group's children, keyed by child key and
  # valued by the child's FULL IMAP PATH ("<parent>/<child>").
  #
  # The path, not the bare leaf name. Sieve `fileinto` resolves a mailbox by
  # its hierarchical path, so `fileinto "GH Workflows"` does not find the
  # child of "31 Cloud - Reports & CI" — it creates a NEW top-level mailbox
  # of that name. That produced an endless churn loop in production: Sieve
  # created the root copy on delivery, ensure_mailboxes reparented it under
  # the group, cleanup_stale then reaped it as a duplicate, and the next
  # message started the cycle over. Observed 22 create/reparent/delete
  # events on oci-mail before it was caught; the folder's mail survived only
  # because cleanup_stale moves messages to INBOX before destroying.
  #
  # Delimiter verified against the live server rather than assumed —
  # IMAP LIST on stalwart returns:
  #   * LIST () "/" "31    ☁️ Cloud - Reports & CI/GH Workflows"
  #
  # This affects the SIEVE side only. The Rust sorter keeps addressing
  # children by leaf name + parentId, which is what JMAP Mailbox/set wants;
  # it has no notion of a path.
  allFolderTargets = merged:
    merged.folders
    // (lib.foldl (acc: g:
         acc // (lib.mapAttrs (_: child: "${g.name}/${child}") (g.children or {}))
       ) {} (merged.folder_groups or []));

  effectiveFlags = rule:
    let mode = rule.engines.stalwart or "full"; in
    if mode == "drop" || mode == "route_only" then []
    else rule.actions.flags or [];

  # Folder this rule routes to (null if not a route for Stalwart).
  effectiveFolder = folders: rule:
    let mode = rule.engines.stalwart or "full"; in
    if mode == "drop" || mode == "tag_only" then null
    else if !(rule.actions ? copy_to) then null
    else folders.${rule.actions.copy_to} or rule.actions.copy_to;

  # A tag-shaped emission: "# id\nif <cond> { addflag "F1"; addflag "F2"; }"
  sieveTagBlock = predicates: account: rule:
    let
      flags = effectiveFlags rule;
    in
    if flags == [] then null
    else
      let
        cond = sieveTest account (resolvePredicate predicates rule.when);
        lines = map (f: ''addflag "${f}";'') flags;
      in "# ${rule.id}\nif ${cond} {\n  ${concatStringsSep "\n  " lines}\n}";

  # A route-shaped emission: flags addflag'd, fileinto :copy :create,
  # optional \Seen, stop.
  sieveRouteBlock = predicates: account: folders: inboxSeen: rule:
    let
      folder = effectiveFolder folders rule;
    in
    if folder == null then null
    else
      let
        cond = sieveTest account (resolvePredicate predicates rule.when);
        tagLines = map (f: ''addflag "${f}";'') (effectiveFlags rule);
        fileintoLine = [ ''fileinto :copy :create "${folder}";'' ];
        seenLine = optional inboxSeen ''addflag "\\Seen";'';
        stopLine = [ "stop;" ];
        body = tagLines ++ fileintoLine ++ seenLine ++ stopLine;
      in "# ${rule.id}\nif ${cond} {\n  ${concatStringsSep "\n  " body}\n}";

  # Predicate: which rules participate in the tag section vs route section.
  isTagKind = r: (r.kind or "route") != "route";
  isRouteKind = r: (r.kind or "route") == "route";

  # Full Sieve script.
  toSieve = merged:
    let
      account     = merged.account;
      folders     = allFolderTargets merged;
      predicates  = merged.predicates;
      requires    = concatMapStringsSep ", " (e: ''"${e}"'') merged.sieve_require;
      sorted      = sortByPriority merged.rules;
      inboxSeen   = merged.inbox_copy.enabled or false;

      tagRules    = filter isTagKind sorted;
      routeRules  = filter isRouteKind sorted;

      tagLines    = filter (x: x != null)
                      (map (sieveTagBlock predicates account) tagRules);
      routeLines  = filter (x: x != null)
                      (map (sieveRouteBlock predicates account folders inboxSeen) routeRules);

      defFolder   = folders.${merged.routing_default} or merged.routing_default;
      fallbackBody =
        [ ''fileinto :copy :create "${defFolder}";'' ]
        ++ (optional inboxSeen ''addflag "\\Seen";'');
      fallbackBlock = "# fallback (no route matched)\n"
        + concatStringsSep "\n" fallbackBody;
    in ''
      require [${requires}];

      # ════════════════════════════════════════════════════════════════
      # Generated by _shared/lib/mail-rules.nix — DO NOT EDIT
      # Source: mail-rules-general.json + profile overlay
      # Semantic:
      #   TAGS accumulate flags (visible to every fileinto + implicit keep).
      #   ROUTES fileinto :copy :create then addflag \Seen → only implicit
      #   keep (INBOX) picks up \Seen; category copies stay unread.
      #   Fallback catches unmatched; implicit keep → INBOX as read.
      # ════════════════════════════════════════════════════════════════

      # ─── TAGS ───────────────────────────────────────────────────────
      ${concatStringsSep "\n\n" tagLines}

      # ─── ROUTES ─────────────────────────────────────────────────────
      ${concatStringsSep "\n\n" routeLines}

      # ─── FALLBACK ───────────────────────────────────────────────────
      ${fallbackBlock}
    '';

  # ── Maddy subset (attrset, caller serializes with builtins.toJSON) ─

  # Honors engines.maddy. Emits resolved predicate + resolved folder name.
  maddyRule = folders: predicates: rule:
    let mode = rule.engines.maddy or "full"; in
    if mode == "drop" then null
    else
      let
        hasFolder = (rule.actions ? copy_to) && (mode == "full" || mode == "route_only");
        hasFlags  = (rule.actions ? flags)   && (mode == "full" || mode == "tag_only");
        resolved  = resolvePredicate predicates rule.when;
        folderName = if hasFolder then (folders.${rule.actions.copy_to} or rule.actions.copy_to) else null;
        flags      = if hasFlags then rule.actions.flags else [];
      in
        { id = rule.id; when = resolved; priority = rule.priority or 500; }
        // (optionalAttrs (folderName != null) { folder = folderName; })
        // (optionalAttrs (flags != [])      { inherit flags; });

  toMaddyJson = merged:
    let
      senderViews = filter (v: (v.axis or null) == "sender") (merged.filters.views or []);
      # Maddy gets ONLY the F0 sender-classification folders now, not the
      # numeric 1*-9* routing folders or the A-E axes. Each F view's own
      # `predicate` IS the delivery-time `when` tree unchanged (from_domain /
      # from_domain_suffix / header_contains / any_of / all_of / not are ALL
      # already supported by this script's atom_match/match_when -- verified,
      # no jq changes needed). id/folder both use the view's folder name
      # since sender views don''t have the separate route-id concept the old
      # numeric rules[] had.
      rules = map (v: { id = v.folder; when = v.predicate; folder = v.folder; }) senderViews;
      # Fz (the sender axis's own NOT-any-of-the-others catch-all) is
      # deliberately the true fallback too: it's built to match exactly what
      # nothing else does, so setting routing_default to it is redundant with
      # first-match-wins ordering, but explicit here as defense in depth in
      # case a future edit reorders `rules` or leaves the F axis empty.
      fzView = lib.findFirst (v: lib.hasPrefix "Fz" v.folder) null senderViews;
      defFolder = if fzView != null then fzView.folder
                  else (merged.folders.${merged.routing_default} or merged.routing_default);
    in {
      schema_version    = 2;
      generated_by      = "_shared/lib/mail-rules.nix";
      account           = merged.account;
      routing_default   = defFolder;
      # Permanently unified-inbox: every message lands in INBOX (marked per
      # inbox_copy_flags, typically \Seen), and mail-sieve-subset-post-hoc.sh
      # apply-rules COPIES (not moves) an unread duplicate into the matched
      # F folder -- real IMAP COPY, independent flags per copy, unlike
      # JMAP/Stalwart where fileinto :copy shares one Email object and can't
      # do this (see route.rs's header doc on the Stalwart side for why).
      # No longer derived from inbox_copy.enabled: that flag went false when
      # Stalwart's JMAP model made an independent flag per copy impossible
      # there, but Maddy's IMAP backend genuinely CAN do it, so Maddy keeps
      # doing it regardless of what Stalwart's flag says. Coupling the two
      # through one shared boolean was itself a bug -- flipping inbox_copy
      # off for the JMAP fix silently flipped Maddy's delivery_strategy to
      # "split" too, undoing the real unread-copy behavior it already had.
      delivery_strategy = "unified-inbox";
      inbox_copy_flags  = merged.inbox_copy.flags or [ "\\Seen" ];
      rules             = rules;
    };

  # ── Legacy schema (the shape the jmap-sorter binary parses) ──────
  #
  # jmap-sorter (src/crate, rules.rs) deserialises:
  #   { account, folders, routing_default, sieve_require,
  #     routing: [ { folder, match: { type, values } } ] }
  #
  # A per-flag "tag bucket" subfolder tree (one physical folder per rule
  # flag, e.g. "4- Admin, Finance & E-commerce" / "4-4 Fin_entity:Bank")
  # used to be synthesized here for the old Python jmap-sorter. It was
  # removed from rules.rs/mailboxes.rs: it never checked engines.stalwart
  # at creation time, so it silently created these folders for every rule
  # with a flag regardless of whether that flag was ever actually emitted
  # on Stalwart — an always-empty, ever-growing folder tree that visually
  # clashed with the two-digit numeric routing folders (11, 12, 13, ...)
  # it sat next to. The dynamic E/F cross-cutting views (JMAP multi-mailbox
  # membership) are what a flag like Fin_entity:Bank should surface as now.

  toLegacyJson = merged:
    let
      predicates = merged.predicates;
      sorted     = sortByPriority merged.rules;

      # Routing: route-kind rules with from_domain-style atoms (jmap-sorter
      # only understands type==from_domain at match time — keep the subset).
      routingFrom = rule:
        let
          mode = rule.engines.stalwart or "full";
          folder = effectiveFolder (allFolderTargets merged) rule;
          atom = resolvePredicate predicates rule.when;
        in
        if mode == "drop" || folder == null then null
        else if atom.type or "" != "from_domain" then null
        else {
          inherit folder;
          match = { type = "from_domain"; values = atom.values; };
        };

      routing = filter (x: x != null)
        (map routingFrom (filter isRouteKind sorted));

      defFolder = merged.folders.${merged.routing_default} or merged.routing_default;
    in {
      account        = merged.account;
      sieve_require  = merged.sieve_require;
      folders        = merged.folders;
      # Two-level folder groups (parent + named children) -- ensure_mailboxes
      # creates each parent then its children with the right parentId.
      # `folders` above stays flat-only: group children are NOT flattened
      # into it, or ensure_mailboxes would create them a second time as
      # stray ROOT mailboxes instead of nesting them under their parent.
      folder_groups  = merged.folder_groups or [];
      # Visual section-header siblings (flat ROOT mailboxes, NOT parents).
      # Consumed by jmap-sorter's ensure_mailboxes + cleanup_stale to
      # mirror Maddy's IMAP layout. Optional — defaults to [].
      folders_ui     = merged.folders_ui or [];
      routing_default = defFolder;
      # Dynamic cross-cutting filter views — maintained by jmap-sorter via
      # JMAP multi-mailbox membership over emails in the numeric folders.
      filters        = merged.filters or { views = []; section_headers = []; };
      folder_renames = merged.folder_renames or { map = {}; };
      inherit routing;
    };

in {
  # Public API
  inherit loadJson loadAndMerge merge
          resolvePredicate
          toSieve toMaddyJson toLegacyJson
          # Internal but useful for tests / extension
          sieveTest sieveAtom sieveList sortByPriority;
}
