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

// Mail
pub const MAIL_DOMAIN: &str = "mail.diegonmarcos.com";
pub const WEBMAIL_DOMAIN: &str = "webmail.diegonmarcos.com";
// Mail clients connect on :443 (Caddy L4 SNI mux), NOT raw 993/465 — those
// legacy ports were collapsed away (see "Public surface collapsed to
// 443+51820+25" memory). imap./smtps. are the real client-facing hostnames
// per B.2; mail.diegonmarcos.com itself only serves HTTPS admin.
pub const IMAP_DOMAIN: &str = "imap.diegonmarcos.com";
pub const SMTPS_DOMAIN: &str = "smtps.diegonmarcos.com";
pub const AUTH_DOMAIN: &str = "auth.diegonmarcos.com";
pub const MCP_DOMAIN: &str = "mcp.diegonmarcos.com";
pub const BASE_DOMAIN: &str = "diegonmarcos.com";
pub const MAIL_CONTAINERS: &[&str] = &["maddy"];
// http-to-smtp-proxy-api runs on gcp-proxy, NOT oci-mail — container_health()
// only ever inspects oci-mail's `docker ps`, so listing it here always
// reports a false "NOT FOUND". Its real liveness signal is the live WG
// probe "IN→4 http-to-smtp-proxy-api :8090 (gcp-proxy)" in path_checker().
pub const EXTRA_CONTAINERS: &[&str] = &["snappymail"];
pub const TEST_FROM: &str = "health@mails.diegonmarcos.com";
pub const TEST_TO: &str = "me@diegonmarcos.com";

// Ports to verify bound on oci-mail
pub const EXPECTED_PORTS: &[u16] = &[25, 143, 465, 587, 993, 8888];

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
pub const HTTP_TO_SMTP_PROXY_API_PORT: u16 = 8080;

// Cloudflare Worker
pub const CF_WORKER_URL: &str = "https://email-forwarder.diegonm-workers.workers.dev";

// Google OAuth token endpoint (for Gmail API health)
pub const GOOGLE_TOKEN_URL: &str = "https://oauth2.googleapis.com/token";

// Maddy CLI (no REST API — admin via `docker exec maddy maddy ...`)
