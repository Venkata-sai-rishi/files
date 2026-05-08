# Coolify Operations Guide — Ubuntu 24.04 + Docker

This guide details the modern, Docker-first architecture for self-hosting apps on an 8GB VPS (e.g., Hostinger KVM2) using Coolify, replacing the legacy bare-metal Virtualmin setup.

---

## 1. Initial VPS Provisioning

Before deploying apps, you must secure the host and install Coolify.

1. SSH into your fresh Ubuntu 24.04 VPS as `root`.
2. Run the provisioning script:
   ```bash
   chmod +x 01_coolify_host_setup.sh
   sudo ./01_coolify_host_setup.sh
   ```
   *What this does:* Sets up a 4GB swapfile (crucial for 8GB RAM hosts running multiple containers), tunes kernel/network sysctls for Docker, hardens SSH (disables password login), configures the UFW firewall, and installs Fail2Ban and Coolify.

3. Navigate to `http://<YOUR_VPS_IP>:8000` to create your Coolify admin account.

---

## 2. DNS Configuration (GoDaddy)

Configure your GoDaddy DNS to point your domain to the VPS.

### A Records (Web Traffic)
| Type | Name | Data | TTL |
|---|---|---|---|
| A | `@` | `<YOUR_VPS_IP>` | 1 Hour |
| A | `*` (Wildcard) | `<YOUR_VPS_IP>` | 1 Hour |
*(The wildcard record allows Coolify to automatically provision subdomains like `app.yourdomain.com` without touching GoDaddy again).*

### DNS Records (Mail Server)
If you are hosting your own mail using the provided `docker-mailserver` setup, you need these records:

| Type | Name | Data |
|---|---|---|
| A | `mail` | `<YOUR_VPS_IP>` |
| MX | `@` | `mail.yourdomain.com` (Priority 10) |
| TXT | `@` | `v=spf1 mx -all` |
| TXT | `_dmarc` | `v=DMARC1; p=quarantine; rua=mailto:admin@yourdomain.com` |
*(Note: DKIM TXT record must be generated inside the mailserver container first, see section 4).*

---

## 3. Deploying Apps via Coolify

We provide standard Docker templates for Node.js, Python, Laravel, and Static sites in the `templates/` folder.

**Local Testing:**
To test an app locally, copy the contents of the desired template folder into your application repo and run:
```bash
docker compose up --build
```

**Coolify Deployment:**
1. Push your application (along with the provided `Dockerfile`) to a GitHub/GitLab repository.
2. In Coolify, go to **Projects -> New Project -> New Resource -> Public Repository** (or Private via GitHub App).
3. Select your repository.
4. Coolify will automatically detect the `Dockerfile`.
5. Enter your environment variables (from `.env.example`) into the Coolify UI.
6. Click **Deploy**. Coolify handles building the image, attaching Traefik for reverse proxying, and automatically issuing SSL certificates via Let's Encrypt.

---

## 4. Mail Server Deployment

We use `docker-mailserver` to keep RAM usage low.

1. Upload the `mailserver/` directory to your VPS (e.g., to `/opt/mailserver`).
2. Rename `.env.example` to `.env` and configure `OVERRIDE_HOSTNAME` and `POSTMASTER_ADDRESS`.
3. Start the mailserver:
   ```bash
   cd /opt/mailserver
   chmod +x 02_mailserver_setup.sh
   ./02_mailserver_setup.sh start
   ```
4. Create an email account:
   ```bash
   ./02_mailserver_setup.sh add_user
   ```
5. Generate DKIM keys for GoDaddy DNS:
   ```bash
   ./02_mailserver_setup.sh generate_dkim
   ```
   *Read the generated `mail.txt` file located in `./docker-data/dms/config/opendkim/keys/yourdomain.com/` and add it as a TXT record in GoDaddy for the name `mail._domainkey`.*

---

## 5. System Optimization & Logs

### RAM Optimization (8GB Limit)
* Coolify itself uses ~1GB RAM.
* `docker-mailserver` uses ~1GB RAM (we disabled ClamAV in `.env.example` specifically to avoid the massive 2GB memory spike it causes).
* **Node.js Apps:** Node.js memory is capped in the Dockerfile `NODE_OPTIONS="--max-old-space-size=512"`.
* **Python Apps:** Gunicorn workers are limited to `2` in the Dockerfile. Do not exceed this unless you have RAM to spare.

### Log Management
Coolify captures standard output. You can view logs directly in the Coolify UI. For host-level monitoring, `htop` is installed. Fail2Ban logs are in `/var/log/fail2ban.log`.
