"""
Shell command execution for Cloud Control Center
"""

import subprocess
import os
from typing import Dict, Optional

from .config_loader import get_ssh_key, get_oci_compartment, get_oci_list_script
from .models import Host, Container


def run_command(cmd: str, timeout: int = 60, env: dict = None) -> Dict[str, any]:
    """Execute shell command and return result dict."""
    try:
        full_env = os.environ.copy()
        if env:
            full_env.update(env)
        result = subprocess.run(
            cmd, shell=True, capture_output=True, text=True,
            timeout=timeout, env=full_env
        )
        return {
            "success": result.returncode == 0,
            "stdout": result.stdout.strip(),
            "stderr": result.stderr.strip(),
            "returncode": result.returncode
        }
    except subprocess.TimeoutExpired:
        return {"success": False, "stdout": "", "stderr": f"Timeout after {timeout}s", "returncode": -1}
    except Exception as e:
        return {"success": False, "stdout": "", "stderr": str(e), "returncode": -1}


# =============================================================================
# GCP COMMANDS
# =============================================================================

def gcp_list() -> str:
    """List GCP instances."""
    cmd = 'gcloud compute instances list --format="table(name,zone,machineType,networkInterfaces[0].accessConfigs[0].natIP:label=EXTERNAL_IP,status)"'
    result = run_command(cmd)
    return result["stdout"] if result["success"] else result["stderr"]


def gcp_start(host: Host) -> str:
    cmd = f"gcloud compute instances start {host.name} --zone={host.zone}"
    result = run_command(cmd)
    return result["stdout"] if result["success"] else result["stderr"]


def gcp_stop(host: Host) -> str:
    cmd = f"gcloud compute instances stop {host.name} --zone={host.zone}"
    result = run_command(cmd)
    return result["stdout"] if result["success"] else result["stderr"]


def gcp_reboot(host: Host) -> str:
    cmd = f"gcloud compute instances reset {host.name} --zone={host.zone}"
    result = run_command(cmd)
    return result["stdout"] if result["success"] else result["stderr"]


def gcp_ssh(host: Host, command: str) -> str:
    """Run command on GCP host via SSH."""
    cmd = f"gcloud compute ssh {host.name} --zone={host.zone} -- {command}"
    result = run_command(cmd)
    return result["stdout"] if result["success"] else result["stderr"]


# =============================================================================
# OCI COMMANDS
# =============================================================================

def oci_list() -> str:
    """List OCI instances."""
    script = get_oci_list_script()
    if script and os.path.exists(script):
        result = run_command(script)
    else:
        compartment = get_oci_compartment()
        cmd = f'''oci compute instance list --compartment-id {compartment} \
            --query 'data[].{{Name:"display-name", State:"lifecycle-state", Shape:shape}}' \
            --output table'''
        result = run_command(cmd, env={"SUPPRESS_LABEL_WARNING": "True"})
    return result["stdout"] if result["success"] else result["stderr"]


def oci_start(host: Host) -> str:
    cmd = f"oci compute instance action --instance-id {host.instance_id} --action START"
    result = run_command(cmd, env={"SUPPRESS_LABEL_WARNING": "True"})
    return result["stdout"] if result["success"] else result["stderr"]


def oci_stop(host: Host) -> str:
    cmd = f"oci compute instance action --instance-id {host.instance_id} --action STOP"
    result = run_command(cmd, env={"SUPPRESS_LABEL_WARNING": "True"})
    return result["stdout"] if result["success"] else result["stderr"]


def oci_reboot(host: Host) -> str:
    cmd = f"oci compute instance action --instance-id {host.instance_id} --action SOFTRESET"
    result = run_command(cmd, env={"SUPPRESS_LABEL_WARNING": "True"})
    return result["stdout"] if result["success"] else result["stderr"]


def oci_ssh(host: Host, command: str) -> str:
    """Run command on OCI host via SSH."""
    ssh_key = get_ssh_key()
    cmd = f'ssh -i {ssh_key} ubuntu@{host.ip} "{command}"'
    result = run_command(cmd)
    return result["stdout"] if result["success"] else result["stderr"]


# =============================================================================
# VM COMMANDS (provider-agnostic)
# =============================================================================

def vm_ssh(host: Host, command: str) -> str:
    """Run command on VM via SSH (auto-detect provider)."""
    if host.provider == "gcp":
        return gcp_ssh(host, command)
    return oci_ssh(host, command)


def vm_docker_ps(host: Host) -> str:
    """Run docker ps on VM."""
    return vm_ssh(host, "docker ps -a")


def vm_top(host: Host) -> str:
    """Run top on VM."""
    return vm_ssh(host, "top -b -n 1 | head -30")


def vm_start(host: Host) -> str:
    if host.provider == "gcp":
        return gcp_start(host)
    return oci_start(host)


def vm_stop(host: Host) -> str:
    if host.provider == "gcp":
        return gcp_stop(host)
    return oci_stop(host)


def vm_reboot(host: Host) -> str:
    if host.provider == "gcp":
        return gcp_reboot(host)
    return oci_reboot(host)


# =============================================================================
# CONTAINER COMMANDS
# =============================================================================

def container_exec(host: Host, container_name: str, command: str) -> str:
    """Execute command inside container."""
    docker_cmd = f"docker exec {container_name} {command}"
    return vm_ssh(host, docker_cmd)


def container_ls(host: Host, container_name: str) -> str:
    return container_exec(host, container_name, "ls -la")


def container_ps(host: Host, container_name: str) -> str:
    return container_exec(host, container_name, "ps aux 2>/dev/null || ls -la")


def container_stats(host: Host, container_name: str) -> str:
    """Get docker stats for container."""
    cmd = f"docker stats {container_name} --no-stream"
    return vm_ssh(host, cmd)


def container_logs(host: Host, container_name: str, lines: int = 50) -> str:
    """Get container logs."""
    cmd = f"docker logs {container_name} --tail {lines}"
    return vm_ssh(host, cmd)


def container_restart(host: Host, container_name: str) -> str:
    """Restart container."""
    cmd = f"docker restart {container_name}"
    return vm_ssh(host, cmd)


def container_stop(host: Host, container_name: str) -> str:
    """Stop container."""
    cmd = f"docker stop {container_name}"
    return vm_ssh(host, cmd)


def container_start(host: Host, container_name: str) -> str:
    """Start container."""
    cmd = f"docker start {container_name}"
    return vm_ssh(host, cmd)
