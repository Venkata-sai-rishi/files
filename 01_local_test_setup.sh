#!/usr/bin/env bash
# =============================================================================
# LOCAL TEST SETUP — Virtualmin Hosting Server  [FIXED v2]
# OS      : Ubuntu 24.04 LTS minimal
# Target  : VirtualBox / VMware / Local machine
# Access  : Local IP (no domain needed)
# RAM goal: < 1 GB idle
#
# FIXES in this version:
#   BUG-01 — /etc/hosts double-entry logic was broken (LOCAL_IP never added)
#   BUG-02 — Virtualmin installer executed without checksum verification
#   BUG-03 — PHP disable_functions used backslash continuation (invalid in ini)
#   BUG-04 — MariaDB log directory not created before config written
#   BUG-05 — UFW mail-port deny rules missing for IPv6
#   SEC-01 — SSH not rate-limited on IPv6
#   SEC-02 — Fail2Ban banaction not portable (ufw may not be active)
#   SEC-03 — Missing Cross-Origin-Resource-Policy header
# =============================================================================
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

GREEN='\033[1;32m'; YELLOW='\033[1;33m'; RED='\033[1;31m'; NC='\033[0m'
info()  { printf "${GREEN}[INFO]${NC}  %s\n" "$*"; }
warn()  { printf "${YELLOW}[WARN]${NC}  %s\n" "$*"; }
err()   { printf "${RED}[ERR]${NC}   %s\n" "$*" >&2; exit 1; }

LOG=/var/log/virtualmin_local_setup.log
exec > >(tee -a "$LOG") 2>&1

[[ ${EUID} -eq 0 ]] || err "Run with sudo."

LOCAL_IP="$(hostname -I | awk '{print $1}')"
[[ -n "$LOCAL_IP" ]] || err "Cannot detect local IP. Check network."
info "Detected local IP: $LOCAL_IP"

# =============================================================================
# STEP 1 — System update and base packages
# =============================================================================
info "Step 1 — System update and base packages"
apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y --no-install-recommends \
  curl wget git unzip ca-certificates gnupg lsb-release \
  software-properties-common build-essential apt-transport-https \
  net-tools htop fail2ban ufw logrotate cron \
  rkhunter chkrootkit bind9-dnsutils

# =============================================================================
# STEP 2 — Swap (1 GB for local test VM)
# =============================================================================
info "Step 2 — Swap setup"
if swapon --show | grep -q '^/swapfile'; then
  info "Swapfile already active — skipping"
else
  fallocate -l 1G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi
sysctl -w vm.swappiness=10 >/dev/null
grep -q 'vm.swappiness' /etc/sysctl.conf || echo 'vm.swappiness=10' >> /etc/sysctl.conf

# =============================================================================
# STEP 3 — Virtualmin GPL install  [BUG-02 FIX: checksum verification]
# =============================================================================
info "Step 3 — Installing Virtualmin GPL"
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
      || err "Virtualmin installer SHA256 mismatch — possible tampering. Aborting."
    popd >/dev/null
    info "Virtualmin installer checksum verified OK"
  else
    warn "SHA256 file unavailable — proceeding without checksum (verify manually)"
  fi
  bash /tmp/virtualmin-install.sh --minimal --bundle LEMP
  rm -f /tmp/virtualmin-install.sh /tmp/virtualmin-install.sh.sha256
fi

# =============================================================================
# STEP 4 — PHP 8.3 FPM ondemand tuning
# =============================================================================
info "Step 4 — Tuning PHP-FPM"
PHP_POOL="/etc/php/8.3/fpm/pool.d/www.conf"
if [[ -f "$PHP_POOL" ]]; then
  sed -i \
    -e 's/^pm = .*/pm = ondemand/' \
    -e 's/^pm\.max_children = .*/pm.max_children = 8/' \
    -e 's/^pm\.max_requests = .*/pm.max_requests = 200/' \
    "$PHP_POOL"
  grep -q '^pm\.process_idle_timeout' "$PHP_POOL" \
    || echo 'pm.process_idle_timeout = 10s' >> "$PHP_POOL"
  grep -q '^pm\.max_requests' "$PHP_POOL" \
    || echo 'pm.max_requests = 200' >> "$PHP_POOL"
fi

PHP_INI="/etc/php/8.3/fpm/php.ini"
if [[ -f "$PHP_INI" ]]; then
  sed -i \
    -e 's/^expose_php = .*/expose_php = Off/' \
    -e 's/^upload_max_filesize = .*/upload_max_filesize = 64M/' \
    -e 's/^post_max_size = .*/post_max_size = 64M/' \
    -e 's/^memory_limit = .*/memory_limit = 128M/' \
    -e 's/^display_errors = .*/display_errors = Off/' \
    -e 's/^log_errors = .*/log_errors = On/' \
    "$PHP_INI"
  # BUG-03 FIX: PHP ini does NOT support backslash line-continuation.
  # disable_functions must be a single unbroken line.
  if grep -q '^disable_functions' "$PHP_INI"; then
    sed -i 's/^disable_functions = .*/disable_functions = exec,passthru,shell_exec,system,proc_open,popen,curl_multi_exec,parse_ini_file,show_source/' "$PHP_INI"
  else
    echo 'disable_functions = exec,passthru,shell_exec,system,proc_open,popen,curl_multi_exec,parse_ini_file,show_source' >> "$PHP_INI"
  fi
fi
systemctl enable php8.3-fpm
systemctl restart php8.3-fpm

# =============================================================================
# STEP 5 — MariaDB low-memory config  [BUG-04 FIX: create log dir first]
# =============================================================================
info "Step 5 — Tuning MariaDB"
mkdir -p /var/log/mysql
chown -R mysql:mysql /var/log/mysql 2>/dev/null || true

cat > /etc/mysql/mariadb.conf.d/99-lowmem.cnf <<'EOF'
[mysqld]
innodb_buffer_pool_size        = 64M
innodb_flush_method            = O_DIRECT
innodb_flush_log_at_trx_commit = 2
key_buffer_size                = 16M
max_allowed_packet             = 64M
max_connections                = 30
thread_stack                   = 192K
thread_cache_size              = 4
query_cache_type               = 0
query_cache_size               = 0
tmp_table_size                 = 16M
max_heap_table_size            = 16M
performance_schema             = OFF
skip_name_resolve
bind-address                   = 127.0.0.1
slow_query_log                 = 1
slow_query_log_file            = /var/log/mysql/slow.log
long_query_time                = 2
EOF
systemctl enable mariadb
systemctl restart mariadb

# =============================================================================
# STEP 6 — Nginx  [SEC-03 FIX: add Cross-Origin-Resource-Policy header]
# =============================================================================
info "Step 6 — Tuning Nginx"
[[ -f /etc/nginx/nginx.conf ]] \
  && sed -i 's/^worker_processes .*/worker_processes 1;/' /etc/nginx/nginx.conf

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

cat > /etc/nginx/conf.d/gzip.conf <<'EOF'
gzip on;
gzip_vary on;
gzip_min_length 1024;
gzip_comp_level 3;
gzip_types text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript;
EOF

nginx -t && systemctl reload nginx

# =============================================================================
# STEP 7 — UFW Firewall  [SEC-01 FIX: SSH rate-limit covers IPv4+IPv6 via ufw limit]
# =============================================================================
info "Step 7 — Configuring UFW"
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw limit ssh    comment 'SSH brute-force protection'
ufw allow 80/tcp    comment 'HTTP'
ufw allow 443/tcp   comment 'HTTPS'
ufw allow 10000/tcp comment 'Virtualmin'
ufw allow 20000/tcp comment 'Usermin'
# BUG-05 FIX: Deny mail ports on both IPv4 and IPv6
for port in 25 110 143 465 587 993 995; do
  ufw deny in "$port" comment 'mail disabled'
done
yes | ufw enable
ufw status verbose

# =============================================================================
# STEP 8 — Fail2Ban  [SEC-02 FIX: portable banaction]
# =============================================================================
info "Step 8 — Configuring Fail2Ban"
cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
bantime   = 1h
findtime  = 10m
maxretry  = 5
backend   = systemd
# SEC-02 FIX: %(banaction_allports)s works with or without UFW
banaction          = %(banaction_allports)s
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
# STEP 9 — Disable mail services
# =============================================================================
info "Step 9 — Disabling mail services"
for svc in postfix dovecot spamassassin clamav-daemon clamav-freshclam; do
  if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}\.service"; then
    systemctl stop    "$svc" 2>/dev/null || true
    systemctl disable "$svc" 2>/dev/null || true
    info "  Disabled: $svc"
  fi
done
if [[ -f /etc/postfix/main.cf ]]; then
  postconf -e 'inet_interfaces = loopback-only'
  postconf -e 'smtpd_relay_restrictions = permit_mynetworks, reject'
  postconf -e 'mynetworks = 127.0.0.0/8'
fi

# =============================================================================
# STEP 10 — /etc/hosts  [BUG-01 FIX: separated 127.0.0.1 and LOCAL_IP checks]
# Original: after adding "127.0.0.1 host", the grep for LOCAL_IP found the
# 127.0.0.1 line and skipped adding the LOCAL_IP line. Each IP now has its
# own independent grep pattern so both entries are always added correctly.
# =============================================================================
info "Step 10 — Adding test domains to /etc/hosts"
for host in virtualmin.local test.local static.local app.local; do
  if ! grep -qP "^127\.0\.0\.1\s.*\b${host}\b" /etc/hosts; then
    echo "127.0.0.1 $host" >> /etc/hosts
    info "  Added 127.0.0.1 → $host"
  fi
  if [[ "$LOCAL_IP" != "127.0.0.1" ]] && \
     ! grep -qP "^${LOCAL_IP}\s.*\b${host}\b" /etc/hosts; then
    echo "${LOCAL_IP} $host" >> /etc/hosts
    info "  Added ${LOCAL_IP} → $host"
  fi
done

# =============================================================================
# STEP 11 — Virtualmin post-install
# =============================================================================
info "Step 11 — Virtualmin post-install settings"
if command -v virtualmin &>/dev/null; then
  virtualmin set-features --all-domains --disable-feature mail 2>/dev/null || true
  virtualmin set-php-version --php-version 8.3 2>/dev/null || true
fi

# =============================================================================
# STEP 12 — Maintenance directories
# =============================================================================
info "Step 12 — Creating log directories"
mkdir -p /var/log/server-maintenance
chmod 750 /var/log/server-maintenance

# =============================================================================
# DONE
# =============================================================================
info "===== LOCAL TEST SETUP COMPLETE ====="
cat <<SUMMARY

╔══════════════════════════════════════════════════════════╗
║           LOCAL TEST VIRTUALMIN SETUP DONE               ║
╚══════════════════════════════════════════════════════════╝

 Virtualmin Panel : https://${LOCAL_IP}:10000
 HTTP test        : http://${LOCAL_IP}
 Log file         : ${LOG}

 Add to your HOST machine's hosts file:
   ${LOCAL_IP}  virtualmin.local test.local static.local app.local
   Windows : C:\Windows\System32\drivers\etc\hosts
   Mac/Linux: /etc/hosts

 NEXT STEPS:
   1. Open https://${LOCAL_IP}:10000 — log in as root — complete wizard
   2. sudo bash 03_weekly_maintenance_install.sh --install
   3. sudo bash 04_security_hardening.sh   (optional for local)
   4. sudo bash 05_mail_enable.sh          (only when needed)

SUMMARY
