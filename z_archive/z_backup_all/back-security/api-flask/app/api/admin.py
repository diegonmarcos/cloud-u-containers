"""
Admin API Routes for Cloud Dashboard
Protected endpoints that require authentication
"""
import logging
from datetime import datetime, timezone
from flask import Blueprint, jsonify, request

from app.api.auth import require_auth
from app.config import get_vm, get_svc
from app.utils.health import run_ssh_command

admin_bp = Blueprint('admin', __name__)
logger = logging.getLogger(__name__)

# Audit log (in production, use proper logging/database)
_audit_log = []


def log_admin_action(user: str, action: str, target: str, result: str):
    """Log admin action for audit trail."""
    entry = {
        'timestamp': datetime.now(timezone.utc).isoformat(),
        'user': user,
        'action': action,
        'target': target,
        'result': result
    }
    _audit_log.append(entry)
    logger.info(f"ADMIN ACTION: {user} - {action} - {target} - {result}")

    # Keep only last 1000 entries
    if len(_audit_log) > 1000:
        _audit_log.pop(0)


# =============================================================================
# VM Admin Endpoints
# =============================================================================

@admin_bp.route('/vms/<vm_id>/reboot', methods=['POST'])
@require_auth
def reboot_vm(vm_id: str):
    """Reboot a VM via SSH."""
    vm_data = get_vm(vm_id)
    if not vm_data:
        return jsonify({'error': f'VM not found: {vm_id}'}), 404

    ip = vm_data.get('network', {}).get('publicIp')
    if not ip or ip == 'pending':
        return jsonify({'error': 'VM has no public IP'}), 400

    # Execute reboot command
    result = run_ssh_command(vm_id, 'sudo reboot')

    if result is None:
        log_admin_action(request.current_user, 'reboot_vm', vm_id, 'failed')
        return jsonify({'error': 'Failed to connect to VM'}), 503

    log_admin_action(request.current_user, 'reboot_vm', vm_id, 'success')
    return jsonify({
        'status': 'ok',
        'message': f'Reboot command sent to {vm_id}',
        'vm_id': vm_id
    })


@admin_bp.route('/vms/<vm_id>/containers', methods=['GET'])
@require_auth
def list_vm_containers(vm_id: str):
    """List Docker containers on a VM."""
    vm_data = get_vm(vm_id)
    if not vm_data:
        return jsonify({'error': f'VM not found: {vm_id}'}), 404

    result = run_ssh_command(vm_id, 'sudo docker ps -a --format "{{.Names}}|{{.Status}}|{{.Image}}"')

    if result is None:
        return jsonify({'error': 'Failed to connect to VM'}), 503

    containers = []
    for line in result.strip().split('\n'):
        if line and '|' in line:
            parts = line.split('|')
            if len(parts) >= 3:
                containers.append({
                    'name': parts[0],
                    'status': parts[1],
                    'image': parts[2]
                })

    return jsonify({
        'vm_id': vm_id,
        'containers': containers
    })


@admin_bp.route('/vms/<vm_id>/containers/<container_name>/restart', methods=['POST'])
@require_auth
def restart_container(vm_id: str, container_name: str):
    """Restart a Docker container on a VM."""
    vm_data = get_vm(vm_id)
    if not vm_data:
        return jsonify({'error': f'VM not found: {vm_id}'}), 404

    result = run_ssh_command(vm_id, f'sudo docker restart {container_name}')

    if result is None:
        log_admin_action(request.current_user, 'restart_container', f'{vm_id}/{container_name}', 'failed')
        return jsonify({'error': 'Failed to execute command'}), 503

    log_admin_action(request.current_user, 'restart_container', f'{vm_id}/{container_name}', 'success')
    return jsonify({
        'status': 'ok',
        'message': f'Container {container_name} restarted',
        'vm_id': vm_id,
        'container': container_name
    })


@admin_bp.route('/vms/<vm_id>/containers/<container_name>/stop', methods=['POST'])
@require_auth
def stop_container(vm_id: str, container_name: str):
    """Stop a Docker container on a VM."""
    vm_data = get_vm(vm_id)
    if not vm_data:
        return jsonify({'error': f'VM not found: {vm_id}'}), 404

    result = run_ssh_command(vm_id, f'sudo docker stop {container_name}')

    if result is None:
        log_admin_action(request.current_user, 'stop_container', f'{vm_id}/{container_name}', 'failed')
        return jsonify({'error': 'Failed to execute command'}), 503

    log_admin_action(request.current_user, 'stop_container', f'{vm_id}/{container_name}', 'success')
    return jsonify({
        'status': 'ok',
        'message': f'Container {container_name} stopped',
        'vm_id': vm_id,
        'container': container_name
    })


@admin_bp.route('/vms/<vm_id>/containers/<container_name>/start', methods=['POST'])
@require_auth
def start_container(vm_id: str, container_name: str):
    """Start a Docker container on a VM."""
    vm_data = get_vm(vm_id)
    if not vm_data:
        return jsonify({'error': f'VM not found: {vm_id}'}), 404

    result = run_ssh_command(vm_id, f'sudo docker start {container_name}')

    if result is None:
        log_admin_action(request.current_user, 'start_container', f'{vm_id}/{container_name}', 'failed')
        return jsonify({'error': 'Failed to execute command'}), 503

    log_admin_action(request.current_user, 'start_container', f'{vm_id}/{container_name}', 'success')
    return jsonify({
        'status': 'ok',
        'message': f'Container {container_name} started',
        'vm_id': vm_id,
        'container': container_name
    })


@admin_bp.route('/vms/<vm_id>/containers/<container_name>/logs', methods=['GET'])
@require_auth
def get_container_logs(vm_id: str, container_name: str):
    """Get logs from a Docker container."""
    vm_data = get_vm(vm_id)
    if not vm_data:
        return jsonify({'error': f'VM not found: {vm_id}'}), 404

    lines = request.args.get('lines', 100, type=int)
    lines = min(lines, 500)  # Cap at 500 lines

    result = run_ssh_command(vm_id, f'sudo docker logs --tail {lines} {container_name}')

    if result is None:
        return jsonify({'error': 'Failed to execute command'}), 503

    return jsonify({
        'vm_id': vm_id,
        'container': container_name,
        'logs': result
    })


# =============================================================================
# Service Admin Endpoints
# =============================================================================

@admin_bp.route('/services/<svc_id>/restart', methods=['POST'])
@require_auth
def restart_service(svc_id: str):
    """Restart a service (its Docker container)."""
    svc_data = get_svc(svc_id)
    if not svc_data:
        return jsonify({'error': f'Service not found: {svc_id}'}), 404

    vm_id = svc_data.get('vmId')
    container = svc_data.get('docker', {}).get('container')

    if not vm_id or not container:
        return jsonify({'error': 'Service has no VM or container info'}), 400

    result = run_ssh_command(vm_id, f'sudo docker restart {container}')

    if result is None:
        log_admin_action(request.current_user, 'restart_service', svc_id, 'failed')
        return jsonify({'error': 'Failed to execute command'}), 503

    log_admin_action(request.current_user, 'restart_service', svc_id, 'success')
    return jsonify({
        'status': 'ok',
        'message': f'Service {svc_id} restarted',
        'service_id': svc_id,
        'container': container
    })


# =============================================================================
# Audit Log Endpoint
# =============================================================================

@admin_bp.route('/audit-log', methods=['GET'])
@require_auth
def get_audit_log():
    """Get recent admin actions audit log."""
    limit = request.args.get('limit', 50, type=int)
    limit = min(limit, 200)

    return jsonify({
        'entries': _audit_log[-limit:],
        'total': len(_audit_log)
    })
