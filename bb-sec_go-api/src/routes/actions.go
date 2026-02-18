package routes

import (
	"fmt"
	"log"
	"net/http"
	"strings"
	"time"

	"github.com/diegonmarcos/go-api/config"
	"github.com/diegonmarcos/go-api/services"
	"github.com/go-chi/chi/v5"
)

// RegisterActions registers all POST action endpoints under /go/*.
func RegisterActions(r chi.Router, cfg *config.AppConfig) {
	// VM actions (provider-backed)
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

	// Legacy flex shortcuts
	r.Post("/go/containers/{name}/start", legacyContainerAction(cfg, "start"))
	r.Post("/go/containers/{name}/stop", legacyContainerAction(cfg, "stop"))
	r.Post("/go/containers/{name}/restart", legacyContainerAction(cfg, "restart"))
	r.Post("/go/services/{service}/start", legacyServiceAction(cfg, "start"))
	r.Post("/go/services/{service}/stop", legacyServiceAction(cfg, "stop"))

	// Bulk on-demand (oci-flex-1)
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

		inst, ok := cfg.VmInstances[vmID]
		if !ok {
			writeError(w, 500, "No instance config for VM: "+vmID)
			return
		}

		var err error
		var providerState string

		switch inst.Provider {
		case "oci":
			if inst.InstanceID == "" {
				writeError(w, 500, "No OCI instance ID configured for "+vmID)
				return
			}
			err = services.OciInstanceAction(cfg.OciConfigFile, inst.InstanceID, action)
			if err == nil {
				providerState, _ = services.GetOciInstanceState(cfg.OciConfigFile, inst.InstanceID)
			}
		case "gcp":
			gcpVm, gcpOk := cfg.GcpVms[vmID]
			if !gcpOk {
				writeError(w, 500, "No GCP VM config for "+vmID)
				return
			}
			gcpAction := services.ResolveGcpAction(action)
			err = services.GcpInstanceAction(cfg.GcpServiceAccountFile, gcpVm.Project, gcpVm.Zone, gcpVm.Name, gcpAction)
			if err == nil {
				providerState, _ = services.GetGcpInstanceState(cfg.GcpServiceAccountFile, gcpVm.Project, gcpVm.Zone, gcpVm.Name)
			}
		default:
			writeError(w, 500, "Unknown provider for VM: "+vmID)
			return
		}

		if err != nil {
			writeJSON(w, map[string]interface{}{
				"status": "error", "vm_id": vmID, "action": action,
				"error": err.Error(),
			})
			return
		}

		writeJSON(w, map[string]interface{}{
			"status": "ok", "vm_id": vmID, "action": action,
			"provider": inst.Provider, "provider_state": providerState,
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

// legacyContainerAction routes to oci-flex-1 (default on-demand VM).
func legacyContainerAction(cfg *config.AppConfig, action string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		name := chi.URLParam(r, "name")
		sshCfg, ok := cfg.VmSSH[cfg.FlexVmID]
		if !ok {
			writeError(w, 500, "SSH config not found for flex VM")
			return
		}

		result := services.SshCommand(sshCfg, fmt.Sprintf("docker %s %s", action, name))
		writeJSON(w, map[string]interface{}{
			"status": boolToStatus(result.Success),
			"vm_id": cfg.FlexVmID, "container": name, "action": action,
			"output": result.Output,
		})
	}
}

// legacyServiceAction routes to oci-flex-1.
func legacyServiceAction(cfg *config.AppConfig, action string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		service := chi.URLParam(r, "service")
		vmMap, ok := cfg.AllVmServices[cfg.FlexVmID]
		if !ok {
			writeError(w, 500, "Flex VM not found in config")
			return
		}
		containers, ok := vmMap.Services[service]
		if !ok {
			writeError(w, 404, fmt.Sprintf("Unknown service '%s' on flex VM", service))
			return
		}

		sshCfg, ok := cfg.VmSSH[cfg.FlexVmID]
		if !ok {
			writeError(w, 500, "SSH config not found for flex VM")
			return
		}

		names := strings.Join(containers, " ")
		result := services.SshCommand(sshCfg, fmt.Sprintf("docker %s %s", action, names))
		writeJSON(w, map[string]interface{}{
			"status": boolToStatus(result.Success),
			"vm_id": cfg.FlexVmID, "service": service, "action": action,
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

// EnsureVmRunning polls a VM's provider state until RUNNING or timeout.
func EnsureVmRunning(cfg *config.AppConfig, vmID string, timeout time.Duration) error {
	inst, ok := cfg.VmInstances[vmID]
	if !ok {
		return fmt.Errorf("no instance config for %s", vmID)
	}

	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		var state string
		var err error

		switch inst.Provider {
		case "oci":
			state, err = services.GetOciInstanceState(cfg.OciConfigFile, inst.InstanceID)
		case "gcp":
			gcpVm, ok := cfg.GcpVms[vmID]
			if !ok {
				return fmt.Errorf("no GCP VM config for %s", vmID)
			}
			state, err = services.GetGcpInstanceState(cfg.GcpServiceAccountFile, gcpVm.Project, gcpVm.Zone, gcpVm.Name)
		}

		if err != nil {
			log.Printf("EnsureVmRunning %s: %v", vmID, err)
		}

		if state == "RUNNING" {
			return nil
		}

		time.Sleep(5 * time.Second)
	}
	return fmt.Errorf("timeout waiting for %s to reach RUNNING", vmID)
}

func boolToStatus(ok bool) string {
	if ok {
		return "ok"
	}
	return "partial"
}
