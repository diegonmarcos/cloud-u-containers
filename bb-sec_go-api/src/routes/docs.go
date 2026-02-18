package routes

import (
	"crypto/tls"
	"fmt"
	"io"
	"net/http"
	"sync"
	"time"

	"github.com/diegonmarcos/go-api/config"
	"github.com/go-chi/chi/v5"
)

// ServiceInfo describes a service in the catalog.
type ServiceInfo struct {
	Name       string   `json:"name"`
	Domain     string   `json:"domain,omitempty"`
	VM         string   `json:"vm"`
	VMLabel    string   `json:"vm_label"`
	Containers []string `json:"containers"`
	SpecURL    string   `json:"spec_url,omitempty"`
}

type specCacheEntry struct {
	data      string
	fetchedAt time.Time
}

var (
	specCache   = map[string]specCacheEntry{}
	specCacheMu sync.RWMutex
	specCacheTTL = 5 * time.Minute
)

// RegisterDocs registers service discovery endpoints under /go/services/*.
func RegisterDocs(r chi.Router, cfg *config.AppConfig) {
	r.Get("/go/services", listServices(cfg))
	r.Get("/go/services/{service}", getService(cfg))
	r.Get("/go/services/{service}/spec", getServiceSpec(cfg))
	r.Get("/go/services/all/specs", getAllSpecs(cfg))
}

// buildServiceCatalog creates a lookup from service name to ServiceInfo.
func buildServiceCatalog(cfg *config.AppConfig) map[string]ServiceInfo {
	catalog := map[string]ServiceInfo{}

	// Known spec endpoints
	specURLs := map[string]string{
		"api":        "https://api.diegonmarcos.com/docs/openapi.json",
		"rust-api":   "https://api.diegonmarcos.com:8080/rust/api-docs/openapi.json",
		"photos":     "https://photos.diegonmarcos.com/api/v1",
		"db":         "https://db.diegonmarcos.com/api/v1/meta",
		"analytics":  "https://analytics.diegonmarcos.com/matomo.php",
		"auth":       "https://auth.diegonmarcos.com/api/oidc/.well-known/openid-configuration",
		"mail":       "https://mail.diegonmarcos.com/admin/",
		"vault":      "https://vault.diegonmarcos.com/api/alive",
		"sync":       "https://sync.diegonmarcos.com/rest/system/status",
		"cal":        "https://cal.diegonmarcos.com/.web/",
		"ide":        "https://ide.diegonmarcos.com/healthz",
		"rss":        "https://rss.diegonmarcos.com/v1/health",
		"git":        "https://git.diegonmarcos.com/api/v1/version",
		"automation": "https://windmill.diegonmarcos.com/api/version",
		"monitoring": "https://grafana.diegonmarcos.com/api/health",
		"drive":      "https://drive-notes-affine.diegonmarcos.com/api/server/status",
		"logs":       "https://logs.diegonmarcos.com/version",
	}

	for vmID, vmMap := range cfg.AllVmServices {
		for svcName, containers := range vmMap.Services {
			// Find primary domain
			domain := ""
			for _, c := range containers {
				if d, ok := cfg.ContainerDomainMap[c]; ok {
					domain = d
					break
				}
			}

			info := ServiceInfo{
				Name:       svcName,
				Domain:     domain,
				VM:         vmID,
				VMLabel:    vmMap.Label,
				Containers: containers,
			}
			if url, ok := specURLs[svcName]; ok {
				info.SpecURL = url
			}

			key := vmMap.Label + "/" + svcName
			catalog[key] = info
		}
	}

	return catalog
}

func listServices(cfg *config.AppConfig) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		catalog := buildServiceCatalog(cfg)

		// Group by VM
		byVM := map[string][]ServiceInfo{}
		for _, info := range catalog {
			byVM[info.VMLabel] = append(byVM[info.VMLabel], info)
		}

		writeJSON(w, map[string]interface{}{
			"services": byVM,
			"total":    len(catalog),
		})
	}
}

func getService(cfg *config.AppConfig) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		service := chi.URLParam(r, "service")
		catalog := buildServiceCatalog(cfg)

		// Search by service name across all VMs
		var matches []ServiceInfo
		for _, info := range catalog {
			if info.Name == service {
				matches = append(matches, info)
			}
		}

		if len(matches) == 0 {
			writeError(w, 404, fmt.Sprintf("Service '%s' not found", service))
			return
		}

		if len(matches) == 1 {
			writeJSON(w, matches[0])
			return
		}

		writeJSON(w, map[string]interface{}{
			"service":   service,
			"instances": matches,
		})
	}
}

func getServiceSpec(cfg *config.AppConfig) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		service := chi.URLParam(r, "service")
		catalog := buildServiceCatalog(cfg)
		refresh := r.URL.Query().Get("refresh") == "true"

		var specURL string
		for _, info := range catalog {
			if info.Name == service && info.SpecURL != "" {
				specURL = info.SpecURL
				break
			}
		}

		if specURL == "" {
			writeError(w, 404, fmt.Sprintf("No spec URL for service '%s'", service))
			return
		}

		// Check cache
		if !refresh {
			specCacheMu.RLock()
			if entry, ok := specCache[service]; ok && time.Since(entry.fetchedAt) < specCacheTTL {
				specCacheMu.RUnlock()
				w.Header().Set("Content-Type", "application/json")
				w.Header().Set("X-Cache", "HIT")
				fmt.Fprint(w, entry.data)
				return
			}
			specCacheMu.RUnlock()
		}

		// Fetch spec
		data, err := fetchSpec(cfg, specURL)
		if err != nil {
			writeError(w, 502, fmt.Sprintf("Failed to fetch spec: %v", err))
			return
		}

		// Cache result
		specCacheMu.Lock()
		specCache[service] = specCacheEntry{data: data, fetchedAt: time.Now()}
		specCacheMu.Unlock()

		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("X-Cache", "MISS")
		fmt.Fprint(w, data)
	}
}

func getAllSpecs(cfg *config.AppConfig) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		catalog := buildServiceCatalog(cfg)
		refresh := r.URL.Query().Get("refresh") == "true"

		type specResult struct {
			Service string `json:"service"`
			URL     string `json:"url"`
			Status  string `json:"status"`
			Data    string `json:"data,omitempty"`
			Error   string `json:"error,omitempty"`
		}

		var mu sync.Mutex
		var wg sync.WaitGroup
		results := []specResult{}

		for _, info := range catalog {
			if info.SpecURL == "" {
				continue
			}
			wg.Add(1)
			go func(svcName, url string) {
				defer wg.Done()

				// Check cache
				if !refresh {
					specCacheMu.RLock()
					if entry, ok := specCache[svcName]; ok && time.Since(entry.fetchedAt) < specCacheTTL {
						specCacheMu.RUnlock()
						mu.Lock()
						results = append(results, specResult{
							Service: svcName, URL: url, Status: "cached",
							Data: truncate(entry.data, 500),
						})
						mu.Unlock()
						return
					}
					specCacheMu.RUnlock()
				}

				data, err := fetchSpec(cfg, url)
				sr := specResult{Service: svcName, URL: url}

				if err != nil {
					sr.Status = "error"
					sr.Error = err.Error()
				} else {
					sr.Status = "ok"
					sr.Data = truncate(data, 500)

					specCacheMu.Lock()
					specCache[svcName] = specCacheEntry{data: data, fetchedAt: time.Now()}
					specCacheMu.Unlock()
				}

				mu.Lock()
				results = append(results, sr)
				mu.Unlock()
			}(info.Name, info.SpecURL)
		}
		wg.Wait()

		writeJSON(w, map[string]interface{}{
			"specs": results,
			"total": len(results),
		})
	}
}

func fetchSpec(cfg *config.AppConfig, specURL string) (string, error) {
	client := &http.Client{
		Timeout: 15 * time.Second,
		Transport: &http.Transport{
			TLSClientConfig: &tls.Config{InsecureSkipVerify: false},
		},
	}

	req, err := http.NewRequest("GET", specURL, nil)
	if err != nil {
		return "", err
	}
	if cfg.AutheliaBearerToken != "" {
		req.Header.Set("Authorization", "Bearer "+cfg.AutheliaBearerToken)
	}

	resp, err := client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	if resp.StatusCode >= 400 {
		return "", fmt.Errorf("HTTP %d", resp.StatusCode)
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", err
	}
	return string(body), nil
}
