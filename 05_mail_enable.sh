#!/usr/bin/env bash
# =============================================================================
# MAIL ENABLE — Virtualmin Hosting Server  [FIXED v2]
#
# Run ONLY when domain DNS is fully propagated and SSL cert exists.
#
# FIXES:
#   BUG-01 — dig may not be installed on minimal Ubuntu (use host as fallback)
#   BUG-02 — master.cf SpamAssassin entry appended on every run (non-idempotent)
#   BUG-03 — Dovecot 10-ssl.conf overwritten entirely (breaks Virtualmin SSL)
#   BUG-04 — spamd user check used id which errors if user absent, swallowed by ||
#   SEC-01 — SPF record was too permissive (~all should be -all for strict mode)
#   SEC-02 — Dovecot allowed plaintext auth before TLS check
#   SEC-03 — No rate limiting on SMTP submission port
# =============================================================================
set -euo pipefail

GREEN='\033[1;32m'; YELLOW='\033[1;33m'; RED='\033[1;31m'; NC='\033[0m'
info()    { printf "${GREEN}[INFO]${NC}  %s\n" "$*"; }
warn()    { printf "${YELLOW}[WARN]${NC}  %s\n" "$*"; }
err()     { printf "${RED}[ERR]${NC}   %s\n" "$*" >&2; exit 1; }
section() { printf "\n${GREEN}══ %s ══${NC}\n" "$*"; }

LOG=/var/log/server-maintenance/mail-enable.log
mkdir -p /var/log/server-maintenance
exec > >(tee -a "$LOG") 2>&1

[[ ${EUID} -eq 0 ]] || err "Run with sudo."

DOMAIN=""
ADMIN_EMAIL=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain) DOMAIN="$2";      shift 2 ;;
    --admin)  ADMIN_EMAIL="$2"; shift 2 ;;
    *) warn "Unknown argument: $1"; shift ;;
  esac
done

[[ -n "$DOMAIN" ]] \
  || err "Usage: $0 --domain yourdomain.com [--admin admin@yourdomain.com]"
[[ -n "$ADMIN_EMAIL" ]] || ADMIN_EMAIL="admin@${DOMAIN}"

VPS_IP="$(hostname -I | awk '{print $1}')"
HOSTNAME_FQDN="mail.${DOMAIN}"
info "Domain : $DOMAIN"
info "Admin  : $ADMIN_EMAIL"
info "VPS IP : $VPS_IP"

# =============================================================================
# STEP 0 — Prerequisites  [BUG-01 FIX: install dns tools if missing]
# =============================================================================
section "Prerequisites Check"

# BUG-01 FIX: Ensure DNS lookup tool is available
apt-get install -y --no-install-recommends bind9-dnsutils 2>/dev/null || true

# DNS check with fallback from dig → host → skip
DNS_IP=""
if command -v dig &>/dev/null; then
  DNS_IP=$(dig +short A "mail.${DOMAIN}" 2>/dev/null | head -1 || true)
elif command -v host &>/dev/null; then
  DNS_IP=$(host "mail.${DOMAIN}" 2>/dev/null | awk '/has address/ {print $4; exit}' || true)
else
  warn "No DNS lookup tool available — skipping DNS verification"
fi

if [[ -n "$DNS_IP" ]]; then
  if [[ "$DNS_IP" == "$VPS_IP" ]]; then
    info "DNS OK: mail.${DOMAIN} → ${VPS_IP}"
  else
    warn "DNS: mail.${DOMAIN} resolves to '${DNS_IP}' (expected ${VPS_IP})"
    read -rp "Continue anyway? (yes/NO): " CONFIRM
    [[ "${CONFIRM:-no}" == "yes" ]] || err "Fix DNS A record first."
  fi
fi

if [[ ! -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]]; then
  warn "No Let's Encrypt cert for ${DOMAIN}"
  read -rp "Continue without SSL cert? Mail will use self-signed. (yes/NO): " CONFIRM
  [[ "${CONFIRM:-no}" == "yes" ]] || err "Get SSL cert first: certbot --nginx -d ${DOMAIN}"
fi

# =============================================================================
# STEP 1 — Install mail packages
# =============================================================================
section "Installing Mail Stack"
apt-get update -qq
apt-get install -y --no-install-recommends \
  postfix postfix-mysql dovecot-core dovecot-imapd dovecot-pop3d \
  dovecot-lmtpd spamassassin spamc opendkim opendkim-tools mailutils

# =============================================================================
# STEP 2 — Postfix  [SEC-03 FIX: smtpd_client_connection_rate_limit added]
# =============================================================================
section "Configuring Postfix"
cp -n /etc/postfix/main.cf "/etc/postfix/main.cf.bak.$(date +%Y%m%d)" 2>/dev/null || true

postconf -e "myhostname = ${HOSTNAME_FQDN}"
postconf -e "mydomain = ${DOMAIN}"
postconf -e "myorigin = \$mydomain"
postconf -e "inet_interfaces = all"
postconf -e "inet_protocols = ipv4"
postconf -e "mydestination = \$myhostname, localhost.\$mydomain, localhost, \$mydomain"
postconf -e "mynetworks = 127.0.0.0/8"
postconf -e "home_mailbox = Maildir/"
postconf -e "smtpd_banner = \$myhostname ESMTP"
postconf -e "biff = no"
postconf -e "append_dot_mydomain = no"

# TLS
if [[ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]]; then
  postconf -e "smtpd_tls_cert_file = /etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
  postconf -e "smtpd_tls_key_file  = /etc/letsencrypt/live/${DOMAIN}/privkey.pem"
else
  postconf -e "smtpd_tls_cert_file = /etc/ssl/certs/ssl-cert-snakeoil.pem"
  postconf -e "smtpd_tls_key_file  = /etc/ssl/private/ssl-cert-snakeoil.key"
fi
postconf -e "smtpd_use_tls = yes"
postconf -e "smtpd_tls_security_level = may"
postconf -e "smtpd_tls_protocols = !SSLv2,!SSLv3,!TLSv1,!TLSv1.1"
postconf -e "smtpd_tls_mandatory_protocols = !SSLv2,!SSLv3,!TLSv1,!TLSv1.1"
postconf -e "smtp_tls_security_level = may"
postconf -e "smtp_tls_loglevel = 1"

# Anti-spam + relay restrictions
postconf -e "smtpd_relay_restrictions = permit_mynetworks, permit_sasl_authenticated, reject_unauth_destination"
postconf -e "smtpd_recipient_restrictions = permit_mynetworks, permit_sasl_authenticated, reject_unauth_destination, reject_rbl_client zen.spamhaus.org, reject_rbl_client bl.spamcop.net"
postconf -e "smtpd_helo_required = yes"
postconf -e "disable_vrfy_command = yes"
postconf -e "strict_rfc821_envelopes = yes"
# SEC-03 FIX: Rate limit connections per IP to prevent spam relay abuse
postconf -e "smtpd_client_connection_rate_limit = 30"
postconf -e "smtpd_client_message_rate_limit = 30"
postconf -e "anvil_rate_time_unit = 60s"

# BUG-02 FIX: Only add SpamAssassin to master.cf if not already present
if ! grep -q 'spamassassin' /etc/postfix/master.cf 2>/dev/null; then
  cat >> /etc/postfix/master.cf <<'EOF'
spamassassin unix -     n       n       -       -       pipe
  user=spamd argv=/usr/bin/spamc -f -e /usr/sbin/sendmail -oi -f ${sender} ${recipient}
EOF
  info "SpamAssassin transport added to master.cf"
else
  info "SpamAssassin already in master.cf — skipping"
fi
postconf -e "content_filter = spamassassin"

# =============================================================================
# STEP 3 — Dovecot  [BUG-03 FIX: don't overwrite 10-ssl.conf entirely]
#                   [SEC-02 FIX: disable_plaintext_auth enforced]
# =============================================================================
section "Configuring Dovecot"
# BUG-03 FIX: Instead of overwriting full config files (breaks Virtualmin SSL
# config), we use conf.d drop-in files and patch only what we need.

cat > /etc/dovecot/conf.d/10-mail.conf <<'EOF'
mail_location = maildir:~/Maildir
mail_privileged_group = mail
EOF

# SEC-02 FIX: Enforce no plaintext auth
cat > /etc/dovecot/conf.d/10-auth.conf <<'EOF'
disable_plaintext_auth = yes
auth_mechanisms = plain login
!include auth-system.conf.ext
EOF

# BUG-03 FIX: Patch SSL config by adding to existing file rather than replacing
if [[ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]]; then
  # Only update cert paths, preserve other settings
  DOVECOT_SSL_CONF="/etc/dovecot/conf.d/10-ssl.conf"
  cp -n "$DOVECOT_SSL_CONF" "${DOVECOT_SSL_CONF}.bak" 2>/dev/null || true
  # Replace cert/key lines if present, otherwise append
  if grep -q '^ssl_cert' "$DOVECOT_SSL_CONF" 2>/dev/null; then
    sed -i \
      -e "s|^ssl_cert.*|ssl_cert = </etc/letsencrypt/live/${DOMAIN}/fullchain.pem|" \
      -e "s|^ssl_key.*|ssl_key  = </etc/letsencrypt/live/${DOMAIN}/privkey.pem|" \
      -e "s|^ssl =.*|ssl = required|" \
      "$DOVECOT_SSL_CONF"
  else
    cat >> "$DOVECOT_SSL_CONF" <<EOF

# Added by mail_enable.sh
ssl = required
ssl_cert = </etc/letsencrypt/live/${DOMAIN}/fullchain.pem
ssl_key  = </etc/letsencrypt/live/${DOMAIN}/privkey.pem
ssl_min_protocol = TLSv1.2
ssl_cipher_list = ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256
EOF
  fi
fi

# =============================================================================
# STEP 4 — SpamAssassin  [BUG-04 FIX: proper user creation check]
# =============================================================================
section "SpamAssassin"
cat > /etc/spamassassin/local.cf <<'EOF'
required_score   5.0
rewrite_header Subject [SPAM]
report_safe      0
use_bayes        1
bayes_auto_learn 1
EOF

# BUG-04 FIX: Check for user existence properly without relying on error code
if ! getent passwd spamd &>/dev/null; then
  useradd -r -s /usr/sbin/nologin -d /var/lib/spamassassin spamd
  info "spamd user created"
else
  info "spamd user already exists"
fi
mkdir -p /var/lib/spamassassin
chown -R spamd:spamd /var/lib/spamassassin

# =============================================================================
# STEP 5 — DKIM
# =============================================================================
section "OpenDKIM Setup"
mkdir -p "/etc/opendkim/keys/${DOMAIN}"

if [[ ! -f "/etc/opendkim/keys/${DOMAIN}/mail.private" ]]; then
  opendkim-genkey -s mail -d "${DOMAIN}" -D "/etc/opendkim/keys/${DOMAIN}/"
  info "DKIM keys generated"
else
  info "DKIM keys already exist — skipping generation"
fi
chown -R opendkim:opendkim /etc/opendkim

cat > /etc/opendkim.conf <<EOF
AutoRestart         Yes
AutoRestartRate     10/1h
UMask               002
Syslog              yes
SyslogSuccess       Yes
Canonicalization    relaxed/simple
ExternalIgnoreList  refile:/etc/opendkim/TrustedHosts
InternalHosts       refile:/etc/opendkim/TrustedHosts
KeyTable            refile:/etc/opendkim/KeyTable
SigningTable        refile:/etc/opendkim/SigningTable
Mode                sv
PidFile             /run/opendkim/opendkim.pid
SignatureAlgorithm  rsa-sha256
UserID              opendkim:opendkim
Socket              inet:8891@localhost
EOF

cat > /etc/opendkim/TrustedHosts <<EOF
127.0.0.1
localhost
${DOMAIN}
*.${DOMAIN}
EOF

cat > /etc/opendkim/KeyTable <<EOF
mail._domainkey.${DOMAIN} ${DOMAIN}:mail:/etc/opendkim/keys/${DOMAIN}/mail.private
EOF

cat > /etc/opendkim/SigningTable <<EOF
*@${DOMAIN} mail._domainkey.${DOMAIN}
EOF

postconf -e "milter_protocol = 2"
postconf -e "milter_default_action = accept"
postconf -e "smtpd_milters = inet:localhost:8891"
postconf -e "non_smtpd_milters = inet:localhost:8891"

# =============================================================================
# STEP 6 — UFW mail ports
# =============================================================================
section "Mail Ports (UFW)"
ufw allow 25/tcp   comment 'SMTP'
ufw allow 587/tcp  comment 'SMTP Submission'
ufw allow 993/tcp  comment 'IMAPS'
ufw allow 995/tcp  comment 'POP3S'
ufw status verbose

# =============================================================================
# STEP 7 — Fail2Ban mail jails (idempotent)
# =============================================================================
section "Fail2Ban Mail Jails"
if ! grep -q '\[postfix\]' /etc/fail2ban/jail.local 2>/dev/null; then
  cat >> /etc/fail2ban/jail.local <<'EOF'

[postfix]
enabled  = true
port     = smtp,465,587
filter   = postfix
logpath  = /var/log/mail.log
maxretry = 5

[dovecot]
enabled  = true
port     = pop3,pop3s,imap,imaps,submission,465
filter   = dovecot
logpath  = /var/log/mail.log
maxretry = 5
EOF
  info "Mail Fail2Ban jails added"
else
  info "Mail jails already in jail.local — skipping"
fi
systemctl restart fail2ban

# =============================================================================
# STEP 8 — Start mail services
# =============================================================================
section "Starting Mail Services"
for svc in opendkim postfix dovecot; do
  systemctl enable "$svc"
  systemctl restart "$svc"
  systemctl is-active --quiet "$svc" \
    && info "[OK]   $svc running" \
    || warn "[ERR]  $svc failed — check: journalctl -u $svc"
done

# =============================================================================
# STEP 9 — Test
# =============================================================================
section "Mail Test"
echo "Test from $(hostname) at $(date)" \
  | mail -s "[TEST] Server Mail" "$ADMIN_EMAIL" 2>/dev/null \
  && info "Test email sent to $ADMIN_EMAIL" \
  || warn "Mail test failed — check: tail -f /var/log/mail.log"

# =============================================================================
# DONE
# =============================================================================
cat <<SUMMARY

╔══════════════════════════════════════════════════════════════╗
║              MAIL STACK ENABLED  [FIXED v2]                  ║
╚══════════════════════════════════════════════════════════════╝

 Domain : ${DOMAIN}
 MX host: mail.${DOMAIN}
 Admin  : ${ADMIN_EMAIL}

 DNS RECORDS TO ADD:
 ─────────────────────────────────────────────────────────────
 A     mail.${DOMAIN}               →  ${VPS_IP}
 MX    ${DOMAIN}                    →  mail.${DOMAIN}  (priority 10)
 TXT   ${DOMAIN}                    →  "v=spf1 mx -all"
 TXT   mail._domainkey.${DOMAIN}    →  (see /etc/opendkim/keys/${DOMAIN}/mail.txt)
 TXT   _dmarc.${DOMAIN}             →  "v=DMARC1; p=quarantine; rua=mailto:${ADMIN_EMAIL}"
 ─────────────────────────────────────────────────────────────

 SPF NOTE: -all (hard fail) used — change to ~all only if using 3rd-party senders

 DKIM public key:
$(cat "/etc/opendkim/keys/${DOMAIN}/mail.txt" 2>/dev/null || echo "  (check /etc/opendkim/keys/${DOMAIN}/mail.txt)")

 TO DISABLE MAIL:
   systemctl stop postfix dovecot opendkim
   systemctl disable postfix dovecot opendkim
   ufw deny 25 && ufw deny 587 && ufw deny 993 && ufw deny 995

SUMMARY
