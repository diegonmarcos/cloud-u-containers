# 📊 Cloud Infrastructure Health Report

**Generated:** {{ metadata.timestamp }}
**Report ID:** {{ metadata.report_id }}
**Status:** {% if summary.fail_count > 0 %}🔴 ALERT{% elif summary.warn_count > 0 %}🟡 WARNING{% else %}🟢 ALL SYSTEMS OPERATIONAL{% endif %}

---

## 🎯 Executive Summary

| Metric | Value | Status |
|--------|-------|--------|
| **Total Checks** | {{ summary.total_checks }} | - |
| ✅ **Passed** | {{ summary.ok_count }} | {% if summary.ok_count > 100 %}Excellent{% elif summary.ok_count > 50 %}Good{% else %}Needs Attention{% endif %} |
| ⚠️ **Warnings** | {{ summary.warn_count }} | {% if summary.warn_count == 0 %}None{% elif summary.warn_count < 10 %}Acceptable{% else %}Review Needed{% endif %} |
| ❌ **Failures** | {{ summary.fail_count }} | {% if summary.fail_count == 0 %}None{% elif summary.fail_count < 5 %}Minor Issues{% else %}Critical{% endif %} |
| 🐳 **Containers Running** | {{ docker_summary.total_running }} | Active |
| 🔒 **Unhealthy Containers** | {{ docker_summary.total_unhealthy }} | {% if docker_summary.total_unhealthy == 0 %}✅ None{% else %}⚠️ {{ docker_summary.total_unhealthy }}{% endif %} |

---

## 1️⃣ External Connectivity

Tests all services from the **outside** (as users would access them)

### VM SSH Accessibility

| Server | Endpoint | Status | Uptime |
|--------|----------|--------|--------|
{% for vm in vms -%}
| {{ vm.name }} | {{ vm.ip }}:22 | {% if vm.ssh_accessible %}✅ OK{% else %}❌ FAIL{% endif %} | {{ vm.uptime | default(value="N/A") }} |
{% endfor %}

**Summary:** {{ vms | filter(attribute="ssh_accessible", value=true) | length }}/{{ vms | length }} VMs accessible

### Web Services (HTTPS)

| Service | URL | HTTP Status | Response Time | Health |
|---------|-----|-------------|---------------|--------|
{% for service in web_services -%}
| {{ service.name }} | {{ service.url }} | {{ service.http_code }} | {{ service.response_time }}ms | {% if service.http_code == 200 %}✅ OK{% elif service.http_code >= 300 and service.http_code < 400 %}🔄 Redirect{% elif service.http_code == 0 %}❌ Unreachable{% else %}⚠️ {{ service.http_code }}{% endif %} |
{% endfor %}

**Summary:** {{ web_services | filter(attribute="http_code", value=200) | length }}/{{ web_services | length }} services healthy

### Mail Server Ports

| Service | Endpoint | Port | Status |
|---------|----------|------|--------|
{% for port in mail_ports -%}
| {{ port.service }} | {{ port.host }}:{{ port.port }} | {{ port.port }} | {% if port.open %}✅ Open{% else %}❌ Closed{% endif %} |
{% endfor %}

### DNS Record Validation

| Record Type | Domain | Expected IP | Current IP | Status |
|-------------|--------|-------------|------------|--------|
{% for dns in dns_records -%}
| {{ dns.type }} | {{ dns.domain }} | {{ dns.expected_ip | default(value="N/A") }} | {{ dns.current_ip | default(value="No record") }} | {% if dns.expected_ip == dns.current_ip %}✅ Match{% elif dns.current_ip %}⚠️ Mismatch{% else %}❌ Missing{% endif %} |
{% endfor %}

**Total External Checks:** {{ summary.external_checks }}

---

## 2️⃣ Cloud Infrastructure Status

Uses **SSH** to gather system metrics from each VM

### VM Health Metrics

| VM | IP | Uptime | Load (1m/5m/15m) | Memory | Disk | Status |
|----|-----|--------|------------------|--------|------|--------|
{% for vm in vms -%}
| **{{ vm.name }}** | {{ vm.ip }} | {{ vm.uptime | default(value="❌ Unreachable") }} | {{ vm.load | default(value="-") }} | {% if vm.memory_pct %}{{ vm.memory_used }}/{{ vm.memory_total }}MB ({{ vm.memory_pct }}%){% else %}-{% endif %} | {% if vm.disk_pct %}{{ vm.disk_pct }}%{% if vm.disk_pct > 90 %} 🔴{% elif vm.disk_pct > 80 %} ⚠️{% endif %}{% else %}-{% endif %} | {% if vm.reachable %}{% if vm.memory_pct > 90 or vm.disk_pct > 90 %}⚠️ High Usage{% else %}✅ Healthy{% endif %}{% else %}❌ Down{% endif %} |
{% endfor %}

### Disk Usage Details

| VM | Filesystem | Size | Used | Available | Usage % | Status |
|----|------------|------|------|-----------|---------|--------|
{% for vm in vms | filter(attribute="reachable", value=true) -%}
| {{ vm.name }} | / | {{ vm.disk_size }} | {{ vm.disk_used }} | {{ vm.disk_avail }} | {{ vm.disk_pct }}% | {% if vm.disk_pct > 90 %}🔴 Critical{% elif vm.disk_pct > 80 %}⚠️ Warning{% else %}✅ OK{% endif %} |
{% endfor %}

### Docker Container Status

{% for vm in vms | filter(attribute="reachable", value=true) -%}
#### {{ vm.name }} ({{ vm.ip }})

**Containers:** {{ vm.docker.running | default(value=0) }} running, {{ vm.docker.stopped | default(value=0) }} stopped

{% if vm.docker.containers %}
| Name | Image | Status | Health |
|------|-------|--------|--------|
{% for container in vm.docker.containers -%}
| {{ container.name }} | {{ container.image }} | {{ container.status }} | {% if container.health == "healthy" %}✅{% elif container.health == "unhealthy" %}❌{% else %}-{% endif %} |
{% endfor %}
{% else %}
*No Docker data available*
{% endif %}

{% endfor %}

**Total Infrastructure Checks:** {{ summary.infra_checks }}

---

## 3️⃣ Docker Summary

Cross-VM container health aggregation

| VM | 🟢 Running | 🔴 Stopped | ⚠️ Unhealthy | 📦 Images |
|----|-----------|-----------|-------------|----------|
{% for vm in vms -%}
| {{ vm.name }} | {{ vm.docker.running | default(value="-") }} | {{ vm.docker.stopped | default(value="-") }} | {% if vm.docker.unhealthy > 0 %}⚠️ {{ vm.docker.unhealthy }}{% else %}{{ vm.docker.unhealthy | default(value="-") }}{% endif %} | {{ vm.docker.images | default(value="-") }} |
{% endfor %}
| **TOTAL** | **{{ docker_summary.total_running }}** | **{{ docker_summary.total_stopped }}** | **{% if docker_summary.total_unhealthy > 0 %}⚠️ {{ docker_summary.total_unhealthy }}{% else %}0{% endif %}** | **{{ docker_summary.total_images }}** |

{% if docker_summary.total_unhealthy > 0 %}
### 🚨 Unhealthy Containers Detected

{% for vm in vms -%}
{% if vm.docker.unhealthy > 0 %}
- **{{ vm.name }}**: {{ vm.docker.unhealthy }} unhealthy container(s)
{% endif %}
{% endfor %}
{% endif %}

---

## 4️⃣ Port Analysis

External port scanning + security validation

### Expected Port Validation

{% for vm in vms -%}
#### {{ vm.name }} ({{ vm.ip }})

| Port | Service | Expected | Status |
|------|---------|----------|--------|
{% for port in vm.ports -%}
| {{ port.port }} | {{ port.service }} | {% if port.expected %}Yes{% else %}No{% endif %} | {% if port.open %}✅ Open{% elif port.expected %}❌ Closed{% else %}✅ Closed{% endif %} |
{% endfor %}

{% endfor %}

### Unexpected Open Ports

{% if risky_ports | length > 0 %}
⚠️ **Risky ports detected:**

| VM | Port | Service | Risk Level |
|----|------|---------|------------|
{% for port in risky_ports -%}
| {{ port.vm }} | {{ port.port }} | {{ port.service }} | {% if port.risk == "high" %}🔴 High{% elif port.risk == "medium" %}🟡 Medium{% else %}🟢 Low{% endif %} |
{% endfor %}
{% else %}
✅ **No unexpected risky ports detected**
{% endif %}

**Total Port Checks:** {{ summary.port_checks }}

---

## 5️⃣ IP Address Inventory

DNS reconciliation and network topology

### Expected vs Actual IPs

| Resource | Expected IP | Current DNS | Cloudflare Proxied | Status |
|----------|-------------|-------------|-------------------|--------|
{% for ip in ip_inventory -%}
| {{ ip.name }} | {{ ip.expected }} | {{ ip.current | default(value="No DNS") }} | {% if ip.proxied %}Yes{% else %}No{% endif %} | {% if ip.expected == ip.current %}✅ Match{% elif ip.current and ip.proxied %}🔄 Proxied{% elif ip.current %}⚠️ Mismatch{% else %}❌ Missing{% endif %} |
{% endfor %}

### Cloudflare DNS Records

```
# A Records
{% for record in dns_a_records -%}
{{ record.domain | truncate(length=40) }}{{ " " | repeat(times=42 - record.domain | length) }}-> {{ record.ip }}
{% endfor %}

# MX Records
{% for record in dns_mx_records -%}
{{ record.priority }} {{ record.server }}
{% endfor %}

{% if dns_cname_records | length > 0 %}
# CNAME Records
{% for record in dns_cname_records -%}
{{ record.domain }}{{ " " | repeat(times=42 - record.domain | length) }}-> {{ record.target }}
{% endfor %}
{% endif %}
```

### Public IP Detection

```
Monitoring Container IP: {{ public_ip }}
```

**Total IP Checks:** {{ summary.ip_checks }}

---

## 6️⃣ Security Checks

SSL certificates, headers, and vulnerability scanning

### SSL Certificate Status

| Domain | Expires | Days Left | Status |
|--------|---------|-----------|--------|
{% for cert in ssl_certs -%}
| {{ cert.domain }} | {{ cert.expiry_date }} | {{ cert.days_left }} | {% if cert.days_left < 0 %}🔴 Expired{% elif cert.days_left < 7 %}🔴 Critical{% elif cert.days_left < 30 %}⚠️ Warning{% else %}✅ OK{% endif %} |
{% endfor %}

{% if ssl_certs | filter(attribute="days_left", value=30, operator="lt") | length > 0 %}
⚠️ **Certificates expiring soon:**
{% for cert in ssl_certs | filter(attribute="days_left", value=30, operator="lt") -%}
- {{ cert.domain }}: {{ cert.days_left }} days remaining
{% endfor %}
{% endif %}

### Security Headers Validation

{% for domain in security_headers -%}
#### {{ domain.url }}

| Header | Status | Value |
|--------|--------|-------|
| HSTS | {% if domain.headers.hsts %}✅ Present{% else %}⚠️ Missing{% endif %} | {{ domain.headers.hsts | default(value="-") }} |
| X-Frame-Options | {% if domain.headers.x_frame %}✅ Present{% else %}⚠️ Missing{% endif %} | {{ domain.headers.x_frame | default(value="-") }} |
| X-Content-Type-Options | {% if domain.headers.x_content_type %}✅ Present{% else %}⚠️ Missing{% endif %} | {{ domain.headers.x_content_type | default(value="-") }} |
| CSP | {% if domain.headers.csp %}✅ Present{% else %}ℹ️ Optional{% endif %} | {{ domain.headers.csp | default(value="-") }} |

{% endfor %}

### Container Security Review

{% if container_security | length > 0 %}
| Container | User | Privileged | Memory Limit | CPU Limit | Status |
|-----------|------|------------|--------------|-----------|--------|
{% for container in container_security -%}
| {{ container.name }} | {{ container.user }} | {% if container.privileged %}⚠️ Yes{% else %}✅ No{% endif %} | {{ container.memory_limit | default(value="None") }} | {{ container.cpu_limit | default(value="None") }} | {% if container.privileged or not container.memory_limit %}⚠️ Review{% else %}✅ OK{% endif %} |
{% endfor %}
{% else %}
*Container security scan not available (requires docker socket access)*
{% endif %}

**Total Security Checks:** {{ summary.security_checks }}

---

## 7️⃣ Malware Scan Reports

YARA scanner alerts from all VMs

{% for vm in vms -%}
### {{ vm.name }} ({{ vm.ip }})

{% if vm.sauron.available %}
**Status:** ✅ Active
**Last Scan:** {{ vm.sauron.last_scan }}
**Files Scanned:** {{ vm.sauron.files_scanned }}
**Alerts:** {% if vm.sauron.alerts > 0 %}⚠️ {{ vm.sauron.alerts }}{% else %}0{% endif %}

{% if vm.sauron.recent_alerts | length > 0 %}
#### Recent Alerts
{% for alert in vm.sauron.recent_alerts -%}
- **{{ alert.timestamp }}** - {{ alert.rule }}: {{ alert.file }}
{% endfor %}
{% endif %}
{% else %}
**Status:** ⚠️ {% if not vm.reachable %}VM Unreachable{% else %}Sauron not deployed{% endif %}
{% endif %}

{% endfor %}

### Malware Scan Summary

| Metric | Value |
|--------|-------|
| Active Scanners | {{ sauron_summary.active_scanners }} / {{ vms | length }} |
| Total Alerts | {% if sauron_summary.total_alerts > 0 %}⚠️ {{ sauron_summary.total_alerts }}{% else %}0{% endif %} |

---

## 🔴 Issues Requiring Attention

{% set critical_issues = [] %}
{% set warnings = [] %}

{% for vm in vms -%}
  {% if not vm.reachable and vm.name != "oci-flex-1" %}
    {% set_global critical_issues = critical_issues | concat(with="VM " ~ vm.name ~ " is unreachable") %}
  {% endif %}
  {% if vm.disk_pct > 90 %}
    {% set_global critical_issues = critical_issues | concat(with="VM " ~ vm.name ~ " disk usage critical: " ~ vm.disk_pct ~ "%") %}
  {% elif vm.disk_pct > 80 %}
    {% set_global warnings = warnings | concat(with="VM " ~ vm.name ~ " disk usage high: " ~ vm.disk_pct ~ "%") %}
  {% endif %}
  {% if vm.memory_pct > 90 %}
    {% set_global warnings = warnings | concat(with="VM " ~ vm.name ~ " memory usage high: " ~ vm.memory_pct ~ "%") %}
  {% endif %}
{% endfor %}

{% for cert in ssl_certs -%}
  {% if cert.days_left < 7 %}
    {% set_global critical_issues = critical_issues | concat(with="SSL certificate for " ~ cert.domain ~ " expires in " ~ cert.days_left ~ " days") %}
  {% elif cert.days_left < 30 %}
    {% set_global warnings = warnings | concat(with="SSL certificate for " ~ cert.domain ~ " expires in " ~ cert.days_left ~ " days") %}
  {% endif %}
{% endfor %}

{% if docker_summary.total_unhealthy > 0 %}
  {% set_global critical_issues = critical_issues | concat(with=docker_summary.total_unhealthy ~ " unhealthy container(s) detected") %}
{% endif %}

### 🔴 Critical Issues ({{ critical_issues | length }})

{% if critical_issues | length > 0 %}
{% for issue in critical_issues -%}
{{ loop.index }}. {{ issue }}
{% endfor %}
{% else %}
✅ **No critical issues detected**
{% endif %}

### ⚠️ Warnings ({{ warnings | length }})

{% if warnings | length > 0 %}
{% for warning in warnings -%}
{{ loop.index }}. {{ warning }}
{% endfor %}
{% else %}
✅ **No warnings**
{% endif %}

### ℹ️ Expected Issues ({{ expected_issues | length }})

{% if expected_issues | length > 0 %}
{% for issue in expected_issues -%}
{{ loop.index }}. {{ issue.description }} - *{{ issue.reason }}*
{% endfor %}
{% else %}
*None*
{% endif %}

---

## 📊 Check Breakdown by Category

| Category | Total Checks | ✅ Passed | ⚠️ Warnings | ❌ Failed |
|----------|--------------|----------|------------|----------|
| External Connectivity | {{ summary.external_checks }} | {{ summary.external_ok }} | {{ summary.external_warn }} | {{ summary.external_fail }} |
| Cloud Infrastructure | {{ summary.infra_checks }} | {{ summary.infra_ok }} | {{ summary.infra_warn }} | {{ summary.infra_fail }} |
| Docker Summary | {{ summary.docker_checks }} | {{ summary.docker_ok }} | {{ summary.docker_warn }} | {{ summary.docker_fail }} |
| Port Analysis | {{ summary.port_checks }} | {{ summary.port_ok }} | {{ summary.port_warn }} | {{ summary.port_fail }} |
| IP Inventory | {{ summary.ip_checks }} | {{ summary.ip_ok }} | {{ summary.ip_warn }} | {{ summary.ip_fail }} |
| Security Checks | {{ summary.security_checks }} | {{ summary.security_ok }} | {{ summary.security_warn }} | {{ summary.security_fail }} |
| Malware Scans | {{ summary.malware_checks }} | {{ summary.malware_ok }} | {{ summary.malware_warn }} | {{ summary.malware_fail }} |
| **TOTAL** | **{{ summary.total_checks }}** | **{{ summary.ok_count }}** | **{{ summary.warn_count }}** | **{{ summary.fail_count }}** |

---

## 🎯 Recommendations

{% if critical_issues | length > 0 %}
### Immediate Actions Required
{% for issue in critical_issues -%}
{{ loop.index }}. Address: {{ issue }}
{% endfor %}
{% endif %}

{% if warnings | length > 0 %}
### Suggested Improvements
{% for warning in warnings -%}
{{ loop.index }}. Review: {{ warning }}
{% endfor %}
{% endif %}

### Proactive Maintenance
1. Monitor disk usage on gcp-micro-1 (currently at {{ (vms | filter(attribute="name", value="gcp-micro-1") | first).disk_pct }}%)
2. Verify NPM proxy admin SSL configuration
3. Consider deploying Sauron malware scanner on all VMs
4. Add security headers to mail.diegonmarcos.com

---

*Generated by **Palantir Monitor** (Lite)*
*Next scheduled report: {{ next_report_time }}*
*Report stored at: `{{ report_file }}`*
