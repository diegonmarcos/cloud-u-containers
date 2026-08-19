// VM identifiers
#[allow(dead_code)]
pub const MAIL_VM: &str = "oci-E2-f_0";
pub const MAIL_ALIAS: &str = "oci-mail";
pub const MAIL_WG_IP: &str = "10.0.0.3";

#[allow(dead_code)]
pub const C3_VM: &str = "oci-A1-f_0";
pub const APPS_ALIAS: &str = "oci-apps";
pub const APPS_WG_IP: &str = "10.0.0.6";

#[allow(dead_code)]
pub const PROXY_VM: &str = "gcp-E2-f_0";
pub const PROXY_ALIAS: &str = "gcp-proxy";
pub const PROXY_WG_IP: &str = "10.0.0.1";

// DKIM signing selector. Source of truth: cloud-repo
// a_solutions/user-comm_tools-maddy/src/templates/maddy.conf.tpl.tpl
//   "Maddy signs DKIM (selector: default)" → modify { dkim ... default }
// The published TXT lives at `default._domainkey.diegonmarcos.com`.
// Was probed as `dkim._domainkey` (no such record) → permanent false-RED.
pub const DKIM_SELECTOR: &str = "default";

// Mail
pub const MAIL_DOMAIN: &str = "mail.diegonmarcos.com";
pub const WEBMAIL_DOMAIN: &str = "webmail.diegonmarcos.com";
// Mail clients connect on :443 (Caddy L4 SNI mux), NOT raw 993/465 — those
// legacy ports were collapsed into the public-surface reduction (see
// "Public surface collapsed to 443+51820+25" memory). imap./smtps. are the
// real client-facing hostnames per B.2; mail.diegonmarcos.com itself only
// serves HTTPS admin.
pub const IMAP_DOMAIN: &str = "imap.diegonmarcos.com";
pub const SMTPS_DOMAIN: &str = "smtps.diegonmarcos.com";
pub const AUTH_DOMAIN: &str = "auth.diegonmarcos.com";
pub const MCP_DOMAIN: &str = "mcp.diegonmarcos.com";
pub const BASE_DOMAIN: &str = "diegonmarcos.com";

// JMAP autoconfig discovery URLs per RFC 8620 §2.2.
// Mirrors the 3 equivalent endpoints declared in cloud-repo
// aa-sui_tools-stalwart/build.json::containers.app.proxy.well_known:
//   1. subdomain well-known (canonical)
//   2. bare-host shortcut (308 → #1)
//   3. apex well-known (autoconfig — client enters me@diegonmarcos.com)
// Each must return HTTP 200 AND a JSON body containing
// `capabilities.urn:ietf:params:jmap:core` — status alone is a
// false-positive trap (Caddy 404 page and Authelia login HTML both
// return HTTP 200 when the route is mis-wired).
pub const JMAP_DISCOVERY_URLS: &[&str] = &[
    "https://jmap.diegonmarcos.com/.well-known/jmap",
    "https://jmap.diegonmarcos.com/",
    "https://diegonmarcos.com/.well-known/jmap",
];

// (STALWART_*_HOST constants removed — the imap-stalwart/smtps-stalwart/
// mail-stalwart Caddy SNI subhostnames were retired upstream, so the
// STAL→ probe group was removed from phases::path_checker. Public
// JMAP discovery is already covered by the DISC→ group on the active
// jmap.diegonmarcos.com canonical hostname.)

// (WG_PUBLIC_PEERS constant removed alongside the WGP→ probe group in
// phases::path_checker. Both :443 and :22 probes produced structural
// false-negatives because the wg-public address doesn't expose any
// uniform liveness port — see the comment block at the WGP removal
// site. Re-add only when the wg-quick handshake-age check is wired.)
pub const MAIL_CONTAINERS: &[&str] = &["maddy"];
// http-to-smtp-proxy-api runs on gcp-proxy, NOT oci-mail — container_health()
// only ever inspects oci-mail's `docker ps`, so listing it here always
// reports a false "NOT FOUND". Its real liveness signal is the live WG
// probe "IN→4 http-to-smtp-proxy-api :8090 (gcp-proxy)" in path_checker().
pub const EXTRA_CONTAINERS: &[&str] = &["snappymail"];
pub const TEST_FROM: &str = "health@mails.diegonmarcos.com";
pub const TEST_TO: &str = "me@diegonmarcos.com";

// Ports to verify bound on oci-mail.
//
// 587 (SMTP submission) intentionally NOT included: neither Maddy nor Stalwart
// binds it on this VM. Public submission is handled by the http-to-smtp-proxy-api
// on gcp-proxy, which speaks SMTP to oci-mail on :25 over WG. Stalwart declares
// 587 internally but the Phase-4 compose doesn't map it to the host. Including
// 587 in this list produces a spurious "All ports bound — missing: 587" failure.
//
// 8888 = Maddy admin debug socket (legacy; bound on 0.0.0.0 by Maddy).
pub const EXPECTED_PORTS: &[u16] = &[25, 143, 465, 993, 8888];

// Bearer token path (relative to $HOME)
pub const BEARER_TOKEN_PATH: &str =
    "git/cloud-vault/A0_keys/providers/authelia/signed-bearer_jwt/tokens/cloud-admin.json";

// SMTP relay hosts
pub const OCI_RELAY_HOST: &str = "smtp.email.eu-marseille-1.oci.oraclecloud.com";
pub const OCI_RELAY_PORT: u16 = 587;
pub const AWS_RELAY_HOST: &str = "email-smtp.us-east-1.amazonaws.com";
pub const AWS_RELAY_PORT: u16 = 587;
pub const HTTP_TO_SMTP_PROXY_API_DOMAIN: &str = "api.diegonmarcos.com";
pub const HTTP_TO_SMTP_PROXY_API_PATH: &str = "/http-to-smtp-proxy-api";
// Bridge listen port. Source of truth: cloud-repo
// a_solutions/infra-api_tools-http-to-smtp-proxy-api/build.json::ports.app = 8090
// (also main.rs LISTEN_PORT default 8090 + Dockerfile EXPOSE 8090).
// Was 8080 — a stale value that probed a DIFFERENT service on gcp-proxy,
// making IN→4 a false-OK (8080 also happens to be open, so the wrong-port
// probe silently passed while never touching the actual bridge).
pub const HTTP_TO_SMTP_PROXY_API_PORT: u16 = 8090;

// Cloudflare Worker
pub const CF_WORKER_URL: &str = "https://email-forwarder.diegonm-workers.workers.dev";

// Google OAuth token endpoint (for Gmail API health)
pub const GOOGLE_TOKEN_URL: &str = "https://oauth2.googleapis.com/token";

// Maddy CLI (no REST API — admin via `docker exec maddy maddy ...`)
