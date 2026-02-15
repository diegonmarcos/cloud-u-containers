package routes

import (
	"fmt"
	"net/http"
	"strings"

	"github.com/diegonmarcos/go-api/config"
	"github.com/diegonmarcos/go-api/services"
	"github.com/go-chi/chi/v5"
)

// RegisterActions registers all POST action endpoints under /go/*.
func RegisterActions(r chi.Router, cfg *config.AppConfig) {
	// VM actions
	r.Post("/go/vms/{vm_id}/start", vmAction(cfg, "start"))
	r.Post("/go/vms/{vm_id}/stop", vmAction(cfg, "stop"))
	r.Post("/go/vms/{vm_id}/reset", vmAction(cfg, "reset"))

	// Container actions
	r.Post("/go/vms/{vm_id}/containers/{name}/start", containerAction(cfg, "start"))
	r.Post("/go/vms/{vm_id}/containers/{name}/stop", containerAction(cfg, "stop"))
	r.Post("/go/vms/{vm_id}/containers/{name}/restart", containerAction(cfg, "restart"))

	// Service actions
	r.Post("/go/vms/{vm_id}/services/{service}/start", serviceAction(cfg, "start"))
	r.Post("/go/vms/{vm_id}/services/{service}/stop", serviceAction(cfg, "stop"))

	// Bulk on-demand (oci-flex)
	r.Post("/go/containers/on-demand/start-all", bulkAction(cfg, "start"))
	r.Post("/go/containers/on-demand/stop-all", bulkAction(cfg, "stop"))
	r.Post("/go/containers/on-demand/restart-all", bulkAction(cfg, "restart"))

	// Matomo / Windmill toggle
	r.Post("/go/containers/matomo/wake", matomoWake(cfg))
	r.Post("/go/containers/matomo/sleep", matomoSleep(cfg))
	r.Post("/go/containers/windmill/start", windmillStart(cfg))
	r.Post("/go/containers/windmill/stop", windmillStop(cfg))
}

func vmAction(cfg *config.AppConfig, action string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		vmID := chi.URLParam(r, "vm_id")
		if _, ok := cfg.AllVmServices[vmID]; !ok {
			writeError(w, 404, "Unknown VM: "+vmID)
			return
		}
		// VM start/stop/reset requires OCI/GCP API — placeholder
		writeJSON(w, map[string]interface{}{
			"status": "ok", "vm_id": vmID, "action": action,
			"note": "VM provider actions not yet implemented in Go API",
		})
	}
}

func containerAction(cfg *config.AppConfig, action string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		vmID := chi.URLParam(r, "vm_id")
		name := chi.URLParam(r, "name")

		sshCfg, ok := cfg.VmSSH[vmID]
		if !ok {
			writeError(w, 404, "Unknown VM: "+vmID)
			return
		}

		result := services.SshCommand(sshCfg, fmt.Sprintf("docker %s %s", action, name))
		writeJSON(w, map[string]interface{}{
			"status": boolToStatus(result.Success),
			"vm_id": vmID, "container": name, "action": action,
			"output": result.Output,
		})
	}
}

func serviceAction(cfg *config.AppConfig, action string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		vmID := chi.URLParam(r, "vm_id")
		service := chi.URLParam(r, "service")

		vmMap, ok := cfg.AllVmServices[vmID]
		if !ok {
			writeError(w, 404, "Unknown VM: "+vmID)
			return
		}
		containers, ok := vmMap.Services[service]
		if !ok {
			writeError(w, 404, fmt.Sprintf("Unknown service '%s' on %s", service, vmID))
			return
		}

		sshCfg, ok := cfg.VmSSH[vmID]
		if !ok {
			writeError(w, 500, "No SSH config for VM: "+vmID)
			return
		}

		names := strings.Join(containers, " ")
		result := services.SshCommand(sshCfg, fmt.Sprintf("docker %s %s", action, names))
		writeJSON(w, map[string]interface{}{
			"status": boolToStatus(result.Success),
			"vm_id": vmID, "service": service, "action": action,
			"containers": containers,
		})
	}
}

func bulkAction(cfg *config.AppConfig, action string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		flexID := cfg.FlexVmID
		sshCfg, ok := cfg.VmSSH[flexID]
		if !ok {
			writeError(w, 500, "SSH config not found for flex VM")
			return
		}

		vmMap, ok := cfg.AllVmServices[flexID]
		if !ok {
			writeError(w, 500, "Flex VM not found in config")
			return
		}

		allContainers := []string{}
		for _, containers := range vmMap.Services {
			allContainers = append(allContainers, containers...)
		}

		names := strings.Join(allContainers, " ")
		result := services.SshCommand(sshCfg, fmt.Sprintf("docker %s %s", action, names))
		writeJSON(w, map[string]interface{}{
			"status":           boolToStatus(result.Success),
			"vm_id":            flexID,
			"action":           action + "-all",
			"containers_total": len(allContainers),
		})
	}
}

const analyticsVmID = "oci-f-micro_2"
const windmillCompose = "/home/ubuntu/windmill/docker-compose.yml"
const matomoContainer = "matomo-hybrid"

func matomoWake(cfg *config.AppConfig) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		sshCfg, ok := cfg.VmSSH[analyticsVmID]
		if !ok {
			writeError(w, 500, "SSH config not found for oci-analytics")
			return
		}
		stop := services.SshCommand(sshCfg, fmt.Sprintf("docker-compose -f %s stop", windmillCompose))
		wake := services.SshCommand(sshCfg, fmt.Sprintf("docker exec %s /scripts/matomo-wake.sh", matomoContainer))
		writeJSON(w, map[string]interface{}{
			"status": boolToStatus(wake.Success), "vm_id": analyticsVmID,
			"action": "matomo-wake", "windmill_stop": stop.Success, "matomo_wake": wake.Success,
		})
	}
}

func matomoSleep(cfg *config.AppConfig) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		sshCfg, ok := cfg.VmSSH[analyticsVmID]
		if !ok {
			writeError(w, 500, "SSH config not found for oci-analytics")
			return
		}
		sleep := services.SshCommand(sshCfg, fmt.Sprintf("docker exec %s /scripts/matomo-sleep.sh", matomoContainer))
		start := services.SshCommand(sshCfg, fmt.Sprintf("docker-compose -f %s start", windmillCompose))
		writeJSON(w, map[string]interface{}{
			"status": boolToStatus(sleep.Success), "vm_id": analyticsVmID,
			"action": "matomo-sleep", "matomo_sleep": sleep.Success, "windmill_start": start.Success,
		})
	}
}

func windmillStart(cfg *config.AppConfig) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		sshCfg, ok := cfg.VmSSH[analyticsVmID]
		if !ok {
			writeError(w, 500, "SSH config not found for oci-analytics")
			return
		}
		sleep := services.SshCommand(sshCfg, fmt.Sprintf("docker exec %s /scripts/matomo-sleep.sh", matomoContainer))
		start := services.SshCommand(sshCfg, fmt.Sprintf("docker-compose -f %s start", windmillCompose))
		writeJSON(w, map[string]interface{}{
			"status": boolToStatus(start.Success), "vm_id": analyticsVmID,
			"action": "windmill-start", "matomo_sleep": sleep.Success, "windmill_start": start.Success,
		})
	}
}

func windmillStop(cfg *config.AppConfig) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		sshCfg, ok := cfg.VmSSH[analyticsVmID]
		if !ok {
			writeError(w, 500, "SSH config not found for oci-analytics")
			return
		}
		stop := services.SshCommand(sshCfg, fmt.Sprintf("docker-compose -f %s stop", windmillCompose))
		wake := services.SshCommand(sshCfg, fmt.Sprintf("docker exec %s /scripts/matomo-wake.sh", matomoContainer))
		writeJSON(w, map[string]interface{}{
			"status": boolToStatus(stop.Success), "vm_id": analyticsVmID,
			"action": "windmill-stop", "windmill_stop": stop.Success, "matomo_wake": wake.Success,
		})
	}
}

func boolToStatus(ok bool) string {
	if ok {
		return "ok"
	}
	return "partial"
}
