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
      # ╔══════════════════════════════════════════════════════════════════╗
      # ║ DO NOT EDIT — DECLARATIVE ENVIRONMENT — NIX FLAKES WAY         ║
      # ║ AUTO-GENERATED — DONT USE IMPERATIVE SOLUTIONS!!!              ║
      # ╠══════════════════════════════════════════════════════════════════╣
      # ║ Source: ~/git/cloud/a_solutions/bc-obs_dagu/src/flake.nix       ║
      # ║ Rebuild: ~/git/cloud/a_solutions/bc-obs_dagu/build.sh ship      ║
      # ╚══════════════════════════════════════════════════════════════════╝
      services:
        dagu:
          build:
            context: .
            dockerfile: Dockerfile
          image: dagu-ssh:local
          container_name: ${config.container_name}
          entrypoint: ["sh", "/var/lib/dagu/fetch-token.sh"]
          restart: unless-stopped
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
            - AUTHELIA_OIDC_CLIENT_ID=dagu-ops
            - AUTHELIA_OIDC_CLIENT_SECRET=''${AUTHELIA_OIDC_DAGU_SECRET}
            - AUTHELIA_TOKEN_URL=https://auth.diegonmarcos.com/api/oidc/token
          volumes:
            - ./data:/var/lib/dagu/data
            - ./dags:/var/lib/dagu/dags
            - ./base.yaml:/var/lib/dagu/base.yaml:ro
            - ./fetch-token.sh:/var/lib/dagu/fetch-token.sh:ro
            - /opt/ssh-keys/dagu:/root/.ssh:ro
          mem_limit: 256m
          networks:
            - default
            - mailu_default

      networks:
        mailu_default:
          external: true
    '';

    # ── Base config: SMTP + default notifications ────────────────────────
    mkBaseConfig = pkgs: pkgs.writeText "base.yaml" ''
      shell: /bin/bash

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

    # ── OIDC token fetch entrypoint ───────────────────────────────────────
    mkFetchToken = pkgs: pkgs.writeText "fetch-token.sh" ''
      #!/bin/sh
      set -e

      # Fetch OIDC token via client_credentials grant, export as AUTHELIA_BEARER_TOKEN
      # so all existing DAG workflows keep working without changes.
      echo "[fetch-token] Requesting OIDC token from $AUTHELIA_TOKEN_URL ..."
      RESPONSE=$(curl -s -f -X POST "$AUTHELIA_TOKEN_URL" \
        -u "$AUTHELIA_OIDC_CLIENT_ID:$AUTHELIA_OIDC_CLIENT_SECRET" \
        -d "grant_type=client_credentials&scope=authelia.bearer.authz")

      TOKEN=$(echo "$RESPONSE" | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
      if [ -z "$TOKEN" ]; then
        echo "[fetch-token] ERROR: Failed to get OIDC token"
        echo "[fetch-token] Response: $RESPONSE"
        exit 1
      fi

      export AUTHELIA_BEARER_TOKEN="$TOKEN"
      echo "[fetch-token] Token acquired (${#TOKEN} chars), starting dagu..."
      exec dagu start-all
    '';

    # ── SSH shorthand used across all workflows ──────────────────────────
    # VMs: ip:name:user
    vmList = "10.0.0.1:gcp-proxy:diego 10.0.0.3:oci-mail:ubuntu 10.0.0.4:oci-analytics:ubuntu 10.0.0.6:oci-apps:ubuntu";
    sshCmd = "ssh -i /root/.ssh/vault_id_rsa -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR";

    # ── DAG workflows ────────────────────────────────────────────────────
    mkDags = pkgs: {

      # ═══════════════════════════════════════════════════════════════════
      # INFRASTRUCTURE
      # ═══════════════════════════════════════════════════════════════════

      healthcheck = pkgs.writeText "healthcheck.yaml" ''
        schedule: "*/5 * * * *"
        env:
          - NTFY_URL: http://10.0.0.1:8090
          - AUTHELIA_BEARER_TOKEN: ''${AUTHELIA_BEARER_TOKEN}
        mailOn:
          failure: false
          success: false
        steps:
          - name: check-mesh-and-notify
            command: |
              SSH="${sshCmd}"
              FAILED=""
              for peer in "10.0.0.1:gcp-proxy:22" "10.0.0.3:oci-mail:25" "10.0.0.4:oci-analytics:22"; do
                ip=''${peer%%:*}
                rest=''${peer#*:}
                name=''${rest%:*}
                port=''${rest##*:}
                if ! echo QUIT | timeout 3 bash -c "cat > /dev/tcp/$ip/$port" 2>/dev/null; then
                  FAILED="''${FAILED}  - $name ($ip) port $port UNREACHABLE\n"
                fi
              done
              if [ -n "$FAILED" ]; then
                MSG=$(echo -e "Unreachable peers:\n''${FAILED}\nAction:\n  ssh <vm> 'wg show'\n  ssh <vm> 'systemctl status wg-quick@wg0'\n\nDagu: http://10.0.0.3:8070")
                curl -s -X POST "$NTFY_URL/infra_mesh-health" \
                  -H "Authorization: Bearer $AUTHELIA_BEARER_TOKEN" \
                  -H "Title: Mesh Health FAILED" \
                  -H "Priority: 5" \
                  -H "Tags: rotating_light" \
                  -d "$MSG"
                exit 1
              fi
      '';

      service-endpoints = pkgs.writeText "service-endpoints.yaml" ''
        schedule: "*/5 * * * *"
        env:
          - NTFY_URL: http://10.0.0.1:8090
          - AUTHELIA_BEARER_TOKEN: ''${AUTHELIA_BEARER_TOKEN}
        mailOn:
          failure: false
          success: false
        steps:
          - name: check-endpoints-and-notify
            command: |
              FAILED=""
              for endpoint in \
                "auth.diegonmarcos.com/api/health:Authelia 2FA" \
                "vault.diegonmarcos.com/:Vaultwarden" \
                "proxy.diegonmarcos.com/:Caddy Proxy" \
                "api.diegonmarcos.com/c3-api/health:C3 API" \
                "analytics.diegonmarcos.com/:Matomo" \
                "mail.diegonmarcos.com/:Mailu"; do
                url=''${endpoint%:*}
                svc=''${endpoint##*:}
                HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -m 5 "https://$url" 2>/dev/null || echo "000")
                if [ "$HTTP_CODE" -lt 200 ] || [ "$HTTP_CODE" -ge 400 ]; then
                  FAILED="''${FAILED}  - $svc (https://$url) -> HTTP $HTTP_CODE\n"
                fi
              done
              if [ -n "$FAILED" ]; then
                MSG=$(echo -e "DOWN endpoints:\n''${FAILED}\nAction:\n  curl -v https://<domain>\n  ssh gcp-proxy 'docker logs caddy --tail 20'\n\nDagu: http://10.0.0.3:8070")
                curl -s -X POST "$NTFY_URL/infra_endpoints" \
                  -H "Authorization: Bearer $AUTHELIA_BEARER_TOKEN" \
                  -H "Title: Service Endpoint DOWN" \
                  -H "Priority: 5" \
                  -H "Tags: rotating_light" \
                  -d "$MSG"
                exit 1
              fi
      '';

      dns-resolution = pkgs.writeText "dns-resolution.yaml" ''
        schedule: "0 8 * * *"
        env:
          - NTFY_URL: http://10.0.0.1:8090
          - AUTHELIA_BEARER_TOKEN: ''${AUTHELIA_BEARER_TOKEN}
        mailOn:
          failure: false
          success: false
        steps:
          - name: check-dns-and-notify
            command: |
              FAILED=""
              for domain in diegonmarcos.com auth.diegonmarcos.com vault.diegonmarcos.com api.diegonmarcos.com analytics.diegonmarcos.com mail.diegonmarcos.com; do
                RESULT=$(dig +short "$domain" @1.1.1.1 2>&1)
                if [ -z "$RESULT" ]; then
                  FAILED="''${FAILED}  - $domain -> NO RECORDS (Cloudflare 1.1.1.1)\n"
                fi
              done
              if [ -n "$FAILED" ]; then
                MSG=$(echo -e "DNS resolution failures:\n''${FAILED}\nAction:\n  dig <domain> @1.1.1.1\n  dig <domain> @8.8.8.8\n  Check Cloudflare DNS dashboard\n\nDagu: http://10.0.0.3:8070")
                curl -s -X POST "$NTFY_URL/infra_dns" \
                  -H "Authorization: Bearer $AUTHELIA_BEARER_TOKEN" \
                  -H "Title: DNS Resolution FAILED" \
                  -H "Priority: 5" \
                  -H "Tags: rotating_light" \
                  -d "$MSG"
                exit 1
              fi
      '';

      system-check = pkgs.writeText "system-check.yaml" ''
        schedule: "0 9 * * *"
        env:
          - NTFY_URL: http://10.0.0.1:8090
          - AUTHELIA_BEARER_TOKEN: ''${AUTHELIA_BEARER_TOKEN}
        mailOn:
          failure: false
          success: false
        steps:
          - name: check-resources-and-notify
            command: |
              SSH="${sshCmd}"
              ALERTS=""
              for vm_data in ${vmList}; do
                ip=''${vm_data%%:*}
                temp=''${vm_data#*:}
                name=''${temp%:*}
                user=''${temp#*:}
                DISK=$($SSH $user@$ip "df -h / | awk 'NR==2 {print substr(\$5,1,length(\$5)-1)}'" 2>/dev/null || echo "N/A")
                MEM=$($SSH $user@$ip "free | awk 'NR==2 {printf \"%.0f\", (\$3/\$2)*100}'" 2>/dev/null || echo "N/A")
                LOAD=$($SSH $user@$ip "cat /proc/loadavg | awk '{print \$1}'" 2>/dev/null || echo "N/A")
                if [ "$DISK" != "N/A" ] && [ "$DISK" -gt 80 ] 2>/dev/null || [ "$MEM" != "N/A" ] && [ "$MEM" -gt 90 ] 2>/dev/null; then
                  ALERTS="''${ALERTS}  - $name ($ip): disk=$DISK% mem=$MEM% load=$LOAD\n"
                fi
              done
              if [ -n "$ALERTS" ]; then
                MSG=$(echo -e "High resource usage:\n''${ALERTS}\nAction:\n  ssh <user>@<ip> 'df -h && free -h && top -bn1 | head -15'\n  ssh <user>@<ip> 'docker stats --no-stream'\n\nDagu: http://10.0.0.3:8070")
                curl -s -X POST "$NTFY_URL/infra_resources" \
                  -H "Authorization: Bearer $AUTHELIA_BEARER_TOKEN" \
                  -H "Title: System Resources Alert" \
                  -H "Priority: 4" \
                  -H "Tags: warning,chart_with_upwards_trend" \
                  -d "$MSG"
                exit 1
              fi
      '';

      docker-check = pkgs.writeText "docker-check.yaml" ''
        schedule: "0 10 * * *"
        env:
          - NTFY_URL: http://10.0.0.1:8090
          - AUTHELIA_BEARER_TOKEN: ''${AUTHELIA_BEARER_TOKEN}
        mailOn:
          failure: false
          success: false
        steps:
          - name: check-containers-and-notify
            command: |
              SSH="${sshCmd}"
              ALERTS=""
              for vm_data in ${vmList}; do
                ip=''${vm_data%%:*}
                temp=''${vm_data#*:}
                name=''${temp%:*}
                user=''${temp#*:}
                UNHEALTHY=$($SSH $user@$ip "docker ps --filter health=unhealthy --format '{{.Names}}'" 2>/dev/null)
                EXITED=$($SSH $user@$ip "docker ps -a --filter status=exited --filter 'exited!=0' --format '{{.Names}} (exit {{.Status}})'" 2>/dev/null)
                if [ -n "$UNHEALTHY" ]; then
                  ALERTS="''${ALERTS}  $name — UNHEALTHY:\n"
                  while IFS= read -r c; do
                    ALERTS="''${ALERTS}    - $c\n"
                  done <<< "$UNHEALTHY"
                fi
                if [ -n "$EXITED" ]; then
                  ALERTS="''${ALERTS}  $name — CRASHED:\n"
                  while IFS= read -r c; do
                    ALERTS="''${ALERTS}    - $c\n"
                  done <<< "$EXITED"
                fi
              done
              if [ -n "$ALERTS" ]; then
                MSG=$(echo -e "Container issues:\n''${ALERTS}\nAction:\n  ssh <user>@<ip> 'docker logs <container> --tail 30'\n  ssh <user>@<ip> 'docker restart <container>'\n\nDagu: http://10.0.0.3:8070")
                curl -s -X POST "$NTFY_URL/infra_containers" \
                  -H "Authorization: Bearer $AUTHELIA_BEARER_TOKEN" \
                  -H "Title: Container Health Issues" \
                  -H "Priority: 4" \
                  -H "Tags: whale,warning" \
                  -d "$MSG"
                exit 1
              fi
      '';

      # ═══════════════════════════════════════════════════════════════════
      # SECURITY
      # ═══════════════════════════════════════════════════════════════════

      security-audit = pkgs.writeText "security-audit.yaml" ''
        schedule: "0 12 * * *"
        env:
          - NTFY_URL: http://10.0.0.1:8090
          - AUTHELIA_BEARER_TOKEN: ''${AUTHELIA_BEARER_TOKEN}
        mailOn:
          failure: false
          success: false
        steps:
          - name: audit-and-notify
            command: |
              SSH="${sshCmd}"
              TODAY=$(date +"%b %e")
              ALERTS=""
              for vm_data in ${vmList}; do
                ip=''${vm_data%%:*}
                temp=''${vm_data#*:}
                name=''${temp%:*}
                user=''${temp#*:}
                FAIL_COUNT=$($SSH $user@$ip "grep 'Failed password' /var/log/auth.log 2>/dev/null | grep -c '$TODAY' || echo 0" 2>/dev/null || echo 0)
                ROOT_LOGIN=$($SSH $user@$ip "grep 'root.*session opened' /var/log/auth.log 2>/dev/null | grep -c '$TODAY' || echo 0" 2>/dev/null || echo 0)
                TOP_IPS=$($SSH $user@$ip "grep 'Failed password' /var/log/auth.log 2>/dev/null | grep '$TODAY' | grep -oP 'from \K[0-9.]+' | sort | uniq -c | sort -rn | head -3 | awk '{print \"    \" \$2 \" (\" \$1 \" attempts)\"}'" 2>/dev/null || echo "")
                if [ "$FAIL_COUNT" -gt 10 ] 2>/dev/null || [ "$ROOT_LOGIN" -gt 0 ] 2>/dev/null; then
                  ALERTS="''${ALERTS}  $name ($ip):\n    Failed SSH: $FAIL_COUNT\n    Root logins: $ROOT_LOGIN\n"
                  if [ -n "$TOP_IPS" ]; then
                    ALERTS="''${ALERTS}    Top attacker IPs:\n$TOP_IPS\n"
                  fi
                fi
              done
              if [ -n "$ALERTS" ]; then
                MSG=$(echo -e "Suspicious auth activity:\n''${ALERTS}\nAction:\n  ssh <user>@<ip> 'grep \"Failed password\" /var/log/auth.log | tail -20'\n  ssh <user>@<ip> 'last -20'\n  ssh <user>@<ip> 'fail2ban-client status sshd'\n\nDagu: http://10.0.0.3:8070")
                curl -s -X POST "$NTFY_URL/security_audit" \
                  -H "Authorization: Bearer $AUTHELIA_BEARER_TOKEN" \
                  -H "Title: Security Audit Alert" \
                  -H "Priority: 5" \
                  -H "Tags: lock,rotating_light" \
                  -d "$MSG"
                exit 1
              fi
      '';

      tls-expiry = pkgs.writeText "tls-expiry.yaml" ''
        schedule: "0 8 * * *"
        env:
          - NTFY_URL: http://10.0.0.1:8090
          - AUTHELIA_BEARER_TOKEN: ''${AUTHELIA_BEARER_TOKEN}
        mailOn:
          failure: false
          success: false
        steps:
          - name: check-tls-and-notify
            command: |
              ALERTS=""
              for domain in auth.diegonmarcos.com vault.diegonmarcos.com proxy.diegonmarcos.com api.diegonmarcos.com analytics.diegonmarcos.com mail.diegonmarcos.com sync.diegonmarcos.com; do
                EXPIRY=$(echo | openssl s_client -servername $domain -connect $domain:443 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
                if [ -n "$EXPIRY" ]; then
                  EXPIRY_SEC=$(date -d "$EXPIRY" +%s 2>/dev/null || echo 0)
                  NOW_SEC=$(date +%s)
                  DAYS_LEFT=$(( (EXPIRY_SEC - NOW_SEC) / 86400 ))
                  if [ $DAYS_LEFT -lt 14 ]; then
                    ALERTS="''${ALERTS}  - $domain: expires in $DAYS_LEFT days ($EXPIRY)\n"
                  fi
                else
                  ALERTS="''${ALERTS}  - $domain: COULD NOT READ CERTIFICATE\n"
                fi
              done
              if [ -n "$ALERTS" ]; then
                MSG=$(echo -e "TLS certificates expiring soon:\n''${ALERTS}\nAction:\n  openssl s_client -connect <domain>:443 </dev/null 2>/dev/null | openssl x509 -noout -dates\n  ssh gcp-proxy 'docker exec caddy caddy reload'\n  Check Let's Encrypt / Caddy auto-renewal logs\n\nDagu: http://10.0.0.3:8070")
                curl -s -X POST "$NTFY_URL/security_tls" \
                  -H "Authorization: Bearer $AUTHELIA_BEARER_TOKEN" \
                  -H "Title: TLS Certificate Expiring" \
                  -H "Priority: 4" \
                  -H "Tags: warning,lock" \
                  -d "$MSG"
                exit 1
              fi
      '';

      auth-events = pkgs.writeText "auth-events.yaml" ''
        schedule: "0 9 * * *"
        env:
          - NTFY_URL: http://10.0.0.1:8090
          - AUTHELIA_BEARER_TOKEN: ''${AUTHELIA_BEARER_TOKEN}
        mailOn:
          failure: false
          success: false
        steps:
          - name: collect-all-connections
            command: |
              SSH="${sshCmd}"
              TODAY=$(date +"%b %e")
              REPORT=""
              for vm_data in ${vmList}; do
                ip=''${vm_data%%:*}
                temp=''${vm_data#*:}
                name=''${temp%:*}
                user=''${temp#*:}
                ACCEPTED=$($SSH $user@$ip "grep 'Accepted' /var/log/auth.log 2>/dev/null | grep -c '$TODAY' || echo 0" 2>/dev/null || echo "N/A")
                FAILED_SSH=$($SSH $user@$ip "grep 'Failed password' /var/log/auth.log 2>/dev/null | grep -c '$TODAY' || echo 0" 2>/dev/null || echo "N/A")
                SUDO_EVENTS=$($SSH $user@$ip "grep 'sudo:' /var/log/auth.log 2>/dev/null | grep -c '$TODAY' || echo 0" 2>/dev/null || echo "N/A")
                ACTIVE_CONN=$($SSH $user@$ip "ss -tun state established 2>/dev/null | tail -n +2 | wc -l" 2>/dev/null || echo "N/A")
                DOCKER_CONN=$($SSH $user@$ip "ss -tlnp 2>/dev/null | grep -c docker || echo 0" 2>/dev/null || echo "N/A")
                RECENT_LOGINS=$($SSH $user@$ip "grep 'Accepted' /var/log/auth.log 2>/dev/null | grep '$TODAY' | tail -3 | awk '{print \"    \" \$0}'" 2>/dev/null || echo "    (none)")
                REPORT="''${REPORT}$name ($ip):\n  SSH accepted: $ACCEPTED | failed: $FAILED_SSH\n  Sudo events: $SUDO_EVENTS\n  Active TCP: $ACTIVE_CONN | Docker listeners: $DOCKER_CONN\n  Recent logins:\n$RECENT_LOGINS\n\n"
              done
              MSG=$(echo -e "Daily Connection Report ($TODAY):\n\n''${REPORT}Inspect:\n  ssh <user>@<ip> 'journalctl -u ssh --since yesterday'\n  ssh <user>@<ip> 'last -20'\n  ssh <user>@<ip> 'ss -tunap'\n\nDagu: http://10.0.0.3:8070")
              curl -s -X POST "$NTFY_URL/security_connections" \
                -H "Authorization: Bearer $AUTHELIA_BEARER_TOKEN" \
                -H "Title: Daily Connection Report" \
                -H "Priority: 2" \
                -H "Tags: key,shield" \
                -d "$MSG"
      '';

      sauron-integrity = pkgs.writeText "sauron-integrity.yaml" ''
        schedule: "0 3 * * 0"
        env:
          - NTFY_URL: http://10.0.0.1:8090
          - AUTHELIA_BEARER_TOKEN: ''${AUTHELIA_BEARER_TOKEN}
        mailOn:
          failure: false
          success: false
        steps:
          - name: verify-scanners-and-notify
            command: |
              SSH="${sshCmd}"
              RUNNING=0
              TOTAL=0
              MISSING=""
              for vm_data in ${vmList}; do
                ip=''${vm_data%%:*}
                temp=''${vm_data#*:}
                name=''${temp%:*}
                user=''${temp#*:}
                TOTAL=$((TOTAL + 1))
                if $SSH $user@$ip "docker ps --format '{{.Names}}' | grep -q sauron" 2>/dev/null; then
                  RUNNING=$((RUNNING + 1))
                else
                  MISSING="''${MISSING}  - $name ($ip): sauron-lite NOT running\n"
                fi
              done
              if [ $RUNNING -lt $TOTAL ]; then
                MSG=$(echo -e "YARA scanner status: $RUNNING/$TOTAL running\n\nMissing:\n''${MISSING}\nAction:\n  ssh <user>@<ip> 'docker ps -a | grep sauron'\n  ssh <user>@<ip> 'cd /opt/containers/sauron && docker compose up -d'\n\nDagu: http://10.0.0.3:8070")
                curl -s -X POST "$NTFY_URL/security_yara" \
                  -H "Authorization: Bearer $AUTHELIA_BEARER_TOKEN" \
                  -H "Title: Sauron Scanner(s) Down" \
                  -H "Priority: 4" \
                  -H "Tags: warning,eye" \
                  -d "$MSG"
                exit 1
              fi
      '';

      # ═══════════════════════════════════════════════════════════════════
      # OPERATIONS
      # ═══════════════════════════════════════════════════════════════════

      ops-summary = pkgs.writeText "ops-summary.yaml" ''
        schedule: "0 18 * * *"
        env:
          - NTFY_URL: http://10.0.0.1:8090
          - AUTHELIA_BEARER_TOKEN: ''${AUTHELIA_BEARER_TOKEN}
        mailOn:
          failure: false
          success: false
        steps:
          - name: gather-and-report
            command: |
              SSH="${sshCmd}"
              REPORT=""
              for vm_data in ${vmList}; do
                ip=''${vm_data%%:*}
                temp=''${vm_data#*:}
                name=''${temp%:*}
                user=''${temp#*:}
                UPTIME=$($SSH $user@$ip "uptime -p" 2>/dev/null || echo "N/A")
                CONTAINERS=$($SSH $user@$ip "docker ps -q 2>/dev/null | wc -l" 2>/dev/null || echo "N/A")
                DISK=$($SSH $user@$ip "df -h / | awk 'NR==2 {print \$5}'" 2>/dev/null || echo "N/A")
                MEM=$($SSH $user@$ip "free | awk 'NR==2 {printf \"%.0f%%\", (\$3/\$2)*100}'" 2>/dev/null || echo "N/A")
                REPORT="''${REPORT}$name ($ip):\n  Uptime: $UPTIME\n  Containers: $CONTAINERS | Disk: $DISK | Mem: $MEM\n\n"
              done
              MSG=$(echo -e "Daily Ops Summary:\n\n''${REPORT}Dagu: http://10.0.0.3:8070")
              curl -s -X POST "$NTFY_URL/ops_summary" \
                -H "Authorization: Bearer $AUTHELIA_BEARER_TOKEN" \
                -H "Title: Daily Ops Summary" \
                -H "Priority: 2" \
                -H "Tags: chart_with_upwards_trend" \
                -d "$MSG"
      '';

      backup-check = pkgs.writeText "backup-check.yaml" ''
        schedule: "0 11 * * *"
        env:
          - NTFY_URL: http://10.0.0.1:8090
          - AUTHELIA_BEARER_TOKEN: ''${AUTHELIA_BEARER_TOKEN}
        mailOn:
          failure: false
          success: false
        steps:
          - name: check-backups-and-notify
            command: |
              SSH="${sshCmd}"
              ALERTS=""
              for vm_data in ${vmList}; do
                ip=''${vm_data%%:*}
                temp=''${vm_data#*:}
                name=''${temp%:*}
                user=''${temp#*:}
                RECENT=$($SSH $user@$ip "find /var/backups -name '*.sql.gz' -o -name '*.tar.gz' -o -name '*.bak' 2>/dev/null | head -5 | while read f; do stat --format='%n (%s bytes, %y)' \"\$f\" 2>/dev/null; done | head -5" 2>/dev/null)
                COUNT=$($SSH $user@$ip "find /var/backups -name '*.sql.gz' -mtime -1 2>/dev/null | wc -l" 2>/dev/null || echo 0)
                if [ "$COUNT" -eq 0 ] 2>/dev/null; then
                  ALERTS="''${ALERTS}  $name ($ip): NO backups in last 24h\n"
                  if [ -n "$RECENT" ]; then
                    ALERTS="''${ALERTS}    Latest files:\n"
                    while IFS= read -r f; do
                      ALERTS="''${ALERTS}      $f\n"
                    done <<< "$RECENT"
                  fi
                fi
              done
              if [ -n "$ALERTS" ]; then
                MSG=$(echo -e "Backup freshness issues:\n''${ALERTS}\nAction:\n  ssh <user>@<ip> 'ls -lt /var/backups/ | head -10'\n  Check backup cron: ssh <user>@<ip> 'crontab -l'\n\nDagu: http://10.0.0.3:8070")
                curl -s -X POST "$NTFY_URL/ops_backups" \
                  -H "Authorization: Bearer $AUTHELIA_BEARER_TOKEN" \
                  -H "Title: Backup Alert" \
                  -H "Priority: 4" \
                  -H "Tags: floppy_disk,warning" \
                  -d "$MSG"
                exit 1
              fi
      '';

      cron-status = pkgs.writeText "cron-status.yaml" ''
        schedule: "0 7 * * *"
        env:
          - NTFY_URL: http://10.0.0.1:8090
          - AUTHELIA_BEARER_TOKEN: ''${AUTHELIA_BEARER_TOKEN}
        mailOn:
          failure: false
          success: false
        steps:
          - name: check-timers-and-notify
            command: |
              SSH="${sshCmd}"
              ALERTS=""
              for vm_data in ${vmList}; do
                ip=''${vm_data%%:*}
                temp=''${vm_data#*:}
                name=''${temp%:*}
                user=''${temp#*:}
                FAILED_TIMERS=$($SSH $user@$ip "systemctl list-timers --failed --no-legend 2>/dev/null" 2>/dev/null || echo "")
                if [ -n "$FAILED_TIMERS" ]; then
                  ALERTS="''${ALERTS}  $name ($ip):\n"
                  while IFS= read -r t; do
                    ALERTS="''${ALERTS}    - $t\n"
                  done <<< "$FAILED_TIMERS"
                fi
              done
              if [ -n "$ALERTS" ]; then
                MSG=$(echo -e "Failed systemd timers:\n''${ALERTS}\nAction:\n  ssh <user>@<ip> 'systemctl list-timers --failed'\n  ssh <user>@<ip> 'journalctl -u <timer-name> --since yesterday'\n\nDagu: http://10.0.0.3:8070")
                curl -s -X POST "$NTFY_URL/ops_cron" \
                  -H "Authorization: Bearer $AUTHELIA_BEARER_TOKEN" \
                  -H "Title: Cron/Timer Failures" \
                  -H "Priority: 4" \
                  -H "Tags: warning,clock1" \
                  -d "$MSG"
                exit 1
              fi
      '';

      deploy-digest = pkgs.writeText "deploy-digest.yaml" ''
        schedule: "0 19 * * *"
        env:
          - NTFY_URL: http://10.0.0.1:8090
          - AUTHELIA_BEARER_TOKEN: ''${AUTHELIA_BEARER_TOKEN}
        mailOn:
          failure: false
          success: false
        steps:
          - name: collect-deploys-and-notify
            command: |
              SSH="${sshCmd}"
              REPORT=""
              TOTAL=0
              for vm_data in ${vmList}; do
                ip=''${vm_data%%:*}
                temp=''${vm_data#*:}
                name=''${temp%:*}
                user=''${temp#*:}
                RESTARTS=$($SSH $user@$ip "journalctl -u docker --since '24 hours ago' 2>/dev/null | grep 'Container.*Started' | awk '{print \$NF}' | sort | uniq -c | sort -rn | head -5 | awk '{print \"    \" \$2 \" (\" \$1 \"x)\"}'" 2>/dev/null || echo "")
                COUNT_RAW=$($SSH $user@$ip "journalctl -u docker --since '24 hours ago' 2>/dev/null | grep -c 'Container.*Started' || echo 0" 2>/dev/null || echo 0)
                COUNT=$(echo "$COUNT_RAW" | tr -dc '0-9')
                COUNT=''${COUNT:-0}
                TOTAL=$((TOTAL + COUNT))
                if [ "''${COUNT:-0}" -gt 0 ]; then
                  REPORT="''${REPORT}$name ($ip): $COUNT restarts\n"
                  if [ -n "$RESTARTS" ]; then
                    REPORT="''${REPORT}$RESTARTS\n"
                  fi
                  REPORT="''${REPORT}\n"
                fi
              done
              MSG=$(echo -e "Deploy Digest (24h): $TOTAL total restarts\n\n''${REPORT}Action:\n  ssh <user>@<ip> 'docker ps --format \"table {{.Names}}\t{{.Status}}\"'\n\nDagu: http://10.0.0.3:8070")
              curl -s -X POST "$NTFY_URL/cicd_deploy-digest" \
                -H "Authorization: Bearer $AUTHELIA_BEARER_TOKEN" \
                -H "Title: Daily Deploy Digest ($TOTAL restarts)" \
                -H "Priority: 2" \
                -H "Tags: rocket" \
                -d "$MSG"
      '';

      capacity-review = pkgs.writeText "capacity-review.yaml" ''
        schedule: "0 9 * * 1"
        env:
          - NTFY_URL: http://10.0.0.1:8090
          - AUTHELIA_BEARER_TOKEN: ''${AUTHELIA_BEARER_TOKEN}
        mailOn:
          failure: false
          success: false
        steps:
          - name: review-capacity-and-notify
            command: |
              SSH="${sshCmd}"
              REPORT=""
              for vm_data in ${vmList}; do
                ip=''${vm_data%%:*}
                temp=''${vm_data#*:}
                name=''${temp%:*}
                user=''${temp#*:}
                DISK_DETAIL=$($SSH $user@$ip "df -h / | awk 'NR==2 {print \"Used: \" \$3 \"/\" \$2 \" (\" \$5 \")\"}'" 2>/dev/null || echo "N/A")
                DOCKER_IMAGES=$($SSH $user@$ip "docker system df --format '{{.Type}}\t{{.Size}}' 2>/dev/null | head -3 | awk '{print \"    \" \$0}'" 2>/dev/null || echo "    N/A")
                LARGEST=$($SSH $user@$ip "du -sh /opt/containers/*/data 2>/dev/null | sort -rh | head -3 | awk '{print \"    \" \$0}'" 2>/dev/null || echo "    N/A")
                REPORT="''${REPORT}$name ($ip):\n  Disk: $DISK_DETAIL\n  Docker storage:\n$DOCKER_IMAGES\n  Largest data dirs:\n$LARGEST\n\n"
              done
              MSG=$(echo -e "Weekly Capacity Review:\n\n''${REPORT}Action:\n  ssh <user>@<ip> 'docker system prune -f'\n  ssh <user>@<ip> 'du -sh /opt/containers/*/data | sort -rh'\n\nDagu: http://10.0.0.3:8070")
              curl -s -X POST "$NTFY_URL/ops_summary" \
                -H "Authorization: Bearer $AUTHELIA_BEARER_TOKEN" \
                -H "Title: Weekly Capacity Review" \
                -H "Priority: 2" \
                -H "Tags: bar_chart" \
                -d "$MSG"
      '';

      # ═══════════════════════════════════════════════════════════════════
      # DAILY EMAIL REPORT
      # ═══════════════════════════════════════════════════════════════════

      daily-report-script = pkgs.writeText "daily-report.sh" ''
        #!/bin/bash
        SSH="${sshCmd}"
        DATE=$(date '+%Y-%m-%d')
        TIME=$(date '+%H:%M %Z')

        # ── Color constants ──
        C_OK="#00d68f"; C_WARN="#ffaa00"; C_CRIT="#ff3d71"; C_DIM="#8899aa"
        BG_BODY="#1a1a2e"; BG_CARD="#16213e"; BG_HEAD="#0f3460"; BG_BAR="#2a2a4e"
        C_TEXT="#e0e0e0"

        # ── Fleet data arrays ──
        declare -a VM_NAMES VM_IPS VM_USERS
        declare -a VM_UPTIMES VM_LOADS VM_DISKS VM_DISK_PCTS VM_MEMS VM_MEM_PCTS
        declare -a VM_CONTAINERS VM_UNHEALTHY VM_EXITED
        declare -a VM_SSH_ACCEPTS VM_SSH_FAILS VM_SUDOS VM_TOP_FAILS
        declare -a VM_RESTARTS VM_BACKUPS VM_FAILED_UNITS VM_STATUS
        declare -a VM_WG_PEERS VM_DOCKER_DFS VM_CONTAINER_STATS
        declare -a VM_CTR_RUNNING VM_CTR_TOTAL VM_CTR_UNHEALTHY

        # ── Helper: parse section between markers from $RAW ──
        section() { echo "$RAW" | awk "/===$1===/,/===$2===/" | grep -v '===' || true; }

        # ── Helper: color for percentage ──
        pct_color() {
          local p=$1
          if [ "$p" -gt 90 ] 2>/dev/null; then echo "$C_CRIT"
          elif [ "$p" -gt 75 ] 2>/dev/null; then echo "$C_WARN"
          else echo "$C_OK"; fi
        }

        # ── Helper: HTML progress bar ──
        progress_bar() {
          local pct=$1 color
          color=$(pct_color "$pct")
          echo "<div style=\"display:inline-block;background:$BG_BAR;border-radius:4px;height:14px;width:80px;vertical-align:middle;\"><div style=\"background:$color;border-radius:4px;height:14px;width:''${pct}%;\"></div></div> <span style=\"color:$color;font-size:12px;\">''${pct}%</span>"
        }

        # ── Helper: status badge ──
        badge_html() {
          local status=$1 color label
          case "$status" in
            healthy)  color=$C_OK;   label="HEALTHY" ;;
            warning)  color=$C_WARN; label="WARNING" ;;
            critical) color=$C_CRIT; label="CRITICAL" ;;
            *)        color=$C_DIM;  label="UNKNOWN" ;;
          esac
          echo "<span style=\"display:inline-block;padding:2px 8px;border-radius:4px;font-size:11px;font-weight:bold;background:$color;color:$BG_BODY;\">$label</span>"
        }

        # ══════════════════════════════════════════════════════════════════════
        # COLLECT DATA FROM EACH VM
        # ══════════════════════════════════════════════════════════════════════
        i=0
        for vm_data in ${vmList}; do
          ip=''${vm_data%%:*}
          temp=''${vm_data#*:}
          name=''${temp%:*}
          user=''${temp#*:}
          VM_NAMES[$i]=$name
          VM_IPS[$i]=$ip
          VM_USERS[$i]=$user

          RAW=$($SSH $user@$ip 'bash -s' <<'EOSSH' 2>/dev/null || echo "===SSH_FAILED==="
        echo "===UPTIME==="
        uptime -p 2>/dev/null || echo "N/A"
        echo "===LOAD==="
        cat /proc/loadavg 2>/dev/null | awk '{print $1, $2, $3}' || echo "N/A"
        echo "===DISK==="
        df -h / 2>/dev/null | awk 'NR==2 {print $3 "/" $2 " (" $5 ")"}' || echo "N/A"
        echo "===DISK_PCT==="
        df / 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5}' || echo "0"
        echo "===MEM==="
        free -h 2>/dev/null | awk '/Mem:/ {print $3 "/" $2}' || echo "N/A"
        echo "===MEM_PCT==="
        free 2>/dev/null | awk '/Mem:/ {printf "%.0f", ($3/$2)*100}' || echo "0"
        echo "===CONTAINERS==="
        docker ps -a --format '{{.Names}}|{{.Status}}|{{.State}}' 2>/dev/null | head -40 || echo ""
        echo "===UNHEALTHY==="
        docker ps --filter health=unhealthy --format '{{.Names}}' 2>/dev/null
        echo "===EXITED==="
        docker ps -a --filter status=exited --format '{{.Names}}' 2>/dev/null | head -10
        echo "===CONTAINER_COUNTS==="
        R=$(docker ps -q 2>/dev/null | wc -l)
        T=$(docker ps -aq 2>/dev/null | wc -l)
        U=$(docker ps --filter health=unhealthy -q 2>/dev/null | wc -l)
        echo "$R|$T|$U"
        echo "===CONTAINER_STATS==="
        docker stats --no-stream --format '{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}|{{.MemPerc}}' 2>/dev/null | sort -t'|' -k2 -rn | head -10 || echo ""
        echo "===WG_PEERS==="
        sudo wg show wg0 latest-handshakes 2>/dev/null || echo ""
        echo "===DOCKER_DF==="
        docker system df --format '{{.Type}}|{{.TotalCount}}|{{.Size}}|{{.Reclaimable}}' 2>/dev/null || echo ""
        echo "===SSH_ACCEPT==="
        journalctl -u ssh --since '24 hours ago' 2>/dev/null | grep -c 'Accepted' || echo 0
        echo "===SSH_FAIL==="
        journalctl -u ssh --since '24 hours ago' 2>/dev/null | grep -c 'Failed' || echo 0
        echo "===SUDO==="
        journalctl --since '24 hours ago' 2>/dev/null | grep -c 'sudo:' || echo 0
        echo "===TOP_FAIL_IPS==="
        journalctl -u ssh --since '24 hours ago' 2>/dev/null | grep 'Failed' | awk '{for(i=1;i<=NF;i++) if($i ~ /[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/) print $i}' | sort | uniq -c | sort -rn | head -5 | awk '{print $2 "|" $1}'
        echo "===RESTARTS==="
        journalctl -u docker --since '24 hours ago' 2>/dev/null | grep 'Container.*Started' | awk '{print $NF}' | sort | uniq -c | sort -rn | head -5 | awk '{print $2 "|" $1}'
        echo "===BACKUPS==="
        ls -lht /opt/backups/ 2>/dev/null | awk 'NR>1{print $NF "|" $5 "|" $6 " " $7 " " $8}' || echo ""
        echo "===FAILED_UNITS==="
        systemctl --failed --no-legend 2>/dev/null | head -5 | awk '{print $1}'
        echo "===END==="
        EOSSH
        )

          # ── Parse sections into arrays ──
          VM_UPTIMES[$i]=$(section UPTIME LOAD | tr -d '\n' | sed 's/^ *//'); : "''${VM_UPTIMES[$i]:=N/A}"
          VM_LOADS[$i]=$(section LOAD DISK | tr -d '\n' | sed 's/^ *//'); : "''${VM_LOADS[$i]:=N/A}"
          VM_DISKS[$i]=$(section DISK DISK_PCT | tr -d '\n' | sed 's/^ *//'); : "''${VM_DISKS[$i]:=N/A}"
          VM_DISK_PCTS[$i]=$(section DISK_PCT MEM | tr -d '\n' | sed 's/[^0-9]//g'); : "''${VM_DISK_PCTS[$i]:=0}"
          VM_MEMS[$i]=$(section MEM MEM_PCT | tr -d '\n' | sed 's/^ *//'); : "''${VM_MEMS[$i]:=N/A}"
          VM_MEM_PCTS[$i]=$(section MEM_PCT CONTAINERS | tr -d '\n' | sed 's/[^0-9]//g'); : "''${VM_MEM_PCTS[$i]:=0}"
          VM_CONTAINERS[$i]=$(section CONTAINERS UNHEALTHY)
          VM_UNHEALTHY[$i]=$(section UNHEALTHY EXITED)
          VM_EXITED[$i]=$(section EXITED CONTAINER_COUNTS)
          counts=$(section CONTAINER_COUNTS CONTAINER_STATS | head -1)
          VM_CTR_RUNNING[$i]=$(echo "$counts" | cut -d'|' -f1 | tr -d ' '); : "''${VM_CTR_RUNNING[$i]:=0}"
          VM_CTR_TOTAL[$i]=$(echo "$counts" | cut -d'|' -f2 | tr -d ' '); : "''${VM_CTR_TOTAL[$i]:=0}"
          VM_CTR_UNHEALTHY[$i]=$(echo "$counts" | cut -d'|' -f3 | tr -d ' '); : "''${VM_CTR_UNHEALTHY[$i]:=0}"
          VM_CONTAINER_STATS[$i]=$(section CONTAINER_STATS WG_PEERS)
          VM_WG_PEERS[$i]=$(section WG_PEERS DOCKER_DF)
          VM_DOCKER_DFS[$i]=$(section DOCKER_DF SSH_ACCEPT)
          VM_SSH_ACCEPTS[$i]=$(section SSH_ACCEPT SSH_FAIL | tr -d '\n' | tr -d ' '); : "''${VM_SSH_ACCEPTS[$i]:=0}"
          VM_SSH_FAILS[$i]=$(section SSH_FAIL SUDO | tr -d '\n' | tr -d ' '); : "''${VM_SSH_FAILS[$i]:=0}"
          VM_SUDOS[$i]=$(section SUDO TOP_FAIL_IPS | tr -d '\n' | tr -d ' '); : "''${VM_SUDOS[$i]:=0}"
          VM_TOP_FAILS[$i]=$(section TOP_FAIL_IPS RESTARTS)
          VM_RESTARTS[$i]=$(section RESTARTS BACKUPS)
          VM_BACKUPS[$i]=$(section BACKUPS FAILED_UNITS)
          VM_FAILED_UNITS[$i]=$(section FAILED_UNITS END)

          # ── Derive health status ──
          dp=''${VM_DISK_PCTS[$i]}; mp=''${VM_MEM_PCTS[$i]}
          if echo "$RAW" | grep -q '===SSH_FAILED==='; then
            VM_STATUS[$i]="critical"
          elif [ "$dp" -gt 90 ] 2>/dev/null || [ "$mp" -gt 90 ] 2>/dev/null || [ "''${VM_CTR_UNHEALTHY[$i]}" -gt 0 ] 2>/dev/null; then
            VM_STATUS[$i]="critical"
          elif [ "$dp" -gt 75 ] 2>/dev/null || [ "$mp" -gt 75 ] 2>/dev/null; then
            VM_STATUS[$i]="warning"
          else
            VM_STATUS[$i]="healthy"
          fi
          i=$((i+1))
        done
        VM_COUNT=$i

        # ── Fleet totals ──
        FLEET_RUNNING=0; FLEET_TOTAL=0; FLEET_UNHEALTHY=0
        for ((j=0; j<VM_COUNT; j++)); do
          FLEET_RUNNING=$((FLEET_RUNNING + ''${VM_CTR_RUNNING[$j]}))
          FLEET_TOTAL=$((FLEET_TOTAL + ''${VM_CTR_TOTAL[$j]}))
          FLEET_UNHEALTHY=$((FLEET_UNHEALTHY + ''${VM_CTR_UNHEALTHY[$j]}))
        done

        # ══════════════════════════════════════════════════════════════════════
        # BUILD HTML EMAIL
        # ══════════════════════════════════════════════════════════════════════
        F=$(mktemp)

        # ── Email headers ──
        cat > "$F" <<EOHEADERS
        From: no-reply@diegonmarcos.com
        To: me@diegonmarcos.com
        Subject: C3 Daily Ops Report - $DATE
        MIME-Version: 1.0
        Content-Type: text/html; charset=UTF-8
        EOHEADERS

        # ── HTML start + styles ──
        cat >> "$F" <<'EOSTYLE'

        <!DOCTYPE html>
        <html><head><meta charset="UTF-8"><style>
        body{margin:0;padding:0;background:#1a1a2e}
        td,th{font-family:'Courier New',Consolas,monospace}
        </style></head>
        <body style="margin:0;padding:0;background:#1a1a2e;">
        <center>
        <table width="100%" cellpadding="0" cellspacing="0" style="background:#1a1a2e;"><tr><td align="center">
        <table width="700" cellpadding="0" cellspacing="0" style="max-width:700px;width:100%;">
        EOSTYLE

        # ── HEADER BANNER ──
        cat >> "$F" <<EOHEAD
        <tr><td style="background:#0f3460;padding:20px 24px;text-align:center;border-radius:8px 8px 0 0;">
        <h1 style="margin:0;font-size:20px;color:#e0e0e0;font-family:'Courier New',monospace;letter-spacing:1px;">C3 Daily Ops Report</h1>
        <p style="margin:4px 0 0;color:#8899aa;font-size:12px;font-family:'Courier New',monospace;">$DATE &mdash; Generated at $TIME</p>
        </td></tr>
        EOHEAD

        # ══════════════════════════════════════════════════════════════════════
        # FLEET DASHBOARD
        # ══════════════════════════════════════════════════════════════════════
        cat >> "$F" <<'EODASH1'
        <tr><td style="padding:8px;">
        <table width="100%" cellpadding="0" cellspacing="0" style="background:#16213e;border-radius:6px;">
        <tr><td colspan="7" style="padding:12px 16px;background:#0f3460;border-radius:6px 6px 0 0;font-size:14px;font-weight:bold;color:#e0e0e0;font-family:'Courier New',monospace;">Fleet Dashboard</td></tr>
        <tr>
        <th style="text-align:left;color:#8899aa;font-size:11px;padding:8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">VM</th>
        <th style="text-align:left;color:#8899aa;font-size:11px;padding:8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">Status</th>
        <th style="text-align:left;color:#8899aa;font-size:11px;padding:8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">Uptime</th>
        <th style="text-align:left;color:#8899aa;font-size:11px;padding:8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">Load</th>
        <th style="text-align:left;color:#8899aa;font-size:11px;padding:8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">Mem</th>
        <th style="text-align:left;color:#8899aa;font-size:11px;padding:8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">Disk</th>
        <th style="text-align:left;color:#8899aa;font-size:11px;padding:8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">Ctrs</th>
        </tr>
        EODASH1

        for ((j=0; j<VM_COUNT; j++)); do
          n=''${VM_NAMES[$j]}; s=''${VM_STATUS[$j]}
          badge=$(badge_html "$s")
          up=''${VM_UPTIMES[$j]}
          ld=$(echo "''${VM_LOADS[$j]}" | awk '{print $1}')
          mp=''${VM_MEM_PCTS[$j]}; dp=''${VM_DISK_PCTS[$j]}
          mbar=$(progress_bar "$mp"); dbar=$(progress_bar "$dp")
          run=''${VM_CTR_RUNNING[$j]}; tot=''${VM_CTR_TOTAL[$j]}
          cat >> "$F" <<EOROW
        <tr>
        <td style="padding:6px 8px;color:#e0e0e0;font-size:12px;font-weight:bold;border-bottom:1px solid rgba(15,52,96,0.5);font-family:'Courier New',monospace;">$n</td>
        <td style="padding:6px 8px;border-bottom:1px solid rgba(15,52,96,0.5);">$badge</td>
        <td style="padding:6px 8px;color:#8899aa;font-size:11px;border-bottom:1px solid rgba(15,52,96,0.5);font-family:'Courier New',monospace;">$up</td>
        <td style="padding:6px 8px;color:#e0e0e0;font-size:12px;border-bottom:1px solid rgba(15,52,96,0.5);font-family:'Courier New',monospace;">$ld</td>
        <td style="padding:6px 8px;border-bottom:1px solid rgba(15,52,96,0.5);">$mbar</td>
        <td style="padding:6px 8px;border-bottom:1px solid rgba(15,52,96,0.5);">$dbar</td>
        <td style="padding:6px 8px;color:#e0e0e0;font-size:12px;border-bottom:1px solid rgba(15,52,96,0.5);font-family:'Courier New',monospace;">$run/$tot</td>
        </tr>
        EOROW
        done

        cat >> "$F" <<'EODASH2'
        </table>
        </td></tr>
        EODASH2

        # ══════════════════════════════════════════════════════════════════════
        # 1. OPERATIONS — Fleet Health
        # ══════════════════════════════════════════════════════════════════════
        cat >> "$F" <<'EOOPS1'
        <tr><td style="padding:8px;">
        <table width="100%" cellpadding="0" cellspacing="0" style="background:#16213e;border-radius:6px;">
        <tr><td style="padding:12px 16px;background:#0f3460;border-radius:6px 6px 0 0;font-size:14px;font-weight:bold;color:#e0e0e0;font-family:'Courier New',monospace;">1. Operations &mdash; Fleet Health</td></tr>
        <tr><td style="padding:12px 16px;">
        EOOPS1

        for ((j=0; j<VM_COUNT; j++)); do
          n=''${VM_NAMES[$j]}; up=''${VM_UPTIMES[$j]}; ld=''${VM_LOADS[$j]}
          dk=''${VM_DISKS[$j]}; dp=''${VM_DISK_PCTS[$j]}
          mm=''${VM_MEMS[$j]}; mp=''${VM_MEM_PCTS[$j]}
          mbar=$(progress_bar "$mp"); dbar=$(progress_bar "$dp")
          cat >> "$F" <<EOOPSVM
        <table width="100%" cellpadding="0" cellspacing="0" style="margin-bottom:12px;">
        <tr><td colspan="2" style="padding:4px 8px;font-weight:bold;color:#e0e0e0;font-size:13px;font-family:'Courier New',monospace;">$n</td></tr>
        <tr><td style="padding:3px 8px;color:#8899aa;width:80px;font-size:12px;font-family:'Courier New',monospace;">Uptime</td><td style="padding:3px 8px;color:#e0e0e0;font-size:12px;font-family:'Courier New',monospace;">$up</td></tr>
        <tr><td style="padding:3px 8px;color:#8899aa;font-size:12px;font-family:'Courier New',monospace;">Load</td><td style="padding:3px 8px;color:#e0e0e0;font-size:12px;font-family:'Courier New',monospace;">$ld</td></tr>
        <tr><td style="padding:3px 8px;color:#8899aa;font-size:12px;font-family:'Courier New',monospace;">Disk</td><td style="padding:3px 8px;color:#e0e0e0;font-size:12px;font-family:'Courier New',monospace;">$dk &nbsp; $dbar</td></tr>
        <tr><td style="padding:3px 8px;color:#8899aa;font-size:12px;font-family:'Courier New',monospace;">Memory</td><td style="padding:3px 8px;color:#e0e0e0;font-size:12px;font-family:'Courier New',monospace;">$mm &nbsp; $mbar</td></tr>
        </table>
        EOOPSVM
        done

        # WireGuard Mesh
        cat >> "$F" <<'EOWG1'
        <table width="100%" cellpadding="0" cellspacing="0" style="margin-top:8px;">
        <tr><td colspan="3" style="padding:6px 8px;font-weight:bold;color:#e0e0e0;font-size:13px;font-family:'Courier New',monospace;">WireGuard Mesh</td></tr>
        <tr>
        <th style="text-align:left;color:#8899aa;font-size:11px;padding:4px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">VM</th>
        <th style="text-align:left;color:#8899aa;font-size:11px;padding:4px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">Peer</th>
        <th style="text-align:left;color:#8899aa;font-size:11px;padding:4px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">Last Handshake</th>
        </tr>
        EOWG1

        NOW_EPOCH=$(date +%s)
        for ((j=0; j<VM_COUNT; j++)); do
          n=''${VM_NAMES[$j]}; peers=''${VM_WG_PEERS[$j]}
          if [ -n "$peers" ]; then
            while IFS= read -r line; do
              [ -z "$line" ] && continue
              peer_key=$(echo "$line" | awk '{print substr($1,1,8) "..."}')
              epoch=$(echo "$line" | awk '{print $2}')
              if [ "$epoch" -gt 0 ] 2>/dev/null; then
                age=$((NOW_EPOCH - epoch))
                if [ "$age" -lt 180 ]; then age_str="''${age}s ago"; age_color=$C_OK
                elif [ "$age" -lt 600 ]; then age_str="$((age/60))m ago"; age_color=$C_WARN
                else age_str="$((age/60))m ago"; age_color=$C_CRIT; fi
              else
                age_str="never"; age_color=$C_CRIT
              fi
              cat >> "$F" <<EOWGROW
        <tr>
        <td style="padding:4px 8px;color:#e0e0e0;font-size:12px;border-bottom:1px solid rgba(15,52,96,0.3);font-family:'Courier New',monospace;">$n</td>
        <td style="padding:4px 8px;color:#8899aa;font-size:12px;border-bottom:1px solid rgba(15,52,96,0.3);font-family:monospace;">$peer_key</td>
        <td style="padding:4px 8px;color:$age_color;font-size:12px;border-bottom:1px solid rgba(15,52,96,0.3);font-family:'Courier New',monospace;">$age_str</td>
        </tr>
        EOWGROW
            done <<< "$peers"
          fi
        done

        cat >> "$F" <<'EOWG2'
        </table>
        </td></tr></table>
        </td></tr>
        EOWG2

        # ══════════════════════════════════════════════════════════════════════
        # 2. INVENTORY — Container Census
        # ══════════════════════════════════════════════════════════════════════
        cat >> "$F" <<'EOINV1'
        <tr><td style="padding:8px;">
        <table width="100%" cellpadding="0" cellspacing="0" style="background:#16213e;border-radius:6px;">
        <tr><td style="padding:12px 16px;background:#0f3460;border-radius:6px 6px 0 0;font-size:14px;font-weight:bold;color:#e0e0e0;font-family:'Courier New',monospace;">2. Inventory &mdash; Container Census</td></tr>
        <tr><td style="padding:12px 16px;">
        <table width="100%" cellpadding="0" cellspacing="0">
        <tr>
        <th style="text-align:left;color:#8899aa;font-size:11px;padding:6px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">VM</th>
        <th style="text-align:left;color:#8899aa;font-size:11px;padding:6px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">Running</th>
        <th style="text-align:left;color:#8899aa;font-size:11px;padding:6px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">Stopped</th>
        <th style="text-align:left;color:#8899aa;font-size:11px;padding:6px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">Unhealthy</th>
        <th style="text-align:left;color:#8899aa;font-size:11px;padding:6px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">Total</th>
        </tr>
        EOINV1

        for ((j=0; j<VM_COUNT; j++)); do
          n=''${VM_NAMES[$j]}; run=''${VM_CTR_RUNNING[$j]}
          tot=''${VM_CTR_TOTAL[$j]}; unh=''${VM_CTR_UNHEALTHY[$j]}
          stopped=$((tot - run))
          if [ "$unh" -gt 0 ] 2>/dev/null; then unh_color=$C_CRIT; else unh_color=$C_TEXT; fi
          cat >> "$F" <<EOINVROW
        <tr>
        <td style="padding:6px 8px;color:#e0e0e0;font-size:12px;border-bottom:1px solid rgba(15,52,96,0.5);font-weight:bold;font-family:'Courier New',monospace;">$n</td>
        <td style="padding:6px 8px;color:$C_OK;font-size:12px;border-bottom:1px solid rgba(15,52,96,0.5);font-family:'Courier New',monospace;">$run</td>
        <td style="padding:6px 8px;color:#8899aa;font-size:12px;border-bottom:1px solid rgba(15,52,96,0.5);font-family:'Courier New',monospace;">$stopped</td>
        <td style="padding:6px 8px;color:$unh_color;font-size:12px;border-bottom:1px solid rgba(15,52,96,0.5);font-family:'Courier New',monospace;">$unh</td>
        <td style="padding:6px 8px;color:#e0e0e0;font-size:12px;border-bottom:1px solid rgba(15,52,96,0.5);font-family:'Courier New',monospace;">$tot</td>
        </tr>
        EOINVROW
        done

        FLEET_STOPPED=$((FLEET_TOTAL - FLEET_RUNNING))
        cat >> "$F" <<EOINVTOT
        <tr style="background:rgba(15,52,96,0.3);">
        <td style="padding:6px 8px;color:#e0e0e0;font-size:12px;font-weight:bold;font-family:'Courier New',monospace;">Fleet</td>
        <td style="padding:6px 8px;color:$C_OK;font-size:12px;font-weight:bold;font-family:'Courier New',monospace;">$FLEET_RUNNING</td>
        <td style="padding:6px 8px;color:#8899aa;font-size:12px;font-weight:bold;font-family:'Courier New',monospace;">$FLEET_STOPPED</td>
        <td style="padding:6px 8px;color:#e0e0e0;font-size:12px;font-weight:bold;font-family:'Courier New',monospace;">$FLEET_UNHEALTHY</td>
        <td style="padding:6px 8px;color:#e0e0e0;font-size:12px;font-weight:bold;font-family:'Courier New',monospace;">$FLEET_TOTAL</td>
        </tr>
        </table>
        EOINVTOT

        # Per-VM container lists
        for ((j=0; j<VM_COUNT; j++)); do
          n=''${VM_NAMES[$j]}; ctrs=''${VM_CONTAINERS[$j]}
          if [ -n "$ctrs" ]; then
            cat >> "$F" <<EOCTRHEAD
        <div style="margin-top:10px;font-weight:bold;color:#8899aa;font-size:11px;margin-bottom:4px;font-family:'Courier New',monospace;">$n containers</div>
        <table width="100%" cellpadding="0" cellspacing="0">
        EOCTRHEAD
            while IFS='|' read -r cname cstatus cstate; do
              [ -z "$cname" ] && continue
              case "$cstate" in
                running) sc=$C_OK ;; exited) sc=$C_CRIT ;; *) sc=$C_WARN ;;
              esac
              cat >> "$F" <<EOCTRROW
        <tr><td style="padding:2px 8px;color:#e0e0e0;font-size:11px;border-bottom:1px solid rgba(15,52,96,0.3);font-family:'Courier New',monospace;">$cname</td>
        <td style="padding:2px 8px;color:$sc;font-size:11px;border-bottom:1px solid rgba(15,52,96,0.3);font-family:'Courier New',monospace;">$cstatus</td></tr>
        EOCTRROW
            done <<< "$ctrs"
            echo '</table>' >> "$F"
          fi
        done

        cat >> "$F" <<'EOINV2'
        </td></tr></table>
        </td></tr>
        EOINV2

        # ══════════════════════════════════════════════════════════════════════
        # 3. OBSERVABILITY — Alerts & Issues
        # ══════════════════════════════════════════════════════════════════════
        cat >> "$F" <<'EOOBS1'
        <tr><td style="padding:8px;">
        <table width="100%" cellpadding="0" cellspacing="0" style="background:#16213e;border-radius:6px;">
        <tr><td style="padding:12px 16px;background:#0f3460;border-radius:6px 6px 0 0;font-size:14px;font-weight:bold;color:#e0e0e0;font-family:'Courier New',monospace;">3. Observability &mdash; Alerts &amp; Issues</td></tr>
        <tr><td style="padding:12px 16px;">
        EOOBS1

        HAS_ISSUES=false

        # Unhealthy containers
        for ((j=0; j<VM_COUNT; j++)); do
          unh=''${VM_UNHEALTHY[$j]}
          if [ -n "$unh" ]; then
            HAS_ISSUES=true; n=''${VM_NAMES[$j]}
            echo "<div style=\"margin-bottom:8px;\"><span style=\"color:$C_CRIT;font-weight:bold;font-size:12px;font-family:'Courier New',monospace;\">Unhealthy on $n:</span>" >> "$F"
            while IFS= read -r c; do
              [ -z "$c" ] && continue
              echo "<div style=\"padding:2px 0 2px 16px;color:$C_CRIT;font-size:12px;font-family:'Courier New',monospace;\">$c</div>" >> "$F"
            done <<< "$unh"
            echo '</div>' >> "$F"
          fi
        done

        # Exited containers
        for ((j=0; j<VM_COUNT; j++)); do
          ex=''${VM_EXITED[$j]}
          if [ -n "$ex" ]; then
            HAS_ISSUES=true; n=''${VM_NAMES[$j]}
            echo "<div style=\"margin-bottom:8px;\"><span style=\"color:$C_WARN;font-weight:bold;font-size:12px;font-family:'Courier New',monospace;\">Exited on $n:</span>" >> "$F"
            while IFS= read -r c; do
              [ -z "$c" ] && continue
              echo "<div style=\"padding:2px 0 2px 16px;color:$C_WARN;font-size:12px;font-family:'Courier New',monospace;\">$c</div>" >> "$F"
            done <<< "$ex"
            echo '</div>' >> "$F"
          fi
        done

        # Container restarts (24h)
        for ((j=0; j<VM_COUNT; j++)); do
          rst=''${VM_RESTARTS[$j]}
          if [ -n "$rst" ]; then
            HAS_ISSUES=true; n=''${VM_NAMES[$j]}
            echo "<div style=\"margin-bottom:8px;\"><span style=\"color:$C_WARN;font-weight:bold;font-size:12px;font-family:'Courier New',monospace;\">Restarts (24h) on $n:</span>" >> "$F"
            while IFS='|' read -r cname cnt; do
              [ -z "$cname" ] && continue
              echo "<div style=\"padding:2px 0 2px 16px;color:#e0e0e0;font-size:12px;font-family:'Courier New',monospace;\">$cname (''${cnt}x)</div>" >> "$F"
            done <<< "$rst"
            echo '</div>' >> "$F"
          fi
        done

        # Failed systemd units
        for ((j=0; j<VM_COUNT; j++)); do
          fu=''${VM_FAILED_UNITS[$j]}
          if [ -n "$fu" ]; then
            HAS_ISSUES=true; n=''${VM_NAMES[$j]}
            echo "<div style=\"margin-bottom:8px;\"><span style=\"color:$C_CRIT;font-weight:bold;font-size:12px;font-family:'Courier New',monospace;\">Failed units on $n:</span>" >> "$F"
            while IFS= read -r u; do
              [ -z "$u" ] && continue
              echo "<div style=\"padding:2px 0 2px 16px;color:$C_CRIT;font-size:12px;font-family:'Courier New',monospace;\">$u</div>" >> "$F"
            done <<< "$fu"
            echo '</div>' >> "$F"
          fi
        done

        # Top resource consumers (docker stats)
        cat >> "$F" <<'EOTOP1'
        <div style="margin-top:10px;font-weight:bold;color:#e0e0e0;font-size:13px;margin-bottom:6px;font-family:'Courier New',monospace;">Top Resource Consumers</div>
        <table width="100%" cellpadding="0" cellspacing="0">
        <tr>
        <th style="text-align:left;color:#8899aa;font-size:11px;padding:4px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">VM</th>
        <th style="text-align:left;color:#8899aa;font-size:11px;padding:4px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">Container</th>
        <th style="text-align:left;color:#8899aa;font-size:11px;padding:4px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">CPU</th>
        <th style="text-align:left;color:#8899aa;font-size:11px;padding:4px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">Memory</th>
        </tr>
        EOTOP1

        for ((j=0; j<VM_COUNT; j++)); do
          stats=''${VM_CONTAINER_STATS[$j]}; n=''${VM_NAMES[$j]}
          if [ -n "$stats" ]; then
            echo "$stats" | head -5 | while IFS='|' read -r cname cpu mem mempct; do
              [ -z "$cname" ] && continue
              cat >> "$F" <<EOTOPROW
        <tr>
        <td style="padding:3px 8px;color:#8899aa;font-size:11px;border-bottom:1px solid rgba(15,52,96,0.3);font-family:'Courier New',monospace;">$n</td>
        <td style="padding:3px 8px;color:#e0e0e0;font-size:11px;border-bottom:1px solid rgba(15,52,96,0.3);font-family:'Courier New',monospace;">$cname</td>
        <td style="padding:3px 8px;color:#e0e0e0;font-size:11px;border-bottom:1px solid rgba(15,52,96,0.3);font-family:'Courier New',monospace;">$cpu</td>
        <td style="padding:3px 8px;color:#e0e0e0;font-size:11px;border-bottom:1px solid rgba(15,52,96,0.3);font-family:'Courier New',monospace;">$mem</td>
        </tr>
        EOTOPROW
            done
          fi
        done

        echo '</table>' >> "$F"

        if [ "$HAS_ISSUES" = false ]; then
          echo '<p style="color:#00d68f;font-style:italic;padding:8px 0;font-family:'"'"'Courier New'"'"',monospace;font-size:13px;">All systems nominal &mdash; no alerts.</p>' >> "$F"
        fi

        cat >> "$F" <<'EOOBS2'
        </td></tr></table>
        </td></tr>
        EOOBS2

        # ══════════════════════════════════════════════════════════════════════
        # 4. SECURITY — Access Events (24h)
        # ══════════════════════════════════════════════════════════════════════
        cat >> "$F" <<'EOSEC1'
        <tr><td style="padding:8px;">
        <table width="100%" cellpadding="0" cellspacing="0" style="background:#16213e;border-radius:6px;">
        <tr><td style="padding:12px 16px;background:#0f3460;border-radius:6px 6px 0 0;font-size:14px;font-weight:bold;color:#e0e0e0;font-family:'Courier New',monospace;">4. Security &mdash; Access Events (24h)</td></tr>
        <tr><td style="padding:12px 16px;">
        <table width="100%" cellpadding="0" cellspacing="0">
        <tr>
        <th style="text-align:left;color:#8899aa;font-size:11px;padding:6px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">VM</th>
        <th style="text-align:left;color:#8899aa;font-size:11px;padding:6px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">SSH Accepted</th>
        <th style="text-align:left;color:#8899aa;font-size:11px;padding:6px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">SSH Failed</th>
        <th style="text-align:left;color:#8899aa;font-size:11px;padding:6px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">Sudo</th>
        </tr>
        EOSEC1

        for ((j=0; j<VM_COUNT; j++)); do
          n=''${VM_NAMES[$j]}; sa=''${VM_SSH_ACCEPTS[$j]}
          sf=''${VM_SSH_FAILS[$j]}; su=''${VM_SUDOS[$j]}
          if [ "$sf" -gt 10 ] 2>/dev/null; then sf_color=$C_CRIT; else sf_color=$C_TEXT; fi
          cat >> "$F" <<EOSECROW
        <tr>
        <td style="padding:6px 8px;color:#e0e0e0;font-size:12px;border-bottom:1px solid rgba(15,52,96,0.5);font-weight:bold;font-family:'Courier New',monospace;">$n</td>
        <td style="padding:6px 8px;color:$C_OK;font-size:12px;border-bottom:1px solid rgba(15,52,96,0.5);font-family:'Courier New',monospace;">$sa</td>
        <td style="padding:6px 8px;color:$sf_color;font-size:12px;border-bottom:1px solid rgba(15,52,96,0.5);font-family:'Courier New',monospace;">$sf</td>
        <td style="padding:6px 8px;color:#e0e0e0;font-size:12px;border-bottom:1px solid rgba(15,52,96,0.5);font-family:'Courier New',monospace;">$su</td>
        </tr>
        EOSECROW
        done

        echo '</table>' >> "$F"

        # Top failed IPs
        for ((j=0; j<VM_COUNT; j++)); do
          sf=''${VM_SSH_FAILS[$j]}; tips=''${VM_TOP_FAILS[$j]}
          if [ "$sf" -gt 10 ] 2>/dev/null && [ -n "$tips" ]; then
            n=''${VM_NAMES[$j]}
            echo "<div style=\"margin-top:8px;\"><span style=\"color:$C_WARN;font-weight:bold;font-size:12px;font-family:'Courier New',monospace;\">Top failed IPs on $n:</span>" >> "$F"
            while IFS='|' read -r fip cnt; do
              [ -z "$fip" ] && continue
              echo "<div style=\"padding:2px 0 2px 16px;color:#e0e0e0;font-size:12px;font-family:'Courier New',monospace;\">$fip (''${cnt}x)</div>" >> "$F"
            done <<< "$tips"
            echo '</div>' >> "$F"
          fi
        done

        cat >> "$F" <<'EOSEC2'
        </td></tr></table>
        </td></tr>
        EOSEC2

        # ══════════════════════════════════════════════════════════════════════
        # 5. DELIVERY — Backups & Workflows
        # ══════════════════════════════════════════════════════════════════════
        cat >> "$F" <<'EODEL1'
        <tr><td style="padding:8px;">
        <table width="100%" cellpadding="0" cellspacing="0" style="background:#16213e;border-radius:6px;">
        <tr><td style="padding:12px 16px;background:#0f3460;border-radius:6px 6px 0 0;font-size:14px;font-weight:bold;color:#e0e0e0;font-family:'Courier New',monospace;">5. Delivery &mdash; Backups &amp; Workflows</td></tr>
        <tr><td style="padding:12px 16px;">
        EODEL1

        for ((j=0; j<VM_COUNT; j++)); do
          n=''${VM_NAMES[$j]}; bk=''${VM_BACKUPS[$j]}
          echo "<div style=\"margin-bottom:10px;\"><div style=\"font-weight:bold;color:#e0e0e0;font-size:12px;margin-bottom:4px;font-family:'Courier New',monospace;\">$n</div>" >> "$F"
          if [ -n "$bk" ]; then
            cat >> "$F" <<'EOBKTBL'
        <table width="100%" cellpadding="0" cellspacing="0">
        <tr>
        <th style="text-align:left;color:#8899aa;font-size:11px;padding:3px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">File</th>
        <th style="text-align:left;color:#8899aa;font-size:11px;padding:3px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">Size</th>
        <th style="text-align:left;color:#8899aa;font-size:11px;padding:3px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">Date</th>
        </tr>
        EOBKTBL
            while IFS='|' read -r fname fsize fdate; do
              [ -z "$fname" ] && continue
              cat >> "$F" <<EOBKROW
        <tr>
        <td style="padding:3px 8px;color:#e0e0e0;font-size:11px;border-bottom:1px solid rgba(15,52,96,0.3);font-family:'Courier New',monospace;">$fname</td>
        <td style="padding:3px 8px;color:#8899aa;font-size:11px;border-bottom:1px solid rgba(15,52,96,0.3);font-family:'Courier New',monospace;">$fsize</td>
        <td style="padding:3px 8px;color:#8899aa;font-size:11px;border-bottom:1px solid rgba(15,52,96,0.3);font-family:'Courier New',monospace;">$fdate</td>
        </tr>
        EOBKROW
            done <<< "$bk"
            echo '</table>' >> "$F"
          else
            echo '<div style="color:#8899aa;font-size:12px;font-style:italic;padding-left:8px;font-family:'"'"'Courier New'"'"',monospace;">No backup files found</div>' >> "$F"
          fi
          echo '</div>' >> "$F"
        done

        cat >> "$F" <<'EODEL2'
        <div style="margin-top:8px;padding:8px;background:rgba(15,52,96,0.3);border-radius:4px;">
        <span style="color:#8899aa;font-size:12px;font-family:'Courier New',monospace;">Dagu Dashboard: </span>
        <a href="http://10.0.0.3:8070" style="color:#00d68f;font-size:12px;font-family:'Courier New',monospace;">http://10.0.0.3:8070</a>
        </div>
        </td></tr></table>
        </td></tr>
        EODEL2

        # ══════════════════════════════════════════════════════════════════════
        # 6. FINOPS — Resource Utilization
        # ══════════════════════════════════════════════════════════════════════
        cat >> "$F" <<'EOFIN1'
        <tr><td style="padding:8px;">
        <table width="100%" cellpadding="0" cellspacing="0" style="background:#16213e;border-radius:6px;">
        <tr><td style="padding:12px 16px;background:#0f3460;border-radius:6px 6px 0 0;font-size:14px;font-weight:bold;color:#e0e0e0;font-family:'Courier New',monospace;">6. FinOps &mdash; Resource Utilization</td></tr>
        <tr><td style="padding:12px 16px;">
        <div style="font-weight:bold;color:#e0e0e0;font-size:13px;margin-bottom:6px;font-family:'Courier New',monospace;">Docker Disk Usage</div>
        <table width="100%" cellpadding="0" cellspacing="0">
        <tr>
        <th style="text-align:left;color:#8899aa;font-size:11px;padding:4px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">VM</th>
        <th style="text-align:left;color:#8899aa;font-size:11px;padding:4px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">Type</th>
        <th style="text-align:left;color:#8899aa;font-size:11px;padding:4px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">Count</th>
        <th style="text-align:left;color:#8899aa;font-size:11px;padding:4px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">Size</th>
        <th style="text-align:left;color:#8899aa;font-size:11px;padding:4px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">Reclaimable</th>
        </tr>
        EOFIN1

        for ((j=0; j<VM_COUNT; j++)); do
          n=''${VM_NAMES[$j]}; ddf=''${VM_DOCKER_DFS[$j]}
          if [ -n "$ddf" ]; then
            first_row=true
            while IFS='|' read -r dtype dcount dsize dreclaim; do
              [ -z "$dtype" ] && continue
              if $first_row; then vm_cell="$n"; first_row=false; else vm_cell=""; fi
              cat >> "$F" <<EOFINROW
        <tr>
        <td style="padding:3px 8px;color:#e0e0e0;font-size:11px;border-bottom:1px solid rgba(15,52,96,0.3);font-weight:bold;font-family:'Courier New',monospace;">$vm_cell</td>
        <td style="padding:3px 8px;color:#8899aa;font-size:11px;border-bottom:1px solid rgba(15,52,96,0.3);font-family:'Courier New',monospace;">$dtype</td>
        <td style="padding:3px 8px;color:#e0e0e0;font-size:11px;border-bottom:1px solid rgba(15,52,96,0.3);font-family:'Courier New',monospace;">$dcount</td>
        <td style="padding:3px 8px;color:#e0e0e0;font-size:11px;border-bottom:1px solid rgba(15,52,96,0.3);font-family:'Courier New',monospace;">$dsize</td>
        <td style="padding:3px 8px;color:#8899aa;font-size:11px;border-bottom:1px solid rgba(15,52,96,0.3);font-family:'Courier New',monospace;">$dreclaim</td>
        </tr>
        EOFINROW
            done <<< "$ddf"
          fi
        done

        echo '</table>' >> "$F"

        # Fleet utilization bars
        cat >> "$F" <<'EOUTIL1'
        <div style="margin-top:12px;font-weight:bold;color:#e0e0e0;font-size:13px;margin-bottom:6px;font-family:'Courier New',monospace;">Fleet Utilization</div>
        <table width="100%" cellpadding="0" cellspacing="0">
        <tr>
        <th style="text-align:left;color:#8899aa;font-size:11px;padding:4px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">VM</th>
        <th style="text-align:left;color:#8899aa;font-size:11px;padding:4px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">Memory</th>
        <th style="text-align:left;color:#8899aa;font-size:11px;padding:4px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">Disk</th>
        </tr>
        EOUTIL1

        for ((j=0; j<VM_COUNT; j++)); do
          n=''${VM_NAMES[$j]}; mp=''${VM_MEM_PCTS[$j]}; dp=''${VM_DISK_PCTS[$j]}
          mbar=$(progress_bar "$mp"); dbar=$(progress_bar "$dp")
          cat >> "$F" <<EOUTILROW
        <tr>
        <td style="padding:4px 8px;color:#e0e0e0;font-size:12px;border-bottom:1px solid rgba(15,52,96,0.3);font-weight:bold;font-family:'Courier New',monospace;">$n</td>
        <td style="padding:4px 8px;border-bottom:1px solid rgba(15,52,96,0.3);">$mbar</td>
        <td style="padding:4px 8px;border-bottom:1px solid rgba(15,52,96,0.3);">$dbar</td>
        </tr>
        EOUTILROW
        done

        cat >> "$F" <<EOFINTOT
        </table>
        <div style="margin-top:10px;padding:8px;background:rgba(15,52,96,0.3);border-radius:4px;color:#8899aa;font-size:12px;font-family:'Courier New',monospace;">
        Fleet totals: <span style="color:#e0e0e0;">$FLEET_RUNNING running</span> / <span style="color:#e0e0e0;">$FLEET_TOTAL total containers</span>
        </div>
        EOFINTOT

        cat >> "$F" <<'EOFIN2'
        </td></tr></table>
        </td></tr>
        EOFIN2

        # ── FOOTER ──
        cat >> "$F" <<EOFOOT
        <tr><td style="text-align:center;padding:16px;color:#8899aa;font-size:11px;font-family:'Courier New',monospace;">
        C3 Daily Ops Report &mdash; $DATE $TIME<br>
        <a href="http://10.0.0.3:8070" style="color:#00d68f;">Dagu Dashboard</a>
        </td></tr>
        </table>
        </td></tr></table>
        </center>
        </body>
        </html>
        EOFOOT

        # ── Send email via SMTP ──
        curl -s --url "smtp://mailu-smtp-1:25" \
          --mail-from "no-reply@diegonmarcos.com" \
          --mail-rcpt "me@diegonmarcos.com" \
          -T "$F"
        rm -f "$F"
        echo "C3 Daily Ops Report sent for $DATE"
      '';

      daily-report = pkgs.writeText "daily-report.yaml" ''
        schedule: "0 7 * * *"
        env:
          - NTFY_URL: http://10.0.0.1:8090
          - AUTHELIA_BEARER_TOKEN: ''${AUTHELIA_BEARER_TOKEN}
        mailOn:
          failure: true
          success: false
        steps:
          - name: collect-and-email
            command: bash /var/lib/dagu/dags/daily-report.sh
      '';

      # ═══════════════════════════════════════════════════════════════════
      # DATA SYNC
      # ═══════════════════════════════════════════════════════════════════

      cloud-data-sync = pkgs.writeText "cloud-data-sync.yaml" ''
        schedule: "*/5 * * * *"
        env:
          - AUTHELIA_BEARER_TOKEN: ''${AUTHELIA_BEARER_TOKEN}
          - C3_API: http://10.0.0.6:8081
          - REPO_DIR: /var/lib/dagu/data/cloud-data
          - REPO_URL: git@github.com:diegonmarcos/cloud-data.git
          - NTFY_URL: http://10.0.0.1:8090
        mailOn:
          failure: true
          success: false
        steps:
          - name: ensure-clone
            command: |
              export GIT_SSH_COMMAND="ssh -i /root/.ssh/vault_id_rsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
              if [ ! -d "$REPO_DIR/.git" ]; then
                git clone "$REPO_URL" "$REPO_DIR"
                cd "$REPO_DIR"
                git config user.name "dagu-bot"
                git config user.email "no-reply@diegonmarcos.com"
              fi
          - name: pull-rebase
            depends:
              - ensure-clone
            command: |
              export GIT_SSH_COMMAND="ssh -i /root/.ssh/vault_id_rsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
              cd "$REPO_DIR"
              git pull --rebase origin main || {
                echo "Rebase conflict — resetting to remote"
                git rebase --abort 2>/dev/null
                git reset --hard origin/main
              }
          - name: fetch-topology
            depends:
              - pull-rebase
            command: |
              curl -sf "$C3_API/topology" | jq '.' > "$REPO_DIR/cloud-topology.json.tmp"
              mv "$REPO_DIR/cloud-topology.json.tmp" "$REPO_DIR/cloud-topology.json"
              echo "Fetched cloud-topology.json ($(wc -c < "$REPO_DIR/cloud-topology.json") bytes)"
          - name: fetch-configs
            depends:
              - pull-rebase
            command: |
              curl -sf "$C3_API/configs" | jq '.' > "$REPO_DIR/cloud-configs.json.tmp"
              mv "$REPO_DIR/cloud-configs.json.tmp" "$REPO_DIR/cloud-configs.json"
              echo "Fetched cloud-configs.json ($(wc -c < "$REPO_DIR/cloud-configs.json") bytes)"
          - name: commit-and-push
            depends:
              - fetch-topology
              - fetch-configs
            command: |
              export GIT_SSH_COMMAND="ssh -i /root/.ssh/vault_id_rsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
              cd "$REPO_DIR"
              git add cloud-topology.json cloud-configs.json
              if git diff --cached --quiet; then
                echo "No changes — skipping commit"
                exit 0
              fi
              STAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
              git commit -m "sync: cloud-topology + cloud-configs ''${STAMP}"
              git push origin main
              echo "Pushed changes at ''${STAMP}"
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
        cp ${mkFetchToken pkgs} $out/fetch-token.sh
        chmod +x $out/fetch-token.sh
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
        cp ${dags.daily-report} $out/dags/daily-report.yaml
        cp ${dags.daily-report-script} $out/dags/daily-report.sh
        cp ${dags.cloud-data-sync} $out/dags/cloud-data-sync.yaml
      '';
    in {
      default = defaultPkg;
      docs = mkDocs pkgs defaultPkg;
    });
  };
}
