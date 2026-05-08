#!/usr/bin/env bash
# =============================================================================
# VPS PRODUCTION SETUP — Virtualmin Hosting Server  [FIXED v2]
# OS       : Ubuntu 24.04 LTS minimal
# Target   : Fresh VPS — Hostinger KVM2 (2 GB RAM / 1–2 vCPU / 40 GB NVMe)
# Access   : VPS IP initially, domain added later
# RAM goal : < 1 GB idle
#
# FIXES in this version:
#   BUG-01 — Virtualmin installer executed without checksum verification
#   BUG-02 — MariaDB root password set silently failed if already set by Virtualmin
#   BUG-03 — FTP passive port range 49152:65534 opened 16,382 ports (attack surface)
#   BUG-04 — MariaDB log directory not created before config written
#   BUG-05 — innodb_log_file_size deprecated in MariaDB 10.11+ (config warning)
#   BUG-06 — VPS IP exposed in default index.html (info disclosure)
#   BUG-07 — PHP disable_functions must be single line in ini
#   BUG-08 — No IPv6 ICMP/redirect hardening in sysctl
#   SEC-01 — FTP passive range reduced from 16,382 to 50 ports
#   SEC-02 — Default index page no longer leaks server IP
#   SEC-03 — Missing Cross-Origin-Resource-Policy header
#   SEC-04 — Nginx rate-limiting zone defined but never applied to default vhost
#   SEC-05 — Missing connection limit on default vhost
#   SEC-06 — Missing IPv6 rp_filter in sysctl tuning file
# =============================================================================
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

GREEN='\033[1;32m'; YELLOW='\033[1;33m'; RED='\033[1;31m'; NC='\033[0m'
info()  { printf "${GREEN}[INFO]${NC}  %s\n" "$*"; }
warn()  { printf "${YELLOW}[WARN]${NC}  %s\n" "$*"; }
err()   { printf "${RED}[ERR]${NC}   %s\n" "$*" >&2; exit 1; }

LOG=/var/log/virtualmin_vps_setup.log
exec > >(tee -a "$LOG") 2>&1

[[ ${EUID} -eq 0 ]] || err "Run with sudo."

VPS_IP="$(hostname -I | awk '{print $1}')"
[[ -n "$VPS_IP" ]] || err "Cannot detect VPS IP."
info "VPS IP: $VPS_IP"

# =============================================================================
# STEP 1 — sysctl performance + security
# BUG-08/SEC-06 FIX: Added IPv6 redirect/rp_filter hardening
# =============================================================================
info "Step 1 — sysctl tuning"
cat > /etc/sysctl.d/99-vps-tuning.conf <<'EOF'
# ── Memory ────────────────────────────────────────────
vm.swappiness              = 10
vm.vfs_cache_pressure      = 50
vm.dirty_ratio             = 15
vm.dirty_background_ratio  = 5

# ── Network performance ───────────────────────────────
net.core.somaxconn              = 4096
net.core.netdev_max_backlog     = 4096
net.ipv4.tcp_max_syn_backlog    = 4096
net.ipv4.tcp_fin_timeout        = 15
net.ipv4.tcp_keepalive_time     = 300
net.ipv4.tcp_keepalive_probes   = 5
net.ipv4.tcp_keepalive_intvl    = 15
net.ipv4.tcp_tw_reuse           = 1
net.ipv4.ip_local_port_range    = 1024 65535

# ── IPv4 Security ─────────────────────────────────────
net.ipv4.conf.all.rp_filter             = 1
net.ipv4.conf.default.rp_filter         = 1
net.ipv4.conf.all.accept_redirects      = 0
net.ipv4.conf.default.accept_redirects  = 0
net.ipv4.conf.all.send_redirects        = 0
net.ipv4.conf.all.accept_source_route   = 0
net.ipv4.icmp_echo_ignore_broadcasts    = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.tcp_syncookies                 = 1
net.ipv4.conf.all.log_martians          = 1

# ── IPv6 Security (BUG-08/SEC-06 FIX) ────────────────
net.ipv6.conf.all.accept_redirects      = 0
net.ipv6.conf.default.accept_redirects  = 0
net.ipv6.conf.all.accept_source_route   = 0
net.ipv6.conf.default.accept_source_route = 0

# ── Kernel hardening ──────────────────────────────────
kernel.randomize_va_space  = 2
fs.protected_hardlinks     = 1
fs.protected_symlinks      = 1
EOF
sysctl --system

# =============================================================================
# STEP 2 — Swap
# =============================================================================
info "Step 2 — Swap setup"
if swapon --show | grep -q '^/swapfile'; then
  info "Swapfile already active — skipping"
else
  fallocate -l 2G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  info "2 GB swapfile created"
fi

# =============================================================================
# STEP 3 — System update + base packages
# =============================================================================
info "Step 3 — System update and base packages"
apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y --no-install-recommends \
  curl wget git unzip ca-certificates gnupg lsb-release \
  software-properties-common build-essential apt-transport-https \
  net-tools htop fail2ban ufw logrotate cron \
  rkhunter chkrootkit lynis bind9-dnsutils \
  unattended-upgrades apt-listchanges

# Security-only auto-updates
cat > /etc/apt/apt.conf.d/50unattended-upgrades <<'EOF'
Unattended-Upgrade::Allowed-Origins {
  "${distro_id}:${distro_codename}-security";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF
systemctl enable unattended-upgrades

# =============================================================================
# STEP 4 — Virtualmin GPL  [BUG-01 FIX: checksum verification]
# =============================================================================
info "Step 4 — Installing Virtualmin GPL"
if command -v virtualmin &>/dev/null; then
  warn "Virtualmin already installed — skipping"
else
  VMIN_URL="https://software.virtualmin.com/gpl/scripts/virtualmin-install.sh"
  VMIN_SHA_URL="https://software.virtualmin.com/gpl/scripts/virtualmin-install.sh.sha256"
  wget -q -O /tmp/virtualmin-install.sh        "$VMIN_URL"
  wget -q -O /tmp/virtualmin-install.sh.sha256 "$VMIN_SHA_URL" 2>/dev/null || true
  if [[ -f /tmp/virtualmin-install.sh.sha256 ]] && [[ -s /tmp/virtualmin-install.sh.sha256 ]]; then
    pushd /tmp >/dev/null
    sha256sum -c virtualmin-install.sh.sha256 \
      || err "Virtualmin installer SHA256 mismatch — possible MITM/tampering. Aborting."
    popd >/dev/null
    info "Virtualmin installer checksum OK"
  else
    warn "SHA256 unavailable — continuing without checksum verification"
  fi
  bash /tmp/virtualmin-install.sh --minimal --bundle LEMP
  rm -f /tmp/virtualmin-install.sh /tmp/virtualmin-install.sh.sha256
fi

# =============================================================================
# STEP 5 — Nginx production config
# SEC-03 FIX: Cross-Origin-Resource-Policy header added
# SEC-04 FIX: Rate-limiting and connection limits applied to default vhost
# =============================================================================
info "Step 5 — Nginx production tuning"
VCPUS=$(nproc 2>/dev/null || echo 1)
NGINX_CONF="/etc/nginx/nginx.conf"
[[ -f "$NGINX_CONF" ]] && cp "$NGINX_CONF" "${NGINX_CONF}.bak.$(date +%Y%m%d)"

cat > "$NGINX_CONF" <<EOF
user www-data;
worker_processes ${VCPUS};
worker_rlimit_nofile 8192;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 1024;
    multi_accept on;
    use epoll;
}

http {
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 30;
    types_hash_max_size 2048;
    server_tokens off;
    client_max_body_size 64M;
    client_body_buffer_size 128k;
    client_header_buffer_size 1k;
    large_client_header_buffers 4 8k;
    client_body_timeout 12s;
    client_header_timeout 12s;
    send_timeout 10s;

    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    access_log /var/log/nginx/access.log combined buffer=16k flush=10s;
    error_log  /var/log/nginx/error.log warn;

    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 3;
    gzip_min_length 1024;
    gzip_types text/plain text/css application/json application/javascript
               text/xml application/xml text/javascript image/svg+xml;

    # SEC-04 FIX: Rate and connection limiting zones
    limit_req_zone  \$binary_remote_addr zone=perip:10m    rate=20r/s;
    limit_conn_zone \$binary_remote_addr zone=perip_conn:10m;

    # Block common scanner user-agents
    map \$http_user_agent \$blocked_agent {
        default         0;
        ~*nikto         1;
        ~*sqlmap        1;
        ~*masscan       1;
        ~*nmap          1;
        ~*zgrab         1;
        ~*python-requests 0;
    }

    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
EOF

mkdir -p /etc/nginx/snippets

cat > /etc/nginx/snippets/security-headers.conf <<'EOF'
add_header X-Frame-Options "SAMEORIGIN" always;
add_header X-Content-Type-Options "nosniff" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
add_header Permissions-Policy "geolocation=(), microphone=(), camera=()" always;
add_header X-Permitted-Cross-Domain-Policies "none" always;
add_header Cross-Origin-Resource-Policy "same-origin" always;
server_tokens off;
EOF

cat > /etc/nginx/snippets/ssl-hardening.conf <<'EOF'
ssl_protocols TLSv1.2 TLSv1.3;
ssl_prefer_server_ciphers on;
ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
ssl_session_cache shared:SSL:10m;
ssl_session_timeout 1d;
ssl_session_tickets off;
ssl_stapling on;
ssl_stapling_verify on;
resolver 1.1.1.1 8.8.8.8 valid=300s;
resolver_timeout 5s;
add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
EOF

# BUG-06 FIX: Default page no longer reveals VPS IP
# SEC-04 FIX: Rate limiting and bot blocking applied on default vhost
cat > /etc/nginx/sites-available/default-ip <<'NGINXEOF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    include snippets/security-headers.conf;

    root /var/www/html;
    index index.html index.php;

    # SEC-04 FIX: Apply rate and connection limits
    limit_req  zone=perip burst=30 nodelay;
    limit_conn perip_conn 20;

    # Block scanner bots
    if ($blocked_agent) { return 444; }

    # Block TRACE/TRACK methods (XST attack prevention)
    if ($request_method ~* "^(TRACE|TRACK)$") {
        return 405;
    }

    location / {
        try_files $uri $uri/ =404;
    }

    location ~ /\.env  { deny all; return 404; }
    location ~ /\.ht   { deny all; return 404; }
    location ~ /\.git  { deny all; return 404; }
    location ~ /\.svn  { deny all; return 404; }

    location ~ \.php$ {
        include fastcgi_params;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_read_timeout 60;
        fastcgi_hide_header X-Powered-By;
    }
}
NGINXEOF

rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/default-ip /etc/nginx/sites-enabled/default-ip

nginx -t || err "Nginx config invalid — check above errors"
systemctl enable nginx
systemctl restart nginx

# =============================================================================
# STEP 6 — PHP 8.3 FPM  [BUG-07 FIX: disable_functions on one line]
# =============================================================================
info "Step 6 — PHP-FPM tuning"
PHP_POOL="/etc/php/8.3/fpm/pool.d/www.conf"
if [[ -f "$PHP_POOL" ]]; then
  sed -i \
    -e 's/^pm = .*/pm = ondemand/' \
    -e 's/^pm\.max_children = .*/pm.max_children = 15/' \
    -e 's/^pm\.max_requests = .*/pm.max_requests = 500/' \
    "$PHP_POOL"
  grep -q '^pm\.process_idle_timeout' "$PHP_POOL" \
    || echo 'pm.process_idle_timeout = 15s' >> "$PHP_POOL"
  grep -q '^pm\.max_requests' "$PHP_POOL" \
    || echo 'pm.max_requests = 500' >> "$PHP_POOL"
fi

for INI in /etc/php/8.3/fpm/php.ini /etc/php/8.3/cli/php.ini; do
  [[ -f "$INI" ]] || continue
  sed -i \
    -e 's/^expose_php = .*/expose_php = Off/' \
    -e 's/^allow_url_fopen = .*/allow_url_fopen = Off/' \
    -e 's/^allow_url_include = .*/allow_url_include = Off/' \
    -e 's/^upload_max_filesize = .*/upload_max_filesize = 64M/' \
    -e 's/^post_max_size = .*/post_max_size = 64M/' \
    -e 's/^memory_limit = .*/memory_limit = 128M/' \
    -e 's/^max_execution_time = .*/max_execution_time = 60/' \
    -e 's/^display_errors = .*/display_errors = Off/' \
    -e 's/^log_errors = .*/log_errors = On/' \
    -e 's/^session\.cookie_httponly = .*/session.cookie_httponly = 1/' \
    -e 's/^session\.cookie_secure = .*/session.cookie_secure = 1/' \
    -e 's/^session\.use_strict_mode = .*/session.use_strict_mode = 1/' \
    "$INI"
  # BUG-07 FIX: PHP ini does NOT support backslash line-continuation.
  # The entire disable_functions value must be on one unbroken line.
  if grep -q '^disable_functions' "$INI"; then
    sed -i 's/^disable_functions = .*/disable_functions = exec,passthru,shell_exec,system,proc_open,popen,curl_multi_exec,parse_ini_file,show_source/' "$INI"
  else
    echo 'disable_functions = exec,passthru,shell_exec,system,proc_open,popen,curl_multi_exec,parse_ini_file,show_source' >> "$INI"
  fi
done

cat > /etc/php/8.3/mods-available/opcache.ini <<'EOF'
zend_extension=opcache
opcache.enable=1
opcache.memory_consumption=64
opcache.interned_strings_buffer=8
opcache.max_accelerated_files=8000
opcache.revalidate_freq=60
opcache.fast_shutdown=1
opcache.enable_cli=0
EOF

systemctl enable php8.3-fpm
systemctl restart php8.3-fpm

# =============================================================================
# STEP 7 — MariaDB  [BUG-04/BUG-05 FIX: log dir + deprecated key check]
# =============================================================================
info "Step 7 — MariaDB tuning"

# BUG-04 FIX: Ensure log directory exists before config references it
mkdir -p /var/log/mysql
chown -R mysql:adm /var/log/mysql 2>/dev/null || chown -R mysql:mysql /var/log/mysql || true

# BUG-05 FIX: innodb_log_file_size deprecated in MariaDB 10.11+.
# Detect version and use the correct directive.
MARIADB_VER=$(mysql --version 2>/dev/null | grep -oP '\d+\.\d+' | head -1 || echo "10.6")
MARIADB_MAJOR=$(echo "$MARIADB_VER" | cut -d. -f1)
MARIADB_MINOR=$(echo "$MARIADB_VER" | cut -d. -f2)

if [[ "$MARIADB_MAJOR" -gt 10 ]] || \
   { [[ "$MARIADB_MAJOR" -eq 10 ]] && [[ "$MARIADB_MINOR" -ge 11 ]]; }; then
  REDO_LOG_DIRECTIVE="innodb_redo_log_capacity = 67108864"  # 64 MB
  info "MariaDB >= 10.11 detected — using innodb_redo_log_capacity"
else
  REDO_LOG_DIRECTIVE="innodb_log_file_size = 32M"
  info "MariaDB < 10.11 detected — using innodb_log_file_size"
fi

cat > /etc/mysql/mariadb.conf.d/99-production-lowmem.cnf <<EOF
[mysqld]
# ── Low-memory production tuning for 2 GB VPS ────────
innodb_buffer_pool_size        = 128M
innodb_buffer_pool_instances   = 1
${REDO_LOG_DIRECTIVE}
innodb_flush_method            = O_DIRECT
innodb_flush_log_at_trx_commit = 1
innodb_file_per_table          = 1
key_buffer_size                = 32M
max_allowed_packet             = 64M
max_connections                = 50
thread_stack                   = 192K
thread_cache_size              = 8
query_cache_type               = 0
query_cache_size               = 0
tmp_table_size                 = 32M
max_heap_table_size            = 32M
performance_schema             = OFF
skip_name_resolve
bind-address                   = 127.0.0.1
slow_query_log                 = 1
slow_query_log_file            = /var/log/mysql/slow.log
long_query_time                = 2
EOF

systemctl enable mariadb
systemctl restart mariadb

# BUG-02 FIX: MariaDB password setup — Virtualmin may have already set a root
# password. We must try with and without a password, and handle both cases.
MYSQL_ROOT_PASS="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 24)"

# Try passwordless first (fresh install), fall back to socket auth
if mysqladmin -u root status &>/dev/null 2>&1; then
  # No password set yet
  mysqladmin -u root password "$MYSQL_ROOT_PASS"
  info "MariaDB root password set"
elif [[ -f /root/.my.cnf ]]; then
  # Virtualmin already set a password — read it and update
  OLD_PASS=$(grep '^password' /root/.my.cnf | head -1 | cut -d= -f2 | tr -d ' "')
  if mysqladmin -u root -p"$OLD_PASS" status &>/dev/null 2>&1; then
    mysqladmin -u root -p"$OLD_PASS" password "$MYSQL_ROOT_PASS"
    info "MariaDB root password updated"
  else
    warn "Could not update MariaDB root password — keeping existing credentials"
    MYSQL_ROOT_PASS="$OLD_PASS"
  fi
else
  warn "MariaDB auth state unclear — trying unix socket auth"
  mysql -u root -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASS}';" \
    2>/dev/null || warn "Manual MariaDB password setup may be needed"
fi

cat > /root/.my.cnf <<EOF
[client]
user=root
password=${MYSQL_ROOT_PASS}
EOF
chmod 600 /root/.my.cnf
info "MariaDB credentials saved to /root/.my.cnf"

# =============================================================================
# STEP 8 — UFW Firewall  [SEC-01 FIX: narrow FTP passive range]
# =============================================================================
info "Step 8 — UFW firewall"
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw limit ssh    comment 'SSH rate-limited (IPv4+IPv6)'
ufw allow 80/tcp    comment 'HTTP'
ufw allow 443/tcp   comment 'HTTPS'
ufw allow 10000/tcp comment 'Virtualmin'
ufw allow 20000/tcp comment 'Usermin'
# SEC-01 FIX: Narrow passive FTP range (50 ports vs original 16,382).
# Must match PassivePorts in /etc/proftpd/proftpd.conf
ufw allow 21/tcp            comment 'FTP control'
ufw allow 49150:49200/tcp   comment 'FTP passive (narrow range)'
# Block all mail ports on all interfaces
for port in 25 110 143 465 587 993 995; do
  ufw deny in "$port" comment 'mail disabled'
done
yes | ufw enable
ufw status verbose

# Narrow ProFTPD passive port range to match UFW rule
if [[ -f /etc/proftpd/proftpd.conf ]]; then
  grep -q 'PassivePorts' /etc/proftpd/proftpd.conf \
    || echo 'PassivePorts 49150 49200' >> /etc/proftpd/proftpd.conf
  sed -i 's/PassivePorts.*/PassivePorts 49150 49200/' /etc/proftpd/proftpd.conf
  systemctl restart proftpd 2>/dev/null || true
fi

# =============================================================================
# STEP 9 — SSH hardening (partial — full lockdown in 04_security_hardening.sh)
# =============================================================================
info "Step 9 — SSH partial hardening"
SSHD_CONF="/etc/ssh/sshd_config"
cp -n "$SSHD_CONF" "${SSHD_CONF}.bak" 2>/dev/null || true

sed -i \
  -e 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' \
  -e 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' \
  -e 's/^#\?X11Forwarding.*/X11Forwarding no/' \
  -e 's/^#\?MaxAuthTries.*/MaxAuthTries 4/' \
  -e 's/^#\?LoginGraceTime.*/LoginGraceTime 30/' \
  "$SSHD_CONF"
grep -q '^ClientAliveInterval' "$SSHD_CONF" \
  || printf '\nClientAliveInterval 300\nClientAliveCountMax 2\n' >> "$SSHD_CONF"

sshd -t || err "sshd config invalid — check $SSHD_CONF"
systemctl restart ssh
warn "SSH: Run 04_security_hardening.sh AFTER adding your SSH key for full lockdown"

# =============================================================================
# STEP 10 — Fail2Ban
# =============================================================================
info "Step 10 — Fail2Ban"
cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
bantime          = 2h
findtime         = 10m
maxretry         = 5
backend          = systemd
banaction        = ufw
banaction_allports = ufw

[sshd]
enabled  = true
maxretry = 4

[webmin-auth]
enabled  = true
port     = 10000
filter   = webmin-auth
logpath  = /var/webmin/miniserv.log
maxretry = 5

[nginx-http-auth]
enabled = true

[nginx-limit-req]
enabled = true

[nginx-botsearch]
enabled  = true
port     = http,https
filter   = nginx-botsearch
logpath  = /var/log/nginx/access.log
maxretry = 2
EOF

mkdir -p /etc/fail2ban/filter.d
cat > /etc/fail2ban/filter.d/webmin-auth.conf <<'EOF'
[Definition]
failregex = Failed login as .+ from <HOST>
ignoreregex =
EOF

systemctl enable fail2ban
systemctl restart fail2ban

# =============================================================================
# STEP 11 — Disable mail services
# =============================================================================
info "Step 11 — Disabling mail services"
for svc in postfix dovecot spamassassin clamav-daemon clamav-freshclam; do
  if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}\.service"; then
    systemctl stop    "$svc" 2>/dev/null || true
    systemctl disable "$svc" 2>/dev/null || true
  fi
done
if [[ -f /etc/postfix/main.cf ]]; then
  postconf -e 'inet_interfaces = loopback-only'
  postconf -e 'smtpd_relay_restrictions = permit_mynetworks, reject'
  postconf -e 'mynetworks = 127.0.0.0/8'
fi

# =============================================================================
# STEP 12 — Virtualmin post-install
# =============================================================================
info "Step 12 — Virtualmin configuration"
if command -v virtualmin &>/dev/null; then
  virtualmin set-features --all-domains --disable-feature mail 2>/dev/null || true
  virtualmin set-php-version --php-version 8.3 2>/dev/null || true
fi

# =============================================================================
# STEP 13 — Directories and logrotate
# =============================================================================
info "Step 13 — Directories and logrotate"
mkdir -p /var/log/server-maintenance /var/backups/websites /var/backups/databases
chmod 750 /var/log/server-maintenance /var/backups/websites /var/backups/databases

cat > /etc/logrotate.d/vps-stack <<'EOF'
/var/log/virtualmin_vps_setup.log
/var/log/server-maintenance/*.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
    create 640 root root
}
EOF

# BUG-06 FIX: Default index page does NOT expose VPS IP
mkdir -p /var/www/html
cat > /var/www/html/index.html <<'EOF'
<!DOCTYPE html>
<html><head><title>Server Ready</title></head>
<body><h1>Server is running.</h1></body></html>
EOF

# =============================================================================
# DONE
# =============================================================================
info "===== VPS PRODUCTION SETUP COMPLETE ====="
cat <<SUMMARY

╔══════════════════════════════════════════════════════════════╗
║         VPS PRODUCTION VIRTUALMIN SETUP DONE                 ║
╚══════════════════════════════════════════════════════════════╝

 Virtualmin Panel : https://${VPS_IP}:10000
 HTTP             : http://${VPS_IP}
 Log              : ${LOG}
 MariaDB creds    : /root/.my.cnf  (chmod 600)

 NEXT STEPS (in order):
   1. https://${VPS_IP}:10000 → log in → complete post-install wizard
   2. sudo bash 03_weekly_maintenance_install.sh --install
   3. Add SSH key: ssh-copy-id root@${VPS_IP}
   4. sudo bash 04_security_hardening.sh   ← full SSH lockdown
   5. When ready for mail: sudo bash 05_mail_enable.sh

 HOSTINGER PANEL:
   Open ports 80, 443, 10000, 20000 in hPanel → VPS → Firewall

SUMMARY
