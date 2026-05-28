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
      routing_default  = p.routing_default or general.routing_default or "others";
      inbox_copy       = p.inbox_copy or general.inbox_copy or { enabled = false; flags = []; };
      cleanup          = p.cleanup or general.cleanup or {};
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
      folders     = merged.folders;
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
      folders    = merged.folders;
      predicates = merged.predicates;
      sorted     = sortByPriority merged.rules;
      rules      = filter (x: x != null) (map (maddyRule folders predicates) sorted);
      defFolder  = folders.${merged.routing_default} or merged.routing_default;
      # delivery_strategy derives from inbox_copy.enabled so the script
      # has a single boolean to read. Cases:
      #   enabled = true  → "unified-inbox": maddy delivery-time always
      #     places the message in INBOX (with inbox_copy_flags applied);
      #     per-rule placement into category folders is done by
      #     post-hoc apply-rules as COPY (INBOX retains the original).
      #   enabled = false → "split": maddy delivery-time places the
      #     message directly in the matched rule''s folder. INBOX only
      #     gets messages that don''t match any routing rule.
      strategy = if (merged.inbox_copy.enabled or false)
                 then "unified-inbox" else "split";
    in {
      schema_version    = 2;
      generated_by      = "_shared/lib/mail-rules.nix";
      account           = merged.account;
      routing_default   = defFolder;
      delivery_strategy = strategy;
      inbox_copy_flags  = merged.inbox_copy.flags or [];
      rules             = rules;
    };

  # ── Legacy schema (for jmap-sorter.py during transition) ─────────
  #
  # jmap-sorter.py expects:
  #   { account, folders, routing_default, sieve_require,
  #     tags: [ { id, name, rules: [ { type, values|header|bytes, flag } ] } ],
  #     routing: [ { folder, match: { type, values } } ] }
  #
  # We synthesize one tag bucket per top-level rule prefix (dev, career,
  # lifestyle, admin, info, cloud, meta.route, meta.attach, profile) so
  # jmap-sorter's "folder subfolder per bucket" logic still produces
  # a stable layout. Meta/attachment rules go into synthetic B7/B8-named
  # groups so jmap-sorter's `META_TAG_IDS = {"B7", "B8"}` self-seen
  # behavior continues to fire.

  # Flatten a v2 rule into legacy tag-rule shape (one per flag emitted).
  legacyTagRulesFor = predicates: rule:
    let
      mode = rule.engines.stalwart or "full";
      flags = effectiveFlags rule;
      atom = resolvePredicate predicates rule.when;
      # Legacy jmap-sorter only understands simple atoms. Skip combinators.
      usable = !(hasAttr "any_of" atom) && !(hasAttr "all_of" atom) && !(hasAttr "not" atom);
    in
    # `route_only` means "this engine should only execute the copy_to action,
    # skip the tag/keyword action entirely" — symmetric with Maddy's
    # routingFromRule above at line ~245 (`hasFlags = mode == "full" ||
    # "tag_only"`). Without this check the sorter created the full
    # B1..B9 tag bucket hierarchy + ~30 subfolders even when the operator
    # had set every rule's stalwart-mode to `route_only` to match Maddy's
    # "route, don't tag" behaviour. Result: Stalwart and Maddy ended up
    # with wildly different mailbox shapes for the same SoT.
    if mode == "drop" || mode == "route_only" || flags == [] || !usable then []
    else
      map (flag:
        { type = atom.type; flag = flag; }
        // (optionalAttrs (atom ? values) { inherit (atom) values; })
        // (optionalAttrs (atom ? header) { inherit (atom) header; })
        // (optionalAttrs (atom ? bytes)  { inherit (atom) bytes;  })
        // (optionalAttrs (atom ? value)  { inherit (atom) value;  })
      ) flags;

  # Synthetic tag-bucket grouping: map rule.id prefix to legacy group id/name.
  legacyBucketOf = rule:
    let id = rule.id; in
    if lib.hasPrefix "route.dev" id || lib.hasPrefix "tag.dev" id            then { id = "B1"; name = "1- Development, Education & Tools"; }
    else if lib.hasPrefix "route.career" id || lib.hasPrefix "tag.career" id then { id = "B2"; name = "2- Career & Networking"; }
    else if lib.hasPrefix "route.lifestyle" id || lib.hasPrefix "tag.lifestyle" id then { id = "B3"; name = "3- Lifestyle, Travel & Logistics"; }
    else if lib.hasPrefix "route.admin" id || lib.hasPrefix "tag.admin" id   then { id = "B4"; name = "4- Admin, Finance & E-commerce"; }
    else if lib.hasPrefix "route.info" id || lib.hasPrefix "tag.info" id     then { id = "B5"; name = "5- Information, Media & Feeds"; }
    else if lib.hasPrefix "route.cloud" id || lib.hasPrefix "tag.cloud" id   then { id = "B6"; name = "6- Cloud (Homelab) Management"; }
    else if lib.hasPrefix "meta.attach" id || lib.hasPrefix "meta.size" id   then { id = "B7"; name = "7- Meta Size & Attachment Types"; }
    else if lib.hasPrefix "meta" id                                          then { id = "B8"; name = "8- Meta Routing & Sender Properties"; }
    else                                                                          { id = "B9"; name = "9- Profile Overlay"; };

  toLegacyJson = merged:
    let
      predicates = merged.predicates;
      sorted     = sortByPriority merged.rules;

      # Tags: flatten rules with flags to legacy {type, values, flag} items,
      # grouped by synthetic bucket. Rules with combinator predicates
      # contribute to the `rules` list but without a usable atom — keep
      # them out (jmap-sorter would crash on unknown shape).
      tagsByBucket =
        lib.foldl (acc: rule:
          let
            bucket = legacyBucketOf rule;
            items = legacyTagRulesFor predicates rule;
          in
          if items == [] then acc
          else acc // {
            ${bucket.id} = (acc.${bucket.id} or { inherit (bucket) id name; rules = []; }) // {
              rules = (acc.${bucket.id}.rules or []) ++ items;
            };
          }
        ) {} sorted;

      # Fixed display order B1..B9
      orderedBuckets =
        filter (b: b != null)
          (map (k: tagsByBucket.${k} or null) ["B1" "B2" "B3" "B4" "B5" "B6" "B7" "B8" "B9"]);

      # Routing: route-kind rules with from_domain-style atoms (jmap-sorter
      # only understands type==from_domain at match time — keep the subset).
      routingFrom = rule:
        let
          mode = rule.engines.stalwart or "full";
          folder = effectiveFolder merged.folders rule;
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
      routing_default = defFolder;
      tags           = orderedBuckets;
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
