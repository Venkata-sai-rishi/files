#!/usr/bin/env bash
# =============================================================================
# WEEKLY MAINTENANCE — Virtualmin Hosting Server  [FIXED v2]
#
# Usage:
#   sudo bash 03_weekly_maintenance_install.sh --install   (register cron)
#   sudo bash 03_weekly_maintenance_install.sh --run       (run now)
#
# FIXES:
#   BUG-01 — REPORT_DATE not defined when script self-invoked in --run mode
#   BUG-02 — rkhunter --check would fail if DB not initialised on first run
#   BUG-03 — mysqlcheck failed if /root/.my.cnf missing
#   BUG-04 — Slow query count query broke if MariaDB auth changed
#   SEC-01 — Maintenance log dir had no check for world-readability
# =============================================================================
set -euo pipefail

LOG_DIR="/var/log/server-maintenance"
# BUG-01 FIX: Define REPORT_DATE at top level so it is always set in --run mode
REPORT_DATE="$(date +%Y-%m-%d_%H-%M)"
REPORT_FILE="${LOG_DIR}/weekly-${REPORT_DATE}.log"
SCRIPT_SELF="$(realpath "$0")"

GREEN='\033[1;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()    { printf "${GREEN}[INFO]${NC}  %s\n" "$*"; }
warn()    { printf "${YELLOW}[WARN]${NC}  %s\n" "$*"; }
section() { printf "\n${GREEN}══════ %s ══════${NC}\n" "$*"; }

[[ ${EUID} -eq 0 ]] || { echo "Run with sudo."; exit 1; }

# =============================================================================
# INSTALL MODE
# =============================================================================
install_cron() {
  mkdir -p "$LOG_DIR"
  # SEC-01 FIX: Ensure log directory is not world-readable
  chmod 750 "$LOG_DIR"

  CRON_LINE="0 2 * * 0 root bash ${SCRIPT_SELF} --run >> ${LOG_DIR}/cron-stdout.log 2>&1"
  if grep -qF "$SCRIPT_SELF" /etc/crontab 2>/dev/null; then
    info "Cron job already registered in /etc/crontab"
  else
    echo "$CRON_LINE" >> /etc/crontab
    info "Weekly maintenance cron installed: every Sunday at 02:00"
  fi

  # rkhunter daily DB update (quiet — no scan, just update signatures)
  RKHUNTER_CRON="0 1 * * * root rkhunter --update --quiet >> /var/log/rkhunter.log 2>&1 || true"
  grep -q 'rkhunter --update' /etc/crontab 2>/dev/null \
    || echo "$RKHUNTER_CRON" >> /etc/crontab

  info "Run maintenance now: sudo bash $SCRIPT_SELF --run"
}

# =============================================================================
# RUN MODE
# =============================================================================
run_maintenance() {
  mkdir -p "$LOG_DIR"
  chmod 750 "$LOG_DIR"
  exec > >(tee -a "$REPORT_FILE") 2>&1

  echo "============================================================"
  echo "  WEEKLY SERVER MAINTENANCE REPORT"
  echo "  Date   : $(date)"
  echo "  Host   : $(hostname) — $(hostname -I | awk '{print $1}')"
  echo "============================================================"

  # ── 1. rkhunter ───────────────────────────────────────────────────────────
  section "ROOTKIT SCAN — rkhunter"
  if command -v rkhunter &>/dev/null; then
    # BUG-02 FIX: Initialise DB if first run, then update before scanning
    if [[ ! -f /var/lib/rkhunter/db/rkhunter.dat ]]; then
      rkhunter --propupd --quiet 2>/dev/null || true
    fi
    rkhunter --update --quiet 2>/dev/null || true
    rkhunter --check --skip-keypress --report-warnings-only 2>&1 || \
      warn "rkhunter found warnings — review report above"
  else
    warn "rkhunter not installed — run: apt install rkhunter"
  fi

  # ── 2. chkrootkit ─────────────────────────────────────────────────────────
  section "ROOTKIT SCAN — chkrootkit"
  if command -v chkrootkit &>/dev/null; then
    chkrootkit 2>&1 | grep -vE "^(Checking|not infected|nothing found|no packets)$" \
      || echo "  No issues detected."
  else
    warn "chkrootkit not installed — run: apt install chkrootkit"
  fi

  # ── 3. Package update check ───────────────────────────────────────────────
  section "PACKAGE UPDATE CHECK"
  apt-get update -qq 2>/dev/null || true
  # ⚡ Bolt Optimization: Cache the result of apt list to avoid running it twice (saves ~1-2 seconds)
  UPDATES_LIST=$(apt list --upgradable 2>/dev/null | awk '!/^Listing/ && NF' || true)
  if [[ -n "$UPDATES_LIST" ]]; then
    UPDATES=$(echo "$UPDATES_LIST" | wc -l)
  else
    UPDATES=0
  fi
  echo "  Upgradable packages: $UPDATES"
  if [[ "$UPDATES" -gt 0 ]]; then
    echo "$UPDATES_LIST"
    warn "Run 'apt upgrade' to apply updates"
  fi

  # ── 4. Journal cleanup ────────────────────────────────────────────────────
  section "JOURNAL CLEANUP"
  journalctl --vacuum-time=7d 2>&1
  journalctl --vacuum-size=100M 2>&1

  # ── 5. Temp cleanup ───────────────────────────────────────────────────────
  section "TEMP CLEANUP"
  find /tmp    -type f -atime +7  -delete 2>/dev/null && echo "  /tmp cleaned"
  find /var/tmp -type f -atime +14 -delete 2>/dev/null && echo "  /var/tmp cleaned"
  find /var/lib/php/sessions -type f -atime +1 -delete 2>/dev/null \
    && echo "  PHP sessions cleaned" || true

  # ── 6. Fail2Ban status ────────────────────────────────────────────────────
  section "FAIL2BAN STATUS"
  if systemctl is-active --quiet fail2ban; then
    fail2ban-client status 2>&1 || true
    for jail in sshd webmin-auth nginx-http-auth; do
      fail2ban-client status "$jail" 2>/dev/null || true
    done
  else
    warn "Fail2Ban NOT running — restarting"
    systemctl start fail2ban && echo "  Fail2Ban restarted"
  fi

  # ── 7. Disk usage ─────────────────────────────────────────────────────────
  section "DISK USAGE"
  df -hT | grep -vE '^(tmpfs|udev|Filesystem)'
  echo ""
  DISK_USED_PCT=$(df / | awk 'NR==2 {gsub(/%/,"",$5); print $5}')
  echo "  Root partition: ${DISK_USED_PCT}% used"
  [[ "$DISK_USED_PCT" -gt 85 ]] && warn "DISK USAGE HIGH: ${DISK_USED_PCT}%"
  echo ""
  echo "  Top 10 directories in /var:"
  du -sh /var/* 2>/dev/null | sort -rh | head -10 || true
  echo ""
  echo "  Virtualmin sites:"
  du -sh /home/*/public_html 2>/dev/null | sort -rh || echo "  (none yet)"

  # ── 8. RAM usage ──────────────────────────────────────────────────────────
  section "RAM USAGE"
  free -h
  RAM_USED_MB=$(free -m | awk '/^Mem:/ {print $3}')
  echo ""
  echo "  RAM used: ${RAM_USED_MB} MB"
  [[ "$RAM_USED_MB" -gt 900 ]] && warn "RAM > 900 MB — check services"
  echo "  Top processes:"
  ps aux --sort=-%mem | awk 'NR<=11 {printf "  %-12s %5s%% %s\n", $1, $4, $11}'

  # ── 9. Service health ─────────────────────────────────────────────────────
  section "SERVICE HEALTH"
  for svc in nginx php8.3-fpm mariadb fail2ban; do
    if systemctl is-active --quiet "$svc"; then
      echo "  [OK]   $svc running"
    else
      warn "[DOWN] $svc — attempting restart"
      systemctl restart "$svc" 2>/dev/null \
        && echo "  [OK]   $svc restarted" \
        || warn "[FAIL] $svc could not restart"
    fi
  done
  nginx -t 2>&1 | tail -2

  # ── 10. MariaDB health  [BUG-03/BUG-04 FIX] ──────────────────────────────
  section "MARIADB HEALTH"
  if [[ -f /root/.my.cnf ]]; then
    mysqlcheck --defaults-file=/root/.my.cnf --all-databases --silent 2>/dev/null \
      && echo "  All databases OK" \
      || warn "Some tables may need repair"
    SLOW_COUNT=$(mysql --defaults-file=/root/.my.cnf \
      -e "SHOW GLOBAL STATUS LIKE 'Slow_queries';" 2>/dev/null \
      | awk 'NR==2 {print $2}' || echo "N/A")
    echo "  Slow queries (since restart): $SLOW_COUNT"
  else
    warn "/root/.my.cnf not found — skipping MariaDB health check"
    warn "Run 02_vps_production_setup.sh first"
  fi

  # ── 11. Backup check ──────────────────────────────────────────────────────
  section "BACKUP CHECK"
  for DIR in /var/backups/websites /var/backups/databases; do
    if [[ -d "$DIR" ]]; then
      RECENT=$(find "$DIR" \( -name "*.tar.gz" -o -name "*.sql.gz" \) -mtime -8 | wc -l)
      TOTAL_SIZE=$(du -sh "$DIR" 2>/dev/null | cut -f1)
      echo "  $DIR — recent: $RECENT — size: $TOTAL_SIZE"
      [[ "$RECENT" -eq 0 ]] && warn "No recent backup in $DIR — run 06_backup.sh"
    else
      warn "Backup dir missing: $DIR"
    fi
  done

  # ── 12. Log cleanup ───────────────────────────────────────────────────────
  section "LOG CLEANUP"
  find "$LOG_DIR" -name "*.log" -mtime +30 -delete 2>/dev/null || true
  KEPT=$(find "$LOG_DIR" -name "*.log" | wc -l)
  echo "  Maintenance logs kept: $KEPT"
  logrotate -f /etc/logrotate.conf 2>/dev/null || true

  # ── 13. Open ports audit ──────────────────────────────────────────────────
  section "OPEN PORTS"
  ss -tlnp | awk 'NR>1 {printf "  %-12s %s\n", $1, $4}'

  # ── 14. UFW status ────────────────────────────────────────────────────────
  section "FIREWALL STATUS"
  ufw status verbose 2>/dev/null || warn "UFW not active"

  echo ""
  echo "============================================================"
  echo "  Maintenance complete: $(date)"
  echo "  Report saved: $REPORT_FILE"
  echo "============================================================"
}

# =============================================================================
# Entry point
# =============================================================================
case "${1:-install}" in
  --run)      run_maintenance ;;
  --install|install|"") install_cron ;;
  *) echo "Usage: $0 [--install | --run]"; exit 1 ;;
esac
