package config

import "os"

// SshConfig holds SSH connection details for a VM.
type SshConfig struct {
	Host    string
	User    string
	KeyPath string
}

// VmServiceMap maps services to their containers for a VM.
type VmServiceMap struct {
	Label    string
	Services map[string][]string
}

// RouteCheckDomain is a domain to probe for health.
type RouteCheckDomain struct {
	Domain  string
	Service string
}

// AppConfig holds all application configuration.
type AppConfig struct {
	Port               int
	VmSSH              map[string]SshConfig
	AllVmServices      map[string]VmServiceMap
	FlexVmID           string
	RouteCheckDomains  []RouteCheckDomain
	ContainerDomainMap map[string]string
}

// Load initializes the application config (mirrors Rust config.rs).
func Load() *AppConfig {
	sshKey := envOr("SSH_KEY_PATH", "/app/config/id_rsa")
	gcpKey := envOr("GCP_SSH_KEY_PATH", "/app/config/gcp_key")

	vmSSH := map[string]SshConfig{
		"oci-p-flex_1":  {Host: "10.0.0.2", User: "ubuntu", KeyPath: sshKey},
		"oci-f-micro_1": {Host: "10.0.0.3", User: "ubuntu", KeyPath: sshKey},
		"oci-f-micro_2": {Host: "10.0.0.4", User: "ubuntu", KeyPath: sshKey},
		"gcp-f-micro_1": {Host: "10.0.0.1", User: "diego", KeyPath: gcpKey},
	}

	allVmServices := map[string]VmServiceMap{
		"oci-p-flex_1": {
			Label: "oci-flex",
			Services: map[string][]string{
				"photos":     {"photoprism_app", "photoprism_mariadb"},
				"calendar":   {"radicale"},
				"hedgedoc":   {"hedgedoc_app", "hedgedoc_postgres"},
				"etherpad":   {"etherpad_app", "etherpad_postgres"},
				"grist":      {"grist_app"},
				"files":      {"filebrowser_app"},
				"slides":     {"revealmd_app"},
				"code":       {"code-server"},
				"nocodb":     {"nocodb_app", "nocodb_postgres"},
				"monitoring": {"lgtm_grafana", "lgtm_loki", "lgtm_mimir", "lgtm_tempo"},
				"git":        {"gitea"},
				"cache":      {"redis"},
				"security":   {"sauron"},
				"logs":       {"fluent-bit"},
			},
		},
		"gcp-f-micro_1": {
			Label: "gcp-proxy",
			Services: map[string][]string{
				"proxy":         {"npm", "introspect-proxy"},
				"auth":          {"authelia", "authelia-redis"},
				"api":           {"flask-api"},
				"notifications": {"ntfy"},
				"passwords":     {"vaultwarden"},
				"logs":          {"fluent-bit"},
			},
		},
		"oci-f-micro_1": {
			Label: "oci-mail",
			Services: map[string][]string{
				"mail":       {"mailu-front-1", "mailu-admin-1", "mailu-imap-1", "mailu-smtp-1", "mailu-antispam-1", "mailu-webmail-1", "mailu-redis-1", "mailu-resolver-1"},
				"calendar":   {"radicale"},
				"smtp_proxy": {"smtp-proxy"},
				"sync":       {"syncthing"},
				"analytics":  {"matomo-app", "matomo-db"},
				"proxy":      {"nginx-proxy"},
				"logs":       {"fluent-bit", "syslog-forwarder"},
			},
		},
		"oci-f-micro_2": {
			Label: "oci-analytics",
			Services: map[string][]string{
				"analytics":  {"matomo-hybrid"},
				"security":   {"sauron", "sauron-forwarder"},
				"automation": {"windmill-server", "windmill-worker", "windmill-db"},
				"logs":       {"fluent-bit", "syslog-forwarder"},
			},
		},
	}

	containerDomainMap := map[string]string{
		"authelia":       "auth.diegonmarcos.com",
		"vaultwarden":    "vault.diegonmarcos.com",
		"ntfy":           "rss.diegonmarcos.com",
		"photoprism_app": "photos.diegonmarcos.com",
		"nocodb_app":     "db.diegonmarcos.com",
		"code-server":    "ide.diegonmarcos.com",
		"syncthing":      "sync.diegonmarcos.com",
		"radicale":       "cal.diegonmarcos.com",
		"matomo-hybrid":  "analytics.diegonmarcos.com",
		"mailu-front-1":  "mail.diegonmarcos.com",
		"flask-api":      "api.diegonmarcos.com",
		"affine":         "drive-notes-affine.diegonmarcos.com",
	}

	routeCheckDomains := []RouteCheckDomain{
		{Domain: "analytics.diegonmarcos.com", Service: "analytics"},
		{Domain: "db.diegonmarcos.com", Service: "db"},
		{Domain: "ide.diegonmarcos.com", Service: "ide"},
		{Domain: "auth.diegonmarcos.com", Service: "auth"},
		{Domain: "photos.diegonmarcos.com", Service: "photos"},
		{Domain: "cal.diegonmarcos.com", Service: "cal"},
		{Domain: "api.diegonmarcos.com", Service: "api"},
	}

	return &AppConfig{
		Port:               8090,
		VmSSH:              vmSSH,
		AllVmServices:      allVmServices,
		FlexVmID:           "oci-p-flex_1",
		RouteCheckDomains:  routeCheckDomains,
		ContainerDomainMap: containerDomainMap,
	}
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
