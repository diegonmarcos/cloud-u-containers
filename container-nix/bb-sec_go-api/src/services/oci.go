package services

import (
	"bufio"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"
)

// OciConfig holds parsed OCI CLI config values.
type OciConfig struct {
	Tenancy     string
	User        string
	Fingerprint string
	Region      string
	KeyFile     string
}

// ParseOciConfig reads an OCI config ini file.
func ParseOciConfig(path string) (*OciConfig, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("open oci config: %w", err)
	}
	defer f.Close()

	cfg := &OciConfig{}
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") || strings.HasPrefix(line, "[") {
			continue
		}
		parts := strings.SplitN(line, "=", 2)
		if len(parts) != 2 {
			continue
		}
		key := strings.TrimSpace(parts[0])
		val := strings.TrimSpace(parts[1])
		switch key {
		case "tenancy":
			cfg.Tenancy = val
		case "user":
			cfg.User = val
		case "fingerprint":
			cfg.Fingerprint = val
		case "region":
			cfg.Region = val
		case "key_file":
			cfg.KeyFile = val
		}
	}
	return cfg, scanner.Err()
}

func loadPrivateKey(path string) (*rsa.PrivateKey, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read key: %w", err)
	}
	block, _ := pem.Decode(data)
	if block == nil {
		return nil, fmt.Errorf("no PEM block found in %s", path)
	}

	key, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		// Fallback to PKCS1
		key2, err2 := x509.ParsePKCS1PrivateKey(block.Bytes)
		if err2 != nil {
			return nil, fmt.Errorf("parse key: %w (pkcs1: %w)", err, err2)
		}
		return key2, nil
	}
	rsaKey, ok := key.(*rsa.PrivateKey)
	if !ok {
		return nil, fmt.Errorf("key is not RSA")
	}
	return rsaKey, nil
}

// signOciRequest builds the OCI HTTP Signature header for a request.
func signOciRequest(cfg *OciConfig, method, path, host string, body []byte) (map[string]string, error) {
	now := time.Now().UTC().Format(http.TimeFormat)
	keyID := fmt.Sprintf("%s/%s/%s", cfg.Tenancy, cfg.User, cfg.Fingerprint)

	headers := []string{"date", "(request-target)", "host"}
	signingString := fmt.Sprintf("date: %s\n(request-target): %s %s\nhost: %s",
		now, strings.ToLower(method), path, host)

	if body != nil && len(body) > 0 {
		bodyHash := sha256.Sum256(body)
		b64Hash := base64.StdEncoding.EncodeToString(bodyHash[:])
		contentLen := fmt.Sprintf("%d", len(body))
		headers = append(headers, "content-length", "content-type", "x-content-sha256")
		signingString += fmt.Sprintf("\ncontent-length: %s\ncontent-type: application/json\nx-content-sha256: %s",
			contentLen, b64Hash)
	}

	privKey, err := loadPrivateKey(cfg.KeyFile)
	if err != nil {
		return nil, err
	}

	hashed := sha256.Sum256([]byte(signingString))
	sig, err := rsa.SignPKCS1v15(rand.Reader, privKey, crypto.SHA256, hashed[:])
	if err != nil {
		return nil, fmt.Errorf("sign: %w", err)
	}

	authHeader := fmt.Sprintf(
		`Signature version="1",keyId="%s",algorithm="rsa-sha256",headers="%s",signature="%s"`,
		keyID, strings.Join(headers, " "), base64.StdEncoding.EncodeToString(sig),
	)

	result := map[string]string{
		"date":          now,
		"authorization": authHeader,
	}
	if body != nil && len(body) > 0 {
		bodyHash := sha256.Sum256(body)
		result["content-type"] = "application/json"
		result["content-length"] = fmt.Sprintf("%d", len(body))
		result["x-content-sha256"] = base64.StdEncoding.EncodeToString(bodyHash[:])
	}

	return result, nil
}

func ociAPIRequest(cfg *OciConfig, method, url string, body []byte) ([]byte, int, error) {
	// Extract host and path from URL
	// URL format: https://host/path
	withoutScheme := strings.TrimPrefix(url, "https://")
	slashIdx := strings.Index(withoutScheme, "/")
	host := withoutScheme[:slashIdx]
	path := withoutScheme[slashIdx:]

	headers, err := signOciRequest(cfg, method, path, host, body)
	if err != nil {
		return nil, 0, err
	}

	var bodyReader io.Reader
	if body != nil {
		bodyReader = strings.NewReader(string(body))
	}
	req, err := http.NewRequest(method, url, bodyReader)
	if err != nil {
		return nil, 0, err
	}
	for k, v := range headers {
		req.Header.Set(k, v)
	}

	client := &http.Client{Timeout: 30 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return nil, 0, err
	}
	defer resp.Body.Close()

	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, resp.StatusCode, err
	}
	return respBody, resp.StatusCode, nil
}

// GetOciInstanceState returns the lifecycle state for an OCI instance.
func GetOciInstanceState(ociCfgPath, instanceID string) (string, error) {
	if ociCfgPath == "" || instanceID == "" {
		return "UNKNOWN", nil
	}

	cfg, err := ParseOciConfig(ociCfgPath)
	if err != nil {
		return "UNKNOWN", fmt.Errorf("parse oci config: %w", err)
	}

	url := fmt.Sprintf("https://iaas.%s.oraclecloud.com/20160918/instances/%s", cfg.Region, instanceID)
	respBody, status, err := ociAPIRequest(cfg, "GET", url, nil)
	if err != nil {
		return "UNKNOWN", err
	}
	if status != 200 {
		return "UNKNOWN", fmt.Errorf("OCI API returned %d: %s", status, string(respBody))
	}

	var result struct {
		LifecycleState string `json:"lifecycleState"`
	}
	if err := json.Unmarshal(respBody, &result); err != nil {
		return "UNKNOWN", err
	}
	return result.LifecycleState, nil
}

// OciInstanceAction performs a start/stop/reset on an OCI instance.
func OciInstanceAction(ociCfgPath, instanceID, action string) error {
	if ociCfgPath == "" || instanceID == "" {
		return fmt.Errorf("missing OCI config or instance ID")
	}

	cfg, err := ParseOciConfig(ociCfgPath)
	if err != nil {
		return fmt.Errorf("parse oci config: %w", err)
	}

	var ociAction string
	switch action {
	case "start":
		ociAction = "START"
	case "stop":
		ociAction = "STOP"
	case "reset":
		ociAction = "RESET"
	default:
		return fmt.Errorf("unknown action: %s", action)
	}

	url := fmt.Sprintf("https://iaas.%s.oraclecloud.com/20160918/instances/%s?action=%s",
		cfg.Region, instanceID, ociAction)
	_, status, err := ociAPIRequest(cfg, "POST", url, nil)
	if err != nil {
		return err
	}
	if status != 200 {
		return fmt.Errorf("OCI action %s returned %d", ociAction, status)
	}
	return nil
}
