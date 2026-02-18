package routes

import (
	"crypto/tls"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"sync"
	"time"

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

// Tier 3: status (comprehensive — provider state + resources + domain probing)
func healthStatus(cfg *config.AppConfig) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		type vmResult struct {
			vmID          string
			label         string
			sshOK         bool
			pingOK        bool
			providerState string
			containers    []services.ContainerStatus
			resources     map[string]string
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

				// Provider state
				provState := getProviderState(cfg, id)

				pingOK := services.CheckPing(sshCfg.Host)
				sshOK := services.CheckSSH(sshCfg)
				var containers []services.ContainerStatus
				var resources map[string]string
				if sshOK {
					containers = services.BatchContainerStatuses(sshCfg)
					resources = gatherVmResources(sshCfg)
				}
				mu.Lock()
				results[id] = vmResult{id, label, sshOK, pingOK, provState, containers, resources}
				mu.Unlock()
			}(vmID, vmMap.Label)
		}
		wg.Wait()

		// Domain probing
		domainResults := probeDomains(cfg)

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

			vmData := map[string]interface{}{
				"label": res.label, "ssh": res.sshOK, "ping": res.pingOK,
				"health": health, "containers": details,
				"provider_state": res.providerState,
				"summary": map[string]int{
					"containers_running": running, "containers_total": total,
				},
			}
			if res.resources != nil {
				vmData["resources"] = res.resources
			}
			vms[vmID] = vmData
		}

		writeJSON(w, map[string]interface{}{
			"vms":     vms,
			"domains": domainResults,
		})
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

		provState := getProviderState(cfg, vmID)
		pingOK := services.CheckPing(sshCfg.Host)
		sshOK := services.CheckSSH(sshCfg)
		var containers []services.ContainerStatus
		var resources map[string]string
		if sshOK {
			containers = services.BatchContainerStatuses(sshCfg)
			resources = gatherVmResources(sshCfg)
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

		resp := map[string]interface{}{
			"vm_id": vmID, "label": vmMap.Label,
			"ssh": sshOK, "ping": pingOK, "health": health,
			"provider_state": provState,
			"containers":     details,
			"summary": map[string]int{
				"containers_running": running, "containers_total": total,
			},
		}
		if resources != nil {
			resp["resources"] = resources
		}

		writeJSON(w, resp)
	}
}

// getProviderState queries OCI/GCP for the VM's current state.
func getProviderState(cfg *config.AppConfig, vmID string) string {
	inst, ok := cfg.VmInstances[vmID]
	if !ok {
		return "UNKNOWN"
	}

	switch inst.Provider {
	case "oci":
		state, err := services.GetOciInstanceState(cfg.OciConfigFile, inst.InstanceID)
		if err != nil {
			return "ERROR"
		}
		return state
	case "gcp":
		gcpVm, ok := cfg.GcpVms[vmID]
		if !ok {
			return "UNKNOWN"
		}
		state, err := services.GetGcpInstanceState(cfg.GcpServiceAccountFile, gcpVm.Project, gcpVm.Zone, gcpVm.Name)
		if err != nil {
			return "ERROR"
		}
		return state
	}
	return "UNKNOWN"
}

// gatherVmResources collects CPU, memory, disk, and docker stats via SSH.
func gatherVmResources(sshCfg config.SshConfig) map[string]string {
	resources := map[string]string{}

	// CPU load
	r := services.SshCommand(sshCfg, "cat /proc/loadavg | awk '{print $1, $2, $3}'")
	if r.Success {
		resources["load_avg"] = strings.TrimSpace(r.Output)
	}

	// Memory
	r = services.SshCommand(sshCfg, "free -m | awk '/^Mem:/{printf \"%s/%sMB (%.0f%%)\", $3, $2, $3/$2*100}'")
	if r.Success {
		resources["memory"] = strings.TrimSpace(r.Output)
	}

	// Disk
	r = services.SshCommand(sshCfg, "df -h / | awk 'NR==2{printf \"%s/%s (%s)\", $3, $2, $5}'")
	if r.Success {
		resources["disk"] = strings.TrimSpace(r.Output)
	}

	// Docker container count
	r = services.SshCommand(sshCfg, "docker ps -q | wc -l")
	if r.Success {
		resources["docker_running"] = strings.TrimSpace(r.Output)
	}

	return resources
}

// probeDomains probes all configured domains via HTTPS.
func probeDomains(cfg *config.AppConfig) []map[string]interface{} {
	client := &http.Client{
		Timeout: 10 * time.Second,
		Transport: &http.Transport{
			TLSClientConfig: &tls.Config{InsecureSkipVerify: false},
		},
	}

	var mu sync.Mutex
	var wg sync.WaitGroup
	results := make([]map[string]interface{}, 0, len(cfg.RouteCheckDomains))

	for _, d := range cfg.RouteCheckDomains {
		wg.Add(1)
		go func(domain, service string) {
			defer wg.Done()
			start := time.Now()

			reqURL := fmt.Sprintf("https://%s/", domain)
			req, err := http.NewRequest("GET", reqURL, nil)
			if err != nil {
				mu.Lock()
				results = append(results, map[string]interface{}{
					"domain": domain, "service": service, "reachable": false,
					"error": err.Error(), "time_ms": time.Since(start).Milliseconds(),
				})
				mu.Unlock()
				return
			}

			if cfg.AutheliaBearerToken != "" {
				req.Header.Set("Authorization", "Bearer "+cfg.AutheliaBearerToken)
			}

			resp, err := client.Do(req)
			elapsed := time.Since(start).Milliseconds()

			entry := map[string]interface{}{
				"domain": domain, "service": service, "time_ms": elapsed,
			}

			if err != nil {
				entry["reachable"] = false
				entry["error"] = err.Error()
			} else {
				resp.Body.Close()
				entry["reachable"] = resp.StatusCode < 500
				entry["status_code"] = resp.StatusCode
			}

			mu.Lock()
			results = append(results, entry)
			mu.Unlock()
		}(d.Domain, d.Service)
	}
	wg.Wait()

	return results
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
