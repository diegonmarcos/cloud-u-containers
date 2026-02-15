package services

// GCP instance control — placeholder for future implementation.
// The Rust API handles GCP API calls; this Go API will mirror
// the same logic when deployed.

// GetGcpInstanceState returns the provider state for a GCP instance.
// TODO: Implement GCP Compute Engine REST API calls.
func GetGcpInstanceState(project, zone, instance string) (string, error) {
	return "UNKNOWN", nil
}

// GcpInstanceAction performs a start/stop/reset on a GCP instance.
// TODO: Implement GCP Compute Engine REST API calls.
func GcpInstanceAction(project, zone, instance, action string) error {
	return nil
}
