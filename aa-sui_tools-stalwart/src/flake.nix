{
  description = "Stalwart Mail Server v0.13 — SHADOW MODE (JMAP/Sieve testing, offset ports)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];
    ports = import ../../_shared/lib/port-enforcement.nix { buildJsonPath = ../build.json; };
    buildJson = builtins.fromJSON (builtins.readFile ../build.json);
    buildContainer = builtins.fromJSON (builtins.readFile ./build-stalwart.json);

    title = "Stalwart Mail Server (Shadow)";
    docker = import ../../_shared/docker.nix;
    lib = nixpkgs.lib;

    # base_domain derived from service domain: "mail-stalwart.example.com" → "example.com"
    base_domain = lib.concatStringsSep "." (lib.drop 1 (lib.splitString "." buildJson.domain));

    # Admin password hash (SHA-512 crypt) — generated from secrets, baked into config
    # This is a HASH, not the plaintext password — safe to include in config
    # Note: '' escapes ${ in nix strings
    adminHash = "$6$StalwartShadow$TnGwCZsckFjb/S6BcJV5UL8Gxf25mlA4eO2WI1G7jDYCwdMTfeSQUAUcR2H6mujyRMTjAWMHf3SyRNW/3.r7a/";

    # ── Mail rules: JSON → Sieve ──────────────────────────────────────
    mailRules = builtins.fromJSON (builtins.readFile ./mail-rules.json);

    # Sieve condition generator — dispatches on rule.type
    mkCondition = rule:
      if rule.type == "from_domain" then
        let domains = lib.concatMapStringsSep ", " (d: ''"${d}"'') rule.values;
        in ''address :domain "From" [${domains}]''
      else if rule.type == "from_address" then
        let addrs = lib.concatMapStringsSep ", " (a: ''"${a}"'') rule.values;
        in ''address :is "From" [${addrs}]''
      else if rule.type == "header_contains" then
        let vals = lib.concatMapStringsSep ", " (v: ''"${v}"'') rule.values;
        in ''header :contains "${rule.header}" [${vals}]''
      else if rule.type == "header_exists" then
        ''exists "${rule.header}"''
      else if rule.type == "size_over" then
        "size :over ${toString rule.bytes}"
      else if rule.type == "self_sent" then
        ''address :is "From" "${mailRules.account}"''
      else if rule.type == "has_cc" then
        ''exists "CC"''
      else if rule.type == "list_header" then
        ''exists "List-Unsubscribe"''
      else if rule.type == "content_type" then
        ''header :mime :anychild :contenttype "Content-Type" "${rule.value}"''
      else
        "false";

    # Tag line: if <condition> { addflag + fileinto numbered subfolder }
    mkTagLine = group: rule:
      let
        idx = toString (lib.lists.findFirstIndex (r: r == rule) 0 group.rules);
        groupNum = builtins.head (lib.strings.splitString "-" group.name);
        subFolder = "${group.name}/${groupNum}-${idx} ${rule.flag}";
      in
      ''if ${mkCondition rule} { addflag "${rule.flag}"; fileinto :copy :create "${subFolder}"; }'';

    # Tag group: comment header + all rules
    mkTagGroup = group:
      "# -- ${group.id}: ${group.name} --\n"
      + lib.concatStringsSep "\n" (map (mkTagLine group) group.rules);

    # Routing rule: if <condition> { fileinto :create "<folder>"; stop; }
    mkRoutingRule = route:
      "if ${mkCondition route.match} {\n  fileinto :create \"${route.folder}\";\n  stop;\n}";

    # Full Sieve script assembly
    mkSieveScript =
      let
        requires = lib.concatMapStringsSep ", " (e: ''"${e}"'') mailRules.sieve_require;
        tagSection = lib.concatStringsSep "\n\n" (map mkTagGroup mailRules.tags);
        routingSection = lib.concatStringsSep "\n" (map mkRoutingRule mailRules.routing);
      in ''
        require [${requires}];

        # ══════════════════════════════════════════════════════════════════
        # TAGS — all matching rules fire (additive IMAP keywords)
        # Generated from mail-rules.json — DO NOT EDIT
        # ══════════════════════════════════════════════════════════════════

        ${tagSection}

        # ══════════════════════════════════════════════════════════════════
        # ROUTING — first match wins (fileinto + stop)
        # ══════════════════════════════════════════════════════════════════

        ${routingSection}
        # Default: unmatched emails go to Others
        fileinto :create "${mailRules.routing_default}";
      '';

    mkSieve = pkgs: pkgs.writeText "default.sieve" mkSieveScript;

    # GHCR image: wrap upstream with config
    ghcr = docker.mkGhcrBuild {
      name = buildContainer.container.container_name;
      fromImage = buildJson.upstream_image;
      configFiles = [
        { src = "config.toml"; dst = "/opt/stalwart-mail/etc/config.toml"; }
      ];
    };

    # ── Config: substitute admin hash ──────────────────────────────────
    # Use printf + awk to avoid shell $ interpretation in the hash
    mkConfig = pkgs: pkgs.runCommand "config.toml" {
      hash = adminHash;
    } ''
      ${pkgs.gawk}/bin/awk -v h="$hash" '{gsub(/@@ADMIN_HASH@@/, h); print}' ${./config.toml.tpl} > $out
    '';

    # ── Docker Compose ─────────────────────────────────────────────────
    mkDockerCompose = pkgs: docker.mkCompose pkgs {
      banner = docker.banner "~/git/cloud/a_solutions/aa-sui_tools-stalwart/src/flake.nix";
      volumes = {
        stalwart_data = {};
      };
      services = {
        stalwart = docker.mkService {
          name = "stalwart";
          image = ghcr.image;
          build = ghcr.build;
          container_name = buildContainer.container.container_name;
          entrypoint = ["stalwart" "--config" "/opt/stalwart-mail/etc/config.toml"];
          skipCapDrop = true;
          skipReadOnly = true;
          environment = [
            "TZ=${buildJson.timezone}"
          ];
          volumes = [
            "stalwart_data:/opt/stalwart-mail/data"
            "/opt/containers/maddy/tls:/opt/stalwart-mail/tls:ro"
            "./config.toml:/opt/stalwart-mail/etc/config.toml:ro"
          ];
          memLimit = buildJson.containers.app.resources.limits.memory;
          memReservation = buildJson.containers.app.resources.reservations.memory;
        };
        stalwart-sorter = docker.mkService {
          name = buildJson.containers.sorter.container_name;
          image = buildJson.containers.sorter.image;
          container_name = buildJson.containers.sorter.container_name;
          entrypoint = ["python3" "/app/jmap-sorter.py"];
          env_file = [".secrets"];
          skipCapDrop = true;
          skipReadOnly = true;
          environment = [
            "JMAP_URL=https://localhost:${toString (ports.valueOf "app")}"
            "RULES_PATH=/data/mail-rules.json"
            "STARTUP_DELAY=20"
          ];
          volumes = [
            "./jmap-sorter.py:/app/jmap-sorter.py:ro"
            "./mail-rules.json:/data/mail-rules.json:ro"
          ];
          memLimit = buildJson.containers.sorter.resources.mem_limit;
          memReservation = buildJson.containers.sorter.resources.mem_reservation;
        };
      };
    };

    # ── Activation script: ensure accounts + upload Sieve ─────────────
    # Runs after compose-up. Idempotent — fieldAlreadyExists is fine.
    # Reads ADMIN_PASSWORD from .secrets to authenticate.
    mkActivate = pkgs: pkgs.writeText "activate.sh" ''
      #!/bin/sh
      set -e
      BASE="https://localhost:${toString (ports.valueOf "app")}"
      URL="$BASE/api/principal"
      PW=$(cat /opt/containers/stalwart/.secrets.d/ADMIN_PASSWORD 2>/dev/null)
      [ -z "$PW" ] && echo "[activate] No ADMIN_PASSWORD found, skipping" && exit 0

      echo "[activate] Waiting for Stalwart to start..."
      for i in $(seq 1 30); do
        curl -sk -u "admin:$PW" "$URL" -o /dev/null 2>/dev/null && break
        sleep 2
      done

      echo "[activate] Ensuring domain + accounts..."
      curl -sk -u "admin:$PW" -X POST "$URL" -H "Content-Type: application/json" \
        -d '{"type":"domain","name":"${base_domain}"}' 2>/dev/null || true

      curl -sk -u "admin:$PW" -X POST "$URL" -H "Content-Type: application/json" \
        -d '{"type":"individual","name":"me@${base_domain}","secrets":["'"$PW"'"],"emails":["me@${base_domain}"],"roles":["admin"]}' 2>/dev/null || true

      NR_PW=$(cat /opt/containers/stalwart/.secrets.d/NOREPLY_PASSWORD 2>/dev/null || echo "noreply")
      curl -sk -u "admin:$PW" -X POST "$URL" -H "Content-Type: application/json" \
        -d '{"type":"individual","name":"no-reply@${base_domain}","secrets":["'"$NR_PW"'"],"emails":["no-reply@${base_domain}","noreply@${base_domain}"],"roles":["user"]}' 2>/dev/null || true

      # ── Upload Sieve script via JMAP ────────────────────────────────
      SIEVE_FILE="/opt/containers/stalwart/default.sieve"
      USER="me@${base_domain}"
      JMAP_URL="$BASE/jmap/"

      if [ ! -f "$SIEVE_FILE" ]; then
        echo "[activate] No default.sieve found, skipping sieve upload"
        echo "[activate] Done — accounts ensured"
        exit 0
      fi

      echo "[activate] Uploading Sieve script for $USER..."

      # Step 0: Discover JMAP accountId from session (Stalwart uses short IDs, not emails)
      SESSION=$(curl -sk -L -u "$USER:$PW" "$BASE/jmap/session" 2>/dev/null)
      ACCOUNT_ID=$(printf '%s' "$SESSION" | grep -o '"urn:ietf:params:jmap:sieve":"[^"]*"' | head -1 | cut -d'"' -f4)
      if [ -z "$ACCOUNT_ID" ]; then
        echo "[activate] WARNING: Could not discover JMAP accountId"
        echo "[activate] Done — accounts ensured (sieve skipped)"
        exit 0
      fi
      echo "[activate] JMAP accountId: $ACCOUNT_ID"

      # Step 1: Upload .sieve as blob
      UPLOAD_RESP=$(curl -sk -u "$USER:$PW" \
        -X POST "$BASE/jmap/upload/$ACCOUNT_ID/" \
        -H "Content-Type: application/sieve" \
        --data-binary @"$SIEVE_FILE" 2>/dev/null)

      BLOB_ID=$(printf '%s' "$UPLOAD_RESP" | grep -o '"blobId":"[^"]*"' | head -1 | cut -d'"' -f4)
      if [ -z "$BLOB_ID" ]; then
        echo "[activate] WARNING: Sieve blob upload failed: $UPLOAD_RESP"
        echo "[activate] Done — accounts ensured (sieve skipped)"
        exit 0
      fi
      echo "[activate] Blob uploaded: $BLOB_ID"

      # Step 2: Create + activate SieveScript via JMAP
      JMAP_RESP=$(curl -sk -u "$USER:$PW" \
        -X POST "$JMAP_URL" \
        -H "Content-Type: application/json" \
        -d '{
          "using": ["urn:ietf:params:jmap:core", "urn:ietf:params:jmap:sieve"],
          "methodCalls": [
            ["SieveScript/set", {
              "accountId": "'"$ACCOUNT_ID"'",
              "create": {
                "inbox-rules": {
                  "name": "inbox-rules",
                  "blobId": "'"$BLOB_ID"'"
                }
              },
              "onSuccessActivateScript": "#inbox-rules"
            }, "0"]
          ]
        }' 2>/dev/null)

      if printf '%s' "$JMAP_RESP" | grep -q '"created"'; then
        echo "[activate] Sieve script created and activated for $USER"
      else
        # Script may already exist — update it
        echo "[activate] Script exists, attempting update..."
        LIST_RESP=$(curl -sk -u "$USER:$PW" \
          -X POST "$JMAP_URL" \
          -H "Content-Type: application/json" \
          -d '{
            "using": ["urn:ietf:params:jmap:core", "urn:ietf:params:jmap:sieve"],
            "methodCalls": [
              ["SieveScript/get", {
                "accountId": "'"$ACCOUNT_ID"'"
              }, "0"]
            ]
          }' 2>/dev/null)

        SCRIPT_ID=$(printf '%s' "$LIST_RESP" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
        if [ -n "$SCRIPT_ID" ]; then
          curl -sk -u "$USER:$PW" \
            -X POST "$JMAP_URL" \
            -H "Content-Type: application/json" \
            -d '{
              "using": ["urn:ietf:params:jmap:core", "urn:ietf:params:jmap:sieve"],
              "methodCalls": [
                ["SieveScript/set", {
                  "accountId": "'"$ACCOUNT_ID"'",
                  "update": {
                    "'"$SCRIPT_ID"'": {
                      "blobId": "'"$BLOB_ID"'"
                    }
                  },
                  "onSuccessActivateScript": "'"$SCRIPT_ID"'"
                }, "0"]
              ]
            }' 2>/dev/null
          echo "[activate] Sieve script updated and activated"
        else
          echo "[activate] WARNING: Could not find existing script to update"
        fi
      fi

      echo "[activate] Done — accounts + sieve ensured"
    '';

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in let
      defaultPkg = pkgs.runCommand "stalwart-configs" {} ''
        mkdir -p $out
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
        cp ${mkConfig pkgs} $out/config.toml
        cp ${mkActivate pkgs} $out/activate.sh
        cp ${mkSieve pkgs} $out/default.sieve
        cp ${./jmap-sorter.py} $out/jmap-sorter.py
        cp ${./mail-rules.json} $out/mail-rules.json
        chmod +x $out/activate.sh
      '';
    in {
      default = defaultPkg;
      docs = docker.mkDocs pkgs { inherit title; config = {}; inherit defaultPkg; };
    });
  };
}
