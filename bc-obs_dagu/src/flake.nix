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
          entrypoint: ["dagu", "start-all"]
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
          - BEARER_TOKEN: ''${BEARER_TOKEN}
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
                MSG=$(printf "Unreachable peers:\n''${FAILED}\nAction:\n  ssh <vm> 'wg show'\n  ssh <vm> 'systemctl status wg-quick@wg0'\n\nDagu: http://10.0.0.3:8070")
                curl -s -X POST "$NTFY_URL/infra_mesh-health" \
                  -H "Authorization: Bearer $BEARER_TOKEN" \
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
          - BEARER_TOKEN: ''${BEARER_TOKEN}
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
                MSG=$(printf "DOWN endpoints:\n''${FAILED}\nAction:\n  curl -v https://<domain>\n  ssh gcp-proxy 'docker logs caddy --tail 20'\n\nDagu: http://10.0.0.3:8070")
                curl -s -X POST "$NTFY_URL/infra_endpoints" \
                  -H "Authorization: Bearer $BEARER_TOKEN" \
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
          - BEARER_TOKEN: ''${BEARER_TOKEN}
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
                MSG=$(printf "DNS resolution failures:\n''${FAILED}\nAction:\n  dig <domain> @1.1.1.1\n  dig <domain> @8.8.8.8\n  Check Cloudflare DNS dashboard\n\nDagu: http://10.0.0.3:8070")
                curl -s -X POST "$NTFY_URL/infra_dns" \
                  -H "Authorization: Bearer $BEARER_TOKEN" \
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
          - BEARER_TOKEN: ''${BEARER_TOKEN}
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
                MSG=$(printf "High resource usage:\n''${ALERTS}\nAction:\n  ssh <user>@<ip> 'df -h && free -h && top -bn1 | head -15'\n  ssh <user>@<ip> 'docker stats --no-stream'\n\nDagu: http://10.0.0.3:8070")
                curl -s -X POST "$NTFY_URL/infra_resources" \
                  -H "Authorization: Bearer $BEARER_TOKEN" \
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
          - BEARER_TOKEN: ''${BEARER_TOKEN}
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
                MSG=$(printf "Container issues:\n''${ALERTS}\nAction:\n  ssh <user>@<ip> 'docker logs <container> --tail 30'\n  ssh <user>@<ip> 'docker restart <container>'\n\nDagu: http://10.0.0.3:8070")
                curl -s -X POST "$NTFY_URL/infra_containers" \
                  -H "Authorization: Bearer $BEARER_TOKEN" \
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
          - BEARER_TOKEN: ''${BEARER_TOKEN}
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
                MSG=$(printf "Suspicious auth activity:\n''${ALERTS}\nAction:\n  ssh <user>@<ip> 'grep \"Failed password\" /var/log/auth.log | tail -20'\n  ssh <user>@<ip> 'last -20'\n  ssh <user>@<ip> 'fail2ban-client status sshd'\n\nDagu: http://10.0.0.3:8070")
                curl -s -X POST "$NTFY_URL/security_audit" \
                  -H "Authorization: Bearer $BEARER_TOKEN" \
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
          - BEARER_TOKEN: ''${BEARER_TOKEN}
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
                MSG=$(printf "TLS certificates expiring soon:\n''${ALERTS}\nAction:\n  openssl s_client -connect <domain>:443 </dev/null 2>/dev/null | openssl x509 -noout -dates\n  ssh gcp-proxy 'docker exec caddy caddy reload'\n  Check Let's Encrypt / Caddy auto-renewal logs\n\nDagu: http://10.0.0.3:8070")
                curl -s -X POST "$NTFY_URL/security_tls" \
                  -H "Authorization: Bearer $BEARER_TOKEN" \
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
          - BEARER_TOKEN: ''${BEARER_TOKEN}
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
              MSG=$(printf "Daily Connection Report ($TODAY):\n\n''${REPORT}Inspect:\n  ssh <user>@<ip> 'journalctl -u ssh --since yesterday'\n  ssh <user>@<ip> 'last -20'\n  ssh <user>@<ip> 'ss -tunap'\n\nDagu: http://10.0.0.3:8070")
              curl -s -X POST "$NTFY_URL/security_connections" \
                -H "Authorization: Bearer $BEARER_TOKEN" \
                -H "Title: Daily Connection Report" \
                -H "Priority: 2" \
                -H "Tags: key,shield" \
                -d "$MSG"
      '';

      sauron-integrity = pkgs.writeText "sauron-integrity.yaml" ''
        schedule: "0 3 * * 0"
        env:
          - NTFY_URL: http://10.0.0.1:8090
          - BEARER_TOKEN: ''${BEARER_TOKEN}
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
                MSG=$(printf "YARA scanner status: $RUNNING/$TOTAL running\n\nMissing:\n''${MISSING}\nAction:\n  ssh <user>@<ip> 'docker ps -a | grep sauron'\n  ssh <user>@<ip> 'cd /opt/containers/sauron && docker compose up -d'\n\nDagu: http://10.0.0.3:8070")
                curl -s -X POST "$NTFY_URL/security_yara" \
                  -H "Authorization: Bearer $BEARER_TOKEN" \
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
          - BEARER_TOKEN: ''${BEARER_TOKEN}
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
              MSG=$(printf "Daily Ops Summary:\n\n''${REPORT}Dagu: http://10.0.0.3:8070")
              curl -s -X POST "$NTFY_URL/ops_summary" \
                -H "Authorization: Bearer $BEARER_TOKEN" \
                -H "Title: Daily Ops Summary" \
                -H "Priority: 2" \
                -H "Tags: chart_with_upwards_trend" \
                -d "$MSG"
      '';

      backup-check = pkgs.writeText "backup-check.yaml" ''
        schedule: "0 11 * * *"
        env:
          - NTFY_URL: http://10.0.0.1:8090
          - BEARER_TOKEN: ''${BEARER_TOKEN}
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
                MSG=$(printf "Backup freshness issues:\n''${ALERTS}\nAction:\n  ssh <user>@<ip> 'ls -lt /var/backups/ | head -10'\n  Check backup cron: ssh <user>@<ip> 'crontab -l'\n\nDagu: http://10.0.0.3:8070")
                curl -s -X POST "$NTFY_URL/ops_backups" \
                  -H "Authorization: Bearer $BEARER_TOKEN" \
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
          - BEARER_TOKEN: ''${BEARER_TOKEN}
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
                MSG=$(printf "Failed systemd timers:\n''${ALERTS}\nAction:\n  ssh <user>@<ip> 'systemctl list-timers --failed'\n  ssh <user>@<ip> 'journalctl -u <timer-name> --since yesterday'\n\nDagu: http://10.0.0.3:8070")
                curl -s -X POST "$NTFY_URL/ops_cron" \
                  -H "Authorization: Bearer $BEARER_TOKEN" \
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
          - BEARER_TOKEN: ''${BEARER_TOKEN}
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
                COUNT=$($SSH $user@$ip "journalctl -u docker --since '24 hours ago' 2>/dev/null | grep -c 'Container.*Started' || echo 0" 2>/dev/null || echo 0)
                TOTAL=$((TOTAL + COUNT))
                if [ "$COUNT" -gt 0 ] 2>/dev/null; then
                  REPORT="''${REPORT}$name ($ip): $COUNT restarts\n"
                  if [ -n "$RESTARTS" ]; then
                    REPORT="''${REPORT}$RESTARTS\n"
                  fi
                  REPORT="''${REPORT}\n"
                fi
              done
              MSG=$(printf "Deploy Digest (24h): $TOTAL total restarts\n\n''${REPORT}Action:\n  ssh <user>@<ip> 'docker ps --format \"table {{.Names}}\t{{.Status}}\"'\n\nDagu: http://10.0.0.3:8070")
              curl -s -X POST "$NTFY_URL/cicd_deploy-digest" \
                -H "Authorization: Bearer $BEARER_TOKEN" \
                -H "Title: Daily Deploy Digest ($TOTAL restarts)" \
                -H "Priority: 2" \
                -H "Tags: rocket" \
                -d "$MSG"
      '';

      capacity-review = pkgs.writeText "capacity-review.yaml" ''
        schedule: "0 9 * * 1"
        env:
          - NTFY_URL: http://10.0.0.1:8090
          - BEARER_TOKEN: ''${BEARER_TOKEN}
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
              MSG=$(printf "Weekly Capacity Review:\n\n''${REPORT}Action:\n  ssh <user>@<ip> 'docker system prune -f'\n  ssh <user>@<ip> 'du -sh /opt/containers/*/data | sort -rh'\n\nDagu: http://10.0.0.3:8070")
              curl -s -X POST "$NTFY_URL/ops_summary" \
                -H "Authorization: Bearer $BEARER_TOKEN" \
                -H "Title: Weekly Capacity Review" \
                -H "Priority: 2" \
                -H "Tags: bar_chart" \
                -d "$MSG"
      '';

      # ═══════════════════════════════════════════════════════════════════
      # DAILY EMAIL REPORT
      # ═══════════════════════════════════════════════════════════════════

      daily-report = pkgs.writeText "daily-report.yaml" ''
        schedule: "0 7 * * *"
        env:
          - NTFY_URL: http://10.0.0.1:8090
          - BEARER_TOKEN: ''${BEARER_TOKEN}
        mailOn:
          failure: true
          success: false
        steps:
          - name: collect-and-email
            command: |
              SSH="${sshCmd}"
              DATE=$(date '+%Y-%m-%d')
              REPORT=""

              for vm_data in ${vmList}; do
                ip=''${vm_data%%:*}
                temp=''${vm_data#*:}
                name=''${temp%:*}
                user=''${temp#*:}

                REPORT="''${REPORT}================================================================\n"
                REPORT="''${REPORT}  $name ($ip)\n"
                REPORT="''${REPORT}================================================================\n\n"

                # -- SINGLE SSH CALL: Collect all data in one shot --
                VM_DATA=$($SSH $user@$ip 'bash -s' <<'EOSSH' 2>/dev/null || echo "ERROR: SSH failed"
                  echo "===UPTIME==="
                  uptime -p 2>/dev/null || echo "N/A"
                  echo "===LOAD==="
                  cat /proc/loadavg 2>/dev/null | awk '{print $1, $2, $3}' || echo "N/A"
                  echo "===DISK==="
                  df -h / 2>/dev/null | awk 'NR==2 {print $3 "/" $2 " (" $5 ")"}' || echo "N/A"
                  echo "===MEM==="
                  free -h 2>/dev/null | awk '/Mem:/ {print $3 "/" $2 " (" int($3/$2*100) "%)"}' || echo "N/A"
                  echo "===CONTAINERS==="
                  docker ps -a --format '  {{.Names}}: {{.Status}}' 2>/dev/null | head -30 || echo "  N/A"
                  echo "===UNHEALTHY==="
                  docker ps --filter health=unhealthy --format '  {{.Names}}' 2>/dev/null
                  echo "===EXITED==="
                  docker ps -a --filter status=exited --format '  {{.Names}} (exited {{.Status}})' 2>/dev/null | head -10
                  echo "===SSH_ACCEPT==="
                  journalctl -u ssh --since '24 hours ago' 2>/dev/null | grep -c 'Accepted' || echo 0
                  echo "===SSH_FAIL==="
                  journalctl -u ssh --since '24 hours ago' 2>/dev/null | grep -c 'Failed' || echo 0
                  echo "===SUDO==="
                  journalctl --since '24 hours ago' 2>/dev/null | grep -c 'sudo:' || echo 0
                  echo "===TOP_FAIL_IPS==="
                  journalctl -u ssh --since '24 hours ago' 2>/dev/null | grep 'Failed' | awk '{for(i=1;i<=NF;i++) if($i ~ /[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/) print $i}' | sort | uniq -c | sort -rn | head -5 | awk '{print "    " $2 " (" $1 "x)"}'
                  echo "===RESTARTS==="
                  journalctl -u docker --since '24 hours ago' 2>/dev/null | grep 'Container.*Started' | awk '{print $NF}' | sort | uniq -c | sort -rn | head -5 | awk '{print "  " $2 " (" $1 "x)"}'
                  echo "===BACKUPS==="
                  ls -lht /opt/backups/ 2>/dev/null | head -5 | awk '{print "  " $0}' || echo "  No backups dir"
                  echo "===FAILED_UNITS==="
                  systemctl --failed --no-legend 2>/dev/null | head -5 | awk '{print "  " $0}'
                  echo "===END==="
EOSSH
)

                # -- Parse the collected data --
                UPTIME=$(echo "$VM_DATA" | awk '/===UPTIME===/,/===LOAD===/' | grep -v '===' || echo "N/A")
                LOAD=$(echo "$VM_DATA" | awk '/===LOAD===/,/===DISK===/' | grep -v '===' || echo "N/A")
                DISK=$(echo "$VM_DATA" | awk '/===DISK===/,/===MEM===/' | grep -v '===' || echo "N/A")
                MEM=$(echo "$VM_DATA" | awk '/===MEM===/,/===CONTAINERS===/' | grep -v '===' || echo "N/A")
                CONTAINERS=$(echo "$VM_DATA" | awk '/===CONTAINERS===/,/===UNHEALTHY===/' | grep -v '===' || echo "  N/A")
                UNHEALTHY=$(echo "$VM_DATA" | awk '/===UNHEALTHY===/,/===EXITED===/' | grep -v '===')
                EXITED=$(echo "$VM_DATA" | awk '/===EXITED===/,/===SSH_ACCEPT===/' | grep -v '===')
                SSH_ACCEPT=$(echo "$VM_DATA" | awk '/===SSH_ACCEPT===/,/===SSH_FAIL===/' | grep -v '===' || echo "0")
                SSH_FAIL=$(echo "$VM_DATA" | awk '/===SSH_FAIL===/,/===SUDO===/' | grep -v '===' || echo "0")
                SUDO_COUNT=$(echo "$VM_DATA" | awk '/===SUDO===/,/===TOP_FAIL_IPS===/' | grep -v '===' || echo "0")
                TOP_FAIL=$(echo "$VM_DATA" | awk '/===TOP_FAIL_IPS===/,/===RESTARTS===/' | grep -v '===')
                RESTARTS=$(echo "$VM_DATA" | awk '/===RESTARTS===/,/===BACKUPS===/' | grep -v '===')
                BACKUP=$(echo "$VM_DATA" | awk '/===BACKUPS===/,/===FAILED_UNITS===/' | grep -v '===')
                FAILED_UNITS=$(echo "$VM_DATA" | awk '/===FAILED_UNITS===/,/===END===/' | grep -v '===')

                # -- Build report --
                REPORT="''${REPORT}[System]\n  Uptime: $UPTIME\n  Load: $LOAD\n  Disk: $DISK\n  Memory: $MEM\n\n"
                REPORT="''${REPORT}[Containers]\n$CONTAINERS\n"
                if [ -n "$UNHEALTHY" ]; then
                  REPORT="''${REPORT}\n  !! UNHEALTHY:\n$UNHEALTHY\n"
                fi
                if [ -n "$EXITED" ]; then
                  REPORT="''${REPORT}\n  !! EXITED:\n$EXITED\n"
                fi
                REPORT="''${REPORT}\n"
                REPORT="''${REPORT}[Security - 24h]\n  SSH accepted: $SSH_ACCEPT | failed: $SSH_FAIL\n  sudo events: $SUDO_COUNT\n"
                if [ "$SSH_FAIL" -gt 10 ] 2>/dev/null && [ -n "$TOP_FAIL" ]; then
                  REPORT="''${REPORT}  Top failed IPs:\n$TOP_FAIL\n"
                fi
                REPORT="''${REPORT}\n"
                if [ -n "$RESTARTS" ]; then
                  REPORT="''${REPORT}[Container Restarts - 24h]\n$RESTARTS\n\n"
                fi
                REPORT="''${REPORT}[Latest Backups]\n$BACKUP\n\n"
                if [ -n "$FAILED_UNITS" ]; then
                  REPORT="''${REPORT}[Failed Services]\n$FAILED_UNITS\n\n"
                else
                  REPORT="''${REPORT}[Failed Services]\n  None\n\n"
                fi
                REPORT="''${REPORT}\n"
              done

              # -- Dagu Workflows (24h execution summary) --
              REPORT="''${REPORT}================================================================\n"
              REPORT="''${REPORT}  Dagu Workflows (24h)\n"
              REPORT="''${REPORT}================================================================\n\n"

              WORKFLOWS="healthcheck system-check docker-check backup-check security-audit ops-summary service-endpoints tls-expiry dns-resolution auth-events cron-status deploy-digest sauron-integrity capacity-review"
              for wf in $WORKFLOWS; do
                # Get the latest run status for each workflow
                STATUS_OUTPUT=$(dagu status /var/lib/dagu/dags/$wf.yaml 2>/dev/null | head -1 || echo "N/A")
                STATUS_LINE=$(echo "$STATUS_OUTPUT" | grep -oE '(Success|Failed|Running|Canceled|N/A)' | head -1)
                if [ -z "$STATUS_LINE" ]; then
                  STATUS_LINE="N/A"
                fi

                # Get run count from last 24h by checking data directory
                RUN_COUNT=$(find /var/lib/dagu/data/dag-runs/$wf/dag-runs -type d -mtime -1 2>/dev/null | wc -l || echo "0")

                # Format status with indicator
                if [ "$STATUS_LINE" = "Success" ]; then
                  INDICATOR="✓"
                elif [ "$STATUS_LINE" = "Failed" ]; then
                  INDICATOR="✗"
                elif [ "$STATUS_LINE" = "Running" ]; then
                  INDICATOR="→"
                else
                  INDICATOR=" "
                fi

                REPORT="''${REPORT}  $INDICATOR $wf: $STATUS_LINE"
                if [ "$RUN_COUNT" -gt 0 ]; then
                  REPORT="''${REPORT} ($RUN_COUNT runs)\n"
                else
                  REPORT="''${REPORT}\n"
                fi
              done
              REPORT="''${REPORT}\n"

              # -- Compose email via curl SMTP --
              SUBJECT="Daily Ops Report - $DATE"

              {
                echo "From: no-reply@diegonmarcos.com"
                echo "To: me@diegonmarcos.com"
                echo "Subject: $SUBJECT"
                echo "Content-Type: text/plain; charset=UTF-8"
                echo ""
                echo "Daily Operations Report - $DATE"
                echo "Generated at $(date '+%H:%M %Z')"
                echo ""
                echo -e "$REPORT"
                echo "---"
                echo "Dagu Dashboard: http://10.0.0.3:8070"
              } | curl -s --url "smtp://mailu-smtp-1:25" \
                    --mail-from "no-reply@diegonmarcos.com" \
                    --mail-rcpt "me@diegonmarcos.com" \
                    -T -

              echo "Daily report email sent for $DATE"
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
        cp ${dags.daily-report} $out/dags/daily-report.yaml
      '';
    in {
      default = defaultPkg;
      docs = mkDocs pkgs defaultPkg;
    });
  };
}
