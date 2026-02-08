# Deployment Guide - Code-Server on oci-p-flex_1

## Architecture

```
User → ide.diegonmarcos.com → Cloudflare DNS
    → NPM (35.226.147.64:443)
    → WireGuard (10.0.0.2:8443)
    → code-server container
```

## Step 1: Deploy on oci-p-flex_1

```bash
# SSH to the VM
ssh ubuntu@84.235.234.87

# Create directory
sudo mkdir -p /opt/docker/web-ide
cd /opt/docker/web-ide

# Copy files (from local machine)
# Or clone from repo and copy secrets
```

**From local machine:**
```bash
# Copy files to VM
scp -r /home/diego/Mounts/Git/cloud/a_solutions/front-apps/web-ide/* ubuntu@84.235.234.87:/opt/docker/web-ide/

# Copy age key for decryption
scp /home/diego/Mounts/Git/vault/A0_keys/age/keys.txt ubuntu@84.235.234.87:~/.config/sops/age/keys.txt
```

**On VM:**
```bash
cd /opt/docker/web-ide
chmod 600 ~/.config/sops/age/keys.txt
./start.sh
```

## Step 2: Configure Cloudflare DNS

Add A record:
| Type | Name | Content | Proxy |
|------|------|---------|-------|
| A | ide | 35.226.147.64 | Proxied (orange) |

## Step 3: Configure NPM Proxy Host

Access NPM: http://35.226.147.64:81

**Add Proxy Host:**

| Setting | Value |
|---------|-------|
| Domain Names | `ide.diegonmarcos.com` |
| Scheme | `http` |
| Forward Hostname/IP | `10.0.0.2` |
| Forward Port | `8443` |
| Websockets Support | ✅ ON |
| Block Common Exploits | ✅ ON |

**SSL Tab:**
| Setting | Value |
|---------|-------|
| SSL Certificate | Request new or use wildcard |
| Force SSL | ✅ ON |
| HTTP/2 Support | ✅ ON |

**Advanced Tab (Custom Nginx Config):**
```nginx
proxy_set_header Upgrade $http_upgrade;
proxy_set_header Connection "upgrade";
proxy_set_header Host $host;
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_read_timeout 86400;
```

## Step 4: (Optional) Add Authelia 2FA

In NPM Advanced tab, add:
```nginx
include /data/nginx/custom/authelia-location.conf;
auth_request /authelia;
auth_request_set $target_url $scheme://$http_host$request_uri;
auth_request_set $user $upstream_http_remote_user;
auth_request_set $groups $upstream_http_remote_groups;
error_page 401 =302 https://auth.diegonmarcos.com/?rd=$target_url;
```

Or use NPM's Access Lists with Authelia integration if configured.

## Step 5: Verify

1. Open https://ide.diegonmarcos.com
2. Login with password from secrets.yaml
3. Test WebSocket (terminal should work)

## Firewall Rules (oci-p-flex_1)

Ensure port 8443 is open for WireGuard subnet:

```bash
# If using UFW
sudo ufw allow from 10.0.0.0/24 to any port 8443

# If using iptables
sudo iptables -A INPUT -s 10.0.0.0/24 -p tcp --dport 8443 -j ACCEPT
```

## Troubleshooting

**502 Bad Gateway:**
- Check if container is running: `docker ps`
- Check WireGuard: `ping 10.0.0.2` from gcp-f-micro_1
- Check port: `curl http://10.0.0.2:8443` from gcp-f-micro_1

**WebSocket not working:**
- Ensure "Websockets Support" is ON in NPM
- Check Advanced config has upgrade headers

**Can't decrypt secrets:**
- Verify age key: `ls -la ~/.config/sops/age/keys.txt`
- Test: `SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops -d secrets.yaml`
