# NPM Proxy Configuration for AFFiNE

## Domain: drive-notes-affine.diegonmarcos.com

### Step 1: Add DNS Record (Cloudflare)

1. Go to Cloudflare Dashboard → DNS
2. Add new A record:
   ```
   Type: A
   Name: drive-notes-affine
   Content: 35.226.147.64 (GCP NPM proxy IP)
   Proxy status: DNS only (gray cloud)
   TTL: Auto
   ```

### Step 2: Configure NPM Proxy Host

1. **Access NPM Admin Panel**
   ```
   URL: http://35.226.147.64:81
   ```

2. **Navigate to**: Proxy Hosts → Add Proxy Host

3. **Details Tab Configuration:**
   ```
   Domain Names:           drive-notes-affine.diegonmarcos.com
   Scheme:                 http
   Forward Hostname / IP:  84.235.234.87
   Forward Port:           3010
   Cache Assets:           ☑ ON
   Block Common Exploits:  ☑ ON
   Websockets Support:     ☑ ON (CRITICAL!)
   Access List:            Publicly Accessible
   ```

4. **SSL Tab Configuration:**
   ```
   SSL Certificate:        Request a new SSL Certificate
   Force SSL:              ☑ ON
   HTTP/2 Support:         ☑ ON
   HSTS Enabled:           ☑ ON
   HSTS Subdomains:        ☐ OFF

   Email Address:          admin@diegonmarcos.com
   Agree to Terms:         ☑ ON
   ```

5. **Advanced Tab Configuration:**

   Add this custom Nginx configuration:

   ```nginx
   # WebSocket support for AFFiNE real-time collaboration
   proxy_set_header Upgrade $http_upgrade;
   proxy_set_header Connection "upgrade";

   # Proper headers
   proxy_set_header Host $host;
   proxy_set_header X-Real-IP $remote_addr;
   proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
   proxy_set_header X-Forwarded-Proto $scheme;

   # Increase timeouts for long-lived WebSocket connections
   proxy_read_timeout 3600s;
   proxy_send_timeout 3600s;
   proxy_connect_timeout 60s;

   # Buffer settings for large uploads
   client_max_body_size 100M;
   proxy_buffering off;
   proxy_request_buffering off;

   # Keep-alive
   proxy_http_version 1.1;
   ```

6. **Click Save**

### Step 3: Update mydrive HTML

Update the AFFiNE URL in `/home/diego/mnt_git/front-Github_io/b_Work_Tools/mydrive/src/index.html`:

Change:
```html
data-url="https://drive.diegonmarcos.com/"
```

To:
```html
data-url="https://drive-notes-affine.diegonmarcos.com/"
```

### Step 4: Test Access

1. Wait 1-2 minutes for DNS propagation
2. Visit: https://drive-notes-affine.diegonmarcos.com
3. Should see AFFiNE login/signup page
4. Create account or login

### Verification Checklist

- [ ] DNS record added in Cloudflare
- [ ] NPM proxy host created
- [ ] SSL certificate issued (Let's Encrypt)
- [ ] Can access https://drive-notes-affine.diegonmarcos.com
- [ ] WebSockets working (check browser dev console for errors)
- [ ] Can create workspace and documents
- [ ] Real-time collaboration works
- [ ] mydrive HTML updated with correct URL

---

## Alternative: Use Root Domain (drive.diegonmarcos.com)

If you prefer to use `drive.diegonmarcos.com` instead:

1. Skip DNS step (already exists)
2. Use same NPM configuration but with:
   - Domain: `drive.diegonmarcos.com`
3. No need to update mydrive HTML

---

**Configured**: Using subdomain `drive-notes-affine.diegonmarcos.com` for clear hierarchical organization.
