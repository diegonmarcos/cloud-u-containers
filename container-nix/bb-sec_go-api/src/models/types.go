package models

// ContainerInfo represents a deployed container's state.
type ContainerInfo struct {
	Name  string `json:"name"`
	State string `json:"state"`
	Ports string `json:"ports"`
}

// VmDeployed holds the deployed containers for a VM.
type VmDeployed struct {
	Label      string          `json:"label"`
	Containers []ContainerInfo `json:"containers"`
	Running    int             `json:"running"`
	Stopped    int             `json:"stopped"`
	Total      int             `json:"total"`
}

// DriftVM holds drift analysis for a VM.
type DriftVM struct {
	Label    string   `json:"label"`
	Declared []string `json:"declared"`
	Deployed []string `json:"deployed"`
	Missing  []string `json:"missing"`
	Extra    []string `json:"extra"`
}

// ProfilingCheck is a single diagnostic check result.
type ProfilingCheck struct {
	Name    string      `json:"name"`
	Success bool        `json:"success"`
	TimeMs  int64       `json:"time_ms"`
	Data    interface{} `json:"data"`
}

// ProfilingSummary aggregates profiling results.
type ProfilingSummary struct {
	ChecksPassed int    `json:"checks_passed"`
	ChecksFailed int    `json:"checks_failed"`
	ChecksTotal  int    `json:"checks_total"`
	Status       string `json:"overall_status"`
}

// ProfilingResponse is the full profiling report for a container.
type ProfilingResponse struct {
	Container   string           `json:"container"`
	VmID        string           `json:"vm_id"`
	VmLabel     string           `json:"vm_label"`
	Service     string           `json:"service"`
	Domain      string           `json:"domain,omitempty"`
	TotalTimeMs int64            `json:"total_time_ms"`
	Checks      []ProfilingCheck `json:"checks"`
	Summary     ProfilingSummary `json:"summary"`
}
