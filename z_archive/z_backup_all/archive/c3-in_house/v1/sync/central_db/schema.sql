-- =============================================================================
-- CENTRAL SECURITY DATABASE SCHEMA
-- =============================================================================
-- Database: SQLite (/var/siem/security.db)
-- Purpose: Consolidated security logs from all VMs
-- Version: 1.0.0
-- Updated: 2025-12-23
-- =============================================================================

-- Enable WAL mode for better concurrent access
PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;
PRAGMA foreign_keys = ON;

-- =============================================================================
-- REFERENCE TABLES
-- =============================================================================

-- VM Registry (Source of truth for VM metadata)
CREATE TABLE IF NOT EXISTS vms (
    id              INTEGER PRIMARY KEY,
    vm_id           TEXT UNIQUE NOT NULL,           -- e.g., 'oci-f-micro_1'
    display_name    TEXT NOT NULL,                   -- e.g., 'OCI Free Micro 1'
    provider        TEXT NOT NULL,                   -- 'oracle' | 'gcloud'
    public_ip       TEXT,
    private_ip      TEXT,
    os_name         TEXT,
    os_version      TEXT,
    last_seen       TEXT,                            -- ISO8601 timestamp
    status          TEXT DEFAULT 'unknown',          -- 'active' | 'inactive' | 'unknown'
    created_at      TEXT DEFAULT (datetime('now'))
);

-- Insert known VMs
INSERT OR IGNORE INTO vms (vm_id, display_name, provider, public_ip, os_name, os_version) VALUES
    ('oci-f-micro_1', 'OCI Free Micro 1', 'oracle', '130.110.251.193', 'Ubuntu', '24.04 LTS'),
    ('oci-f-micro_2', 'OCI Free Micro 2', 'oracle', '129.151.228.66', 'Ubuntu', '24.04 LTS'),
    ('gcp-f-micro_1', 'GCP Free Micro 1', 'gcloud', '34.55.55.234', 'Arch Linux', 'rolling'),
    ('oci-p-flex_1', 'OCI Paid Flex 1', 'oracle', '84.235.234.87', 'Ubuntu', '22.04 Minimal');

-- Severity levels
CREATE TABLE IF NOT EXISTS severity_levels (
    id      INTEGER PRIMARY KEY,
    name    TEXT UNIQUE NOT NULL,
    weight  INTEGER NOT NULL,           -- For sorting/filtering
    color   TEXT                        -- For UI display
);

INSERT OR IGNORE INTO severity_levels (id, name, weight, color) VALUES
    (1, 'debug', 10, '#808080'),
    (2, 'info', 20, '#0066cc'),
    (3, 'notice', 30, '#00cc66'),
    (4, 'warning', 40, '#ffcc00'),
    (5, 'error', 50, '#ff6600'),
    (6, 'critical', 60, '#ff0000'),
    (7, 'alert', 70, '#cc0066'),
    (8, 'emergency', 80, '#990000');

-- Log categories
CREATE TABLE IF NOT EXISTS log_categories (
    id      INTEGER PRIMARY KEY,
    name    TEXT UNIQUE NOT NULL,
    description TEXT
);

INSERT OR IGNORE INTO log_categories (name, description) VALUES
    ('auth', 'Authentication events (SSH, sudo, login)'),
    ('firewall', 'Firewall blocks and allows'),
    ('docker', 'Docker container events'),
    ('system', 'System events (boot, shutdown, services)'),
    ('file', 'File integrity monitoring'),
    ('yara', 'YARA rule matches'),
    ('network', 'Network connections and traffic'),
    ('app', 'Application-specific logs'),
    ('audit', 'Audit trail events');

-- =============================================================================
-- MAIN TABLES
-- =============================================================================

-- Security Alerts (Primary table for YARA, file changes, etc.)
CREATE TABLE IF NOT EXISTS alerts (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp       TEXT NOT NULL,                   -- ISO8601: '2025-12-23T14:30:00Z'
    received_at     TEXT DEFAULT (datetime('now')),  -- When central received it
    vm_id           TEXT NOT NULL,                   -- FK to vms.vm_id
    severity        TEXT NOT NULL DEFAULT 'info',    -- FK to severity_levels.name
    category        TEXT NOT NULL DEFAULT 'system',  -- FK to log_categories.name
    source          TEXT,                            -- 'sauron' | 'yara' | 'auditd' | etc.
    rule            TEXT,                            -- Rule name if applicable
    file_path       TEXT,                            -- Affected file path
    file_hash       TEXT,                            -- SHA256 of file
    message         TEXT,                            -- Human-readable description
    raw_json        TEXT,                            -- Original JSON payload
    acknowledged    INTEGER DEFAULT 0,               -- 0=unread, 1=ack'd
    resolved        INTEGER DEFAULT 0,               -- 0=open, 1=resolved
    notes           TEXT,                            -- Analyst notes

    FOREIGN KEY (vm_id) REFERENCES vms(vm_id)
);

-- Auth Events (SSH, sudo, login failures)
CREATE TABLE IF NOT EXISTS auth_events (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp       TEXT NOT NULL,
    received_at     TEXT DEFAULT (datetime('now')),
    vm_id           TEXT NOT NULL,
    event_type      TEXT NOT NULL,                   -- 'ssh_login' | 'ssh_fail' | 'sudo' | 'su'
    username        TEXT,
    source_ip       TEXT,
    source_port     INTEGER,
    success         INTEGER,                         -- 0=fail, 1=success
    method          TEXT,                            -- 'password' | 'publickey' | 'keyboard-interactive'
    session_id      TEXT,
    message         TEXT,
    raw_json        TEXT,

    FOREIGN KEY (vm_id) REFERENCES vms(vm_id)
);

-- Firewall Events (UFW/iptables)
CREATE TABLE IF NOT EXISTS firewall_events (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp       TEXT NOT NULL,
    received_at     TEXT DEFAULT (datetime('now')),
    vm_id           TEXT NOT NULL,
    action          TEXT NOT NULL,                   -- 'BLOCK' | 'ALLOW'
    protocol        TEXT,                            -- 'TCP' | 'UDP' | 'ICMP'
    src_ip          TEXT,
    src_port        INTEGER,
    dst_ip          TEXT,
    dst_port        INTEGER,
    interface       TEXT,
    rule_id         TEXT,
    raw_json        TEXT,

    FOREIGN KEY (vm_id) REFERENCES vms(vm_id)
);

-- Docker Events (container lifecycle)
CREATE TABLE IF NOT EXISTS docker_events (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp       TEXT NOT NULL,
    received_at     TEXT DEFAULT (datetime('now')),
    vm_id           TEXT NOT NULL,
    event_type      TEXT NOT NULL,                   -- 'start' | 'stop' | 'die' | 'create' | 'destroy'
    container_id    TEXT,
    container_name  TEXT,
    image           TEXT,
    exit_code       INTEGER,
    attributes      TEXT,                            -- JSON of additional attributes
    raw_json        TEXT,

    FOREIGN KEY (vm_id) REFERENCES vms(vm_id)
);

-- System Events (boot, services, kernel)
CREATE TABLE IF NOT EXISTS system_events (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp       TEXT NOT NULL,
    received_at     TEXT DEFAULT (datetime('now')),
    vm_id           TEXT NOT NULL,
    event_type      TEXT NOT NULL,                   -- 'boot' | 'shutdown' | 'service' | 'kernel' | 'oom'
    service_name    TEXT,
    status          TEXT,                            -- 'started' | 'stopped' | 'failed'
    pid             INTEGER,
    message         TEXT,
    raw_json        TEXT,

    FOREIGN KEY (vm_id) REFERENCES vms(vm_id)
);

-- Heartbeats (Agent check-ins)
CREATE TABLE IF NOT EXISTS heartbeats (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp       TEXT NOT NULL,
    vm_id           TEXT NOT NULL,
    agent_version   TEXT,
    uptime_seconds  INTEGER,
    load_avg        REAL,
    memory_used_mb  INTEGER,
    memory_total_mb INTEGER,
    disk_used_gb    REAL,
    disk_total_gb   REAL,
    docker_containers INTEGER,

    FOREIGN KEY (vm_id) REFERENCES vms(vm_id)
);

-- =============================================================================
-- INDEXES
-- =============================================================================

-- Alerts
CREATE INDEX IF NOT EXISTS idx_alerts_timestamp ON alerts(timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_alerts_vm_id ON alerts(vm_id);
CREATE INDEX IF NOT EXISTS idx_alerts_severity ON alerts(severity);
CREATE INDEX IF NOT EXISTS idx_alerts_category ON alerts(category);
CREATE INDEX IF NOT EXISTS idx_alerts_acknowledged ON alerts(acknowledged);
CREATE INDEX IF NOT EXISTS idx_alerts_composite ON alerts(vm_id, severity, timestamp DESC);

-- Auth events
CREATE INDEX IF NOT EXISTS idx_auth_timestamp ON auth_events(timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_auth_vm_id ON auth_events(vm_id);
CREATE INDEX IF NOT EXISTS idx_auth_success ON auth_events(success);
CREATE INDEX IF NOT EXISTS idx_auth_source_ip ON auth_events(source_ip);
CREATE INDEX IF NOT EXISTS idx_auth_composite ON auth_events(vm_id, event_type, timestamp DESC);

-- Firewall events
CREATE INDEX IF NOT EXISTS idx_fw_timestamp ON firewall_events(timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_fw_vm_id ON firewall_events(vm_id);
CREATE INDEX IF NOT EXISTS idx_fw_action ON firewall_events(action);
CREATE INDEX IF NOT EXISTS idx_fw_src_ip ON firewall_events(src_ip);
CREATE INDEX IF NOT EXISTS idx_fw_dst_port ON firewall_events(dst_port);

-- Docker events
CREATE INDEX IF NOT EXISTS idx_docker_timestamp ON docker_events(timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_docker_vm_id ON docker_events(vm_id);
CREATE INDEX IF NOT EXISTS idx_docker_container ON docker_events(container_name);
CREATE INDEX IF NOT EXISTS idx_docker_event_type ON docker_events(event_type);

-- System events
CREATE INDEX IF NOT EXISTS idx_system_timestamp ON system_events(timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_system_vm_id ON system_events(vm_id);
CREATE INDEX IF NOT EXISTS idx_system_event_type ON system_events(event_type);

-- Heartbeats
CREATE INDEX IF NOT EXISTS idx_heartbeat_timestamp ON heartbeats(timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_heartbeat_vm_id ON heartbeats(vm_id);

-- =============================================================================
-- VIEWS
-- =============================================================================

-- Recent critical alerts (last 24h)
CREATE VIEW IF NOT EXISTS v_critical_alerts AS
SELECT
    a.id,
    a.timestamp,
    v.display_name as vm_name,
    a.severity,
    a.category,
    a.source,
    a.rule,
    a.file_path,
    a.message,
    a.acknowledged
FROM alerts a
JOIN vms v ON a.vm_id = v.vm_id
WHERE a.severity IN ('critical', 'alert', 'emergency')
  AND a.timestamp > datetime('now', '-1 day')
ORDER BY a.timestamp DESC;

-- Failed SSH attempts (last 24h)
CREATE VIEW IF NOT EXISTS v_failed_ssh AS
SELECT
    ae.timestamp,
    v.display_name as vm_name,
    ae.username,
    ae.source_ip,
    ae.method,
    ae.message
FROM auth_events ae
JOIN vms v ON ae.vm_id = v.vm_id
WHERE ae.event_type = 'ssh_fail'
  AND ae.success = 0
  AND ae.timestamp > datetime('now', '-1 day')
ORDER BY ae.timestamp DESC;

-- Blocked IPs summary
CREATE VIEW IF NOT EXISTS v_blocked_ips AS
SELECT
    src_ip,
    COUNT(*) as block_count,
    GROUP_CONCAT(DISTINCT vm_id) as vms_affected,
    MAX(timestamp) as last_seen,
    MIN(timestamp) as first_seen
FROM firewall_events
WHERE action = 'BLOCK'
  AND timestamp > datetime('now', '-7 day')
GROUP BY src_ip
ORDER BY block_count DESC;

-- VM health summary
CREATE VIEW IF NOT EXISTS v_vm_health AS
SELECT
    v.vm_id,
    v.display_name,
    v.public_ip,
    h.timestamp as last_heartbeat,
    h.uptime_seconds,
    h.load_avg,
    h.memory_used_mb,
    h.memory_total_mb,
    ROUND(100.0 * h.memory_used_mb / h.memory_total_mb, 1) as memory_percent,
    h.disk_used_gb,
    h.disk_total_gb,
    ROUND(100.0 * h.disk_used_gb / h.disk_total_gb, 1) as disk_percent,
    h.docker_containers,
    CASE
        WHEN h.timestamp > datetime('now', '-5 minutes') THEN 'healthy'
        WHEN h.timestamp > datetime('now', '-15 minutes') THEN 'warning'
        ELSE 'critical'
    END as health_status
FROM vms v
LEFT JOIN (
    SELECT vm_id, MAX(timestamp) as max_ts
    FROM heartbeats
    GROUP BY vm_id
) latest ON v.vm_id = latest.vm_id
LEFT JOIN heartbeats h ON h.vm_id = latest.vm_id AND h.timestamp = latest.max_ts;

-- Alert counts by VM and severity (last 7 days)
CREATE VIEW IF NOT EXISTS v_alert_summary AS
SELECT
    v.vm_id,
    v.display_name,
    a.severity,
    COUNT(*) as alert_count
FROM vms v
LEFT JOIN alerts a ON v.vm_id = a.vm_id
    AND a.timestamp > datetime('now', '-7 day')
GROUP BY v.vm_id, a.severity
ORDER BY v.vm_id,
    CASE a.severity
        WHEN 'emergency' THEN 1
        WHEN 'alert' THEN 2
        WHEN 'critical' THEN 3
        WHEN 'error' THEN 4
        WHEN 'warning' THEN 5
        ELSE 6
    END;

-- =============================================================================
-- CLEANUP / RETENTION TRIGGERS
-- =============================================================================

-- Auto-cleanup old heartbeats (keep 7 days)
CREATE TRIGGER IF NOT EXISTS cleanup_old_heartbeats
AFTER INSERT ON heartbeats
BEGIN
    DELETE FROM heartbeats
    WHERE timestamp < datetime('now', '-7 day');
END;

-- Auto-cleanup old firewall events (keep 30 days)
CREATE TRIGGER IF NOT EXISTS cleanup_old_firewall
AFTER INSERT ON firewall_events
WHEN (SELECT COUNT(*) FROM firewall_events) > 100000
BEGIN
    DELETE FROM firewall_events
    WHERE timestamp < datetime('now', '-30 day');
END;
