package services

import (
	"context"
	"fmt"
	"os/exec"
	"strings"
	"time"

	"github.com/diegonmarcos/go-api/config"
)

// SshResult holds the output of an SSH command.
type SshResult struct {
	Success bool
	Output  string
}

// SshCommand runs a command on a remote VM via SSH.
func SshCommand(cfg config.SshConfig, cmd string) SshResult {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	args := []string{
		"-o", "StrictHostKeyChecking=no",
		"-o", "UserKnownHostsFile=/dev/null",
		"-o", "ConnectTimeout=10",
		"-i", cfg.KeyPath,
		fmt.Sprintf("%s@%s", cfg.User, cfg.Host),
		cmd,
	}

	out, err := exec.CommandContext(ctx, "ssh", args...).CombinedOutput()
	output := strings.TrimSpace(string(out))

	return SshResult{
		Success: err == nil,
		Output:  output,
	}
}

// CheckSSH tests SSH connectivity to a VM.
func CheckSSH(cfg config.SshConfig) bool {
	result := SshCommand(cfg, "echo ok")
	return result.Success && strings.Contains(result.Output, "ok")
}

// CheckPing tests ICMP ping to a host.
func CheckPing(host string) bool {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	err := exec.CommandContext(ctx, "ping", "-c", "1", "-W", "3", host).Run()
	return err == nil
}

// BatchContainerStatuses fetches all container states from a VM via a single SSH call.
func BatchContainerStatuses(cfg config.SshConfig) []ContainerStatus {
	result := SshCommand(cfg, "docker ps -a --format '{{.Names}}|{{.State}}|{{.Ports}}'")
	if !result.Success {
		return nil
	}

	var statuses []ContainerStatus
	for _, line := range strings.Split(result.Output, "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		parts := strings.SplitN(line, "|", 3)
		if len(parts) >= 2 {
			ports := ""
			if len(parts) >= 3 {
				ports = parts[2]
			}
			statuses = append(statuses, ContainerStatus{
				Name:  parts[0],
				State: parts[1],
				Ports: ports,
			})
		}
	}
	return statuses
}

// ContainerStatus holds basic container info from docker ps.
type ContainerStatus struct {
	Name  string `json:"name"`
	State string `json:"state"`
	Ports string `json:"ports"`
}
