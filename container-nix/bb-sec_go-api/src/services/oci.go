package services

// OCI instance control — placeholder for future implementation.
// The Rust API handles OCI API calls; this Go API will mirror
// the same logic when deployed.

// GetOciInstanceState returns the provider state for an OCI instance.
// TODO: Implement OCI REST API calls (requires OCI config + key signing).
func GetOciInstanceState(instanceID string) (string, error) {
	return "UNKNOWN", nil
}

// OciInstanceAction performs a start/stop/reset on an OCI instance.
// TODO: Implement OCI REST API calls.
func OciInstanceAction(instanceID, action string) error {
	return nil
}
