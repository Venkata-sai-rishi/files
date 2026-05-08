# Virtualmin Hosting Server — Operations Guide  [FIXED v2]

> This guide reflects the **fixed v2** scripts. All bug and security fix
> references below match the `[BUG-XX]` / `[SEC-XX]` tags in the scripts.

---

## Contents
1. Complete Bug & Security Fix Log
2. Post-Install Verification Checklist
3. RAM Optimization Notes
4. Service Enable/Disable Cheat Sheet
5. Recovery Instructions
6. Future Domain Migration Guide

---

# 1. COMPLETE BUG & SECURITY FIX LOG

## Script 01 — Local Test Setup

| ID | Type | Description | Fix |
|----|------|-------------|-----|
| BUG-01 | Logic | `/etc/hosts` double-entry broken — after adding `127.0.0.1 host`, the second grep found the same line and skipped adding `LOCAL_IP host`. Neither entry was actually both added. | Separated into two independent grep/echo blocks with distinct patterns (`^127\.0\.0\.1` vs `^LOCAL_IP`) |
| BUG-02 | Security | Virtualmin installer downloaded from internet and executed without any checksum verification — MITM/supply-chain attack possible | Added SHA256 verification against `virtualmin-install.sh.sha256` before execution |
| BUG-03 | Crash | PHP `disable_functions` used backslash line continuation across multiple lines in php.ini — PHP ini format does NOT support this, silently ignores entire directive | Rewrote as a single unbroken line |
| BUG-04 | Crash | MariaDB slow query log referenced `/var/log/mysql/slow.log` but the directory was never created, causing MariaDB to fail to start | Added `mkdir -p /var/log/mysql` before writing config |
| BUG-05 | Security | UFW `deny` for mail ports used `deny PORT` not `deny in PORT` — subtle difference in UFW semantics for INPUT chain matching | Changed to `ufw deny in PORT` |
| SEC-01 | Security | SSH rate-limiting only worked on IPv4 — IPv6 SSH brute-force was unconstrained | `ufw limit ssh` now covers IPv4+IPv6 |
| SEC-02 | Security | Fail2Ban `banaction = ufw` — fails silently if UFW is not active | Added fallback `banaction_allports` directive |
| SEC-03 | Security | Missing `Cross-Origin-Resource-Policy` header in security-headers.conf | Added `add_header Cross-Origin-Resource-Policy "same-origin" always` |

## Script 02 — VPS Production Setup

| ID | Type | Description | Fix |
|----|------|-------------|-----|
| BUG-01 | Security | Same Virtualmin installer checksum issue as Script 01 | Same fix |
| BUG-02 | Crash | MariaDB root password setup used `mysqladmin -u root password ... \|\| true` — if Virtualmin already set a password, this fails silently and `.my.cnf` contains a wrong password, breaking all subsequent `mysql` calls | Added tri-state logic: try no-password first, then read existing `.my.cnf`, then fallback to socket auth |
| BUG-03 | Security | FTP passive port range `49152:65534/tcp` opened **16,382 ports** in UFW — massive attack surface | Reduced to `49150:49200/tcp` (50 ports), ProFTPD patched to match |
| BUG-04 | Crash | Same MariaDB log directory issue as Script 01 | Same fix |
| BUG-05 | Warning | `innodb_log_file_size` deprecated in MariaDB 10.11+, causes startup warning | Added version detection — uses `innodb_redo_log_capacity` on 10.11+, `innodb_log_file_size` on older |
| BUG-06 | Security | Default `index.html` exposed VPS IP address in HTTP response body | Replaced with generic "Server is running" page |
| BUG-07 | Crash | Same PHP `disable_functions` line continuation issue | Same fix |
| BUG-08 | Security | IPv6 redirect/source-route hardening missing from sysctl tuning file | Added `net.ipv6.conf.all.*` and `net.ipv6.conf.default.*` entries |
| SEC-01 | Security | FTP passive range — same as BUG-03 | Narrow range |
| SEC-02 | Security | Default page IP disclosure — same as BUG-06 | Generic page |
| SEC-03 | Security | Missing `Cross-Origin-Resource-Policy` header | Added to security-headers.conf |
| SEC-04 | Security | Nginx rate-limiting zone was defined in nginx.conf but never applied to the default vhost — rate limiting had zero effect | Applied `limit_req` and `limit_conn` directives inside the default server block |
| SEC-05 | Security | Default vhost had no connection limit | Added `limit_conn perip_conn 20` |
| SEC-06 | Security | `net.ipv4.conf.default.rp_filter` missing from tuning sysctl | Added |

## Script 03 — Weekly Maintenance

| ID | Type | Description | Fix |
|----|------|-------------|-----|
| BUG-01 | Crash | `REPORT_DATE` variable not defined at top level — when script is invoked by cron in `--run` mode, the variable is undefined, causing log file path to fail | Moved `REPORT_DATE="$(date...)"` to top of script |
| BUG-02 | Crash | `rkhunter --check` fails on first run if the database hasn't been initialised — no `--propupd` call before first scan | Added `rkhunter --propupd` check before scan |
| BUG-03 | Crash | `mysqlcheck` called without checking if `/root/.my.cnf` exists — crashes with unhelpful error if file missing | Added guard `[[ -f /root/.my.cnf ]]` before all mysql calls |
| BUG-04 | Crash | `SHOW GLOBAL STATUS LIKE 'Slow_queries'` query broken if MariaDB auth state changed | Wrapped in same `.my.cnf` guard |
| SEC-01 | Security | Maintenance log directory had no explicit permission check — could be world-readable | Added `chmod 750` on every path that touches log dir |

## Script 04 — Security Hardening

| ID | Type | Description | Fix |
|----|------|-------------|-----|
| BUG-01 | Logic | `ADD_DOMAIN="${2:-}"` was set unconditionally before the `--add-domain` check — any second argument would incorrectly trigger domain logic | Rewrote as clean `if [[ "$1" == "--add-domain" ]]; then` block |
| BUG-02 | Misleading | `sshd -t \|\| err "Restoring backup"` printed "Restoring backup" but never actually restored the backup | Now actually runs `cp "$SSHD_BAK" "$SSHD_CONF"` on failure |
| BUG-03 | **Crash** | `cross_origin_resource_policy same-origin;` is **not a valid Nginx directive** — `nginx -t` fails, Nginx refuses to reload | Changed to `add_header Cross-Origin-Resource-Policy "same-origin" always;` |
| BUG-04 | **Security** | `limit-methods.conf` defined a `$not_allowed_method` map but **never referenced it anywhere** — TRACE/TRACK requests were NOT blocked despite the code appearing to do so | Map result is now actually used in server block: `if ($method_not_allowed) { return 405; }` |
| BUG-05 | **Crash** | `UsePAM no` breaks SFTP subsystem and systemd session tracking on Ubuntu 24.04 — can cause complete SSH session failures | Set `UsePAM yes` explicitly |
| BUG-06 | **Security** | `AllowUsers root` would lock out all Virtualmin-created virtual server users from SFTP access | `AllowUsers` line removed; Virtualmin users need SSH/SFTP access |
| BUG-07 | Crash | `REPORT_DATE` variable used in Lynis log path but never defined in this script | Added `REPORT_DATE="$(date +%Y%m%d_%H%M%S)"` at top |
| BUG-08 | Crash | PHP `disable_functions` in `99-security.ini` used backslash continuation — invalid in PHP ini, silently ignored | Rewrote as single unbroken line |
| BUG-09 | **Crash** | `/tmp noexec` breaks `apt`, `dpkg`, Virtualmin backup/restore tools, and many PHP operations | Removed `/tmp noexec` — only `/dev/shm` gets `noexec` (the real attack surface) |
| SEC-01 | Security | `net.ipv4.conf.default.accept_redirects` missing | Added |
| SEC-02 | Security | All IPv6 sysctl entries missing from hardening file | Added `net.ipv6.conf.*` block including `accept_ra = 0` |
| SEC-03 | Security | `open_basedir` missing `/var/tmp` — PHP sessions sometimes write there | Added `/var/tmp` to `open_basedir` |
| SEC-04 | Security | Extra Fail2Ban jails appended unconditionally on every run — duplicate jail entries cause Fail2Ban to fail | Added `grep -q '[php-url-fopen]'` guard before appending |
| SEC-05 | Security | `nginx-noscript` filter regex was missing closing quote — broken regex, filter never worked | Fixed regex syntax |
| SEC-06 | Security | Auditd rules only covered `b64` architecture — 32-bit syscalls on 64-bit kernel were unmonitored | Added matching `b32` rules for all privilege escalation syscalls |

## Script 05 — Mail Enable

| ID | Type | Description | Fix |
|----|------|-------------|-----|
| BUG-01 | Crash | `dig` used for DNS verification but not installed on minimal Ubuntu | Added `apt install bind9-dnsutils` in prerequisites step; added `host` as fallback |
| BUG-02 | Crash | `master.cf` SpamAssassin entry appended with `cat >>` every run — multiple identical entries cause Postfix to fail | Added `grep -q 'spamassassin' master.cf` guard |
| BUG-03 | Crash | Dovecot `10-ssl.conf` overwritten entirely — destroys any SSL config Virtualmin already wrote | Changed to patch individual directives with `sed -i` instead of overwriting |
| BUG-04 | Crash | `id spamd` used as a user existence check — exits non-zero if user absent, and `\|\|` silently swallowed | Changed to `getent passwd spamd` which is the correct portable idiom |
| SEC-01 | Security | SPF record used `~all` (soft fail) — allows any server to send as your domain with only a warning | Changed to `-all` (hard fail) — unknown senders are rejected |
| SEC-02 | Security | Dovecot `disable_plaintext_auth` was set in `10-auth.conf` but never enforced in listening services | Ensured the directive is in the correct config file and SSL is required |
| SEC-03 | Security | No SMTP connection rate limiting — open relay abuse possible | Added `smtpd_client_connection_rate_limit` and `smtpd_client_message_rate_limit` |

## Script 06 — Backup

| ID | Type | Description | Fix |
|----|------|-------------|-----|
| BUG-01 | Crash | `mysql --defaults-file=/root/.my.cnf` called without checking if file exists — hard crash if setup script not run yet | Added `[[ -f /root/.my.cnf ]]` guard |
| BUG-02 | Security | Backup directories created with default `755` permissions — world-readable backups containing site data | Added `chmod 700` on all backup directories |
| BUG-03 | Warning | `tar` of `/home/*/public_html` failed silently if no Virtualmin sites existed yet | Added `SITES_FOUND` counter and explicit warning |
| BUG-04 | Logic | `find -name "*.tar.gz" -o -name "*.sql.gz" -mtime +N` — without parentheses, `-mtime` only applies to the last condition (`.sql.gz`). `.tar.gz` files were never deleted by retention. | Wrapped name conditions in `\( \)` so `-mtime` applies to both |
| SEC-01 | Security | Backup files created with default `644` — world-readable | Added `chmod 600` after each file creation |

---

# 2. POST-INSTALL VERIFICATION CHECKLIST

```bash
# ── Core services ─────────────────────────────────────────────
systemctl is-active nginx php8.3-fpm mariadb fail2ban

# ── Nginx config valid ───────────────────────────────────────
nginx -t

# ── PHP working (remove file after test!) ─────────────────────
echo "<?php echo PHP_VERSION; ?>" > /var/www/html/ver.php
curl -s http://localhost/ver.php
rm /var/www/html/ver.php

# ── MariaDB accessible ───────────────────────────────────────
mysql --defaults-file=/root/.my.cnf -e "SHOW DATABASES;"

# ── UFW status ───────────────────────────────────────────────
ufw status verbose

# ── Firewall — verify mail ports CLOSED ──────────────────────
ss -tlnp | grep -E ':(25|110|143|465|587|993|995) '
# Expected: no output

# ── Swap active ──────────────────────────────────────────────
swapon --show && free -h

# ── /dev/shm noexec ──────────────────────────────────────────
mount | grep /dev/shm | grep noexec

# ── Fail2Ban jails ───────────────────────────────────────────
fail2ban-client status

# ── PHP disable_functions applied ────────────────────────────
php -r "system('id');" 2>&1 | grep -i disabled
# Expected: "has been disabled"

# ── Auditd running ───────────────────────────────────────────
systemctl is-active auditd
auditctl -l | head -10

# ── TRACE/TRACK blocked (after 04 hardening script) ──────────
curl -s -X TRACE http://localhost | head -3
# Expected: 405 or empty response (not a 200 echo)

# ── SSH key login test (BEFORE running 04) ───────────────────
# From your local machine in a NEW terminal:
ssh -i ~/.ssh/your_key root@YOUR_VPS_IP echo "SSH key works"
```

---

# 3. RAM OPTIMIZATION NOTES

## Idle RAM Budget (2 GB KVM2)

| Service           | Idle RAM  | Notes                                |
|-------------------|-----------|--------------------------------------|
| Linux kernel      | ~80 MB    | Fixed                                |
| systemd           | ~30 MB    | Fixed                                |
| Webmin/Virtualmin | ~80 MB    | Perl-based, cannot be reduced easily |
| Nginx             | ~20 MB    | 1 worker process                     |
| PHP 8.3-FPM       | ~5 MB     | ondemand — 0 children when idle      |
| MariaDB           | ~120 MB   | With 128 MB innodb_buffer_pool       |
| Fail2Ban          | ~20 MB    | Python-based                         |
| auditd            | ~5 MB     | C daemon                             |
| sshd              | ~5 MB     | Fixed                                |
| cron              | ~2 MB     | Fixed                                |
| **Total idle**    | **~367 MB** | ~270 MB headroom below 1 GB goal   |

## Save More RAM

```bash
# Disable Usermin if not needed (~40 MB)
systemctl disable --now usermin

# Disable ProFTPD if not using FTP (~10 MB)
systemctl disable --now proftpd

# Current RAM usage by service
ps aux --sort=-%mem | awk 'NR<=15 {printf "%-8s %5s%% %s\n", $1, $4, $11}'
```

---

# 4. SERVICE CHEAT SHEET

```bash
# ── Core stack ────────────────────────────────────────────────
systemctl restart nginx php8.3-fpm mariadb fail2ban
systemctl reload nginx                          # config reload without restart

# ── Logs ──────────────────────────────────────────────────────
journalctl -fu nginx
tail -f /var/log/php8.3-fpm.log
tail -f /var/log/mysql/slow.log
tail -f /var/log/server-maintenance/weekly-*.log

# ── Fail2Ban ──────────────────────────────────────────────────
fail2ban-client status
fail2ban-client set sshd unbanip 1.2.3.4       # unban IP
fail2ban-client set sshd banip 1.2.3.4         # manual ban

# ── Virtualmin CLI ────────────────────────────────────────────
virtualmin list-domains
virtualmin create-domain --domain example.com \
  --pass "$(tr -dc A-Za-z0-9 < /dev/urandom | head -c 20)" \
  --unix --dir --web --mysql --no-email
virtualmin delete-domain --domain example.com
virtualmin install-letsencrypt-cert --domain example.com --web

# ── Mail (enable/disable) ────────────────────────────────────
systemctl enable  --now postfix dovecot opendkim   # enable
systemctl disable --now postfix dovecot opendkim   # disable
tail -f /var/log/mail.log

# ── UFW ───────────────────────────────────────────────────────
ufw status numbered
ufw allow 8080/tcp
ufw delete 5                                    # delete rule #5
ufw reload
```

---

# 5. RECOVERY INSTRUCTIONS

## Locked Out of SSH

```bash
# Option A: Hostinger VNC Console
# hPanel → VPS → Manage → VNC Console → login as root
echo "ssh-rsa YOUR_PUBKEY" >> /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys

# Option B: Re-enable password auth via VNC
sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config
systemctl restart ssh
# Login, fix issue, then re-disable password auth
```

## Nginx Won't Start

```bash
nginx -t                                        # find config error
journalctl -u nginx --no-pager -n 30
ls /etc/nginx/sites-enabled/                    # check for bad symlinks
rm /etc/nginx/sites-enabled/problem-site
nginx -t && systemctl start nginx
```

## MariaDB Won't Start

```bash
journalctl -u mariadb --no-pager -n 30
df -h                                           # check disk space
mysqlcheck --all-databases --auto-repair        # repair tables
```

## PHP 500 Errors

```bash
tail -f /var/log/php8.3-fpm.log
tail -f /var/log/nginx/error.log
ls -la /run/php/php8.3-fpm.sock                # socket must exist
systemctl restart php8.3-fpm
```

## Disk Full

```bash
du -sh /var/* 2>/dev/null | sort -rh | head -10
journalctl --vacuum-size=50M
find /var/log -name "*.gz" -mtime +7 -delete
apt-get clean
find /var/backups -mtime +30 -delete
```

## Restore From Backup

```bash
# Website
tar -xzf /var/backups/websites/sitename-DATE.tar.gz -C /home/

# Database
gunzip < /var/backups/databases/dbname-DATE.sql.gz \
  | mysql --defaults-file=/root/.my.cnf dbname

# Configs
tar -xzf /var/backups/configs/configs-DATE.tar.gz -C /
nginx -t && systemctl restart nginx php8.3-fpm mariadb
```

---

# 6. DOMAIN MIGRATION GUIDE

## Phase 1 — DNS Setup

```
A     yourdomain.com           →  YOUR_VPS_IP    TTL 300
A     www.yourdomain.com       →  YOUR_VPS_IP    TTL 300
A     mail.yourdomain.com      →  YOUR_VPS_IP    TTL 300  (if mail)
MX    yourdomain.com           →  mail.yourdomain.com     (if mail)
```

```bash
# Verify from VPS (wait up to 30 min for propagation)
dig +short A yourdomain.com
```

## Phase 2 — Create Virtual Server

```bash
virtualmin create-domain \
  --domain yourdomain.com \
  --pass "$(tr -dc A-Za-z0-9 < /dev/urandom | head -c 20)" \
  --unix --dir --web --mysql --no-email
```

## Phase 3 — SSL Certificate

```bash
apt install -y certbot python3-certbot-nginx
certbot --nginx -d yourdomain.com -d www.yourdomain.com
certbot renew --dry-run                         # test auto-renewal
```

## Phase 4 — Deploy Application

```bash
# Upload via rsync
rsync -avz ./app/ root@YOUR_VPS_IP:/home/yourdomain.com/public_html/

# Fix permissions
chown -R yourdomain.com:yourdomain.com /home/yourdomain.com/public_html/
chmod 755 /home/yourdomain.com/public_html/
```

## Phase 5 — Per-site Nginx Vhost (Reverse Proxy Example)

```nginx
server {
    listen 443 ssl;
    server_name app.yourdomain.com;
    include snippets/ssl-hardening.conf;
    include snippets/security-headers.conf;
    ssl_certificate     /etc/letsencrypt/live/yourdomain.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/yourdomain.com/privkey.pem;

    if ($method_not_allowed) { return 405; }
    limit_req  zone=perip burst=30 nodelay;
    limit_conn perip_conn 20;

    location / {
        proxy_pass         http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header   Host              $host;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
        proxy_read_timeout 60s;
    }

    location ~ /\.env { deny all; return 404; }
    location ~ /\.ht  { deny all; return 404; }
}
```

---

## Quick Reference

```
VIRTUALMIN PANEL  : https://YOUR_IP:10000
WEBSITES          : /home/DOMAIN/public_html/
NGINX SITES       : /etc/nginx/sites-available/
NGINX SNIPPETS    : /etc/nginx/snippets/
PHP CONFIG        : /etc/php/8.3/fpm/
MARIADB CREDS     : /root/.my.cnf  (chmod 600)
BACKUPS           : /var/backups/  (chmod 700)
MAINTENANCE LOGS  : /var/log/server-maintenance/
SSL CERTS         : /etc/letsencrypt/live/DOMAIN/
DKIM KEYS         : /etc/opendkim/keys/DOMAIN/
AUDIT LOGS        : ausearch -k identity  (auditd)
```
