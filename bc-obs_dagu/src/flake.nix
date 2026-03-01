{
  description = "Dagu - Lightweight DAG-based workflow scheduler";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    config = {
      container_name = "dagu";
      image = "ghcr.io/dagu-org/dagu:1.30.3";
      port = 8070;
    };

    title = "Dagu - Lightweight DAG-based workflow scheduler";

    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      services:
        dagu:
          build:
            context: .
            dockerfile: Dockerfile
          image: dagu-ssh:local
          container_name: ${config.container_name}
          restart: unless-stopped
          command: ["dagu", "start-all"]
          ports:
            - "10.0.0.3:${toString config.port}:8080"
          environment:
            - DAGU_HOST=0.0.0.0
            - DAGU_PORT=8080
            - DAGU_DAGS_DIR=/var/lib/dagu/dags
            - DAGU_BASE_CONFIG=/var/lib/dagu/base.yaml
            - DAGU_AUTH_MODE=basic
            - DAGU_AUTH_BASIC_USERNAME=''${DAGU_USERNAME}
            - DAGU_AUTH_BASIC_PASSWORD=''${DAGU_PASSWORD}
            - DAGU_TZ=Europe/Berlin
            - BEARER_TOKEN=''${BEARER_TOKEN}
          volumes:
            - ./data:/var/lib/dagu/data
            - ./dags:/var/lib/dagu/dags
            - ./base.yaml:/var/lib/dagu/base.yaml:ro
            - ~/.ssh:/root/.ssh:ro
          mem_limit: 128m
          networks:
            - default
            - mailu_default

      networks:
        mailu_default:
          external: true
    '';

    # ── Base config: SMTP + default notifications ────────────────────────
    mkBaseConfig = pkgs: pkgs.writeText "base.yaml" ''
      smtp:
        host: mailu-smtp-1
        port: "25"
        username: ""
        password: ""

      mailOn:
        failure: false
        success: false

      errorMail:
        from: no-reply@diegonmarcos.com
        to:
          - me@diegonmarcos.com
        prefix: "[Dagu FAIL]"
        attachLogs: true

      infoMail:
        from: no-reply@diegonmarcos.com
        to:
          - me@diegonmarcos.com
        prefix: "[Dagu OK]"
    '';

    # ── DAG workflows ────────────────────────────────────────────────────
    mkDags = pkgs: {

      healthcheck = pkgs.writeText "healthcheck.yaml" ''
        schedule: "*/5 * * * *"

        env:
          - NTFY_URL: http://10.0.0.1:8090
          - BEARER_TOKEN: ''${BEARER_TOKEN}

        mailOn:
          failure: false
          success: false

        steps:
          - name: check-hub
            command: bash -c "echo QUIT | /usr/bin/timeout 3 bash -c 'cat > /dev/tcp/10.0.0.1/22'"
            retryPolicy:
              limit: 1
              intervalSec: 5
          - name: check-mail
            command: bash -c "echo QUIT | /usr/bin/timeout 3 bash -c 'cat > /dev/tcp/10.0.0.3/25'"
          - name: check-analytics
            command: bash -c "echo QUIT | /usr/bin/timeout 3 bash -c 'cat > /dev/tcp/10.0.0.4/22'"

        handlerOn:
          failure:
            type: http
            config:
              headers:
                Content-Type: application/json
                Authorization: "Bearer ''${BEARER_TOKEN}"
              body: |
                {"topic":"infra","title":"Mesh Health FAILED","message":"One or more always-on peers unreachable","priority":5,"tags":["rotating_light"]}
            command: POST ''${NTFY_URL}

          success:
            type: http
            config:
              headers:
                Content-Type: application/json
                Authorization: "Bearer ''${BEARER_TOKEN}"
              body: |
                {"topic":"infra","title":"Mesh Health OK","message":"All always-on peers reachable","priority":2,"tags":["white_check_mark"]}
            command: POST ''${NTFY_URL}
      '';

      # ── System Health Check (daily) - ALL VMs ──
      system-check = pkgs.writeText "system-check.yaml" ''
        schedule: "0 9 * * *"

        env:
          - NTFY_URL: http://10.0.0.1:8090
          - BEARER_TOKEN: ''${BEARER_TOKEN}

        mailOn:
          failure: false
          success: false

        steps:
          - name: check-all-vms
            command: |
              FAILED=0
              for vm_data in 10.0.0.1:gcp-proxy:diego 10.0.0.3:oci-mail:ubuntu 10.0.0.4:oci-analytics:ubuntu 10.0.0.6:oci-apps:ubuntu; do
                ip=''${vm_data%%:*}
                temp=''${vm_data#*:}
                name=''${temp%:*}
                user=''${temp#*:}
                DISK=$(ssh -i /root/.ssh/vault_id_rsa -o StrictHostKeyChecking=no -o ConnectTimeout=5 $user@$ip "df -h / | awk 'NR==2 {print substr(\$5,1,length(\$5)-1)}'" 2>/dev/null || echo 100)
                MEM=$(ssh -i /root/.ssh/vault_id_rsa -o StrictHostKeyChecking=no -o ConnectTimeout=5 $user@$ip "free | awk 'NR==2 {printf \"%.0f\", (\$3/\$2)*100}'" 2>/dev/null || echo 100)
                if [ $DISK -gt 80 ] || [ $MEM -gt 90 ]; then
                  echo "$name: disk=$DISK% mem=$MEM%"
                  FAILED=1
                fi
              done
              exit $FAILED

        handlerOn:
          failure:
            type: http
            config:
              headers:
                Content-Type: application/json
                Authorization: "Bearer ''${BEARER_TOKEN}"
              body: |
                {"topic":"system","title":"System Health Alert","message":"High resource usage detected on one or more VMs","priority":4,"tags":["warning"]}
            command: POST ''${NTFY_URL}
      '';

      # ── Docker Health Check (daily) - ALL VMs ──
      docker-check = pkgs.writeText "docker-check.yaml" ''
        schedule: "0 10 * * *"

        env:
          - NTFY_URL: http://10.0.0.1:8090
          - BEARER_TOKEN: ''${BEARER_TOKEN}

        mailOn:
          failure: false
          success: false

        steps:
          - name: check-all-containers
            command: |
              FAILED=0
              for vm_data in 10.0.0.1:gcp-proxy:diego 10.0.0.3:oci-mail:ubuntu 10.0.0.4:oci-analytics:ubuntu 10.0.0.6:oci-apps:ubuntu; do
                ip=''${vm_data%%:*}
                temp=''${vm_data#*:}
                name=''${temp%:*}
                user=''${temp#*:}
                UNHEALTHY=$(ssh -i /root/.ssh/vault_id_rsa -o StrictHostKeyChecking=no -o ConnectTimeout=5 $user@$ip "docker ps --filter health=unhealthy --format '{{.Names}}' | wc -l" 2>/dev/null || echo 0)
                EXITED=$(ssh -i /root/.ssh/vault_id_rsa -o StrictHostKeyChecking=no -o ConnectTimeout=5 $user@$ip "docker ps -a --filter status=exited --format '{{.Names}}' | wc -l" 2>/dev/null || echo 0)
                if [ $UNHEALTHY -gt 0 ] || [ $EXITED -gt 0 ]; then
                  echo "$name: unhealthy=$UNHEALTHY exited=$EXITED"
                  FAILED=1
                fi
              done
              exit $FAILED

        handlerOn:
          failure:
            type: http
            config:
              headers:
                Content-Type: application/json
                Authorization: "Bearer ''${BEARER_TOKEN}"
              body: |
                {"topic":"docker","title":"Docker Health Issues","message":"Unhealthy or crashed containers detected on one or more VMs","priority":4,"tags":["whale","warning"]}
            command: POST ''${NTFY_URL}
      '';

      # ── Backup Check (daily) - ALL VMs ──
      backup-check = pkgs.writeText "backup-check.yaml" ''
        schedule: "0 11 * * *"

        env:
          - NTFY_URL: http://10.0.0.1:8090
          - BEARER_TOKEN: ''${BEARER_TOKEN}

        mailOn:
          failure: false
          success: false

        steps:
          - name: check-all-backups
            command: |
              FAILED=0
              for vm_data in 10.0.0.1:gcp-proxy:diego 10.0.0.3:oci-mail:ubuntu 10.0.0.4:oci-analytics:ubuntu 10.0.0.6:oci-apps:ubuntu; do
                ip=''${vm_data%%:*}
                temp=''${vm_data#*:}
                name=''${temp%:*}
                user=''${temp#*:}
                COUNT=$(ssh -i /root/.ssh/vault_id_rsa -o StrictHostKeyChecking=no -o ConnectTimeout=5 $user@$ip "find /var/backups -name '*.sql.gz' -mtime -1 2>/dev/null | wc -l" 2>/dev/null || echo 0)
                if [ $COUNT -eq 0 ]; then
                  echo "$name: no recent backups"
                  FAILED=1
                fi
              done
              exit $FAILED

        handlerOn:
          failure:
            type: http
            config:
              headers:
                Content-Type: application/json
                Authorization: "Bearer ''${BEARER_TOKEN}"
              body: |
                {"topic":"backup","title":"Backup Alert","message":"No recent backups on one or more VMs (>24h)","priority":4,"tags":["floppy_disk","warning"]}
            command: POST ''${NTFY_URL}
      '';

      # ── Security Audit (daily) - ALL VMs ──
      security-audit = pkgs.writeText "security-audit.yaml" ''
        schedule: "0 12 * * *"

        env:
          - NTFY_URL: http://10.0.0.1:8090
          - BEARER_TOKEN: ''${BEARER_TOKEN}

        mailOn:
          failure: false
          success: false

        steps:
          - name: check-all-auth-logs
            command: |
              FAILED=0
              for vm_data in 10.0.0.1:gcp-proxy:diego 10.0.0.3:oci-mail:ubuntu 10.0.0.4:oci-analytics:ubuntu 10.0.0.6:oci-apps:ubuntu; do
                ip=''${vm_data%%:*}
                temp=''${vm_data#*:}
                name=''${temp%:*}
                user=''${temp#*:}
                FAIL_COUNT=$(ssh -i /root/.ssh/vault_id_rsa -o StrictHostKeyChecking=no -o ConnectTimeout=5 $user@$ip "grep 'Failed password' /var/log/auth.log 2>/dev/null | grep -c $(date +%b\ %d) || echo 0" 2>/dev/null || echo 0)
                ROOT_LOGIN=$(ssh -i /root/.ssh/vault_id_rsa -o StrictHostKeyChecking=no -o ConnectTimeout=5 $user@$ip "grep 'root.*session opened' /var/log/auth.log 2>/dev/null | grep -c $(date +%b\ %d) || echo 0" 2>/dev/null || echo 0)
                if [ $FAIL_COUNT -gt 10 ] || [ $ROOT_LOGIN -gt 0 ]; then
                  echo "$name: failed_ssh=$FAIL_COUNT root_login=$ROOT_LOGIN"
                  FAILED=1
                fi
              done
              exit $FAILED

        handlerOn:
          failure:
            type: http
            config:
              headers:
                Content-Type: application/json
                Authorization: "Bearer ''${BEARER_TOKEN}"
              body: |
                {"topic":"security","title":"Security Alert","message":"Suspicious authentication activity on one or more VMs","priority":5,"tags":["lock","rotating_light"]}
            command: POST ''${NTFY_URL}
      '';

      # ── Ops Summary (daily) ──
      ops-summary = pkgs.writeText "ops-summary.yaml" ''
        schedule: "0 18 * * *"

        env:
          - NTFY_URL: http://10.0.0.1:8090
          - BEARER_TOKEN: ''${BEARER_TOKEN}

        mailOn:
          failure: false
          success: true

        steps:
          - name: gather-stats
            command: bash -c "uptime && docker ps | wc -l"

        handlerOn:
          success:
            type: http
            config:
              headers:
                Content-Type: application/json
                Authorization: "Bearer ''${BEARER_TOKEN}"
              body: |
                {"topic":"ops","title":"Daily Ops Summary","message":"All systems operational","priority":1,"tags":["chart_with_upwards_trend"]}
            command: POST ''${NTFY_URL}
      '';

      # ── Service Endpoints (every 5 min) ──
      service-endpoints = pkgs.writeText "service-endpoints.yaml" ''
        schedule: "*/5 * * * *"

        env:
          - NTFY_URL: http://10.0.0.1:8090
          - BEARER_TOKEN: ''${BEARER_TOKEN}

        mailOn:
          failure: false
          success: false

        steps:
          - name: check-auth
            command: curl -f -m 5 https://auth.diegonmarcos.com/api/health || exit 1
          - name: check-vault
            command: curl -f -m 5 https://vault.diegonmarcos.com/ || exit 1
          - name: check-proxy
            command: curl -f -m 5 https://proxy.diegonmarcos.com/ || exit 1
          - name: check-api
            command: curl -f -m 5 https://api.diegonmarcos.com/c3-api/health || exit 1
          - name: check-analytics
            command: curl -f -m 5 https://analytics.diegonmarcos.com/ || exit 1

        handlerOn:
          failure:
            type: http
            config:
              headers:
                Content-Type: application/json
                Authorization: "Bearer ''${BEARER_TOKEN}"
              body: |
                {"topic":"infra","title":"Service Endpoint DOWN","message":"Critical endpoint unreachable","priority":5,"tags":["rotating_light"]}
            command: POST ''${NTFY_URL}
      '';

      # ── TLS Expiry Check (daily 8am) ──
      tls-expiry = pkgs.writeText "tls-expiry.yaml" ''
        schedule: "0 8 * * *"

        env:
          - NTFY_URL: http://10.0.0.1:8090
          - BEARER_TOKEN: ''${BEARER_TOKEN}

        mailOn:
          failure: false
          success: false

        steps:
          - name: check-certs
            command: |
              for domain in auth.diegonmarcos.com vault.diegonmarcos.com proxy.diegonmarcos.com api.diegonmarcos.com analytics.diegonmarcos.com mail.diegonmarcos.com photos.diegonmarcos.com sync.diegonmarcos.com; do
                EXPIRY=$(echo | openssl s_client -servername $domain -connect $domain:443 2>/dev/null | openssl x509 -noout -enddate | cut -d= -f2)
                EXPIRY_SEC=$(date -d "$EXPIRY" +%s)
                NOW_SEC=$(date +%s)
                DAYS_LEFT=$(( ($EXPIRY_SEC - $NOW_SEC) / 86400 ))
                if [ $DAYS_LEFT -lt 14 ]; then
                  echo "$domain expires in $DAYS_LEFT days"
                  exit 1
                fi
              done

        handlerOn:
          failure:
            type: http
            config:
              headers:
                Content-Type: application/json
                Authorization: "Bearer ''${BEARER_TOKEN}"
              body: |
                {"topic":"security","title":"TLS Certificate Expiring","message":"Certificate expires in <14 days","priority":4,"tags":["warning"]}
            command: POST ''${NTFY_URL}
      '';

      # ── DNS Resolution Check (daily 8am) ──
      dns-resolution = pkgs.writeText "dns-resolution.yaml" ''
        schedule: "0 8 * * *"

        env:
          - NTFY_URL: http://10.0.0.1:8090
          - BEARER_TOKEN: ''${BEARER_TOKEN}

        mailOn:
          failure: false
          success: false

        steps:
          - name: check-dns
            command: |
              for domain in diegonmarcos.com auth.diegonmarcos.com vault.diegonmarcos.com api.diegonmarcos.com; do
                dig +short $domain @1.1.1.1 || exit 1
              done

        handlerOn:
          failure:
            type: http
            config:
              headers:
                Content-Type: application/json
                Authorization: "Bearer ''${BEARER_TOKEN}"
              body: |
                {"topic":"infra","title":"DNS Resolution FAILED","message":"Critical domain not resolving","priority":5,"tags":["rotating_light"]}
            command: POST ''${NTFY_URL}
      '';

      # ── Auth Events Aggregator (daily 9am) ──
      auth-events = pkgs.writeText "auth-events.yaml" ''
        schedule: "0 9 * * *"

        env:
          - NTFY_URL: http://10.0.0.1:8090
          - BEARER_TOKEN: ''${BEARER_TOKEN}

        mailOn:
          failure: false
          success: true

        steps:
          - name: collect-auth-events
            command: |
              TOTAL=0
              for vm_data in 10.0.0.1:gcp-proxy:diego 10.0.0.3:oci-mail:ubuntu 10.0.0.4:oci-analytics:ubuntu 10.0.0.6:oci-apps:ubuntu; do
                ip=''${vm_data%%:*}
                temp=''${vm_data#*:}
                name=''${temp%:*}
                user=''${temp#*:}
                COUNT=$(ssh -i /root/.ssh/vault_id_rsa -o StrictHostKeyChecking=no -o ConnectTimeout=5 $user@$ip "grep -c 'Accepted publickey' /var/log/auth.log 2>/dev/null || echo 0")
                TOTAL=$((TOTAL + COUNT))
              done
              echo "Total SSH logins (24h): $TOTAL"

        handlerOn:
          success:
            type: http
            config:
              headers:
                Content-Type: application/json
                Authorization: "Bearer ''${BEARER_TOKEN}"
              body: |
                {"topic":"auth","title":"Daily Auth Summary","message":"SSH activity aggregated across all VMs","priority":1,"tags":["key"]}
            command: POST ''${NTFY_URL}
      '';

      # ── Cron Status Check (daily 7am) ──
      cron-status = pkgs.writeText "cron-status.yaml" ''
        schedule: "0 7 * * *"

        env:
          - NTFY_URL: http://10.0.0.1:8090
          - BEARER_TOKEN: ''${BEARER_TOKEN}

        mailOn:
          failure: false
          success: false

        steps:
          - name: check-systemd-timers
            command: |
              FAILED=0
              for vm_data in 10.0.0.1:gcp-proxy:diego 10.0.0.3:oci-mail:ubuntu 10.0.0.4:oci-analytics:ubuntu 10.0.0.6:oci-apps:ubuntu; do
                ip=''${vm_data%%:*}
                temp=''${vm_data#*:}
                name=''${temp%:*}
                user=''${temp#*:}
                FAIL_COUNT=$(ssh -i /root/.ssh/vault_id_rsa -o StrictHostKeyChecking=no -o ConnectTimeout=5 $user@$ip "systemctl list-timers --failed --no-legend | wc -l" 2>/dev/null || echo 0)
                FAILED=$((FAILED + FAIL_COUNT))
              done
              if [ $FAILED -gt 0 ]; then
                echo "$FAILED failed timers detected"
                exit 1
              fi

        handlerOn:
          failure:
            type: http
            config:
              headers:
                Content-Type: application/json
                Authorization: "Bearer ''${BEARER_TOKEN}"
              body: |
                {"topic":"cron","title":"Cron/Timer Failures Detected","message":"One or more scheduled tasks failed","priority":4,"tags":["warning"]}
            command: POST ''${NTFY_URL}
      '';

      # ── Deploy Digest (daily 7pm) ──
      deploy-digest = pkgs.writeText "deploy-digest.yaml" ''
        schedule: "0 19 * * *"

        env:
          - NTFY_URL: http://10.0.0.1:8090
          - BEARER_TOKEN: ''${BEARER_TOKEN}

        mailOn:
          failure: false
          success: true

        steps:
          - name: summarize-deployments
            command: |
              COUNT=$(ssh -i /root/.ssh/vault_id_rsa -o StrictHostKeyChecking=no diego@10.0.0.1 "journalctl -u docker --since '24 hours ago' | grep -c 'Container.*Started' || echo 0")
              echo "Container restarts (24h): $COUNT"

        handlerOn:
          success:
            type: http
            config:
              headers:
                Content-Type: application/json
                Authorization: "Bearer ''${BEARER_TOKEN}"
              body: |
                {"topic":"deploy","title":"Daily Deploy Digest","message":"Deployment activity summary","priority":1,"tags":["rocket"]}
            command: POST ''${NTFY_URL}
      '';

      # ── Sauron Integrity Check (weekly Sunday 3am) ──
      sauron-integrity = pkgs.writeText "sauron-integrity.yaml" ''
        schedule: "0 3 * * 0"

        env:
          - NTFY_URL: http://10.0.0.1:8090
          - BEARER_TOKEN: ''${BEARER_TOKEN}

        mailOn:
          failure: false
          success: false

        steps:
          - name: verify-scanners
            command: |
              RUNNING=0
              for vm_ip in 10.0.0.1:gcp-proxy 10.0.0.3:oci-mail 10.0.0.4:oci-analytics 10.0.0.6:oci-apps; do
                ip=$${vm_ip%:*}
                if ssh -i /root/.ssh/vault_id_rsa -o StrictHostKeyChecking=no -o ConnectTimeout=5 $user@$ip "docker ps | grep -q sauron-lite" 2>/dev/null; then
                  RUNNING=$((RUNNING + 1))
                fi
              done
              if [ $RUNNING -lt 4 ]; then
                echo "Only $RUNNING/4 Sauron scanners running"
                exit 1
              fi

        handlerOn:
          failure:
            type: http
            config:
              headers:
                Content-Type: application/json
                Authorization: "Bearer ''${BEARER_TOKEN}"
              body: |
                {"topic":"sauron","title":"Sauron Scanner(s) Down","message":"Not all security scanners are running","priority":4,"tags":["warning"]}
            command: POST ''${NTFY_URL}
      '';

      # ── Capacity Review (weekly Monday 9am) ──
      capacity-review = pkgs.writeText "capacity-review.yaml" ''
        schedule: "0 9 * * 1"

        env:
          - NTFY_URL: http://10.0.0.1:8090
          - BEARER_TOKEN: ''${BEARER_TOKEN}

        mailOn:
          failure: false
          success: true

        steps:
          - name: check-capacity
            command: |
              TOTAL_DISK=0
              for vm_data in 10.0.0.1:gcp-proxy:diego 10.0.0.3:oci-mail:ubuntu 10.0.0.4:oci-analytics:ubuntu 10.0.0.6:oci-apps:ubuntu; do
                ip=''${vm_data%%:*}
                temp=''${vm_data#*:}
                name=''${temp%:*}
                user=''${temp#*:}
                USAGE=$(ssh -i /root/.ssh/vault_id_rsa -o StrictHostKeyChecking=no -o ConnectTimeout=5 $user@$ip "df -h / | awk 'NR==2 {print \$5}' | sed 's/%//'" 2>/dev/null || echo 0)
                TOTAL_DISK=$((TOTAL_DISK + USAGE))
              done
              AVG_DISK=$((TOTAL_DISK / 5))
              echo "Average disk usage: $AVG_DISK%"

        handlerOn:
          success:
            type: http
            config:
              headers:
                Content-Type: application/json
                Authorization: "Bearer ''${BEARER_TOKEN}"
              body: |
                {"topic":"ops","title":"Weekly Capacity Review","message":"Storage trends across all VMs","priority":1,"tags":["bar_chart"]}
            command: POST ''${NTFY_URL}
      '';
    };

    # ── Documentation ────────────────────────────────────────────────────
    mkDocs = pkgs: defaultPkg: let
      inherit (pkgs.lib) concatMapStrings hasSuffix optionalString filter subtractLists removeSuffix;
      inherit (builtins) attrNames readDir pathExists;

      portKeys = filter (k: hasSuffix "_port" k || k == "port") (attrNames config);
      imageKeys = filter (k: hasSuffix "_image" k || k == "image") (attrNames config);
      containerKeys = filter (k: hasSuffix "_container" k || k == "container_name") (attrNames config);
      domainKeys = filter (k: k == "domain" || k == "base_domain") (attrNames config);
      otherKeys = subtractLists (portKeys ++ imageKeys ++ containerKeys ++ domainKeys) (attrNames config);

      row = k: let
        v = config.${k};
        vs = if builtins.isBool v then (if v then "true" else "false")
             else if builtins.isAttrs v || builtins.isList v then builtins.toJSON v
             else toString v;
      in "| `${k}` | `${vs}` |\n";
      section = heading: keys: optionalString (keys != []) ''
        ## ${heading}
        | Key | Value |
        |-----|-------|
        ${concatMapStrings row keys}
      '';

      hasNarrative = pathExists ./docs;
      narrativeFiles = if hasNarrative
        then filter (f: hasSuffix ".md" f) (attrNames (readDir ./docs))
        else [];

      specMd = pkgs.writeText "spec.md" ''
        # ${title}
        ${section "Network" (domainKeys ++ portKeys)}
        ${section "Containers" (containerKeys ++ imageKeys)}
        ${section "Configuration" otherKeys}
      '';

      summaryMd = pkgs.writeText "SUMMARY.md" ''
        # Summary
        - [Specification](./spec.md)
        - [Generated Configs](./configs.md)
        ${concatMapStrings (f: "- [${removeSuffix ".md" f}](./${f})\n") narrativeFiles}
      '';

      bookToml = pkgs.writeText "book.toml" ''
        [book]
        title = "${title}"
        [output.html]
        default-theme = "ayu"
      '';
    in pkgs.runCommand "docs" {
      nativeBuildInputs = [ pkgs.mdbook pkgs.file ];
    } ''
      mkdir -p build/src
      cp ${bookToml} build/book.toml
      cp ${summaryMd} build/src/SUMMARY.md
      cp ${specMd} build/src/spec.md
      ${optionalString hasNarrative "cp ${./docs}/*.md build/src/ 2>/dev/null || true"}

      echo "# Generated Configuration Files" > build/src/configs.md
      echo "" >> build/src/configs.md
      echo 'These files are produced by nix build and deployed to the VM.' >> build/src/configs.md
      echo "" >> build/src/configs.md
      find ${defaultPkg} -type f | sort | while read -r f; do
        relpath="''${f#${defaultPkg}/}"
        case "$relpath" in
          .secrets|*.secrets|*.lock|*.png|*.jpg|*.gif|*.ico|*.woff*|*.ttf|*.eot) continue ;;
        esac
        case "$relpath" in
          *.yml|*.yaml)   lang="yaml" ;;
          *.json)         lang="json" ;;
          *.toml)         lang="toml" ;;
          *.py)           lang="python" ;;
          *.sh)           lang="bash" ;;
          *.js|*.ts)      lang="javascript" ;;
          *.tf)           lang="hcl" ;;
          *.conf|*.cnf)   lang="ini" ;;
          *.html)         lang="html" ;;
          *.sql)          lang="sql" ;;
          *.zone)         lang="dns" ;;
          Dockerfile*)    lang="dockerfile" ;;
          Caddyfile*)     lang="caddy" ;;
          *)              lang="" ;;
        esac
        if file -b --mime-type "$f" | grep -q "^text/"; then
          echo '## '"$relpath" >> build/src/configs.md
          echo "" >> build/src/configs.md
          echo "~~~$lang" >> build/src/configs.md
          cat "$f" >> build/src/configs.md
          echo "" >> build/src/configs.md
          echo '~~~' >> build/src/configs.md
          echo "" >> build/src/configs.md
        fi
      done

      cd build && mdbook build -d $out
    '';

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
      dags = mkDags pkgs;
    in let
      defaultPkg = pkgs.runCommand "dagu-configs" {} ''
        mkdir -p $out/dags
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
        cp ${mkBaseConfig pkgs} $out/base.yaml
        cp ${./Dockerfile} $out/Dockerfile
        cp ${dags.healthcheck} $out/dags/healthcheck.yaml
        cp ${dags.system-check} $out/dags/system-check.yaml
        cp ${dags.docker-check} $out/dags/docker-check.yaml
        cp ${dags.backup-check} $out/dags/backup-check.yaml
        cp ${dags.security-audit} $out/dags/security-audit.yaml
        cp ${dags.ops-summary} $out/dags/ops-summary.yaml
        cp ${dags.service-endpoints} $out/dags/service-endpoints.yaml
        cp ${dags.tls-expiry} $out/dags/tls-expiry.yaml
        cp ${dags.dns-resolution} $out/dags/dns-resolution.yaml
        cp ${dags.auth-events} $out/dags/auth-events.yaml
        cp ${dags.cron-status} $out/dags/cron-status.yaml
        cp ${dags.deploy-digest} $out/dags/deploy-digest.yaml
        cp ${dags.sauron-integrity} $out/dags/sauron-integrity.yaml
        cp ${dags.capacity-review} $out/dags/capacity-review.yaml
      '';
    in {
      default = defaultPkg;
      docs = mkDocs pkgs defaultPkg;
    });
  };
}
