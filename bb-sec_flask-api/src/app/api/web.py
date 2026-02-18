"""
Web Routes for Cloud Dashboard (HTML templates)
Serves the dashboard HTML page - static data only, JS fetches status async
"""
from datetime import datetime
from flask import Blueprint, render_template, redirect

from app.config import (
    get_vm_ids_by_category, get_vm_categories, get_vm_category_name, get_vm,
    get_service_ids_by_category, get_service_categories, get_service_category_name, get_svc
)

web_bp = Blueprint('web', __name__)

VERSION = "5.1.0"

# API documentation URL (Swagger UI on GitHub Pages)
DOCS_URL = "https://diegonmarcos.github.io/api/"


@web_bp.route('/')
@web_bp.route('/docs')
def api_docs():
    """Redirect to API documentation (Swagger UI on GitHub Pages)."""
    return redirect(DOCS_URL)


@web_bp.route('/dashboard')
def dashboard():
    """Render the main dashboard HTML page with static config data.

    Status updates are fetched asynchronously via JavaScript.
    This allows the page to load instantly.
    """

    # Gather VM data (static config only, no health checks)
    vm_categories = []
    for cat_id in get_vm_categories():
        cat_vms = []
        for vm_id in get_vm_ids_by_category(cat_id):
            vm_data = get_vm(vm_id)

            cat_vms.append({
                'id': vm_id,
                'name': vm_data.get('name', ''),
                'ip': vm_data.get('network', {}).get('publicIp', ''),
                'type': vm_data.get('instanceType', ''),
                'config_status': vm_data.get('status', 'active')  # For JS to check pending
            })

        if cat_vms:
            vm_categories.append({
                'id': cat_id,
                'name': get_vm_category_name(cat_id),
                'vms': cat_vms
            })

    # Gather Service data (static config only, no health checks)
    service_categories = []
    for cat_id in get_service_categories():
        cat_svcs = []
        for svc_id in get_service_ids_by_category(cat_id):
            svc_data = get_svc(svc_id)
            url = svc_data.get('urls', {}).get('gui') or svc_data.get('urls', {}).get('admin')

            # Create short URL for display
            short_url = '-'
            if url and url != 'null':
                short_url = url.replace('https://', '').replace('http://', '')
                if len(short_url) > 36:
                    short_url = short_url[:33] + '...'

            cat_svcs.append({
                'id': svc_id,
                'name': svc_data.get('name', ''),
                'url': url if url and url != 'null' else None,
                'short_url': short_url,
                'config_status': svc_data.get('status', 'active')  # For JS to check dev/planned
            })

        if cat_svcs:
            service_categories.append({
                'id': cat_id,
                'name': get_service_category_name(cat_id),
                'services': cat_svcs
            })

    return render_template(
        'dashboard.html',
        version=VERSION,
        timestamp=datetime.now().strftime('%Y-%m-%d %H:%M:%S'),
        vm_categories=vm_categories,
        service_categories=service_categories
    )
