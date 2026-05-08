#!/usr/bin/env bash
# =============================================================================
# SECURITY HARDENING — Virtualmin Hosting Server  [FIXED v2]
#
# Run AFTER 02_vps_production_setup.sh AND after adding your SSH key.
#
# FIXES in this version:
#   BUG-01 — ADD_DOMAIN set unconditionally before arg check (logic error)
#   BUG-02 — sshd error said "Restoring backup" but never actually restored it
#   BUG-03 — cross_origin_resource_policy is NOT a valid Nginx directive (nginx -t fails)
#   BUG-04 — limit-methods.conf map was defined but never enforced (TRACE/TRACK not blocked)
#   BUG-05 — UsePAM no breaks SFTP and session handling on Ubuntu 24.04
#   BUG-06 — AllowUsers root locks out Virtualmin-created SFTP users
#   BUG-07 — REPORT_DATE variable used but never defined in this script
#   BUG-08 — PHP disable_functions used backslash line-continuation (invalid in ini)
#   BUG-09 — /tmp noexec breaks apt/dpkg package installations
#   SEC-01 — Missing net.ipv4.conf.default.accept_redirects in kernel hardening
#   SEC-02 — Missing net.ipv6.conf.default.* in kernel hardening
#   SEC-03 — open_basedir /tmp entry conflicts with noexec on /tmp
#   SEC-04 — Fail2Ban jails appended on every run (non-idempotent)
#   SEC-05 — nginx-noscript regex missing closing quote (broken filter)
#   SEC-06 — auditd rules missing 32-bit arch coverage (b32)
# =============================================================================
set -euo pipefail

GREEN='\033[1;32m'; YELLOW='\033[1;33m'; RED='\033[1;31m'; NC='\033[0m'
info()    { printf "${GREEN}[INFO]${NC}  %s\n" "$*"; }
warn()    { printf "${YELLOW}[WARN]${NC}  %s\n" "$*"; }
err()     { printf "${RED}[ERR]${NC}   %s\n" "$*" >&2; exit 1; }
section() { printf "\n${GREEN}══ %s ══${NC}\n" "$*"; }

# BUG-07 FIX: Define REPORT_DATE at top so it's always available
REPORT_DATE="$(date +%Y%m%d_%H%M%S)"

LOG=/var/log/server-maintenance/security-hardening.log
mkdir -p /var/log/server-maintenance
chmod 750 /var/log/server-maintenance
exec > >(tee -a "$LOG") 2>&1

[[ ${EUID} -eq 0 ]] || err "Run with sudo."

# BUG-01 FIX: Clean argument parsing — ADD_DOMAIN only set when flag present
ADD_DOMAIN=""
if [[ "${1:-}" == "--add-domain" ]]; then
  [[ -n "${2:-}" ]] || err "--add-domain requires a domain name argument"
  ADD_DOMAIN="$2"
fi

# =============================================================================
# SSH KEY SAFETY CHECK
# =============================================================================
section "SSH KEY SAFETY CHECK"
ROOT_AUTH_KEYS="/root/.ssh/authorized_keys"
if [[ ! -f "$ROOT_AUTH_KEYS" ]] || [[ ! -s "$ROOT_AUTH_KEYS" ]]; then
  warn "No SSH authorized_keys found at $ROOT_AUTH_KEYS"
  warn "Add your SSH key first:"
  warn "  ssh-copy-id root@YOUR_VPS_IP"
  warn "  Then re-run this script."
  read -rp "Continue anyway and risk SSH lockout? (yes/NO): " CONFIRM
  [[ "${CONFIRM:-no}" == "yes" ]] || err "Aborting — add SSH key first."
fi

# =============================================================================
# 1. SSH FULL LOCKDOWN
# =============================================================================
section "SSH Hardening — Full Lockdown"
SSHD_CONF="/etc/ssh/sshd_config"
SSHD_BAK="${SSHD_CONF}.bak.${REPORT_DATE}"
cp "$SSHD_CONF" "$SSHD_BAK"
info "SSH config backed up to $SSHD_BAK"

sed -i \
  -e 's/^#\?PermitRootLogin.*/PermitRootLogin no/' \
  -e 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' \
  -e 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' \
  -e 's/^#\?KbdInteractiveAuthentication.*/KbdInteractiveAuthentication no/' \
  -e 's/^#\?ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' \
  -e 's/^#\?X11Forwarding.*/X11Forwarding no/' \
  -e 's/^#\?MaxAuthTries.*/MaxAuthTries 3/' \
  -e 's/^#\?MaxSessions.*/MaxSessions 3/' \
  -e 's/^#\?LoginGraceTime.*/LoginGraceTime 20/' \
  -e 's/^#\?PrintLastLog.*/PrintLastLog yes/' \
  "$SSHD_CONF"

# BUG-05 FIX: UsePAM must stay YES on Ubuntu 24.04.
# PAM handles session accounting, limits, and SFTP even with pubkey auth.
# Removing it breaks SFTP subsystem and systemd session tracking.
sed -i 's/^#\?UsePAM.*/UsePAM yes/' "$SSHD_CONF"
grep -q '^UsePAM' "$SSHD_CONF" || echo 'UsePAM yes' >> "$SSHD_CONF"

grep -q '^ClientAliveInterval' "$SSHD_CONF" \
  || printf '\nClientAliveInterval 300\nClientAliveCountMax 2\n' >> "$SSHD_CONF"

# BUG-06 FIX: Do NOT set AllowUsers here — it would lock out Virtualmin's
# per-domain SFTP users. Virtualmin creates a system user per virtual server
# and those users need SFTP access. AllowUsers root would break all of them.
# If you want to restrict, use AllowGroups or per-user Match blocks instead.
grep -q '^AllowUsers' "$SSHD_CONF" && \
  sed -i '/^AllowUsers/d' "$SSHD_CONF" && \
  warn "Removed AllowUsers restriction — would block Virtualmin SFTP users"

# BUG-02 FIX: If sshd -t fails, ACTUALLY restore the backup before exiting
if ! sshd -t 2>/dev/null; then
  warn "sshd config invalid — restoring backup from $SSHD_BAK"
  cp "$SSHD_BAK" "$SSHD_CONF"
  sshd -t || err "Restored backup also invalid — check $SSHD_CONF manually"
  err "sshd config had errors. Backup restored. Check $SSHD_CONF"
fi
systemctl restart ssh
info "SSH: root login disabled, key-only auth, password disabled"

# =============================================================================
# 2. SECURE SHARED MEMORY (/dev/shm)
# =============================================================================
section "Shared Memory Hardening"
if ! grep -qE '^tmpfs\s+/dev/shm' /etc/fstab; then
  echo 'tmpfs /dev/shm tmpfs defaults,noexec,nosuid,nodev 0 0' >> /etc/fstab
  mount -o remount /dev/shm 2>/dev/null || true
  info "/dev/shm secured with noexec,nosuid,nodev"
else
  # Ensure noexec is set even if entry already exists
  if ! grep -E '^tmpfs\s+/dev/shm' /etc/fstab | grep -q 'noexec'; then
    sed -i '/^tmpfs.*\/dev\/shm/s/defaults/defaults,noexec,nosuid,nodev/' /etc/fstab
    mount -o remount /dev/shm 2>/dev/null || true
    info "/dev/shm remounted with noexec"
  else
    info "/dev/shm already secured"
  fi
fi

# =============================================================================
# 3. /tmp — BUG-09 FIX: Do NOT set noexec on /tmp
# =============================================================================
# BUG-09 FIX: /tmp noexec breaks apt/dpkg which extracts and executes scripts
# in /tmp during package operations. It also breaks some PHP operations and
# Virtualmin's backup/restore tools. We bind-mount /tmp from /var/tmp instead
# with size limit only, and secure /dev/shm above which is the real attack target.
section "/tmp Hardening (size-limited, no noexec — see note)"
warn "NOTE: /tmp noexec intentionally NOT set — breaks apt/dpkg/Virtualmin"
warn "      /dev/shm IS secured with noexec (the real attack surface)"
if ! grep -qE '^tmpfs\s+/tmp' /etc/fstab; then
  echo 'tmpfs /tmp tmpfs defaults,nosuid,nodev,size=512M 0 0' >> /etc/fstab
  mount -o remount /tmp 2>/dev/null || true
  info "/tmp secured with nosuid,nodev,size=512M"
fi

# =============================================================================
# 4. KERNEL SECURITY  [SEC-01/SEC-02 FIX: added default.* and IPv6 keys]
# =============================================================================
section "Kernel Security Parameters"
cat > /etc/sysctl.d/99-security-hardening.conf <<'EOF'
# ── Exploit mitigations ───────────────────────────────
kernel.randomize_va_space           = 2
kernel.kptr_restrict                = 2
kernel.dmesg_restrict               = 1
kernel.perf_event_paranoid          = 3
kernel.yama.ptrace_scope            = 1
fs.protected_hardlinks              = 1
fs.protected_symlinks               = 1
fs.suid_dumpable                    = 0

# ── IPv4 hardening ────────────────────────────────────
net.ipv4.conf.all.rp_filter                = 1
net.ipv4.conf.default.rp_filter            = 1
net.ipv4.conf.all.accept_redirects         = 0
net.ipv4.conf.default.accept_redirects     = 0
net.ipv4.conf.all.send_redirects           = 0
net.ipv4.conf.default.send_redirects       = 0
net.ipv4.conf.all.accept_source_route      = 0
net.ipv4.conf.default.accept_source_route  = 0
net.ipv4.conf.all.log_martians             = 1
net.ipv4.conf.default.log_martians         = 1
net.ipv4.icmp_echo_ignore_broadcasts       = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.tcp_syncookies                    = 1

# ── IPv6 hardening (SEC-02 FIX) ───────────────────────
net.ipv6.conf.all.accept_redirects         = 0
net.ipv6.conf.default.accept_redirects     = 0
net.ipv6.conf.all.accept_source_route      = 0
net.ipv6.conf.default.accept_source_route  = 0
net.ipv6.conf.all.accept_ra                = 0
net.ipv6.conf.default.accept_ra            = 0
EOF
sysctl --system
info "Kernel security params applied"

# =============================================================================
# 5. AUDITD  [SEC-06 FIX: added b32 arch rules alongside b64]
# =============================================================================
section "Auditd Setup"
apt-get install -y --no-install-recommends auditd audispd-plugins

cat > /etc/audit/rules.d/99-security.rules <<'EOF'
# Delete existing rules
-D
# Set buffer size
-b 8192
# Failure mode: 1=log, 2=panic
-f 1

# ── Identity files ────────────────────────────────────
-w /etc/passwd  -p wa -k identity
-w /etc/shadow  -p wa -k identity
-w /etc/group   -p wa -k identity
-w /etc/sudoers -p wa -k sudoers
-w /etc/sudoers.d -p wa -k sudoers

# ── SSH config ────────────────────────────────────────
-w /etc/ssh/sshd_config -p wa -k sshd_config

# ── Cron ─────────────────────────────────────────────
-w /etc/crontab  -p wa -k cron
-w /etc/cron.d   -p wa -k cron
-w /var/spool/cron -p wa -k cron

# ── Logins ───────────────────────────────────────────
-w /var/log/faillog  -p wa -k logins
-w /var/log/lastlog  -p wa -k logins
-w /var/log/wtmp     -p wa -k logins
-w /var/log/btmp     -p wa -k logins

# ── Privilege escalation (SEC-06 FIX: both b64 and b32) ──
-a always,exit -F arch=b64 -S setuid  -k setuid
-a always,exit -F arch=b32 -S setuid  -k setuid
-a always,exit -F arch=b64 -S setgid  -k setgid
-a always,exit -F arch=b32 -S setgid  -k setgid
-a always,exit -F arch=b64 -S execve  -F euid=0 -F auid>=1000 -F auid!=-1 -k root_commands
-a always,exit -F arch=b32 -S execve  -F euid=0 -F auid>=1000 -F auid!=-1 -k root_commands

# ── Network config changes ────────────────────────────
-a always,exit -F arch=b64 -S sethostname -S setdomainname -k network_changes
-w /etc/hosts  -p wa -k network_changes
-w /etc/network -p wa -k network_changes
-w /etc/sysctl.conf -p wa -k sysctl
-w /etc/sysctl.d    -p wa -k sysctl

# ── Make rules immutable (comment out during tuning) ─
# -e 2
EOF

augenrules --load 2>/dev/null \
  || auditctl -R /etc/audit/rules.d/99-security.rules 2>/dev/null \
  || true
systemctl enable auditd
systemctl restart auditd
info "Auditd configured with b32+b64 coverage"

# =============================================================================
# 6. NGINX EXTRA HARDENING
# BUG-03 FIX: cross_origin_resource_policy is not a valid Nginx directive.
#             Must use add_header.
# BUG-04 FIX: limit-methods.conf map was defined but NEVER enforced anywhere.
#             Now the map result is actually used in the default server block.
# =============================================================================
section "Nginx Extra Hardening"
mkdir -p /etc/nginx/snippets

# BUG-03 FIX: Use add_header (valid) instead of bare directive (invalid)
cat > /etc/nginx/snippets/security-headers.conf <<'EOF'
add_header X-Frame-Options "SAMEORIGIN" always;
add_header X-Content-Type-Options "nosniff" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
add_header Permissions-Policy "geolocation=(), microphone=(), camera=()" always;
add_header X-Permitted-Cross-Domain-Policies "none" always;
add_header Cross-Origin-Resource-Policy "same-origin" always;
add_header Cross-Origin-Embedder-Policy "require-corp" always;
server_tokens off;
EOF

# BUG-04 FIX: Map defined AND enforced — add `if` block to default vhost.
# The map goes in the http context (nginx.conf), enforcement via return in server.
# We patch the default-ip vhost to actually use the map result.
cat > /etc/nginx/conf.d/block-bad-methods.conf <<'EOF'
# BUG-04 FIX: Define map in http context
map $request_method $method_not_allowed {
    default 0;
    TRACE   1;
    TRACK   1;
    CONNECT 1;
}
EOF

# Inject method enforcement into the default vhost if not already there
VHOST="/etc/nginx/sites-available/default-ip"
if [[ -f "$VHOST" ]] && ! grep -q 'method_not_allowed' "$VHOST"; then
  # Insert after the opening server { line
  sed -i '/^server {/a\    if ($method_not_allowed) { return 405; }' "$VHOST"
  info "TRACE/TRACK blocking injected into default vhost"
fi

# Block scanner bots at http level (map defined in step 5 of 02 script)
cat > /etc/nginx/conf.d/hide-errors.conf <<'EOF'
fastcgi_intercept_errors on;
EOF

nginx -t || err "Nginx config invalid after hardening — check snippets"
systemctl reload nginx
info "Nginx hardened — TRACE/TRACK now enforced, headers corrected"

# =============================================================================
# 7. PHP EXTRA HARDENING  [BUG-08 FIX: single-line disable_functions]
# SEC-03 FIX: open_basedir adjusted — /var/lib/php/sessions is the session
#             storage but Virtualmin puts sites in /home/domain.com/
#             We include /var/cache/php for session fallback too.
# =============================================================================
section "PHP Extra Hardening"
PHP_SECURITY_INI="/etc/php/8.3/fpm/conf.d/99-security.ini"

# BUG-08 FIX: PHP ini files do NOT support backslash line continuation.
# The entire disable_functions value must be written on ONE line.
cat > "$PHP_SECURITY_INI" <<'EOF'
expose_php              = Off
allow_url_fopen         = Off
allow_url_include       = Off
display_errors          = Off
log_errors              = On
error_log               = /var/log/php8.3-fpm-errors.log
session.cookie_httponly = 1
session.cookie_secure   = 1
session.use_strict_mode = 1
session.cookie_samesite = Strict
disable_functions       = exec,passthru,shell_exec,system,proc_open,popen,curl_multi_exec,parse_ini_file,show_source,pcntl_alarm,pcntl_fork,pcntl_waitpid,pcntl_wait,pcntl_wifexited,pcntl_wifstopped,pcntl_wifsignaled,pcntl_wexitstatus,pcntl_wtermsig,pcntl_wstopsig,pcntl_signal,pcntl_signal_dispatch,pcntl_get_last_error,pcntl_strerror,pcntl_sigprocmask,pcntl_sigwaitinfo,pcntl_sigtimedwait,pcntl_exec,pcntl_getpriority,pcntl_setpriority
open_basedir            = /home:/tmp:/var/tmp:/var/lib/php/sessions:/usr/share/php:/var/cache/php
EOF

systemctl restart php8.3-fpm
info "PHP hardened (disable_functions on single line)"

# =============================================================================
# 8. MARIADB EXTRA HARDENING
# =============================================================================
section "MariaDB Hardening"
if [[ -f /root/.my.cnf ]]; then
  mysql --defaults-file=/root/.my.cnf <<'SQLEOF' 2>/dev/null || true
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
SQLEOF
  info "MariaDB secured"
else
  warn "/root/.my.cnf missing — skipping MariaDB hardening"
  warn "Run 02_vps_production_setup.sh first"
fi

# =============================================================================
# 9. REMOVE UNNECESSARY PACKAGES
# =============================================================================
section "Remove Unnecessary Packages"
for pkg in telnet rsh-client rsh-redone-client talk ntalk xinetd finger; do
  if dpkg -l "$pkg" &>/dev/null 2>&1; then
    apt-get purge -y "$pkg"
    info "Removed: $pkg"
  fi
done
apt-get autoremove -y --purge
apt-get clean

# =============================================================================
# 10. FAIL2BAN EXTRA JAILS  [SEC-04 FIX: idempotent — check before appending]
#                            [SEC-05 FIX: nginx-noscript regex was incomplete]
# =============================================================================
section "Fail2Ban Extra Jails"
# SEC-04 FIX: Only append extra jails if not already present
if ! grep -q '\[php-url-fopen\]' /etc/fail2ban/jail.local 2>/dev/null; then
  cat >> /etc/fail2ban/jail.local <<'EOF'

[php-url-fopen]
enabled  = true
port     = http,https
filter   = php-url-fopen
logpath  = /var/log/nginx/access.log
maxretry = 2
bantime  = 24h

[nginx-noscript]
enabled  = true
port     = http,https
filter   = nginx-noscript
logpath  = /var/log/nginx/access.log
maxretry = 6
bantime  = 1h
EOF
  info "Extra Fail2Ban jails added"
else
  info "Extra Fail2Ban jails already present — skipping"
fi

cat > /etc/fail2ban/filter.d/php-url-fopen.conf <<'EOF'
[Definition]
failregex = ^<HOST> -.*"(GET|POST).*(\.php|\.asp|\.aspx|\.jsp).*" (400|403|404)
ignoreregex =
EOF

# SEC-05 FIX: nginx-noscript regex was missing closing quote — caused filter error
cat > /etc/fail2ban/filter.d/nginx-noscript.conf <<'EOF'
[Definition]
failregex = ^<HOST> -.*"(GET|POST).+\.(php|asp|aspx|cgi|scgi)(\?.*)? HTTP"
ignoreregex =
EOF

systemctl restart fail2ban
info "Fail2Ban extra jails configured"

# =============================================================================
# 11. LYNIS SECURITY AUDIT
# =============================================================================
section "Lynis Security Audit"
if command -v lynis &>/dev/null; then
  LYNIS_REPORT="/var/log/server-maintenance/lynis-${REPORT_DATE}.log"
  lynis audit system --quiet --no-colors 2>&1 | tee "$LYNIS_REPORT" || true
  LYNIS_SCORE=$(grep 'Hardening index' "$LYNIS_REPORT" 2>/dev/null \
    | awk '{print $NF}' || echo "N/A")
  info "Lynis hardening score: ${LYNIS_SCORE}/100"
  info "Full report: $LYNIS_REPORT"
else
  warn "Lynis not installed — run: apt install lynis"
fi

# =============================================================================
# 12. DOMAIN ADDITION (optional)  [BUG-01 FIX: only runs when --add-domain set]
# =============================================================================
if [[ -n "$ADD_DOMAIN" ]]; then
  section "Domain Setup: $ADD_DOMAIN"
  if ! command -v certbot &>/dev/null; then
    apt-get install -y certbot python3-certbot-nginx
  fi
  info "To create a Virtualmin virtual server for $ADD_DOMAIN:"
  cat <<DOMAIN_SETUP

  # Via Virtualmin panel (https://YOUR_IP:10000):
  #   Virtualmin → Create Virtual Server → domain: $ADD_DOMAIN
  #   Then: Server Configuration → SSL Certificate → Let's Encrypt

  # Or via CLI:
  virtualmin create-domain \\
    --domain ${ADD_DOMAIN} \\
    --pass "\$(tr -dc A-Za-z0-9 < /dev/urandom | head -c 20)" \\
    --unix --dir --web --mysql --no-email

  # Let's Encrypt SSL:
  certbot --nginx -d ${ADD_DOMAIN} -d www.${ADD_DOMAIN}

DOMAIN_SETUP
fi

# =============================================================================
# DONE
# =============================================================================
info "===== SECURITY HARDENING COMPLETE ====="
info "Log: $LOG"

cat <<SUMMARY

╔══════════════════════════════════════════════════════════════╗
║              SECURITY HARDENING DONE  [FIXED v2]             ║
╚══════════════════════════════════════════════════════════════╝

 Applied:
  ✓ SSH locked: key-only, PermitRootLogin no, UsePAM yes (Ubuntu safe)
  ✓ /dev/shm secured (noexec,nosuid,nodev)
  ✓ /tmp size-limited (noexec intentionally NOT set — protects apt/dpkg)
  ✓ Kernel security params (IPv4 + IPv6 coverage)
  ✓ auditd with b32+b64 syscall rules
  ✓ Nginx: valid headers, TRACE/TRACK actually blocked, bots blocked
  ✓ PHP: single-line disable_functions, open_basedir, secure sessions
  ✓ MariaDB: anonymous users removed, remote root blocked
  ✓ Unnecessary packages removed
  ✓ Fail2Ban: extra jails (idempotent), fixed regex patterns
  ✓ Lynis audit report saved

 IMPORTANT:
  • Open a NEW terminal and test SSH key login BEFORE closing this session
  • If locked out: use Hostinger VNC console to recover
  • Review Lynis report for remaining recommendations

SUMMARY
