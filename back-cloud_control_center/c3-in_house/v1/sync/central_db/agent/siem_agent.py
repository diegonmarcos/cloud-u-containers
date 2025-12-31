#!/usr/bin/env python3
"""
SIEM Agent - Collects security logs and sends to central server
Runs on each VM, sends via TCP to syslog-ng on central

Version: 1.0.0
Updated: 2025-12-23
"""

import json
import socket
import time
import re
import os
import hashlib
import subprocess
from pathlib import Path
from datetime import datetime, timezone
from typing import Optional, Generator, Dict, Any
from dataclasses import dataclass, asdict
import logging

# Configuration
CONFIG = {
    "vm_id": os.environ.get("SIEM_VM_ID", socket.gethostname()),
    "central_host": os.environ.get("SIEM_CENTRAL_HOST", "central.internal"),
    "central_port": int(os.environ.get("SIEM_CENTRAL_PORT", "5514")),
    "heartbeat_interval": 60,  # seconds
    "batch_size": 100,
    "log_sources": {
        "auth": "/var/log/auth.log",
        "syslog": "/var/log/syslog",
        "ufw": "/var/log/ufw.log",
        "docker": "/var/log/docker.log",
        "journal": "journalctl",  # Special: use journalctl
    },
}

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s"
)
logger = logging.getLogger("siem_agent")


# =============================================================================
# DATA CLASSES
# =============================================================================

@dataclass
class LogEvent:
    """Base log event structure"""
    timestamp: str
    vm_id: str
    category: str
    severity: str
    source: str
    message: str
    raw: Optional[str] = None
    extra: Optional[Dict[str, Any]] = None

    def to_json(self) -> str:
        data = asdict(self)
        if self.extra:
            data.update(self.extra)
            del data["extra"]
        return json.dumps(data, default=str)


@dataclass
class Heartbeat:
    """Agent heartbeat with system metrics"""
    timestamp: str
    vm_id: str
    agent_version: str
    uptime_seconds: int
    load_avg: float
    memory_used_mb: int
    memory_total_mb: int
    disk_used_gb: float
    disk_total_gb: float
    docker_containers: int

    def to_json(self) -> str:
        data = asdict(self)
        data["category"] = "heartbeat"
        return json.dumps(data)


# =============================================================================
# PARSERS
# =============================================================================

class AuthLogParser:
    """Parse /var/log/auth.log for SSH, sudo events"""

    # SSH patterns
    SSH_ACCEPTED = re.compile(
        r'sshd\[(\d+)\]: Accepted (\w+) for (\w+) from ([\d.]+) port (\d+)'
    )
    SSH_FAILED = re.compile(
        r'sshd\[(\d+)\]: Failed (\w+) for (?:invalid user )?(\w+) from ([\d.]+) port (\d+)'
    )
    SSH_DISCONNECT = re.compile(
        r'sshd\[(\d+)\]: Disconnected from.*?([\d.]+)'
    )

    # Sudo patterns
    SUDO_CMD = re.compile(
        r'sudo:\s+(\w+)\s+:.*COMMAND=(.+)'
    )
    SUDO_FAIL = re.compile(
        r'sudo:\s+(\w+)\s+: authentication failure'
    )

    @classmethod
    def parse(cls, line: str, vm_id: str) -> Optional[LogEvent]:
        timestamp = cls._extract_timestamp(line)

        # SSH accepted
        match = cls.SSH_ACCEPTED.search(line)
        if match:
            return LogEvent(
                timestamp=timestamp,
                vm_id=vm_id,
                category="auth",
                severity="info",
                source="sshd",
                message=f"SSH login: {match.group(3)} from {match.group(4)}",
                raw=line,
                extra={
                    "event_type": "ssh_login",
                    "method": match.group(2),
                    "username": match.group(3),
                    "source_ip": match.group(4),
                    "source_port": int(match.group(5)),
                    "success": True,
                    "session_id": match.group(1),
                }
            )

        # SSH failed
        match = cls.SSH_FAILED.search(line)
        if match:
            return LogEvent(
                timestamp=timestamp,
                vm_id=vm_id,
                category="auth",
                severity="warning",
                source="sshd",
                message=f"SSH failed: {match.group(3)} from {match.group(4)}",
                raw=line,
                extra={
                    "event_type": "ssh_fail",
                    "method": match.group(2),
                    "username": match.group(3),
                    "source_ip": match.group(4),
                    "source_port": int(match.group(5)),
                    "success": False,
                    "session_id": match.group(1),
                }
            )

        # Sudo command
        match = cls.SUDO_CMD.search(line)
        if match:
            return LogEvent(
                timestamp=timestamp,
                vm_id=vm_id,
                category="auth",
                severity="info",
                source="sudo",
                message=f"sudo: {match.group(1)} ran {match.group(2)[:50]}",
                raw=line,
                extra={
                    "event_type": "sudo",
                    "username": match.group(1),
                    "command": match.group(2),
                    "success": True,
                }
            )

        # Sudo failure
        match = cls.SUDO_FAIL.search(line)
        if match:
            return LogEvent(
                timestamp=timestamp,
                vm_id=vm_id,
                category="auth",
                severity="warning",
                source="sudo",
                message=f"sudo auth failed: {match.group(1)}",
                raw=line,
                extra={
                    "event_type": "sudo_fail",
                    "username": match.group(1),
                    "success": False,
                }
            )

        return None

    @staticmethod
    def _extract_timestamp(line: str) -> str:
        """Extract and normalize timestamp from syslog line"""
        # Typical format: "Dec 23 14:30:00"
        try:
            parts = line.split()[:3]
            year = datetime.now().year
            dt_str = f"{year} {' '.join(parts)}"
            dt = datetime.strptime(dt_str, "%Y %b %d %H:%M:%S")
            return dt.replace(tzinfo=timezone.utc).isoformat()
        except (ValueError, IndexError):
            return datetime.now(timezone.utc).isoformat()


class UFWParser:
    """Parse /var/log/ufw.log for firewall events"""

    UFW_BLOCK = re.compile(
        r'\[UFW (\w+)\].*SRC=([\d.]+).*DST=([\d.]+).*PROTO=(\w+).*(?:SPT=(\d+))?.*(?:DPT=(\d+))?'
    )

    @classmethod
    def parse(cls, line: str, vm_id: str) -> Optional[LogEvent]:
        match = cls.UFW_BLOCK.search(line)
        if not match:
            return None

        action = match.group(1)
        severity = "warning" if action == "BLOCK" else "info"

        return LogEvent(
            timestamp=datetime.now(timezone.utc).isoformat(),
            vm_id=vm_id,
            category="firewall",
            severity=severity,
            source="ufw",
            message=f"UFW {action}: {match.group(2)} -> {match.group(3)}:{match.group(6)}",
            raw=line,
            extra={
                "action": action,
                "protocol": match.group(4),
                "src_ip": match.group(2),
                "src_port": int(match.group(5)) if match.group(5) else None,
                "dst_ip": match.group(3),
                "dst_port": int(match.group(6)) if match.group(6) else None,
            }
        )


class DockerParser:
    """Parse docker events from journalctl -u docker"""

    EVENT_PATTERN = re.compile(
        r'container (\w+) (\w{12}):.*name=(\S+)'
    )

    @classmethod
    def parse(cls, line: str, vm_id: str) -> Optional[LogEvent]:
        match = cls.EVENT_PATTERN.search(line)
        if not match:
            return None

        event_type = match.group(1)
        severity = "warning" if event_type in ("die", "kill", "oom") else "info"

        return LogEvent(
            timestamp=datetime.now(timezone.utc).isoformat(),
            vm_id=vm_id,
            category="docker",
            severity=severity,
            source="docker",
            message=f"Container {match.group(3)}: {event_type}",
            raw=line,
            extra={
                "event_type": event_type,
                "container_id": match.group(2),
                "container_name": match.group(3),
            }
        )


# =============================================================================
# LOG TAILER
# =============================================================================

class LogTailer:
    """Tail log files and track position"""

    def __init__(self, path: str):
        self.path = Path(path)
        self.position_file = Path(f"/var/lib/siem_agent/{self.path.name}.pos")
        self.position_file.parent.mkdir(parents=True, exist_ok=True)
        self._load_position()

    def _load_position(self):
        """Load last read position"""
        try:
            if self.position_file.exists():
                data = json.loads(self.position_file.read_text())
                self.inode = data.get("inode", 0)
                self.offset = data.get("offset", 0)
            else:
                self.inode = 0
                self.offset = 0
        except Exception:
            self.inode = 0
            self.offset = 0

    def _save_position(self, inode: int, offset: int):
        """Save current position"""
        self.position_file.write_text(json.dumps({
            "inode": inode,
            "offset": offset,
        }))

    def read_new_lines(self) -> Generator[str, None, None]:
        """Read new lines since last check"""
        if not self.path.exists():
            return

        stat = self.path.stat()
        current_inode = stat.st_ino

        # File rotated? Start from beginning
        if current_inode != self.inode:
            self.offset = 0
            self.inode = current_inode

        with open(self.path, "r") as f:
            f.seek(self.offset)
            for line in f:
                yield line.rstrip()
            self.offset = f.tell()

        self._save_position(current_inode, self.offset)


# =============================================================================
# SYSTEM METRICS
# =============================================================================

def get_system_metrics() -> Dict[str, Any]:
    """Collect system metrics for heartbeat"""
    metrics = {}

    # Uptime
    try:
        with open("/proc/uptime") as f:
            metrics["uptime_seconds"] = int(float(f.read().split()[0]))
    except Exception:
        metrics["uptime_seconds"] = 0

    # Load average
    try:
        with open("/proc/loadavg") as f:
            metrics["load_avg"] = float(f.read().split()[0])
    except Exception:
        metrics["load_avg"] = 0.0

    # Memory
    try:
        with open("/proc/meminfo") as f:
            meminfo = dict(
                line.split(":")
                for line in f.read().strip().split("\n")
            )
        total = int(meminfo["MemTotal"].strip().split()[0]) // 1024
        available = int(meminfo["MemAvailable"].strip().split()[0]) // 1024
        metrics["memory_total_mb"] = total
        metrics["memory_used_mb"] = total - available
    except Exception:
        metrics["memory_total_mb"] = 0
        metrics["memory_used_mb"] = 0

    # Disk
    try:
        stat = os.statvfs("/")
        total_gb = (stat.f_blocks * stat.f_frsize) / (1024**3)
        free_gb = (stat.f_bavail * stat.f_frsize) / (1024**3)
        metrics["disk_total_gb"] = round(total_gb, 2)
        metrics["disk_used_gb"] = round(total_gb - free_gb, 2)
    except Exception:
        metrics["disk_total_gb"] = 0
        metrics["disk_used_gb"] = 0

    # Docker containers
    try:
        result = subprocess.run(
            ["docker", "ps", "-q"],
            capture_output=True,
            text=True,
            timeout=5
        )
        metrics["docker_containers"] = len(result.stdout.strip().split("\n")) if result.stdout.strip() else 0
    except Exception:
        metrics["docker_containers"] = 0

    return metrics


# =============================================================================
# SENDER
# =============================================================================

class CentralSender:
    """Send events to central syslog-ng server"""

    def __init__(self, host: str, port: int):
        self.host = host
        self.port = port
        self.sock: Optional[socket.socket] = None
        self._connect()

    def _connect(self):
        """Establish TCP connection"""
        try:
            self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            self.sock.settimeout(10)
            self.sock.connect((self.host, self.port))
            logger.info(f"Connected to {self.host}:{self.port}")
        except Exception as e:
            logger.error(f"Connection failed: {e}")
            self.sock = None

    def send(self, event: LogEvent) -> bool:
        """Send single event"""
        if not self.sock:
            self._connect()
            if not self.sock:
                return False

        try:
            data = event.to_json() + "\n"
            self.sock.sendall(data.encode("utf-8"))
            return True
        except Exception as e:
            logger.error(f"Send failed: {e}")
            self.sock = None
            return False

    def send_batch(self, events: list[LogEvent]) -> int:
        """Send batch of events, return count of successful sends"""
        sent = 0
        for event in events:
            if self.send(event):
                sent += 1
        return sent

    def send_heartbeat(self, heartbeat: Heartbeat) -> bool:
        """Send heartbeat"""
        if not self.sock:
            self._connect()
            if not self.sock:
                return False

        try:
            data = heartbeat.to_json() + "\n"
            self.sock.sendall(data.encode("utf-8"))
            return True
        except Exception as e:
            logger.error(f"Heartbeat failed: {e}")
            self.sock = None
            return False

    def close(self):
        if self.sock:
            self.sock.close()
            self.sock = None


# =============================================================================
# MAIN AGENT
# =============================================================================

class SIEMAgent:
    """Main agent orchestrator"""

    def __init__(self, config: dict):
        self.config = config
        self.vm_id = config["vm_id"]
        self.sender = CentralSender(
            config["central_host"],
            config["central_port"]
        )
        self.tailers: dict[str, LogTailer] = {}
        self.parsers = {
            "auth": AuthLogParser,
            "ufw": UFWParser,
            "docker": DockerParser,
        }
        self._init_tailers()
        self.last_heartbeat = 0

    def _init_tailers(self):
        """Initialize log file tailers"""
        for name, path in self.config["log_sources"].items():
            if path != "journalctl" and Path(path).exists():
                self.tailers[name] = LogTailer(path)
                logger.info(f"Tailing: {path}")

    def collect_logs(self) -> list[LogEvent]:
        """Collect new log events from all sources"""
        events = []

        for source, tailer in self.tailers.items():
            parser = self.parsers.get(source)
            if not parser:
                continue

            for line in tailer.read_new_lines():
                event = parser.parse(line, self.vm_id)
                if event:
                    events.append(event)

        return events

    def send_heartbeat(self):
        """Send periodic heartbeat with system metrics"""
        metrics = get_system_metrics()
        heartbeat = Heartbeat(
            timestamp=datetime.now(timezone.utc).isoformat(),
            vm_id=self.vm_id,
            agent_version="1.0.0",
            **metrics
        )
        self.sender.send_heartbeat(heartbeat)

    def run_once(self):
        """Single collection and send cycle"""
        # Collect and send logs
        events = self.collect_logs()
        if events:
            sent = self.sender.send_batch(events)
            logger.info(f"Sent {sent}/{len(events)} events")

        # Heartbeat
        now = time.time()
        if now - self.last_heartbeat >= self.config["heartbeat_interval"]:
            self.send_heartbeat()
            self.last_heartbeat = now

    def run(self):
        """Main loop"""
        logger.info(f"SIEM Agent starting: vm_id={self.vm_id}")
        try:
            while True:
                self.run_once()
                time.sleep(5)  # Poll interval
        except KeyboardInterrupt:
            logger.info("Shutting down...")
        finally:
            self.sender.close()


# =============================================================================
# ENTRY POINT
# =============================================================================

if __name__ == "__main__":
    agent = SIEMAgent(CONFIG)
    agent.run()
