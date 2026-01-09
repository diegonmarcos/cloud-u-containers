# Palantir Monitor (Lite) - Tera Template Edition

> "The Palantíri were made by the Elves of Valinor... those who looked into them could perceive events and places far away in space and time."

Lightweight cloud infrastructure monitoring with beautiful Tera-templated reports.

## Features

- 📊 **Structured Reports**: Beautiful markdown reports using Tera templating (Jinja2-like)
- 🔍 **140+ Automated Checks**: External connectivity, VM health, Docker status, security, malware scans
- 📧 **Rich Email Delivery**: MD + JSON attachments + HTML email body
- 💾 **Tiny Footprint**: ~30MB RAM, ~15MB image
- ⏰ **Scheduled**: Daily reports at 7 AM UTC

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                  palantir-monitor (lite + tera)              │
│                     Alpine/Debian + Rust                     │
├─────────────────────────────────────────────────────────────┤
│  Tools: bash, curl, jq, nc, dig, openssl, ssh, swaks        │
│  Renderer: Rust + Tera templating engine                    │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐    │
│  │ Bash     │  │ JSON     │  │ Tera     │  │ Email    │    │
│  │ Checks   │→ │ Data     │→ │ Renderer │→ │ Sender   │    │
│  └──────────┘  └──────────┘  └──────────┘  └──────────┘    │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

## Report Structure

The new Tera templates provide:

### 1️⃣ Executive Summary
- Total checks, pass/warn/fail counts
- Container health overview
- Visual status indicators

### 2️⃣ External Connectivity
- VM SSH accessibility
- Web services HTTPS checks
- Mail server ports
- DNS validation

### 3️⃣ Cloud Infrastructure
- VM health metrics (uptime, load, memory)
- Disk usage analysis
- Docker container status per VM

### 4️⃣ Docker Summary
- Cross-VM aggregation
- Unhealthy container detection

### 5️⃣ Port Analysis
- Expected port validation
- Unexpected risky port scanning
- Container port mapping

### 6️⃣ IP Address Inventory
- DNS reconciliation
- Cloudflare proxy detection
- Network topology

### 7️⃣ Security Checks
- SSL certificate expiration
- Security headers validation
- Container security review

### 8️⃣ Malware Scans
- Sauron YARA integration
- Alert aggregation

## Template Customization

Edit `templates/health-report.md` to customize the report layout:

```jinja2
# Example: Custom section
## {{ custom_section.title }}

{% for item in custom_section.items %}
- {{ item.name }}: {% if item.status == "ok" %}✅{% else %}❌{% endif %}
{% endfor %}
```

## JSON Data Structure

Check `data/sample-report.json` for the complete schema:

```json
{
  "metadata": {
    "timestamp": "2026-01-08 19:44:14 UTC",
    "report_id": "1736364254"
  },
  "summary": {
    "total_checks": 141,
    "ok_count": 72,
    "warn_count": 11,
    "fail_count": 18
  },
  "vms": [
    {
      "name": "gcp-micro-1",
      "ip": "35.226.147.64",
      "uptime": "up 1 week, 3 days",
      "docker": {
        "running": 9,
        "containers": [...]
      }
    }
  ]
}
```

## Usage

### Manual Run
```bash
docker run --rm palantir-monitor
```

### Scheduled (Daily 7 AM UTC)
```bash
docker-compose up -d palantir-cron
```

### Build Tera Renderer
```bash
cargo build --release
```

### Test Template Rendering
```bash
cat data/sample-report.json | cargo run > test-report.md
```

## Email Delivery

Reports are delivered via 3 methods:

1. **Primary**: Mailu SMTPS (port 465) with attachments
   - `health-report.md` (markdown)
   - `health-report.json` (JSON)
   - HTML body (converted from markdown)

2. **Fallback**: HTTP SMTP proxy (inline text)

3. **Final**: ntfy push notification (summary)

## Files

```
palantir-monitor/
├── Dockerfile              # Multi-stage: Rust builder + Alpine runtime
├── Cargo.toml              # Rust dependencies (tera, serde_json)
├── src/
│   └── main.rs             # Tera renderer
├── templates/
│   └── health-report.md    # Tera template
├── data/
│   └── sample-report.json  # Schema example
├── scripts/
│   ├── run-checks.sh       # Orchestrator (generates JSON)
│   ├── check-*.sh          # Individual check modules
│   └── md-to-html.sh       # Email HTML converter
└── config/
    └── endpoints.conf      # VM IPs, domains, ports
```

## Extending

### Add a New Check Category

1. Create `scripts/check-newfeature.sh`:
```bash
#!/bin/bash
echo "## New Feature Check"
echo "| Item | Status |"
echo "|------|--------|"
echo "| Test | [OK] |"
```

2. Update `run-checks.sh`:
```bash
/app/scripts/check-newfeature.sh >> "$REPORT_FILE"
```

3. Update template `templates/health-report.md`:
```jinja2
## 9️⃣ New Feature

{% for item in new_feature_items %}
| {{ item.name }} | {{ item.status }} |
{% endfor %}
```

4. Update JSON schema in `src/main.rs`:
```rust
#[derive(Debug, Serialize, Deserialize)]
struct NewFeature {
    name: String,
    status: String,
}
```

## Development

```bash
# Build renderer
cargo build --release

# Test with sample data
cat data/sample-report.json | ./target/release/palantir-renderer

# Test email conversion
./scripts/md-to-html.sh reports/latest.md > reports/latest.html
```

## License

MIT
