#!/usr/bin/env bash
# =============================================================================
# LOCAL TEST SETUP — Ubuntu 24.04 LTS (8GB RAM / 2+ Core)
# Target   : Local VM (VirtualBox/VMware)
# Purpose  : Install Docker and Coolify for local testing. Skips strict SSH
#            lockdown and Fail2Ban to avoid local console issues.
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
  net-tools htop jq ufw

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
# STEP 3 — UFW Firewall Setup for Coolify (Local)
# =============================================================================
info "Configuring UFW for Docker & Coolify"
ufw --force reset
ufw default deny incoming
ufw default allow outgoing

# Base Services
ufw allow ssh       comment 'SSH'
ufw allow 80/tcp    comment 'HTTP'
ufw allow 443/tcp   comment 'HTTPS'

# Coolify UI & Reverse Proxy
ufw allow 8000/tcp  comment 'Coolify Dashboard'
# Allow Docker networks to communicate
ufw allow in from 172.16.0.0/12 to any

ufw --force enable
info "UFW active."

# =============================================================================
# STEP 4 — Install Docker & Coolify
# =============================================================================
info "Installing Coolify..."
if command -v coolify &>/dev/null || [[ -d /data/coolify ]]; then
    warn "Coolify appears to be installed already."
else
    # The official Coolify install script. This installs Docker as well.
    curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash
fi

info "===== LOCAL HOST SETUP COMPLETE ====="
LOCAL_IP="$(hostname -I | awk '{print $1}')"
cat <<SUMMARY

╔══════════════════════════════════════════════════════════════╗
║         COOLIFY LOCAL TEST SETUP DONE (8GB)                  ║
╚══════════════════════════════════════════════════════════════╝

 Coolify Dashboard: http://${LOCAL_IP}:8000

 NEXT STEPS:
   1. Open http://${LOCAL_IP}:8000 and create the admin account.
   2. Edit your host machine's /etc/hosts file to map test domains to ${LOCAL_IP}
      (e.g., echo "${LOCAL_IP} local.app.com" >> /etc/hosts)
   3. In Coolify, setup your Wildcard Domain to match your local test domain.

SUMMARY
