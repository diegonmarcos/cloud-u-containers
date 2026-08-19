use crate::types::*;
use anyhow::Result;
use std::time::Duration;
use tokio::time::timeout;

const SSH_TIMEOUT: Duration = Duration::from_secs(60);

async fn ssh_exec_once(alias: &str, user: &str, ip: &str, command: &str) -> Result<String> {
    let dagu_key = "/home/dagu/.ssh/vault_id_rsa";
    let use_dagu_key = std::path::Path::new(dagu_key).exists();

    let target = if use_dagu_key {
        format!("{}@{}", user, ip)
    } else {
        alias.to_string()
    };

    let mut cmd = tokio::process::Command::new("ssh");
    if use_dagu_key {
        cmd.args(["-i", dagu_key]);
    }
    cmd.args([
        "-o", "StrictHostKeyChecking=no",
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=5",
        "-o", "ServerAliveInterval=15",
        "-o", "ServerAliveCountMax=2",
        "-o", "UserKnownHostsFile=/dev/null",
        "-o", "LogLevel=ERROR",
        "-o", "ControlMaster=auto",
        "-o", "ControlPath=/tmp/daily-mail-mux-%h",
        "-o", "ControlPersist=30",
        &target,
        "bash", "-s",
    ]);
    cmd.stdin(std::process::Stdio::piped());
    cmd.stdout(std::process::Stdio::piped());
    cmd.stderr(std::process::Stdio::piped());

    let mut child = cmd.spawn()?;
    if let Some(mut stdin) = child.stdin.take() {
        use tokio::io::AsyncWriteExt;
        stdin.write_all(command.as_bytes()).await?;
        drop(stdin);
    }

    let output = timeout(SSH_TIMEOUT, child.wait_with_output()).await??;

    if output.status.success() {
        Ok(String::from_utf8_lossy(&output.stdout).to_string())
    } else {
        anyhow::bail!("SSH failed")
    }
}

/// Execute SSH command on a VM, return stdout
/// Uses Dagu key + user@ip when running in container, SSH alias when running on desktop
///
/// 2026-07-03: third independent occurrence in this reports/ tree of the
/// same bug (see cloud-mail-health-full/src/ssh.rs and
/// cloud-health-full-daily/src/mail_full/ssh.rs) — a single SSH attempt
/// fired with no retry, misreporting a cold WG handshake miss as a fully
/// down VM (all 4 VMs flipped VmStatus::Critical simultaneously in one
/// run, all verified live and healthy seconds later). One retry after a
/// 3s backoff, matching the same fix already applied to the other two.
async fn ssh_exec(alias: &str, user: &str, ip: &str, command: &str) -> Result<String> {
    if let Ok(out) = ssh_exec_once(alias, user, ip, command).await {
        return Ok(out);
    }
    tokio::time::sleep(Duration::from_secs(3)).await;
    ssh_exec_once(alias, user, ip, command).await
}

/// Parse ===SECTION=== markers from batch output
fn section(raw: &str, start: &str, end: &str) -> String {
    let start_marker = format!("==={}===", start);
    let end_marker = format!("==={}===", end);
    let mut capturing = false;
    let mut lines = Vec::new();

    for line in raw.lines() {
        if line.trim() == start_marker {
            capturing = true;
            continue;
        }
        if capturing && line.trim() == end_marker {
            break;
        }
        if capturing
            && line.trim().starts_with("===")
            && line.trim().ends_with("===")
        {
            break;
        }
        if capturing {
            lines.push(line);
        }
    }
    lines.join("\n").trim().to_string()
}

/// Build the DB size commands for a VM based on its databases
fn build_db_commands(ip: &str, databases: &[DatabaseEntry]) -> String {
    let mut cmds = String::new();
    for db in databases.iter().filter(|d| d.enabled && d.wg_ip == ip) {
        let svc = &db.service;
        let ctr = &db.container;
        let user = db.user.as_deref().unwrap_or("postgres");
        let dbname = db.db.as_deref().unwrap_or(&db.service);

        cmds.push_str(&format!("echo \"===DB_SIZE_{}===\"\n", svc));
        match db.db_type.as_str() {
            "postgres" => {
                cmds.push_str(&format!(
                    "docker exec {} psql -U {} -t -c \"SELECT pg_size_pretty(pg_database_size('{}'))\" 2>/dev/null | tr -d ' ' || echo 'N/A'\n",
                    ctr, user, dbname
                ));
            }
            "mariadb" => {
                cmds.push_str(&format!(
                    "docker exec {} mysql -u{} -e \"SELECT ROUND(SUM(data_length + index_length) / 1024 / 1024, 2) AS 'MB' FROM information_schema.tables WHERE table_schema='{}'\" -s -N 2>/dev/null | awk '{{print $1 \" MB\"}}' || echo 'N/A'\n",
                    ctr, user, dbname
                ));
            }
            "sqlite" => {
                cmds.push_str(&format!(
                    "docker exec {} sh -c 'find /data /app /config /home -maxdepth 3 \\( -name \"*.db\" -o -name \"*.sqlite\" -o -name \"*.sqlite3\" \\) 2>/dev/null | head -1 | xargs ls -lh 2>/dev/null | awk \"{{print \\$5}}\"' || echo 'N/A'\n",
                    ctr
                ));
            }
            "redis" => {
                cmds.push_str(&format!(
                    "docker exec {} sh -c 'redis-cli INFO memory 2>/dev/null | grep used_memory_human | cut -d: -f2 | tr -d \"\\r\" || redis-cli DBSIZE 2>/dev/null | awk \"{{print \\$2 \\\" keys\\\"}}\"' || echo 'N/A'\n",
                    ctr
                ));
            }
            "s3" => {
                // MinIO: get total disk usage from the data volume
                cmds.push_str(&format!(
                    "docker exec {} sh -c 'du -sh /data 2>/dev/null | cut -f1' || echo 'N/A'\n",
                    ctr
                ));
            }
            "loki" | "mimir" | "tempo" | "grafana" => {
                // LGTM stack: measure the data directory size inside the container
                let data_path = match db.db_type.as_str() {
                    "loki" => "/loki",
                    "tempo" => "/var/tempo",
                    "mimir" => "/data",
                    "grafana" => "/var/lib/grafana",
                    _ => "/data",
                };
                cmds.push_str(&format!(
                    "docker exec {} sh -c 'du -sh {} 2>/dev/null | cut -f1' || echo 'N/A'\n",
                    ctr, data_path
                ));
            }
            "custom" => {
                // Custom: try common data paths
                cmds.push_str(&format!(
                    "docker exec {} sh -c 'du -sh /data 2>/dev/null || du -sh /var/lib 2>/dev/null' | cut -f1 || echo 'N/A'\n",
                    ctr
                ));
            }
            _ => {
                cmds.push_str("echo 'N/A'\n");
            }
        }
    }
    cmds
}

/// Collect all data from a single VM via SSH batch command
pub async fn collect_vm(vm: &VmTarget, databases: &[DatabaseEntry]) -> VmData {
    let db_cmds = build_db_commands(&vm.ip, databases);
    let mail_cmds = if vm.name == "oci-mail" {
        r#"
echo "===MAIL_QUEUE==="
docker exec maddy maddy queue list 2>/dev/null | wc -l || echo "0"
echo "===MAIL_DELIVERED==="
docker logs maddy --since 24h 2>/dev/null | grep -c "delivered" || echo "0"
echo "===MAIL_FAILED==="
docker logs maddy --since 24h 2>/dev/null | grep -c "failed\|bounced" || echo "0"
echo "===IMAP_CHECK==="
echo "a001 CAPABILITY" | timeout 3 openssl s_client -connect localhost:993 -quiet 2>/dev/null | head -3 || echo "FAIL"
echo "===SMTP25_BANNER==="
echo QUIT | timeout 3 nc -w3 localhost 25 2>&1 | head -1 || echo "FAIL"
echo "===MAIL_PORTS==="
ss -tlnp 2>/dev/null | grep -E ':(25|143|465|587|993|4190|8888)\s' || echo "(none)"
echo "===MADDY_ACCOUNTS==="
docker exec maddy maddy creds list 2>/dev/null | wc -l || echo "0"
echo "===MADDY_DOMAINS==="
docker exec maddy grep 'local_domains' /data/maddy.conf 2>/dev/null | head -5 || echo "N/A"
echo "===WEBMAIL_INTERNAL==="
curl -skL -o /dev/null -w '%{http_code}' --max-time 3 http://localhost:8888/ 2>&1 || echo "0"
"#
    } else {
        ""
    };

    let script = format!(
        r#"
export PATH="/run/current-system/sw/bin:/usr/bin:/usr/local/bin:$PATH"
echo "===UPTIME==="
uptime -p 2>/dev/null || uptime 2>/dev/null || echo "N/A"
echo "===LOAD==="
cat /proc/loadavg 2>/dev/null | awk '{{print $1, $2, $3}}' || echo "N/A"
echo "===DISK==="
df -h / 2>/dev/null | awk 'NR==2 {{print $3 "/" $2 " (" $5 ")"}}'  || echo "N/A"
echo "===DISK_PCT==="
df / 2>/dev/null | awk 'NR==2 {{gsub(/%/,"",$5); print $5}}' || echo "0"
echo "===MEM==="
free -h 2>/dev/null | awk '/Mem:/ {{print $3 "/" $2}}' || echo "N/A"
echo "===MEM_PCT==="
free 2>/dev/null | awk '/Mem:/ {{printf "%.0f\n", ($3/$2)*100}}' || echo "0"
echo "===CONTAINER_COUNTS==="
R=$(docker ps -q 2>/dev/null | wc -l)
T=$(docker ps -aq 2>/dev/null | wc -l)
U=$(docker ps --filter health=unhealthy -q 2>/dev/null | wc -l)
echo "$R|$T|$U"
echo "===UNHEALTHY==="
docker ps --filter health=unhealthy --format '{{{{.Names}}}}' 2>/dev/null
echo "===EXITED==="
docker ps -a --filter status=exited --format '{{{{.Names}}}}' 2>/dev/null | head -10
echo "===CONTAINER_STATS==="
timeout 8 docker stats --no-stream --format '{{{{.Name}}}}|{{{{.CPUPerc}}}}|{{{{.MemUsage}}}}|{{{{.MemPerc}}}}' 2>/dev/null | sort -t'|' -k2 -rn || echo ""
echo "===CONTAINER_FULL==="
docker ps -a --format '{{{{.Names}}}}|{{{{.Image}}}}|{{{{.Status}}}}|{{{{.RunningFor}}}}' 2>/dev/null | while IFS='|' read n i s r; do
  created=$(docker inspect --format '{{{{.Created}}}}' "$i" 2>/dev/null | cut -dT -f1 || echo "?")
  echo "$n|$i|$s|$r|$created"
done || echo ""
echo "===WG_PEERS==="
sudo wg show wg0 latest-handshakes 2>/dev/null || echo ""
echo "===DOCKER_DF==="
docker system df --format '{{{{.Type}}}}|{{{{.TotalCount}}}}|{{{{.Size}}}}|{{{{.Reclaimable}}}}' 2>/dev/null || echo ""
echo "===SSH_ACCEPT==="
journalctl -u ssh --since '24 hours ago' 2>/dev/null | grep -c 'Accepted' || echo 0
echo "===SSH_FAIL==="
journalctl -u ssh --since '24 hours ago' 2>/dev/null | grep -c 'Failed' || echo 0
echo "===SUDO==="
journalctl --since '24 hours ago' 2>/dev/null | grep -c 'sudo:' || echo 0
echo "===TOP_FAIL_IPS==="
journalctl -u ssh --since '24 hours ago' 2>/dev/null | grep 'Failed' | awk '{{for(i=1;i<=NF;i++) if($i ~ /[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/) print $i}}' | sort | uniq -c | sort -rn | head -5 | awk '{{print $2 "|" $1}}'
echo "===RESTARTS==="
journalctl -u docker --since '24 hours ago' 2>/dev/null | grep 'Container.*Started' | awk '{{print $NF}}' | sort | uniq -c | sort -rn | head -5 | awk '{{print $2 "|" $1}}'
echo "===BACKUPS==="
find /opt/backups/ -maxdepth 2 -type f -printf '%T@ %s %p\n' 2>/dev/null | sort -rn | head -15 || echo ""
echo "===OOM_KILLS==="
dmesg 2>/dev/null | grep -i 'oom\|out of memory' | tail -5 || journalctl -k --since '7 days ago' 2>/dev/null | grep -i oom | tail -5 || echo ""
echo "===SWAP==="
free 2>/dev/null | awk '/Swap:/ {{total=$2; used=$3; if(total>0) printf "%s|%s|%.0f\n", used, total, (used/total)*100; else print "0|0|0"}}'
echo "===LOG_ERRORS==="
timeout 20 sh -c 'docker ps -q 2>/dev/null | while read id; do
  name=$(docker inspect --format "{{{{.Name}}}}" "$id" 2>/dev/null | tr -d "/")
  count=$(timeout 3 docker logs --since 24h "$id" 2>&1 | grep -ci "error\|fatal\|panic" || echo 0)
  [ "$count" -gt 0 ] && echo "$name|$count"
done | sort -t"|" -k2 -rn | head -10' 2>/dev/null || echo ""
echo "===FAILED_UNITS==="
systemctl --failed --no-legend 2>/dev/null | head -5 | awk '{{print $1}}'
echo "===RUNTIME_VOLUMES==="
timeout 20 sh -c '
names=$(docker volume ls -q 2>/dev/null)
[ -z "$names" ] && exit 0
docker volume inspect $names --format "{{{{.Name}}}}|{{{{.Mountpoint}}}}" 2>/dev/null > /tmp/vols.txt
cut -d"|" -f2 /tmp/vols.txt | xargs -r du -sh 2>/dev/null > /tmp/sizes.txt
while IFS="|" read name mp; do
  sz=$(grep -F "$mp" /tmp/sizes.txt 2>/dev/null | cut -f1 || echo "?")
  echo "$name|$sz"
done < /tmp/vols.txt
rm -f /tmp/vols.txt /tmp/sizes.txt
' 2>/dev/null || echo ""
echo "===RUNTIME_CONTAINERS_WITH_VOLUMES==="
timeout 10 sh -c 'docker ps -a --format "{{{{.Names}}}}" 2>/dev/null | while read ctr; do
  mounts=$(docker inspect "$ctr" --format "{{{{range .Mounts}}}}{{{{.Name}}}}={{{{.Destination}}}} {{{{end}}}}" 2>/dev/null | tr -d "\n")
  [ -n "$mounts" ] && echo "$ctr|$mounts"
done' 2>/dev/null || echo ""
echo "===KERNEL==="
uname -r 2>/dev/null || echo "?"
echo "===WG_TRANSFER==="
sudo wg show wg0 transfer 2>/dev/null || echo ""
{db_cmds}
{mail_cmds}
echo "===END==="
"#
    );

    let raw = match ssh_exec(&vm.name, &vm.user, &vm.ip, &script).await {
        Ok(r) => {
            eprintln!("  SSH {} OK ({} bytes)", vm.name, r.len());
            // Phase 2: side-effect — materialise raw evidence on disk so
            // reports-logs/dist/vms/<vm>/ is populated as a byproduct of
            // the report's analysis SSH. Eliminates the bash collector's
            // duplicate SSH for the same data. Best-effort, non-fatal.
            crate::evidence::write_vm_evidence(&vm.name, &r, true);
            r
        }
        Err(e) => {
            eprintln!("  SSH {} full batch FAILED: {} — trying lightweight fallback", vm.name, e);
            // Lightweight fallback: basic health + container stats (critical for report)
            let fallback_script = r#"
export PATH="/run/current-system/sw/bin:/usr/bin:/usr/local/bin:$PATH"
echo "===UPTIME==="
uptime -p 2>/dev/null || uptime 2>/dev/null || echo "N/A"
echo "===LOAD==="
cat /proc/loadavg 2>/dev/null | awk '{print $1, $2, $3}' || echo "N/A"
echo "===DISK==="
df -h / 2>/dev/null | awk 'NR==2 {print $3 "/" $2 " (" $5 ")"}'  || echo "N/A"
echo "===DISK_PCT==="
df / 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5}' || echo "0"
echo "===MEM==="
free -h 2>/dev/null | awk '/Mem:/ {print $3 "/" $2}' || echo "N/A"
echo "===MEM_PCT==="
free 2>/dev/null | awk '/Mem:/ {printf "%.0f\n", ($3/$2)*100}' || echo "0"
echo "===CONTAINER_COUNTS==="
R=$(docker ps -q 2>/dev/null | wc -l); T=$(docker ps -aq 2>/dev/null | wc -l); U=$(docker ps --filter health=unhealthy -q 2>/dev/null | wc -l); echo "$R|$T|$U"
echo "===UNHEALTHY==="
docker ps --filter health=unhealthy --format '{{.Names}}' 2>/dev/null
echo "===EXITED==="
docker ps -a --filter status=exited --format '{{.Names}}' 2>/dev/null | head -10
echo "===CONTAINER_STATS==="
timeout 12 docker stats --no-stream --format '{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}|{{.MemPerc}}' 2>/dev/null | sort -t'|' -k2 -rn || echo ""
echo "===CONTAINER_FULL==="
docker ps -a --format '{{.Names}}|{{.Image}}|{{.Status}}|{{.RunningFor}}' 2>/dev/null | while IFS='|' read n i s r; do
  created=$(docker inspect --format '{{.Created}}' "$i" 2>/dev/null | cut -dT -f1 || echo "?")
  echo "$n|$i|$s|$r|$created"
done || echo ""
echo "===KERNEL==="
uname -r 2>/dev/null || echo "?"
echo "===SWAP==="
free 2>/dev/null | awk '/Swap:/ {total=$2; used=$3; if(total>0) printf "%s|%s|%.0f\n", used, total, (used/total)*100; else print "0|0|0"}'
echo "===END==="
"#;
            match ssh_exec(&vm.name, &vm.user, &vm.ip, fallback_script).await {
                Ok(r) => {
                    eprintln!("  SSH {} fallback OK ({} bytes)", vm.name, r.len());
                    // Same evidence side-effect on the fallback path —
                    // partial sections still better than none for debug.
                    crate::evidence::write_vm_evidence(&vm.name, &r, true);
                    r
                }
                Err(e2) => {
                    eprintln!("  SSH {} UNREACHABLE: {}", vm.name, e2);
                    // Mark unreachable in evidence so reports-logs index
                    // tags this VM with state:unreachable for debug context.
                    crate::evidence::write_vm_evidence(&vm.name, "", false);
                    return VmData {
                        name: vm.name.clone(),
                        ip: vm.ip.clone(),
                        status: VmStatus::Critical,
                        ..Default::default()
                    };
                }
            }
        }
    };

    let mut data = VmData {
        name: vm.name.clone(),
        ip: vm.ip.clone(),
        ..Default::default()
    };

    data.uptime = section(&raw, "UPTIME", "LOAD");
    if data.uptime.is_empty() { data.uptime = "N/A".into(); }
    data.load = section(&raw, "LOAD", "DISK");
    if data.load.is_empty() { data.load = "N/A".into(); }
    data.disk = section(&raw, "DISK", "DISK_PCT");
    if data.disk.is_empty() { data.disk = "N/A".into(); }
    data.disk_pct = section(&raw, "DISK_PCT", "MEM").parse().unwrap_or(0);
    data.mem = section(&raw, "MEM", "MEM_PCT");
    if data.mem.is_empty() { data.mem = "N/A".into(); }
    data.mem_pct = section(&raw, "MEM_PCT", "CONTAINER_COUNTS").parse().unwrap_or(0);

    // Container counts
    let counts = section(&raw, "CONTAINER_COUNTS", "UNHEALTHY");
    if let Some(line) = counts.lines().next() {
        let parts: Vec<&str> = line.split('|').collect();
        if parts.len() >= 3 {
            data.containers_running = parts[0].trim().parse().unwrap_or(0);
            data.containers_total = parts[1].trim().parse().unwrap_or(0);
            data.containers_unhealthy = parts[2].trim().parse().unwrap_or(0);
        }
    }

    // Unhealthy / exited
    data.unhealthy_names = section(&raw, "UNHEALTHY", "EXITED")
        .lines().filter(|l| !l.is_empty()).map(|l| l.trim().to_string()).collect();
    data.exited_names = section(&raw, "EXITED", "CONTAINER_COUNTS")
        .lines().filter(|l| !l.is_empty()).map(|l| l.trim().to_string()).collect();

    // Container stats (top CPU/mem)
    for line in section(&raw, "CONTAINER_STATS", "CONTAINER_FULL").lines() {
        let parts: Vec<&str> = line.split('|').collect();
        if parts.len() >= 4 {
            data.container_stats.push(ContainerStat {
                name: parts[0].to_string(),
                cpu: parts[1].to_string(),
                mem_usage: parts[2].to_string(),
                mem_pct: parts[3].to_string(),
            });
        }
    }

    // Full container list (with optional image_created as 5th field)
    for line in section(&raw, "CONTAINER_FULL", "WG_PEERS").lines() {
        let parts: Vec<&str> = line.split('|').collect();
        if parts.len() >= 4 {
            data.container_list.push(ContainerInfo {
                name: parts[0].to_string(),
                image: parts[1].to_string(),
                status: parts[2].to_string(),
                running_for: parts[3].to_string(),
                image_created: parts.get(4).unwrap_or(&"?").to_string(),
            });
        }
    }

    // WG peers
    for line in section(&raw, "WG_PEERS", "DOCKER_DF").lines() {
        let parts: Vec<&str> = line.split_whitespace().collect();
        if parts.len() >= 2 {
            let ts: u64 = parts[1].parse().unwrap_or(0);
            data.wg_peers.push((parts[0].to_string(), ts));
        }
    }

    // Docker DF
    for line in section(&raw, "DOCKER_DF", "SSH_ACCEPT").lines() {
        let parts: Vec<&str> = line.split('|').collect();
        if parts.len() >= 4 {
            data.docker_df.push(DockerDfEntry {
                dtype: parts[0].to_string(),
                count: parts[1].to_string(),
                size: parts[2].to_string(),
                reclaimable: parts[3].to_string(),
            });
        }
    }

    // Security events
    data.ssh_accepts = section(&raw, "SSH_ACCEPT", "SSH_FAIL").trim().parse().unwrap_or(0);
    data.ssh_fails = section(&raw, "SSH_FAIL", "SUDO").trim().parse().unwrap_or(0);
    data.sudo_count = section(&raw, "SUDO", "TOP_FAIL_IPS").trim().parse().unwrap_or(0);

    for line in section(&raw, "TOP_FAIL_IPS", "RESTARTS").lines() {
        let parts: Vec<&str> = line.split('|').collect();
        if parts.len() >= 2 {
            data.top_fail_ips.push((
                parts[0].to_string(),
                parts[1].trim().parse().unwrap_or(0),
            ));
        }
    }

    for line in section(&raw, "RESTARTS", "BACKUPS").lines() {
        let parts: Vec<&str> = line.split('|').collect();
        if parts.len() >= 2 {
            data.restarts.push((
                parts[0].to_string(),
                parts[1].trim().parse().unwrap_or(0),
            ));
        }
    }

    // Backups
    for line in section(&raw, "BACKUPS", "FAILED_UNITS").lines() {
        let parts: Vec<&str> = line.split_whitespace().collect();
        if parts.len() >= 3 {
            data.backups.push(BackupEntry {
                epoch: parts[0].parse().unwrap_or(0.0),
                size_bytes: parts[1].parse().unwrap_or(0),
                file: std::path::Path::new(parts[2])
                    .file_name()
                    .map(|f| f.to_string_lossy().to_string())
                    .unwrap_or_else(|| parts[2].to_string()),
            });
        }
    }

    // Failed units — section ends at next === marker (DB_SIZE_ or MAIL_ or END)
    let fu_start = "===FAILED_UNITS===";
    data.failed_units = raw.lines()
        .skip_while(|l| l.trim() != fu_start)
        .skip(1)
        .take_while(|l| !l.trim().starts_with("==="))
        .filter(|l| !l.trim().is_empty())
        .map(|l| l.trim().to_string())
        .collect();

    // DB sizes — parse ===DB_SIZE_xxx=== markers individually
    for db in databases.iter().filter(|d| d.enabled && d.wg_ip == vm.ip) {
        let marker = format!("===DB_SIZE_{}===", db.service);
        let size = raw.lines()
            .skip_while(|l| l.trim() != marker)
            .skip(1) // skip the marker itself
            .take_while(|l| !l.trim().starts_with("==="))
            .find(|l| !l.trim().is_empty())
            .map(|l| l.trim().to_string())
            .unwrap_or_else(|| "N/A".into());
        data.db_sizes.push((db.service.clone(), size));
    }

    // Mail data
    if vm.name == "oci-mail" {
        data.mail_queue = Some(section(&raw, "MAIL_QUEUE", "MAIL_DELIVERED").trim().parse().unwrap_or(0));
        data.mail_delivered = Some(section(&raw, "MAIL_DELIVERED", "MAIL_FAILED").trim().parse().unwrap_or(0));
        data.mail_failed = Some(section(&raw, "MAIL_FAILED", "IMAP_CHECK").trim().parse().unwrap_or(0));
        data.imap_check = section(&raw, "IMAP_CHECK", "SMTP25_BANNER");
        data.smtp25_banner = section(&raw, "SMTP25_BANNER", "MAIL_PORTS");
        data.mail_ports_bound = section(&raw, "MAIL_PORTS", "MADDY_ACCOUNTS");
        data.maddy_accounts = section(&raw, "MADDY_ACCOUNTS", "MADDY_DOMAINS").trim().parse().unwrap_or(0);
        data.maddy_domains = section(&raw, "MADDY_DOMAINS", "WEBMAIL_INTERNAL");
        data.webmail_internal_code = section(&raw, "WEBMAIL_INTERNAL", "END").trim().parse().unwrap_or(0);
    }

    // Runtime volumes — first parse sizes from RUNTIME_VOLUMES
    let mut vol_sizes: std::collections::HashMap<String, String> = std::collections::HashMap::new();
    for line in raw.lines()
        .skip_while(|l| l.trim() != "===RUNTIME_VOLUMES===")
        .skip(1)
        .take_while(|l| !l.trim().starts_with("==="))
    {
        let parts: Vec<&str> = line.splitn(2, '|').collect();
        if parts.len() >= 2 && !parts[0].is_empty() {
            vol_sizes.insert(parts[0].to_string(), parts[1].trim().to_string());
        }
    }

    // Then parse container→volume mappings and attach sizes
    for line in raw.lines()
        .skip_while(|l| l.trim() != "===RUNTIME_CONTAINERS_WITH_VOLUMES===")
        .skip(1)
        .take_while(|l| !l.trim().starts_with("==="))
    {
        let parts: Vec<&str> = line.splitn(2, '|').collect();
        if parts.len() < 2 { continue; }
        let container = parts[0].to_string();
        for mount in parts[1].split_whitespace() {
            let mp: Vec<&str> = mount.splitn(2, '=').collect();
            if mp.len() == 2 && !mp[0].is_empty() {
                let vol_name = mp[0].to_string();
                let size = vol_sizes.get(&vol_name).cloned().unwrap_or_default();
                data.runtime_volumes.push(RuntimeVolume {
                    name: vol_name,
                    size,
                    container: container.clone(),
                    mount_point: mp[1].to_string(),
                });
            }
        }
    }

    // Also add volumes that have sizes but no container mapping (orphaned volumes)
    let mapped_vols: std::collections::HashSet<String> = data.runtime_volumes.iter()
        .map(|v| v.name.clone()).collect();
    for (name, size) in &vol_sizes {
        if !mapped_vols.contains(name) {
            data.runtime_volumes.push(RuntimeVolume {
                name: name.clone(),
                size: size.clone(),
                container: "(orphan)".into(),
                mount_point: String::new(),
            });
        }
    }

    // OOM kills
    data.oom_kills = section(&raw, "OOM_KILLS", "SWAP")
        .lines()
        .filter(|l| !l.trim().is_empty())
        .map(|l| l.trim().to_string())
        .collect();

    // Swap usage
    let swap_line = section(&raw, "SWAP", "LOG_ERRORS");
    if let Some(line) = swap_line.lines().next() {
        let parts: Vec<&str> = line.split('|').collect();
        if parts.len() >= 3 {
            let used: u64 = parts[0].trim().parse().unwrap_or(0);
            let total: u64 = parts[1].trim().parse().unwrap_or(0);
            data.swap_pct = parts[2].trim().parse().unwrap_or(0);
            if total > 0 {
                data.swap = format!("{}M/{}M", used / 1024, total / 1024);
            } else {
                data.swap = "N/A".into();
            }
        }
    }

    // Log errors
    for line in section(&raw, "LOG_ERRORS", "FAILED_UNITS").lines() {
        let parts: Vec<&str> = line.split('|').collect();
        if parts.len() >= 2 {
            let name = parts[0].to_string();
            let count: u32 = parts[1].trim().parse().unwrap_or(0);
            if count > 0 {
                data.log_errors.push((name, count));
            }
        }
    }

    // Kernel version
    data.kernel = section(&raw, "KERNEL", "WG_TRANSFER");
    if data.kernel.is_empty() { data.kernel = "?".into(); }

    // WireGuard transfer stats — section ends at next === marker (DB_SIZE_, MAIL_, or END)
    for line in section(&raw, "WG_TRANSFER", "END").lines() {
        if line.trim().is_empty() { continue; }
        let parts: Vec<&str> = line.split_whitespace().collect();
        if parts.len() >= 3 {
            data.wg_transfer.push(WgTransfer {
                peer: parts[0].to_string(),
                rx_bytes: parts[1].parse().unwrap_or(0),
                tx_bytes: parts[2].parse().unwrap_or(0),
            });
        }
    }

    // Derive status
    data.status = if data.disk_pct > 90 || data.mem_pct > 90 || data.containers_unhealthy > 0 {
        VmStatus::Critical
    } else if data.disk_pct > 75 || data.mem_pct > 75 {
        VmStatus::Warning
    } else {
        VmStatus::Healthy
    };

    data
}
