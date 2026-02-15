package routes

import (
	"encoding/json"
	"net/http"
	"sync"

	"github.com/diegonmarcos/go-api/config"
	"github.com/diegonmarcos/go-api/services"
	"github.com/go-chi/chi/v5"
)

// RegisterHealth registers all tiered health endpoints under /go/health/*.
func RegisterHealth(r chi.Router, cfg *config.AppConfig) {
	r.Get("/go/health", healthAlive)
	r.Get("/go/health/declared", healthDeclared(cfg))
	r.Get("/go/health/deployed", healthDeployed(cfg))
	r.Get("/go/health/deployed/{vm_id}", healthDeployedVM(cfg))
	r.Get("/go/health/drift", healthDrift(cfg))
	r.Get("/go/health/status", healthStatus(cfg))
	r.Get("/go/health/status/{vm_id}", healthStatusVM(cfg))
}

func writeJSON(w http.ResponseWriter, v interface{}) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, code int, msg string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(map[string]string{"error": msg})
}

// Tier 0: alive
func healthAlive(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, map[string]string{"status": "ok"})
}

// Tier 0: declared (no SSH)
func healthDeclared(cfg *config.AppConfig) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		vms := map[string]interface{}{}
		totalServices := 0
		totalContainers := 0

		for vmID, vmMap := range cfg.AllVmServices {
			svcMap := map[string][]string{}
			for svcName, containers := range vmMap.Services {
				totalServices++
				totalContainers += len(containers)
				svcMap[svcName] = containers
			}
			vms[vmID] = map[string]interface{}{
				"label":    vmMap.Label,
				"services": svcMap,
			}
		}

		writeJSON(w, map[string]interface{}{
			"vms":     vms,
			"domains": cfg.ContainerDomainMap,
			"totals": map[string]int{
				"vms":        len(cfg.AllVmServices),
				"services":   totalServices,
				"containers": totalContainers,
			},
		})
	}
}

// Tier 1: deployed (docker ps -a via SSH, parallel)
func healthDeployed(cfg *config.AppConfig) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		type vmResult struct {
			vmID       string
			label      string
			containers []services.ContainerStatus
		}

		var mu sync.Mutex
		var wg sync.WaitGroup
		results := make([]vmResult, 0, len(cfg.AllVmServices))

		for vmID, vmMap := range cfg.AllVmServices {
			wg.Add(1)
			go func(id, label string) {
				defer wg.Done()
				sshCfg, ok := cfg.VmSSH[id]
				if !ok {
					return
				}
				containers := services.BatchContainerStatuses(sshCfg)
				mu.Lock()
				results = append(results, vmResult{id, label, containers})
				mu.Unlock()
			}(vmID, vmMap.Label)
		}
		wg.Wait()

		vms := map[string]interface{}{}
		globalRunning, globalStopped, globalTotal := 0, 0, 0

		for _, res := range results {
			running, stopped := 0, 0
			details := make([]map[string]string, 0, len(res.containers))
			for _, c := range res.containers {
				if c.State == "running" {
					running++
				} else {
					stopped++
				}
				details = append(details, map[string]string{
					"name": c.Name, "state": c.State, "ports": c.Ports,
				})
			}
			globalRunning += running
			globalStopped += stopped
			globalTotal += len(res.containers)
			vms[res.vmID] = map[string]interface{}{
				"label": res.label, "containers": details,
				"running": running, "stopped": stopped, "total": len(res.containers),
			}
		}

		writeJSON(w, map[string]interface{}{
			"vms": vms,
			"summary": map[string]int{
				"running": globalRunning, "stopped": globalStopped, "total": globalTotal,
			},
		})
	}
}

// Tier 1: deployed per-VM
func healthDeployedVM(cfg *config.AppConfig) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		vmID := chi.URLParam(r, "vm_id")
		vmMap, ok := cfg.AllVmServices[vmID]
		if !ok {
			writeError(w, 404, "Unknown VM: "+vmID)
			return
		}
		sshCfg, ok := cfg.VmSSH[vmID]
		if !ok {
			writeError(w, 500, "No SSH config for VM: "+vmID)
			return
		}

		containers := services.BatchContainerStatuses(sshCfg)
		running, stopped := 0, 0
		details := make([]map[string]string, 0, len(containers))
		for _, c := range containers {
			if c.State == "running" {
				running++
			} else {
				stopped++
			}
			details = append(details, map[string]string{
				"name": c.Name, "state": c.State, "ports": c.Ports,
			})
		}

		writeJSON(w, map[string]interface{}{
			"vm_id": vmID, "label": vmMap.Label,
			"containers": details,
			"running": running, "stopped": stopped, "total": len(containers),
		})
	}
}

// Tier 2: drift
func healthDrift(cfg *config.AppConfig) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		type vmResult struct {
			vmID       string
			containers []services.ContainerStatus
		}

		var mu sync.Mutex
		var wg sync.WaitGroup
		deployedMap := map[string][]services.ContainerStatus{}

		for vmID := range cfg.AllVmServices {
			wg.Add(1)
			go func(id string) {
				defer wg.Done()
				sshCfg, ok := cfg.VmSSH[id]
				if !ok {
					return
				}
				containers := services.BatchContainerStatuses(sshCfg)
				mu.Lock()
				deployedMap[id] = containers
				mu.Unlock()
			}(vmID)
		}
		wg.Wait()

		vms := map[string]interface{}{}
		sumDeclared, sumDeployed, sumMissing, sumExtra := 0, 0, 0, 0

		for vmID, vmMap := range cfg.AllVmServices {
			declared := []string{}
			for _, containers := range vmMap.Services {
				declared = append(declared, containers...)
			}

			deployedRaw := deployedMap[vmID]
			deployed := make([]string, 0, len(deployedRaw))
			for _, c := range deployedRaw {
				deployed = append(deployed, c.Name)
			}

			missing := diff(declared, deployed)
			extra := diff(deployed, declared)

			sumDeclared += len(declared)
			sumDeployed += len(deployed)
			sumMissing += len(missing)
			sumExtra += len(extra)

			vms[vmID] = map[string]interface{}{
				"label": vmMap.Label, "declared": declared, "deployed": deployed,
				"missing": missing, "extra": extra,
			}
		}

		writeJSON(w, map[string]interface{}{
			"vms": vms,
			"summary": map[string]interface{}{
				"declared": sumDeclared, "deployed": sumDeployed,
				"missing": sumMissing, "extra": sumExtra,
				"drift": sumMissing > 0 || sumExtra > 0,
			},
		})
	}
}

// Tier 3: status (comprehensive)
func healthStatus(cfg *config.AppConfig) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		type vmResult struct {
			vmID       string
			label      string
			sshOK      bool
			pingOK     bool
			containers []services.ContainerStatus
		}

		var mu sync.Mutex
		var wg sync.WaitGroup
		results := map[string]vmResult{}

		for vmID, vmMap := range cfg.AllVmServices {
			wg.Add(1)
			go func(id, label string) {
				defer wg.Done()
				sshCfg, ok := cfg.VmSSH[id]
				if !ok {
					return
				}
				pingOK := services.CheckPing(sshCfg.Host)
				sshOK := services.CheckSSH(sshCfg)
				var containers []services.ContainerStatus
				if sshOK {
					containers = services.BatchContainerStatuses(sshCfg)
				}
				mu.Lock()
				results[id] = vmResult{id, label, sshOK, pingOK, containers}
				mu.Unlock()
			}(vmID, vmMap.Label)
		}
		wg.Wait()

		vms := map[string]interface{}{}
		for vmID, res := range results {
			health := "unknown"
			if res.sshOK {
				health = "online"
			} else if res.pingOK {
				health = "degraded"
			} else {
				health = "offline"
			}

			running, total := 0, 0
			details := make([]map[string]string, 0, len(res.containers))
			for _, c := range res.containers {
				total++
				if c.State == "running" {
					running++
				}
				details = append(details, map[string]string{
					"name": c.Name, "state": c.State, "ports": c.Ports,
				})
			}

			vms[vmID] = map[string]interface{}{
				"label": res.label, "ssh": res.sshOK, "ping": res.pingOK,
				"health": health, "containers": details,
				"summary": map[string]int{
					"containers_running": running, "containers_total": total,
				},
			}
		}

		writeJSON(w, map[string]interface{}{"vms": vms})
	}
}

// Tier 3: status per-VM
func healthStatusVM(cfg *config.AppConfig) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		vmID := chi.URLParam(r, "vm_id")
		vmMap, ok := cfg.AllVmServices[vmID]
		if !ok {
			writeError(w, 404, "Unknown VM: "+vmID)
			return
		}
		sshCfg, ok := cfg.VmSSH[vmID]
		if !ok {
			writeError(w, 500, "No SSH config for VM: "+vmID)
			return
		}

		pingOK := services.CheckPing(sshCfg.Host)
		sshOK := services.CheckSSH(sshCfg)
		var containers []services.ContainerStatus
		if sshOK {
			containers = services.BatchContainerStatuses(sshCfg)
		}

		health := "unknown"
		if sshOK {
			health = "online"
		} else if pingOK {
			health = "degraded"
		} else {
			health = "offline"
		}

		running, total := 0, 0
		details := make([]map[string]string, 0, len(containers))
		for _, c := range containers {
			total++
			if c.State == "running" {
				running++
			}
			details = append(details, map[string]string{
				"name": c.Name, "state": c.State, "ports": c.Ports,
			})
		}

		writeJSON(w, map[string]interface{}{
			"vm_id": vmID, "label": vmMap.Label,
			"ssh": sshOK, "ping": pingOK, "health": health,
			"containers": details,
			"summary": map[string]int{
				"containers_running": running, "containers_total": total,
			},
		})
	}
}

// diff returns elements in a that are not in b.
func diff(a, b []string) []string {
	set := map[string]bool{}
	for _, v := range b {
		set[v] = true
	}
	var result []string
	for _, v := range a {
		if !set[v] {
			result = append(result, v)
		}
	}
	if result == nil {
		return []string{}
	}
	return result
}
