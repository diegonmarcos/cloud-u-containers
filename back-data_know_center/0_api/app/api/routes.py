"""
API Routes for Cloud Dashboard
"""
from flask import Blueprint, jsonify, request

from app.config import (
    load_config,
    get_vm_ids, get_vm_ids_by_category, get_vm_categories, get_vm_category_name, get_vm,
    get_service_ids, get_service_ids_by_category, get_service_categories, get_service_category_name, get_svc
)
from app.utils.health import (
    get_vm_status, get_vm_ram_percent, get_vm_details,
    get_svc_status, get_container_status
)

api_bp = Blueprint('api', __name__)


# =============================================================================
# Health Check
# =============================================================================

@api_bp.route('/health', methods=['GET'])
def health_check():
    """API health check endpoint."""
    return jsonify({
        'status': 'ok',
        'service': 'cloud-dashboard-api',
        'version': '1.0.0'
    })


# =============================================================================
# Configuration Endpoints
# =============================================================================

@api_bp.route('/config', methods=['GET'])
def get_full_config():
    """Get full infrastructure configuration."""
    try:
        config = load_config()
        return jsonify(config)
    except FileNotFoundError as e:
        return jsonify({'error': str(e)}), 404


@api_bp.route('/config/reload', methods=['POST'])
def reload_config():
    """Force reload configuration from disk."""
    try:
        config = load_config(force_reload=True)
        return jsonify({'status': 'ok', 'message': 'Configuration reloaded'})
    except FileNotFoundError as e:
        return jsonify({'error': str(e)}), 404


# =============================================================================
# VM Endpoints
# =============================================================================

@api_bp.route('/vms', methods=['GET'])
def list_vms():
    """List all VMs with basic info."""
    category = request.args.get('category')

    if category:
        vm_ids = get_vm_ids_by_category(category)
    else:
        vm_ids = get_vm_ids()

    vms = []
    for vm_id in vm_ids:
        vm_data = get_vm(vm_id)
        vms.append({
            'id': vm_id,
            'name': vm_data.get('name'),
            'provider': vm_data.get('provider'),
            'category': vm_data.get('category'),
            'ip': vm_data.get('network', {}).get('publicIp'),
            'instanceType': vm_data.get('instanceType'),
            'configStatus': vm_data.get('status')
        })

    return jsonify({'vms': vms})


@api_bp.route('/vms/categories', methods=['GET'])
def list_vm_categories():
    """List all VM categories."""
    categories = []
    for cat_id in get_vm_categories():
        categories.append({
            'id': cat_id,
            'name': get_vm_category_name(cat_id)
        })
    return jsonify({'categories': categories})


@api_bp.route('/vms/<vm_id>', methods=['GET'])
def get_vm_info(vm_id: str):
    """Get detailed VM information."""
    vm_data = get_vm(vm_id)
    if not vm_data:
        return jsonify({'error': f'VM not found: {vm_id}'}), 404

    return jsonify({
        'id': vm_id,
        **vm_data
    })


@api_bp.route('/vms/<vm_id>/status', methods=['GET'])
def get_vm_health(vm_id: str):
    """Get VM health status (ping, SSH)."""
    vm_data = get_vm(vm_id)
    if not vm_data:
        return jsonify({'error': f'VM not found: {vm_id}'}), 404

    status = get_vm_status(vm_id)
    ram = get_vm_ram_percent(vm_id)

    return jsonify({
        'id': vm_id,
        'name': vm_data.get('name'),
        'ip': vm_data.get('network', {}).get('publicIp'),
        **status,
        'ram_percent': ram
    })


@api_bp.route('/vms/<vm_id>/details', methods=['GET'])
def get_vm_remote_details(vm_id: str):
    """Get detailed system info from VM via SSH."""
    vm_data = get_vm(vm_id)
    if not vm_data:
        return jsonify({'error': f'VM not found: {vm_id}'}), 404

    details = get_vm_details(vm_id)
    if details is None:
        return jsonify({'error': 'Failed to connect to VM'}), 503

    return jsonify({
        'id': vm_id,
        'name': vm_data.get('name'),
        'details': details
    })


@api_bp.route('/vms/<vm_id>/containers', methods=['GET'])
def get_vm_containers(vm_id: str):
    """Get Docker container status on VM."""
    vm_data = get_vm(vm_id)
    if not vm_data:
        return jsonify({'error': f'VM not found: {vm_id}'}), 404

    containers = get_container_status(vm_id)
    if containers is None:
        return jsonify({'error': 'Failed to get container status'}), 503

    return jsonify({
        'id': vm_id,
        'name': vm_data.get('name'),
        'containers': containers
    })


# =============================================================================
# Service Endpoints
# =============================================================================

@api_bp.route('/services', methods=['GET'])
def list_services():
    """List all services with basic info."""
    category = request.args.get('category')

    if category:
        svc_ids = get_service_ids_by_category(category)
    else:
        svc_ids = get_service_ids()

    services = []
    for svc_id in svc_ids:
        svc_data = get_svc(svc_id)
        url = svc_data.get('urls', {}).get('gui') or svc_data.get('urls', {}).get('admin')
        services.append({
            'id': svc_id,
            'name': svc_data.get('name'),
            'category': svc_data.get('category'),
            'vmId': svc_data.get('vmId'),
            'url': url,
            'configStatus': svc_data.get('status')
        })

    return jsonify({'services': services})


@api_bp.route('/services/categories', methods=['GET'])
def list_service_categories():
    """List all service categories."""
    categories = []
    for cat_id in get_service_categories():
        categories.append({
            'id': cat_id,
            'name': get_service_category_name(cat_id)
        })
    return jsonify({'categories': categories})


@api_bp.route('/services/<svc_id>', methods=['GET'])
def get_service_info(svc_id: str):
    """Get detailed service information."""
    svc_data = get_svc(svc_id)
    if not svc_data:
        return jsonify({'error': f'Service not found: {svc_id}'}), 404

    return jsonify({
        'id': svc_id,
        **svc_data
    })


@api_bp.route('/services/<svc_id>/status', methods=['GET'])
def get_service_health(svc_id: str):
    """Get service health status (HTTP check)."""
    svc_data = get_svc(svc_id)
    if not svc_data:
        return jsonify({'error': f'Service not found: {svc_id}'}), 404

    status = get_svc_status(svc_id)
    url = svc_data.get('urls', {}).get('gui') or svc_data.get('urls', {}).get('admin')

    return jsonify({
        'id': svc_id,
        'name': svc_data.get('name'),
        'url': url,
        **status
    })


# =============================================================================
# Dashboard Summary Endpoints
# =============================================================================

@api_bp.route('/dashboard/summary', methods=['GET'])
def get_dashboard_summary():
    """Get summary of all VMs and services with status."""
    # VMs
    vm_summary = []
    for cat_id in get_vm_categories():
        cat_vms = []
        for vm_id in get_vm_ids_by_category(cat_id):
            vm_data = get_vm(vm_id)
            status = get_vm_status(vm_id)
            ram = get_vm_ram_percent(vm_id)
            cat_vms.append({
                'id': vm_id,
                'name': vm_data.get('name'),
                'ip': vm_data.get('network', {}).get('publicIp'),
                'instanceType': vm_data.get('instanceType'),
                **status,
                'ram_percent': ram
            })
        if cat_vms:
            vm_summary.append({
                'category': cat_id,
                'categoryName': get_vm_category_name(cat_id),
                'vms': cat_vms
            })

    # Services
    svc_summary = []
    for cat_id in get_service_categories():
        cat_svcs = []
        for svc_id in get_service_ids_by_category(cat_id):
            svc_data = get_svc(svc_id)
            status = get_svc_status(svc_id)
            url = svc_data.get('urls', {}).get('gui') or svc_data.get('urls', {}).get('admin')
            cat_svcs.append({
                'id': svc_id,
                'name': svc_data.get('name'),
                'url': url,
                **status
            })
        if cat_svcs:
            svc_summary.append({
                'category': cat_id,
                'categoryName': get_service_category_name(cat_id),
                'services': cat_svcs
            })

    return jsonify({
        'vms': vm_summary,
        'services': svc_summary
    })


@api_bp.route('/dashboard/quick-status', methods=['GET'])
def get_quick_status():
    """Get quick status without health checks (from config only)."""
    # VMs
    vms = []
    for vm_id in get_vm_ids():
        vm_data = get_vm(vm_id)
        vms.append({
            'id': vm_id,
            'name': vm_data.get('name'),
            'ip': vm_data.get('network', {}).get('publicIp'),
            'provider': vm_data.get('provider'),
            'category': vm_data.get('category'),
            'configStatus': vm_data.get('status')
        })

    # Services
    services = []
    for svc_id in get_service_ids():
        svc_data = get_svc(svc_id)
        url = svc_data.get('urls', {}).get('gui') or svc_data.get('urls', {}).get('admin')
        services.append({
            'id': svc_id,
            'name': svc_data.get('name'),
            'category': svc_data.get('category'),
            'vmId': svc_data.get('vmId'),
            'url': url,
            'configStatus': svc_data.get('status')
        })

    return jsonify({
        'vms': vms,
        'services': services
    })


# =============================================================================
# Providers & Domains
# =============================================================================

@api_bp.route('/providers', methods=['GET'])
def list_providers():
    """List all cloud providers."""
    config = load_config()
    return jsonify({'providers': config.get('providers', {})})


@api_bp.route('/domains', methods=['GET'])
def list_domains():
    """List all domains and subdomains."""
    config = load_config()
    return jsonify(config.get('domains', {}))


# =============================================================================
# Cloud Control Endpoints (4 subpages: monitor, costs_infra, costs_ai, infrastructure)
# =============================================================================

@api_bp.route('/cloud_control/monitor', methods=['GET'])
def cloud_control_monitor():
    """Monitor page - VMs and services status summary."""
    # VMs
    vm_summary = []
    for cat_id in get_vm_categories():
        cat_vms = []
        for vm_id in get_vm_ids_by_category(cat_id):
            vm_data = get_vm(vm_id)
            status = get_vm_status(vm_id)
            ram = get_vm_ram_percent(vm_id)
            cat_vms.append({
                'id': vm_id,
                'name': vm_data.get('name'),
                'ip': vm_data.get('network', {}).get('publicIp'),
                'instanceType': vm_data.get('instanceType'),
                'provider': vm_data.get('provider'),
                **status,
                'ram_percent': ram
            })
        if cat_vms:
            vm_summary.append({
                'category': cat_id,
                'categoryName': get_vm_category_name(cat_id),
                'vms': cat_vms
            })

    # Services
    svc_summary = []
    for cat_id in get_service_categories():
        cat_svcs = []
        for svc_id in get_service_ids_by_category(cat_id):
            svc_data = get_svc(svc_id)
            status = get_svc_status(svc_id)
            url = svc_data.get('urls', {}).get('gui') or svc_data.get('urls', {}).get('admin')
            cat_svcs.append({
                'id': svc_id,
                'name': svc_data.get('name'),
                'url': url,
                'vmId': svc_data.get('vmId'),
                **status
            })
        if cat_svcs:
            svc_summary.append({
                'category': cat_id,
                'categoryName': get_service_category_name(cat_id),
                'services': cat_svcs
            })

    return jsonify({
        'vms': vm_summary,
        'services': svc_summary
    })


@api_bp.route('/cloud_control/costs_infra', methods=['GET'])
def cloud_control_costs_infra():
    """Infrastructure costs page - cloud provider costs."""
    config = load_config()
    costs_infra = config.get('costs', {}).get('infra', {})

    return jsonify({
        'costs': costs_infra,
        'timestamp': config.get('lastUpdated')
    })


@api_bp.route('/cloud_control/costs_ai', methods=['GET'])
def cloud_control_costs_ai():
    """AI costs page - Claude/OpenAI/etc usage costs."""
    config = load_config()
    costs_ai = config.get('costs', {}).get('ai', {})

    return jsonify({
        'costs': costs_ai,
        'timestamp': config.get('lastUpdated')
    })


@api_bp.route('/cloud_control/infrastructure', methods=['GET'])
def cloud_control_infrastructure():
    """Infrastructure page - full details on VMs, services, providers, domains."""
    config = load_config()

    # VMs with full details
    vms = []
    for vm_id in get_vm_ids():
        vm_data = get_vm(vm_id)
        vms.append({
            'id': vm_id,
            **vm_data
        })

    # Services with full details
    services = []
    for svc_id in get_service_ids():
        svc_data = get_svc(svc_id)
        services.append({
            'id': svc_id,
            **svc_data
        })

    return jsonify({
        'vms': vms,
        'services': services,
        'providers': config.get('providers', {}),
        'domains': config.get('domains', {}),
        'dockerNetworks': config.get('dockerNetworks', {}),
        'firewallRules': config.get('firewallRules', {}),
        'objectStorage': config.get('objectStorage', {}),
        'vmCategories': config.get('vmCategories', {}),
        'serviceCategories': config.get('serviceCategories', {})
    })


# =============================================================================
# Wake-on-Demand Endpoints (for oci-p-flex_1 / photoprism)
# =============================================================================

import os
import threading
import time
import logging

logger = logging.getLogger(__name__)

# Wake state tracking
_wake_state = {
    'status': 'unknown',  # unknown, starting, running, stopped, error
    'last_trigger': None,
    'message': ''
}
_wake_lock = threading.Lock()

# OCI instance details for wake-on-demand VM
OCI_INSTANCE_ID = os.environ.get('OCI_WAKE_INSTANCE_ID', 'ocid1.instance.oc1.eu-marseille-1.anwxeljruadvczachwpa3qrh7n25vfez3smidz4o7gpmtj4ga4d7zqlja5yq')

# Lazy-loaded OCI clients
_oci_compute_client = None
_oci_initialized = False


def _init_oci():
    """Initialize OCI SDK client using instance principal or config file."""
    global _oci_compute_client, _oci_initialized

    if _oci_initialized:
        return _oci_compute_client is not None

    _oci_initialized = True

    try:
        import oci

        # Try config file first (for local/container deployment)
        config_file = os.environ.get('OCI_CONFIG_FILE', '/app/config/oci_config')
        key_file = os.environ.get('OCI_KEY_FILE', '/app/config/oci_api_key.pem')

        if os.path.exists(config_file):
            config = oci.config.from_file(config_file)
            # Override key file path if specified
            if os.path.exists(key_file):
                config['key_file'] = key_file
            # Set request timeout to 30 seconds
            _oci_compute_client = oci.core.ComputeClient(
                config,
                timeout=(10, 30)  # (connect_timeout, read_timeout)
            )
            logger.info("OCI SDK initialized with config file")
            return True
        else:
            logger.warning(f"OCI config file not found at {config_file}")
            return False

    except Exception as e:
        logger.error(f"Failed to initialize OCI SDK: {e}")
        return False


def _get_instance_state() -> str:
    """Get current OCI instance lifecycle state using SDK."""
    if not _init_oci():
        return 'unknown'

    try:
        response = _oci_compute_client.get_instance(OCI_INSTANCE_ID)
        return response.data.lifecycle_state.lower()
    except Exception as e:
        logger.error(f"Failed to get instance state: {e}")
        return 'unknown'


def _start_instance() -> tuple:
    """Start OCI instance using SDK."""
    if not _init_oci():
        return False, 'OCI SDK not initialized'

    try:
        _oci_compute_client.instance_action(OCI_INSTANCE_ID, 'START')
        return True, 'Start command sent'
    except Exception as e:
        return False, str(e)


def _wake_worker():
    """Background worker to start instance and monitor status."""
    global _wake_state

    with _wake_lock:
        _wake_state['status'] = 'starting'
        _wake_state['message'] = 'Sending start command to OCI...'

    success, output = _start_instance()

    if not success:
        with _wake_lock:
            _wake_state['status'] = 'error'
            _wake_state['message'] = f'Failed to start: {output}'
        return

    # Poll for running state (max 5 minutes)
    for _ in range(60):
        time.sleep(5)
        state = _get_instance_state()
        with _wake_lock:
            _wake_state['message'] = f'Instance state: {state}'
            if state == 'running':
                _wake_state['status'] = 'running'
                return
            elif state in ('terminated', 'terminating'):
                _wake_state['status'] = 'error'
                _wake_state['message'] = f'Instance in unexpected state: {state}'
                return

    with _wake_lock:
        _wake_state['status'] = 'timeout'
        _wake_state['message'] = 'Timeout waiting for instance to start'


@api_bp.route('/wake/trigger', methods=['POST'])
def trigger_wake():
    """Trigger wake for the photoprism VM (oci-p-flex_1)."""
    global _wake_state

    # Check if OCI is configured
    if not _init_oci():
        return jsonify({
            'status': 'error',
            'message': 'OCI SDK not configured'
        }), 503

    # Check current state
    current_state = _get_instance_state()

    if current_state == 'running':
        return jsonify({
            'status': 'already_running',
            'message': 'Instance is already running'
        })

    if current_state == 'starting':
        return jsonify({
            'status': 'starting',
            'message': 'Instance is already starting'
        })

    # Start wake in background
    with _wake_lock:
        if _wake_state['status'] == 'starting':
            return jsonify({
                'status': 'starting',
                'message': 'Wake already in progress'
            })
        _wake_state['last_trigger'] = time.time()

    thread = threading.Thread(target=_wake_worker, daemon=True)
    thread.start()

    return jsonify({
        'status': 'ok',
        'message': 'Wake command triggered'
    })


@api_bp.route('/wake/status', methods=['GET'])
def wake_status():
    """Get current wake/instance status."""
    current_state = _get_instance_state()

    with _wake_lock:
        return jsonify({
            'instance_state': current_state,
            'wake_status': _wake_state['status'],
            'message': _wake_state['message'],
            'last_trigger': _wake_state['last_trigger']
        })


# =============================================================================
# VM Control Endpoints (start, stop, reset for all VMs)
# =============================================================================

# VM Instance IDs mapping
VM_INSTANCE_IDS = {
    'oci-p-flex_1': os.environ.get('OCI_WAKE_INSTANCE_ID', 'ocid1.instance.oc1.eu-marseille-1.anzwiljr5s34nfycnbimjtxr2zxutda5l67b6vgvb7ocfpjny3qbkx4hgfhq'),
    'oci-f-micro_1': os.environ.get('OCI_MICRO1_INSTANCE_ID', ''),
    'oci-f-micro_2': os.environ.get('OCI_MICRO2_INSTANCE_ID', ''),
}

# GCP VM mapping
GCP_VMS = {
    'gcp-f-micro_1': {'name': 'arch-1', 'zone': 'us-central1-a'}
}


def _get_oci_instance_state(instance_id: str) -> str:
    """Get OCI instance lifecycle state."""
    if not instance_id or not _init_oci():
        return 'unknown'
    try:
        response = _oci_compute_client.get_instance(instance_id)
        return response.data.lifecycle_state.upper()
    except Exception as e:
        logger.error(f"Failed to get OCI instance state: {e}")
        return 'unknown'


def _oci_instance_action(instance_id: str, action: str) -> tuple:
    """Perform OCI instance action (START, STOP, SOFTRESET, RESET)."""
    if not instance_id:
        return False, 'Instance ID not configured'
    if not _init_oci():
        return False, 'OCI SDK not initialized'
    try:
        _oci_compute_client.instance_action(instance_id, action)
        return True, f'{action} command sent'
    except Exception as e:
        return False, str(e)


def _gcp_instance_action(vm_name: str, zone: str, action: str) -> tuple:
    """Perform GCP instance action via gcloud CLI."""
    import subprocess
    try:
        cmd = ['gcloud', 'compute', 'instances', action, vm_name, f'--zone={zone}', '--quiet']
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
        if result.returncode == 0:
            return True, f'{action} command sent'
        return False, result.stderr or 'Command failed'
    except Exception as e:
        return False, str(e)


def _gcp_instance_state(vm_name: str, zone: str) -> str:
    """Get GCP instance state via gcloud CLI."""
    import subprocess
    try:
        cmd = ['gcloud', 'compute', 'instances', 'describe', vm_name, f'--zone={zone}', '--format=value(status)']
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        if result.returncode == 0:
            return result.stdout.strip().upper()
        return 'unknown'
    except Exception as e:
        logger.error(f"Failed to get GCP instance state: {e}")
        return 'unknown'


@api_bp.route('/vms/<vm_id>/start', methods=['POST'])
def start_vm(vm_id: str):
    """Start a VM."""
    # Check if OCI VM
    if vm_id in VM_INSTANCE_IDS:
        instance_id = VM_INSTANCE_IDS[vm_id]
        if not instance_id:
            return jsonify({'error': f'Instance ID not configured for {vm_id}'}), 400

        current_state = _get_oci_instance_state(instance_id)
        if current_state == 'RUNNING':
            return jsonify({'status': 'already_running', 'state': current_state})

        success, msg = _oci_instance_action(instance_id, 'START')
        if success:
            return jsonify({'status': 'ok', 'action': 'started', 'message': msg})
        return jsonify({'error': msg}), 500

    # Check if GCP VM
    if vm_id in GCP_VMS:
        vm_info = GCP_VMS[vm_id]
        current_state = _gcp_instance_state(vm_info['name'], vm_info['zone'])
        if current_state == 'RUNNING':
            return jsonify({'status': 'already_running', 'state': current_state})

        success, msg = _gcp_instance_action(vm_info['name'], vm_info['zone'], 'start')
        if success:
            return jsonify({'status': 'ok', 'action': 'started', 'message': msg})
        return jsonify({'error': msg}), 500

    return jsonify({'error': f'Unknown VM: {vm_id}'}), 404


@api_bp.route('/vms/<vm_id>/stop', methods=['POST'])
def stop_vm(vm_id: str):
    """Stop a VM."""
    # Check if OCI VM
    if vm_id in VM_INSTANCE_IDS:
        instance_id = VM_INSTANCE_IDS[vm_id]
        if not instance_id:
            return jsonify({'error': f'Instance ID not configured for {vm_id}'}), 400

        current_state = _get_oci_instance_state(instance_id)
        if current_state == 'STOPPED':
            return jsonify({'status': 'already_stopped', 'state': current_state})

        success, msg = _oci_instance_action(instance_id, 'STOP')
        if success:
            return jsonify({'status': 'ok', 'action': 'stopped', 'message': msg})
        return jsonify({'error': msg}), 500

    # Check if GCP VM
    if vm_id in GCP_VMS:
        vm_info = GCP_VMS[vm_id]
        current_state = _gcp_instance_state(vm_info['name'], vm_info['zone'])
        if current_state in ('STOPPED', 'TERMINATED'):
            return jsonify({'status': 'already_stopped', 'state': current_state})

        success, msg = _gcp_instance_action(vm_info['name'], vm_info['zone'], 'stop')
        if success:
            return jsonify({'status': 'ok', 'action': 'stopped', 'message': msg})
        return jsonify({'error': msg}), 500

    return jsonify({'error': f'Unknown VM: {vm_id}'}), 404


@api_bp.route('/vms/<vm_id>/reset', methods=['POST'])
def reset_vm(vm_id: str):
    """Reset a VM (reboot if running, start if stopped)."""
    # Check if OCI VM
    if vm_id in VM_INSTANCE_IDS:
        instance_id = VM_INSTANCE_IDS[vm_id]
        if not instance_id:
            return jsonify({'error': f'Instance ID not configured for {vm_id}'}), 400

        current_state = _get_oci_instance_state(instance_id)

        if current_state == 'STOPPED':
            success, msg = _oci_instance_action(instance_id, 'START')
            action = 'started'
        elif current_state == 'RUNNING':
            success, msg = _oci_instance_action(instance_id, 'SOFTRESET')
            action = 'rebooted'
        else:
            return jsonify({'error': f'Cannot reset VM in state: {current_state}'}), 400

        if success:
            return jsonify({'status': 'ok', 'action': action, 'message': msg})
        return jsonify({'error': msg}), 500

    # Check if GCP VM
    if vm_id in GCP_VMS:
        vm_info = GCP_VMS[vm_id]
        current_state = _gcp_instance_state(vm_info['name'], vm_info['zone'])

        if current_state in ('STOPPED', 'TERMINATED'):
            success, msg = _gcp_instance_action(vm_info['name'], vm_info['zone'], 'start')
            action = 'started'
        elif current_state == 'RUNNING':
            success, msg = _gcp_instance_action(vm_info['name'], vm_info['zone'], 'reset')
            action = 'rebooted'
        else:
            return jsonify({'error': f'Cannot reset VM in state: {current_state}'}), 400

        if success:
            return jsonify({'status': 'ok', 'action': action, 'message': msg})
        return jsonify({'error': msg}), 500

    return jsonify({'error': f'Unknown VM: {vm_id}'}), 404


# =============================================================================
# Container Control Endpoints
# =============================================================================

# VM SSH connection details
VM_SSH_CONFIG = {
    'oci-p-flex_1': {'host': '84.235.234.87', 'user': 'ubuntu', 'key': '/app/config/id_rsa'},
    'oci-f-micro_1': {'host': '130.110.251.193', 'user': 'ubuntu', 'key': '/app/config/id_rsa'},
    'oci-f-micro_2': {'host': '129.151.228.66', 'user': 'ubuntu', 'key': '/app/config/id_rsa'},
    'gcp-f-micro_1': {'host': '34.55.55.234', 'user': 'diego', 'key': '/app/config/gcp_key'},
}


def _ssh_command(vm_id: str, command: str) -> tuple:
    """Execute command on VM via SSH."""
    import subprocess

    if vm_id not in VM_SSH_CONFIG:
        return False, f'SSH not configured for {vm_id}'

    config = VM_SSH_CONFIG[vm_id]
    ssh_cmd = [
        'ssh', '-o', 'StrictHostKeyChecking=no', '-o', 'ConnectTimeout=10',
        '-i', config['key'],
        f"{config['user']}@{config['host']}",
        command
    ]

    try:
        result = subprocess.run(ssh_cmd, capture_output=True, text=True, timeout=30)
        if result.returncode == 0:
            return True, result.stdout.strip()
        return False, result.stderr.strip() or 'Command failed'
    except subprocess.TimeoutExpired:
        return False, 'SSH timeout'
    except Exception as e:
        return False, str(e)


@api_bp.route('/vms/<vm_id>/containers/<container_name>/restart', methods=['POST'])
def restart_container(vm_id: str, container_name: str):
    """Restart a Docker container on a VM."""
    success, output = _ssh_command(vm_id, f'docker restart {container_name}')

    if success:
        return jsonify({
            'status': 'ok',
            'action': 'restarted',
            'container': container_name,
            'vm': vm_id,
            'message': f'Container {container_name} restarted'
        })

    return jsonify({
        'error': f'Failed to restart container: {output}',
        'container': container_name,
        'vm': vm_id
    }), 500


@api_bp.route('/vms/<vm_id>/containers/<container_name>/stop', methods=['POST'])
def stop_container(vm_id: str, container_name: str):
    """Stop a Docker container on a VM."""
    success, output = _ssh_command(vm_id, f'docker stop {container_name}')

    if success:
        return jsonify({
            'status': 'ok',
            'action': 'stopped',
            'container': container_name,
            'vm': vm_id
        })

    return jsonify({
        'error': f'Failed to stop container: {output}',
        'container': container_name,
        'vm': vm_id
    }), 500


@api_bp.route('/vms/<vm_id>/containers/<container_name>/start', methods=['POST'])
def start_container(vm_id: str, container_name: str):
    """Start a Docker container on a VM."""
    success, output = _ssh_command(vm_id, f'docker start {container_name}')

    if success:
        return jsonify({
            'status': 'ok',
            'action': 'started',
            'container': container_name,
            'vm': vm_id
        })

    return jsonify({
        'error': f'Failed to start container: {output}',
        'container': container_name,
        'vm': vm_id
    }), 500
