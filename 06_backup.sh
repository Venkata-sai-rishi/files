#!/usr/bin/env bash
# =============================================================================
# BACKUP SCRIPT — Virtualmin Hosting Server  [FIXED v2]
#
# Usage:
#   sudo bash 06_backup.sh            — run backup now
#   sudo bash 06_backup.sh --install  — register as weekly Sunday 03:00 cron
#
# FIXES:
#   BUG-01 — /root/.my.cnf existence not checked before mysql commands (hard fail)
#   BUG-02 — Backup dirs not chmod'd (world-readable backup files)
#   BUG-03 — tar backup of /home fails silently if no virtual servers exist
#   BUG-04 — Retention find command used -o without grouping (logic error)
#   SEC-01 — Backup files were not chmod 600 after creation
# =============================================================================
set -euo pipefail

BACKUP_BASE="/var/backups"
WEBSITE_BACKUP_DIR="${BACKUP_BASE}/websites"
DB_BACKUP_DIR="${BACKUP_BASE}/databases"
CONFIG_BACKUP_DIR="${BACKUP_BASE}/configs"
LOG_DIR="/var/log/server-maintenance"
TIMESTAMP="$(date +%Y-%m-%d_%H-%M)"
LOG="${LOG_DIR}/backup-${TIMESTAMP}.log"
RETENTION_DAYS=28

GREEN='\033[1;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()    { printf "${GREEN}[INFO]${NC}  %s\n" "$*"; }
warn()    { printf "${YELLOW}[WARN]${NC}  %s\n" "$*"; }
section() { printf "\n${GREEN}══ %s ══${NC}\n" "$*"; }

[[ ${EUID} -eq 0 ]] || { echo "Run with sudo."; exit 1; }

# =============================================================================
# INSTALL MODE
# =============================================================================
if [[ "${1:-}" == "--install" ]]; then
  mkdir -p "$LOG_DIR"
  chmod 750 "$LOG_DIR"
  CRON_LINE="0 3 * * 0 root bash $(realpath "$0") >> ${LOG_DIR}/backup-cron.log 2>&1"
  if grep -qF "$(realpath "$0")" /etc/crontab 2>/dev/null; then
    info "Backup cron already installed"
  else
    echo "$CRON_LINE" >> /etc/crontab
    info "Backup cron installed: every Sunday at 03:00"
  fi
  exit 0
fi

# =============================================================================
# RUN MODE
# =============================================================================
# BUG-02 FIX: Ensure backup dirs are NOT world-readable
mkdir -p "$WEBSITE_BACKUP_DIR" "$DB_BACKUP_DIR" "$CONFIG_BACKUP_DIR" "$LOG_DIR"
chmod 700 "$WEBSITE_BACKUP_DIR" "$DB_BACKUP_DIR" "$CONFIG_BACKUP_DIR"
chmod 750 "$LOG_DIR"

exec > >(tee -a "$LOG") 2>&1

echo "============================================================"
echo "  BACKUP STARTED: $(date)"
echo "  Host: $(hostname)"
echo "============================================================"

ERRORS=0

# ── 1. Website backups  [BUG-03 FIX: handle no sites gracefully] ─────────────
section "Website Backups"
SITES_FOUND=0
if [[ -d /home ]]; then
  for SITE_HOME in /home/*/; do
    [[ -d "${SITE_HOME}public_html" ]] || continue
    SITE_NAME=$(basename "$SITE_HOME")
    ARCHIVE="${WEBSITE_BACKUP_DIR}/${SITE_NAME}-${TIMESTAMP}.tar.gz"
    info "Backing up: $SITE_NAME"
    if tar -czf "$ARCHIVE" \
      --exclude="${SITE_HOME}.cache" \
      --exclude="${SITE_HOME}.npm" \
      --exclude="${SITE_HOME}.composer" \
      -C /home "$SITE_NAME" 2>/dev/null; then
      # SEC-01 FIX: Restrict backup file permissions
      chmod 600 "$ARCHIVE"
      SIZE=$(du -sh "$ARCHIVE" | cut -f1)
      info "  → $ARCHIVE ($SIZE)"
      SITES_FOUND=$((SITES_FOUND + 1))
    else
      warn "  Backup failed for: $SITE_NAME"
      ERRORS=$((ERRORS + 1))
    fi
  done
fi
[[ "$SITES_FOUND" -gt 0 ]] \
  && info "Total sites backed up: $SITES_FOUND" \
  || warn "No Virtualmin sites found in /home — skipping website backup"

# ── 2. Database backups  [BUG-01 FIX: check .my.cnf first] ──────────────────
section "Database Backups"
if [[ ! -f /root/.my.cnf ]]; then
  warn "/root/.my.cnf missing — skipping database backup"
  warn "Run 02_vps_production_setup.sh to configure MariaDB credentials"
  ERRORS=$((ERRORS + 1))
else
  DATABASES=$(mysql --defaults-file=/root/.my.cnf \
    -e "SHOW DATABASES;" 2>/dev/null \
    | grep -vE '^(Database|information_schema|performance_schema|sys|mysql)$' \
    || true)

  if [[ -z "$DATABASES" ]]; then
    warn "No user databases found"
  else
    for DB in $DATABASES; do
      DUMP_FILE="${DB_BACKUP_DIR}/${DB}-${TIMESTAMP}.sql.gz"
      info "Dumping: $DB"
      if mysqldump --defaults-file=/root/.my.cnf \
        --single-transaction --quick --lock-tables=false \
        "$DB" 2>/dev/null | gzip > "$DUMP_FILE"; then
        # SEC-01 FIX: Restrict dump file permissions
        chmod 600 "$DUMP_FILE"
        SIZE=$(du -sh "$DUMP_FILE" | cut -f1)
        info "  → $DUMP_FILE ($SIZE)"
      else
        warn "  Dump failed for: $DB"
        ERRORS=$((ERRORS + 1))
      fi
    done
  fi
fi

# ── 3. Config backups ─────────────────────────────────────────────────────────
section "Config Backups"
CONFIG_ARCHIVE="${CONFIG_BACKUP_DIR}/configs-${TIMESTAMP}.tar.gz"
tar -czf "$CONFIG_ARCHIVE" \
  /etc/nginx/ \
  /etc/php/8.3/fpm/ \
  /etc/mysql/ \
  /etc/fail2ban/ \
  /etc/ssh/sshd_config \
  /etc/postfix/ \
  /etc/crontab \
  /root/.my.cnf \
  2>/dev/null || true
# SEC-01 FIX: Config archive contains sensitive data — restrict permissions
chmod 600 "$CONFIG_ARCHIVE"
SIZE=$(du -sh "$CONFIG_ARCHIVE" | cut -f1)
info "Configs: $CONFIG_ARCHIVE ($SIZE)"

# ── 4. Retention cleanup  [BUG-04 FIX: parentheses group -o conditions] ──────
section "Retention Cleanup (${RETENTION_DAYS} days)"
for DIR in "$WEBSITE_BACKUP_DIR" "$DB_BACKUP_DIR" "$CONFIG_BACKUP_DIR"; do
  # BUG-04 FIX: Original: find -name "*.tar.gz" -o -name "*.sql.gz" -mtime +N
  # Without parentheses, -mtime only applies to the last -name condition.
  # FIX: Group conditions in parentheses so -mtime applies to both.
  DELETED=$(find "$DIR" \( -name "*.tar.gz" -o -name "*.sql.gz" \) \
    -mtime "+${RETENTION_DAYS}" 2>/dev/null | wc -l)
  find "$DIR" \( -name "*.tar.gz" -o -name "*.sql.gz" \) \
    -mtime "+${RETENTION_DAYS}" -delete 2>/dev/null || true
  info "Cleaned $DELETED old files from $DIR"
done

# ── 5. Summary ────────────────────────────────────────────────────────────────
section "Backup Summary"
TOTAL_SIZE=$(du -sh "$BACKUP_BASE" 2>/dev/null | cut -f1)
WEB_COUNT=$(find "$WEBSITE_BACKUP_DIR" -name '*.tar.gz' 2>/dev/null | wc -l)
DB_COUNT=$(find "$DB_BACKUP_DIR" -name '*.sql.gz' 2>/dev/null | wc -l)
CFG_COUNT=$(find "$CONFIG_BACKUP_DIR" -name '*.tar.gz' 2>/dev/null | wc -l)

echo "  Total backup size  : $TOTAL_SIZE"
echo "  Website backups    : $WEB_COUNT"
echo "  Database backups   : $DB_COUNT"
echo "  Config backups     : $CFG_COUNT"
echo "  Errors this run    : $ERRORS"

echo ""
echo "============================================================"
echo "  BACKUP COMPLETE: $(date)"
echo "  Log: $LOG"
echo "============================================================"

[[ "$ERRORS" -gt 0 ]] && warn "Backup completed with $ERRORS error(s) — review log above"

# ── Optional: Remote rsync (uncomment and configure) ─────────────────────────
# REMOTE_USER="backup"
# REMOTE_HOST="backup.yourserver.com"
# REMOTE_DIR="/backups/$(hostname)"
# rsync -az --delete \
#   -e "ssh -i /root/.ssh/backup_key -p 22 -o StrictHostKeyChecking=yes" \
#   "$BACKUP_BASE/" \
#   "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_DIR}/"
# info "Remote sync complete"
