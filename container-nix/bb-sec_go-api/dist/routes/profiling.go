package routes

import (
	"crypto/tls"
	"fmt"
	"net/http"
	"strings"
	"time"

	"github.com/diegonmarcos/go-api/config"
	"github.com/diegonmarcos/go-api/services"
	"github.com/go-chi/chi/v5"
)

// RegisterProfiling registers profiling endpoints under /go/profiling/*.
func RegisterProfiling(r chi.Router, cfg *config.AppConfig) {
	r.Get("/go/profiling/{container}", profileContainer(cfg))
	r.Get("/go/profiling/vm/{vm_id}", profileVM(cfg))
	r.Get("/go/profiling/authelia", profileAuthelia(cfg))
}

// resolveContainer finds which VM and service a container belongs to.
func resolveContainer(cfg *config.AppConfig, container string) (vmID, vmLabel, serviceName, domain string, found bool) {
	for vid, vmMap := range cfg.AllVmServices {
		for svcName, containers := range vmMap.Services {
			for _, c := range containers {
				if c == container {
					d := cfg.ContainerDomainMap[container]
					return vid, vmMap.Label, svcName, d, true
				}
			}
		}
	}
	return "", "", "", "", false
}

func profileContainer(cfg *config.AppConfig) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		container := chi.URLParam(r, "container")
		vmID, vmLabel, svcName, domain, found := resolveContainer(cfg, container)
		if !found {
			writeError(w, 404, fmt.Sprintf("Container '%s' not found in any VM", container))
			return
		}

		sshCfg, ok := cfg.VmSSH[vmID]
		if !ok {
			writeError(w, 500, fmt.Sprintf("No SSH config for VM %s", vmID))
			return
		}

		totalStart := time.Now()
		checks := []map[string]interface{}{}

		// Check 1: Ping
		pingStart := time.Now()
		pingOK := services.CheckPing(sshCfg.Host)
		checks = append(checks, map[string]interface{}{
			"name": "wireguard_ping", "success": pingOK,
			"time_ms": time.Since(pingStart).Milliseconds(),
			"data":    map[string]interface{}{"host": sshCfg.Host},
		})

		// Check 2: SSH
		sshStart := time.Now()
		sshOK := services.CheckSSH(sshCfg)
		checks = append(checks, map[string]interface{}{
			"name": "ssh_connectivity", "success": sshOK,
			"time_ms": time.Since(sshStart).Milliseconds(),
			"data":    map[string]interface{}{"host": sshCfg.Host},
		})

		if sshOK {
			// Check 3: Container status
			statusStart := time.Now()
			result := services.SshCommand(sshCfg, fmt.Sprintf(
				"docker inspect --format '{{.State.Status}}|{{.Config.Image}}' %s 2>&1", container))
			parts := strings.SplitN(result.Output, "|", 2)
			state := "unknown"
			image := ""
			if len(parts) >= 1 {
				state = parts[0]
			}
			if len(parts) >= 2 {
				image = parts[1]
			}
			checks = append(checks, map[string]interface{}{
				"name": "container_status", "success": state == "running",
				"time_ms": time.Since(statusStart).Milliseconds(),
				"data":    map[string]interface{}{"state": state, "image": image},
			})

			// Check 4: Docker network
			netStart := time.Now()
			netResult := services.SshCommand(sshCfg, fmt.Sprintf(
				"docker inspect --format '{{range .NetworkSettings.Networks}}{{.NetworkID}}{{end}}' %s 2>&1", container))
			netOK := netResult.Success && strings.TrimSpace(netResult.Output) != ""
			checks = append(checks, map[string]interface{}{
				"name": "docker_network", "success": netOK,
				"time_ms": time.Since(netStart).Milliseconds(),
				"data":    map[string]interface{}{"has_network": netOK},
			})

			// Check 5: Port reachability (host-level)
			portStart := time.Now()
			portResult := services.SshCommand(sshCfg, fmt.Sprintf(
				"docker inspect --format '{{range $p, $c := .NetworkSettings.Ports}}{{$p}} {{end}}' %s 2>&1", container))
			portOK := portResult.Success
			checks = append(checks, map[string]interface{}{
				"name": "port_reachability", "success": portOK,
				"time_ms": time.Since(portStart).Milliseconds(),
				"data":    map[string]interface{}{"ports": strings.TrimSpace(portResult.Output)},
			})

			// Check 6: WireGuard port reachability (from gcp-proxy)
			if vmID != "gcp-f-micro_1" {
				wgStart := time.Now()
				gcpSSH, gcpOk := cfg.VmSSH["gcp-f-micro_1"]
				wgOK := false
				if gcpOk {
					wgResult := services.SshCommand(gcpSSH, fmt.Sprintf(
						"timeout 3 bash -c 'echo > /dev/tcp/%s/22' 2>/dev/null && echo ok || echo fail", sshCfg.Host))
					wgOK = strings.Contains(wgResult.Output, "ok")
				}
				checks = append(checks, map[string]interface{}{
					"name": "wireguard_port_reachability", "success": wgOK,
					"time_ms": time.Since(wgStart).Milliseconds(),
					"data":    map[string]interface{}{"from": "gcp-proxy", "to": sshCfg.Host},
				})
			}

			// Check 7: iptables DNAT (check if nftables has relevant rules)
			dnatStart := time.Now()
			dnatResult := services.SshCommand(sshCfg, "nft list ruleset 2>/dev/null | grep -c dnat || iptables -t nat -S 2>/dev/null | grep -c DNAT || echo 0")
			dnatCount := strings.TrimSpace(dnatResult.Output)
			checks = append(checks, map[string]interface{}{
				"name": "iptables_dnat", "success": dnatResult.Success,
				"time_ms": time.Since(dnatStart).Milliseconds(),
				"data":    map[string]interface{}{"dnat_rules": dnatCount},
			})
		} else {
			for _, name := range []string{"container_status", "docker_network", "port_reachability", "wireguard_port_reachability", "iptables_dnat"} {
				checks = append(checks, map[string]interface{}{
					"name": name, "success": false, "time_ms": 0,
					"data": map[string]string{"error": "skipped: SSH unavailable"},
				})
			}
		}

		// Check 8: Authelia bearer auth (domain probe)
		if domain != "" {
			authStart := time.Now()
			authOK := probeWithBearer(cfg, domain)
			checks = append(checks, map[string]interface{}{
				"name": "authelia_bearer_auth", "success": authOK,
				"time_ms": time.Since(authStart).Milliseconds(),
				"data":    map[string]interface{}{"domain": domain},
			})
		}

		totalTime := time.Since(totalStart).Milliseconds()
		passed, failed := 0, 0
		for _, c := range checks {
			if c["success"].(bool) {
				passed++
			} else {
				failed++
			}
		}

		status := "healthy"
		if failed > 0 && passed > 0 {
			status = "degraded"
		} else if passed == 0 {
			status = "down"
		}

		resp := map[string]interface{}{
			"container":     container,
			"vm_id":         vmID,
			"vm_label":      vmLabel,
			"service":       svcName,
			"total_time_ms": totalTime,
			"checks":        checks,
			"summary": map[string]interface{}{
				"checks_passed":  passed,
				"checks_failed":  failed,
				"checks_total":   len(checks),
				"overall_status": status,
			},
		}
		if domain != "" {
			resp["domain"] = domain
		}

		writeJSON(w, resp)
	}
}

func profileVM(cfg *config.AppConfig) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		vmID := chi.URLParam(r, "vm_id")
		vmMap, ok := cfg.AllVmServices[vmID]
		if !ok {
			writeError(w, 404, "Unknown VM: "+vmID)
			return
		}

		totalStart := time.Now()
		allContainers := []string{}
		for _, containers := range vmMap.Services {
			allContainers = append(allContainers, containers...)
		}

		results := []map[string]interface{}{}
		healthy, degraded, down := 0, 0, 0

		for _, container := range allContainers {
			_, _, svcName, _, _ := resolveContainer(cfg, container)
			sshCfg, hasSsh := cfg.VmSSH[vmID]

			status := "down"
			if hasSsh {
				result := services.SshCommand(sshCfg, fmt.Sprintf(
					"docker inspect --format '{{.State.Status}}' %s 2>/dev/null || echo not_found", container))
				state := strings.TrimSpace(result.Output)
				if state == "running" {
					status = "healthy"
					healthy++
				} else {
					down++
				}
			} else {
				down++
			}

			results = append(results, map[string]interface{}{
				"container": container,
				"service":   svcName,
				"summary":   map[string]string{"overall_status": status},
			})
		}

		writeJSON(w, map[string]interface{}{
			"vm_id":         vmID,
			"label":         vmMap.Label,
			"total_time_ms": time.Since(totalStart).Milliseconds(),
			"containers":    results,
			"summary": map[string]int{
				"total": len(allContainers), "healthy": healthy,
				"degraded": degraded, "down": down,
			},
		})
	}
}

// profileAuthelia runs comprehensive checks on the Authelia auth chain.
func profileAuthelia(cfg *config.AppConfig) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		totalStart := time.Now()
		checks := []map[string]interface{}{}

		// 1. Authelia container status
		sshCfg, ok := cfg.VmSSH["gcp-f-micro_1"]
		if ok {
			statusStart := time.Now()
			result := services.SshCommand(sshCfg, "docker inspect --format '{{.State.Status}}' authelia 2>&1")
			checks = append(checks, map[string]interface{}{
				"name": "authelia_container", "success": strings.TrimSpace(result.Output) == "running",
				"time_ms": time.Since(statusStart).Milliseconds(),
				"data":    map[string]interface{}{"state": strings.TrimSpace(result.Output)},
			})

			// 2. Authelia Redis
			redisStart := time.Now()
			redisResult := services.SshCommand(sshCfg, "docker inspect --format '{{.State.Status}}' authelia-redis 2>&1")
			checks = append(checks, map[string]interface{}{
				"name": "authelia_redis", "success": strings.TrimSpace(redisResult.Output) == "running",
				"time_ms": time.Since(redisStart).Milliseconds(),
				"data":    map[string]interface{}{"state": strings.TrimSpace(redisResult.Output)},
			})

			// 3. Introspect proxy
			introStart := time.Now()
			introResult := services.SshCommand(sshCfg, "docker inspect --format '{{.State.Status}}' introspect-proxy 2>&1")
			checks = append(checks, map[string]interface{}{
				"name": "introspect_proxy", "success": strings.TrimSpace(introResult.Output) == "running",
				"time_ms": time.Since(introStart).Milliseconds(),
				"data":    map[string]interface{}{"state": strings.TrimSpace(introResult.Output)},
			})
		}

		// 4. Auth domain HTTPS
		authStart := time.Now()
		authOK := probeWithBearer(cfg, "auth.diegonmarcos.com")
		checks = append(checks, map[string]interface{}{
			"name": "auth_domain_https", "success": authOK,
			"time_ms": time.Since(authStart).Milliseconds(),
			"data":    map[string]interface{}{"domain": "auth.diegonmarcos.com"},
		})

		// 5. Bearer token validity (probe a protected service)
		if cfg.AutheliaBearerToken != "" {
			bearerStart := time.Now()
			bearerOK := probeWithBearer(cfg, "db.diegonmarcos.com")
			checks = append(checks, map[string]interface{}{
				"name": "bearer_token_valid", "success": bearerOK,
				"time_ms": time.Since(bearerStart).Milliseconds(),
				"data":    map[string]interface{}{"tested_against": "db.diegonmarcos.com"},
			})
		} else {
			checks = append(checks, map[string]interface{}{
				"name": "bearer_token_valid", "success": false, "time_ms": int64(0),
				"data": map[string]string{"error": "no bearer token configured"},
			})
		}

		// 6. Docker network connectivity (authelia → npm_default)
		if ok {
			netStart := time.Now()
			netResult := services.SshCommand(sshCfg, "docker network inspect npm_default --format '{{range .Containers}}{{.Name}} {{end}}' 2>&1")
			hasAuthelia := strings.Contains(netResult.Output, "authelia")
			checks = append(checks, map[string]interface{}{
				"name": "docker_network_npm", "success": hasAuthelia,
				"time_ms": time.Since(netStart).Milliseconds(),
				"data":    map[string]interface{}{"containers_in_network": strings.TrimSpace(netResult.Output)},
			})

			// 7. Port 9091 listening
			portStart := time.Now()
			portResult := services.SshCommand(sshCfg, "docker inspect --format '{{range $p, $c := .NetworkSettings.Ports}}{{$p}} {{end}}' authelia 2>&1")
			has9091 := strings.Contains(portResult.Output, "9091")
			checks = append(checks, map[string]interface{}{
				"name": "authelia_port_9091", "success": has9091,
				"time_ms": time.Since(portStart).Milliseconds(),
				"data":    map[string]interface{}{"ports": strings.TrimSpace(portResult.Output)},
			})

			// 8. OIDC introspection endpoint
			oidcStart := time.Now()
			oidcResult := services.SshCommand(sshCfg, "docker exec authelia curl -sf http://localhost:9091/api/oidc/.well-known/openid-configuration 2>&1 | head -c 200")
			checks = append(checks, map[string]interface{}{
				"name": "oidc_endpoint", "success": oidcResult.Success && strings.Contains(oidcResult.Output, "issuer"),
				"time_ms": time.Since(oidcStart).Milliseconds(),
				"data":    map[string]interface{}{"response_preview": truncate(oidcResult.Output, 200)},
			})
		}

		totalTime := time.Since(totalStart).Milliseconds()
		passed, failed := 0, 0
		for _, c := range checks {
			if c["success"].(bool) {
				passed++
			} else {
				failed++
			}
		}

		status := "healthy"
		if failed > 0 && passed > 0 {
			status = "degraded"
		} else if passed == 0 {
			status = "down"
		}

		writeJSON(w, map[string]interface{}{
			"service":       "authelia",
			"total_time_ms": totalTime,
			"checks":        checks,
			"summary": map[string]interface{}{
				"checks_passed":  passed,
				"checks_failed":  failed,
				"checks_total":   len(checks),
				"overall_status": status,
			},
		})
	}
}

// probeWithBearer makes an HTTPS GET with optional bearer token.
func probeWithBearer(cfg *config.AppConfig, domain string) bool {
	client := &http.Client{
		Timeout: 10 * time.Second,
		Transport: &http.Transport{
			TLSClientConfig: &tls.Config{InsecureSkipVerify: false},
		},
	}

	reqURL := fmt.Sprintf("https://%s/", domain)
	req, err := http.NewRequest("GET", reqURL, nil)
	if err != nil {
		return false
	}
	if cfg.AutheliaBearerToken != "" {
		req.Header.Set("Authorization", "Bearer "+cfg.AutheliaBearerToken)
	}

	resp, err := client.Do(req)
	if err != nil {
		return false
	}
	resp.Body.Close()
	return resp.StatusCode < 500
}

func truncate(s string, max int) string {
	if len(s) <= max {
		return s
	}
	return s[:max] + "..."
}
