package services

import (
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
	"net/url"
	"os"
	"sync"
	"time"
)

// GcpServiceAccount holds parsed GCP service account key JSON.
type GcpServiceAccount struct {
	ClientEmail  string `json:"client_email"`
	PrivateKey   string `json:"private_key"`
	TokenURI     string `json:"token_uri"`
	ProjectID    string `json:"project_id"`
	PrivateKeyID string `json:"private_key_id"`
}

// GcpTokenCache caches OAuth2 access tokens with expiration.
type GcpTokenCache struct {
	mu        sync.RWMutex
	token     string
	expiresAt time.Time
}

// ParseServiceAccount reads a GCP service account key JSON file.
func ParseServiceAccount(path string) (*GcpServiceAccount, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read service account: %w", err)
	}
	var sa GcpServiceAccount
	if err := json.Unmarshal(data, &sa); err != nil {
		return nil, fmt.Errorf("parse service account: %w", err)
	}
	if sa.TokenURI == "" {
		sa.TokenURI = "https://oauth2.googleapis.com/token"
	}
	return &sa, nil
}

func createSignedJWT(sa *GcpServiceAccount) (string, error) {
	now := time.Now().Unix()
	header := base64URLEncode([]byte(`{"alg":"RS256","typ":"JWT"}`))

	claimSet := map[string]interface{}{
		"iss":   sa.ClientEmail,
		"scope": "https://www.googleapis.com/auth/compute",
		"aud":   sa.TokenURI,
		"iat":   now,
		"exp":   now + 3600,
	}
	claimJSON, err := json.Marshal(claimSet)
	if err != nil {
		return "", err
	}
	payload := base64URLEncode(claimJSON)

	sigInput := header + "." + payload
	hashed := sha256.Sum256([]byte(sigInput))

	block, _ := pem.Decode([]byte(sa.PrivateKey))
	if block == nil {
		return "", fmt.Errorf("no PEM block in service account key")
	}
	key, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return "", fmt.Errorf("parse private key: %w", err)
	}
	rsaKey, ok := key.(*rsa.PrivateKey)
	if !ok {
		return "", fmt.Errorf("key is not RSA")
	}

	sig, err := rsa.SignPKCS1v15(rand.Reader, rsaKey, crypto.SHA256, hashed[:])
	if err != nil {
		return "", fmt.Errorf("sign JWT: %w", err)
	}

	return sigInput + "." + base64URLEncode(sig), nil
}

func base64URLEncode(data []byte) string {
	return base64.RawURLEncoding.EncodeToString(data)
}

// GetAccessToken returns a cached or fresh OAuth2 access token.
func GetAccessToken(sa *GcpServiceAccount, cache *GcpTokenCache) (string, error) {
	cache.mu.RLock()
	if cache.token != "" && time.Now().Before(cache.expiresAt) {
		t := cache.token
		cache.mu.RUnlock()
		return t, nil
	}
	cache.mu.RUnlock()

	jwt, err := createSignedJWT(sa)
	if err != nil {
		return "", err
	}

	form := url.Values{
		"grant_type": {"urn:ietf:params:oauth:grant-type:jwt-bearer"},
		"assertion":  {jwt},
	}

	resp, err := http.PostForm(sa.TokenURI, form)
	if err != nil {
		return "", fmt.Errorf("token request: %w", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", err
	}
	if resp.StatusCode != 200 {
		return "", fmt.Errorf("token exchange failed (%d): %s", resp.StatusCode, string(body))
	}

	var tokenResp struct {
		AccessToken string `json:"access_token"`
		ExpiresIn   int    `json:"expires_in"`
	}
	if err := json.Unmarshal(body, &tokenResp); err != nil {
		return "", err
	}

	cache.mu.Lock()
	cache.token = tokenResp.AccessToken
	cache.expiresAt = time.Now().Add(time.Duration(tokenResp.ExpiresIn-60) * time.Second)
	cache.mu.Unlock()

	return tokenResp.AccessToken, nil
}

func gcpAPIRequest(sa *GcpServiceAccount, cache *GcpTokenCache, method, apiURL string) ([]byte, int, error) {
	token, err := GetAccessToken(sa, cache)
	if err != nil {
		return nil, 0, err
	}

	req, err := http.NewRequest(method, apiURL, nil)
	if err != nil {
		return nil, 0, err
	}
	req.Header.Set("Authorization", "Bearer "+token)

	client := &http.Client{Timeout: 30 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return nil, 0, err
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, resp.StatusCode, err
	}
	return body, resp.StatusCode, nil
}

// Global GCP token cache
var gcpCache = &GcpTokenCache{}

// GetGcpInstanceState returns the status of a GCP Compute instance.
func GetGcpInstanceState(saPath, project, zone, instance string) (string, error) {
	if saPath == "" || project == "" {
		return "UNKNOWN", nil
	}

	sa, err := ParseServiceAccount(saPath)
	if err != nil {
		return "UNKNOWN", err
	}

	apiURL := fmt.Sprintf("https://compute.googleapis.com/compute/v1/projects/%s/zones/%s/instances/%s",
		project, zone, instance)
	body, status, err := gcpAPIRequest(sa, gcpCache, "GET", apiURL)
	if err != nil {
		return "UNKNOWN", err
	}
	if status != 200 {
		return "UNKNOWN", fmt.Errorf("GCP API returned %d: %s", status, string(body))
	}

	var result struct {
		Status string `json:"status"`
	}
	if err := json.Unmarshal(body, &result); err != nil {
		return "UNKNOWN", err
	}
	return result.Status, nil
}

// GcpInstanceAction performs a start/stop/reset on a GCP instance.
func GcpInstanceAction(saPath, project, zone, instance, action string) error {
	if saPath == "" || project == "" {
		return fmt.Errorf("missing GCP service account or project")
	}

	sa, err := ParseServiceAccount(saPath)
	if err != nil {
		return err
	}

	apiURL := fmt.Sprintf("https://compute.googleapis.com/compute/v1/projects/%s/zones/%s/instances/%s/%s",
		project, zone, instance, action)
	_, status, err := gcpAPIRequest(sa, gcpCache, "POST", apiURL)
	if err != nil {
		return err
	}
	if status != 200 {
		// GCP returns 200 for successful operations
		return fmt.Errorf("GCP action %s returned %d", action, status)
	}
	return nil
}

// ResolveGcpAction maps generic action names to GCP API actions.
func ResolveGcpAction(action string) string {
	switch action {
	case "start":
		return "start"
	case "stop":
		return "stop"
	case "reset":
		return "reset"
	default:
		return action
	}
}

// NewGcpTokenCache creates a new token cache.
func NewGcpTokenCache() *GcpTokenCache {
	return &GcpTokenCache{}
}

// InvalidateGcpCache clears the cached token.
func InvalidateGcpCache() {
	gcpCache.mu.Lock()
	gcpCache.token = ""
	gcpCache.expiresAt = time.Time{}
	gcpCache.mu.Unlock()
}
