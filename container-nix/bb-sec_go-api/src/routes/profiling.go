package routes

import (
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
		} else {
			for _, name := range []string{"container_status", "docker_network", "port_reachability"} {
				checks = append(checks, map[string]interface{}{
					"name": name, "success": false, "time_ms": 0,
					"data": map[string]string{"error": "skipped: SSH unavailable"},
				})
			}
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
