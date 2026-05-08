#!/usr/bin/env bash
# =============================================================================
# COOLIFY HOST SETUP — Ubuntu 24.04 LTS
# Target   : Fresh VPS — Hostinger KVM2 (8 GB RAM / NVMe)
# Purpose  : Base security, firewall, tuning, and Coolify installation.
# =============================================================================
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

GREEN='\033[1;32m'; YELLOW='\033[1;33m'; RED='\033[1;31m'; NC='\033[0m'
info()  { printf "${GREEN}[INFO]${NC}  %s\n" "$*"; }
warn()  { printf "${YELLOW}[WARN]${NC}  %s\n" "$*"; }
err()   { printf "${RED}[ERR]${NC}   %s\n" "$*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || err "Run with sudo."

# =============================================================================
# STEP 1 — System update and base packages
# =============================================================================
info "System update and base packages"
apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y --no-install-recommends \
  curl wget git unzip ca-certificates gnupg lsb-release \
  software-properties-common apt-transport-https \
  net-tools htop fail2ban ufw logrotate cron \
  unattended-upgrades apt-listchanges jq fail2ban

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
# STEP 2 — Swap (4 GB for 8GB RAM host)
# =============================================================================
info "Swap setup"
if swapon --show | grep -q '^/swapfile'; then
  info "Swapfile already active"
else
  fallocate -l 4G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  info "4 GB swapfile created"
fi

# =============================================================================
# STEP 3 — sysctl performance + security (Optimized for 8GB RAM)
# =============================================================================
info "sysctl tuning"
cat > /etc/sysctl.d/99-vps-tuning.conf <<'EOF'
# ── Memory ────────────────────────────────────────────
vm.swappiness              = 10
vm.vfs_cache_pressure      = 50

# ── Network performance (Docker friendly) ─────────────
net.core.somaxconn              = 65535
net.core.netdev_max_backlog     = 16384
net.ipv4.tcp_max_syn_backlog    = 16384
net.ipv4.tcp_fin_timeout        = 15
net.ipv4.tcp_keepalive_time     = 300
net.ipv4.tcp_keepalive_probes   = 5
net.ipv4.tcp_keepalive_intvl    = 15
net.ipv4.tcp_tw_reuse           = 1
net.ipv4.ip_local_port_range    = 1024 65535
net.ipv4.ip_forward             = 1

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

# ── IPv6 Security ─────────────────────────────────────
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
# STEP 4 — UFW Firewall Setup for Coolify
# =============================================================================
info "Configuring UFW for Docker & Coolify"
ufw --force reset
ufw default deny incoming
ufw default allow outgoing

# Base Services
ufw limit ssh    comment 'SSH rate-limited'
ufw allow 80/tcp    comment 'HTTP'
ufw allow 443/tcp   comment 'HTTPS'

# Coolify UI & Reverse Proxy
ufw allow 8000/tcp  comment 'Coolify Dashboard'
# Allow Docker networks to communicate (important for internal routing)
ufw allow in from 172.16.0.0/12 to any

yes | ufw enable
info "UFW active."
warn "Note: Docker bypasses UFW by default for mapped ports. Coolify Traefik handles external routing."

# =============================================================================
# STEP 5 — SSH Hardening
# =============================================================================
info "SSH Hardening"
SSHD_CONF="/etc/ssh/sshd_config.d/99-security.conf"
cat > "$SSHD_CONF" <<'EOF'
PermitRootLogin prohibit-password
PasswordAuthentication no
PubkeyAuthentication yes
X11Forwarding no
MaxAuthTries 4
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
EOF
systemctl restart ssh
info "SSH: Password auth disabled, key-only required."

# =============================================================================
# STEP 6 — Fail2Ban
# =============================================================================
info "Configuring Fail2Ban"
cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
bantime   = 1h
findtime  = 10m
maxretry  = 5
backend   = systemd
banaction = ufw

[sshd]
enabled  = true
maxretry = 4
EOF
systemctl enable fail2ban
systemctl restart fail2ban

# =============================================================================
# STEP 7 — Install Docker & Coolify
# =============================================================================
info "Installing Coolify..."
if command -v coolify &>/dev/null || [[ -d /data/coolify ]]; then
    warn "Coolify appears to be installed already."
else
    # The official Coolify install script. This installs Docker as well.
    curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash
fi

info "===== HOST SETUP COMPLETE ====="
VPS_IP="$(hostname -I | awk '{print $1}')"
cat <<SUMMARY

╔══════════════════════════════════════════════════════════════╗
║         COOLIFY & HOST PRODUCTION SETUP DONE                 ║
╚══════════════════════════════════════════════════════════════╝

 Coolify Dashboard: http://${VPS_IP}:8000

 NEXT STEPS:
   1. Open http://${VPS_IP}:8000 and create the admin account.
   2. Configure your GoDaddy DNS (A record for domain -> ${VPS_IP}).
   3. In Coolify, setup your Wildcard Domain for Traefik.
   4. Connect your Github/Gitlab repository to deploy apps.

SUMMARY
