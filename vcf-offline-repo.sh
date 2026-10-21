#!/usr/bin/env bash
# =============================================================================
# setup-vcf-offline-depot.sh
# Configures Apache (httpd) on Oracle Linux 9 as an HTTPS + basic-auth
# offline depot for VMware Cloud Foundation 9.1.
#
# Usage:
#   sudo ./setup-vcf-offline-depot.sh -f depot.example.com -i 10.0.0.50 [options]
#
# Options:
#   -f FQDN        Depot server FQDN (required)
#   -i IP          Depot server IP for certificate SAN (required)
#   -d DIR         Depot root (default: /home/vcf-depot)
#   -u USER        Basic-auth username (default: vcfdepot)
#   -p PASS        Basic-auth password (prompted if omitted)
#   -c CERT KEY    Use existing cert/key instead of self-signed (two args)
#   -h             Show help
#
# Assumes binaries are already downloaded into the depot root.
# Re-running the script is safe: it updates config, permissions and labels.
# =============================================================================
set -euo pipefail

# ---------- defaults ----------
DEPOT_DIR="/home/vcf-depot"
AUTH_USER="vcfdepot"
AUTH_PASS=""
FQDN=""
IPADDR=""
CERT_FILE="/etc/pki/tls/certs/vcf-depot.crt"
KEY_FILE="/etc/pki/tls/private/vcf-depot.key"
USE_EXISTING_CERT=0
HTPASSWD_FILE="/etc/httpd/conf/.htpasswd"
VHOST_FILE="/etc/httpd/conf.d/00-vcf-depot.conf"
OLD_VHOST_FILE="/etc/httpd/conf.d/vcf-depot.conf"

log()  { echo -e "\e[1;32m[+]\e[0m $*"; }
warn() { echo -e "\e[1;33m[!]\e[0m $*"; }
die()  { echo -e "\e[1;31m[x]\e[0m $*" >&2; exit 1; }

usage() { sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

# ---------- args ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -f) FQDN="$2"; shift 2 ;;
    -i) IPADDR="$2"; shift 2 ;;
    -d) DEPOT_DIR="${2%/}"; shift 2 ;;
    -u) AUTH_USER="$2"; shift 2 ;;
    -p) AUTH_PASS="$2"; shift 2 ;;
    -c) CERT_FILE="$2"; KEY_FILE="$3"; USE_EXISTING_CERT=1; shift 3 ;;
    -h|--help) usage ;;
    *) die "Unknown option: $1 (use -h)" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "Run as root (sudo)."
[[ -n "$FQDN"   ]] || die "-f FQDN is required."
[[ -n "$IPADDR" ]] || die "-i IP is required."
if [[ $USE_EXISTING_CERT -eq 1 ]]; then
  [[ -f "$CERT_FILE" && -f "$KEY_FILE" ]] || die "Cert or key not found."
fi
grep -qiE 'oracle|rhel|rocky|alma' /etc/os-release || warn "Not Oracle Linux/RHEL-family; continuing anyway."

# ---------- 1. packages & firewall ----------
log "Installing httpd, mod_ssl, httpd-tools, SELinux utilities..."
dnf install -y httpd mod_ssl httpd-tools policycoreutils-python-utils openssl >/dev/null

if systemctl is-active --quiet firewalld; then
  log "Opening HTTPS in firewalld..."
  firewall-cmd --permanent --add-service=https >/dev/null
  firewall-cmd --reload >/dev/null
else
  warn "firewalld not running; skipping firewall config."
fi

# ---------- 2. check existing depot content ----------
[[ -d "$DEPOT_DIR" ]] || die "Depot directory $DEPOT_DIR not found."
[[ -d "$DEPOT_DIR/PROD" ]] || warn "$DEPOT_DIR/PROD not found; is the depot root correct?"
[[ -d "$DEPOT_DIR/umds-patch-store" ]] || warn "$DEPOT_DIR/umds-patch-store not found (only needed for ESX/UMDS content)."
log "Using existing depot at $DEPOT_DIR ($(du -sh "$DEPOT_DIR" 2>/dev/null | cut -f1))"

# ---------- 3. permissions & SELinux ----------
fix_perms() {
  log "Setting permissions and ownership on $DEPOT_DIR ..."
  # every parent directory needs execute for apache to traverse
  local p="$DEPOT_DIR"
  while [[ "$p" != "/" ]]; do
    chmod o+x "$p"
    p="$(dirname "$p")"
  done
  find "$DEPOT_DIR" -type d -exec chmod 755 {} +
  find "$DEPOT_DIR" -type f -exec chmod 644 {} +
  chown -R apache:apache "$DEPOT_DIR"

  if command -v getenforce >/dev/null && [[ "$(getenforce)" != "Disabled" ]]; then
    log "Applying SELinux label httpd_sys_content_t ..."
    semanage fcontext -a -t httpd_sys_content_t "${DEPOT_DIR}(/.*)?" 2>/dev/null \
      || semanage fcontext -m -t httpd_sys_content_t "${DEPOT_DIR}(/.*)?"
    restorecon -R "$DEPOT_DIR"
  fi
}
fix_perms

# ---------- 4. TLS certificate ----------
if [[ $USE_EXISTING_CERT -eq 0 ]]; then
  if [[ -f "$CERT_FILE" ]]; then
    log "Certificate $CERT_FILE already exists; keeping it."
  else
    log "Generating self-signed certificate for $FQDN / $IPADDR ..."
    openssl req -x509 -nodes -newkey rsa:4096 -days 1825 \
      -keyout "$KEY_FILE" -out "$CERT_FILE" \
      -subj "/CN=${FQDN}" \
      -addext "subjectAltName=DNS:${FQDN},DNS:${FQDN%%.*},IP:${IPADDR}" 2>/dev/null
    chmod 600 "$KEY_FILE"
  fi
fi
restorecon -v "$CERT_FILE" "$KEY_FILE" >/dev/null 2>&1 || true

# The stock ssl.conf default vhost points at localhost.crt/.key, which may not
# exist on OL9 (normally created by httpd-init/sscg). Point it at our cert.
SSL_CONF="/etc/httpd/conf.d/ssl.conf"
if [[ -f "$SSL_CONF" ]]; then
  log "Pointing $SSL_CONF default vhost at $CERT_FILE ..."
  cp -an "$SSL_CONF" "${SSL_CONF}.orig"
  sed -i -E "s|^([[:space:]]*SSLCertificateFile[[:space:]]+).*|\\1${CERT_FILE}|" "$SSL_CONF"
  sed -i -E "s|^([[:space:]]*SSLCertificateKeyFile[[:space:]]+).*|\\1${KEY_FILE}|" "$SSL_CONF"
else
  warn "$SSL_CONF missing; adding 'Listen 443 https' to the depot vhost."
  NEED_LISTEN=1
fi

# ---------- 5. basic auth ----------
if [[ -z "$AUTH_PASS" ]]; then
  read -rsp "Password for depot user '$AUTH_USER': " AUTH_PASS; echo
  read -rsp "Confirm password: " AUTH_PASS2; echo
  [[ "$AUTH_PASS" == "$AUTH_PASS2" ]] || die "Passwords do not match."
fi
log "Creating basic-auth user $AUTH_USER ..."
if [[ -f "$HTPASSWD_FILE" ]]; then
  htpasswd -bB "$HTPASSWD_FILE" "$AUTH_USER" "$AUTH_PASS" >/dev/null 2>&1
else
  htpasswd -cbB "$HTPASSWD_FILE" "$AUTH_USER" "$AUTH_PASS" >/dev/null 2>&1
fi
chown root:apache "$HTPASSWD_FILE"
chmod 640 "$HTPASSWD_FILE"

# ---------- 6. virtual host ----------
log "Writing $VHOST_FILE ..."
# 00- prefix makes this the default 443 vhost (loads before ssl.conf), so
# requests by IP or short name hit the depot, not /var/www/html.
[[ -f "$OLD_VHOST_FILE" ]] && mv "$OLD_VHOST_FILE" "${OLD_VHOST_FILE}.disabled"
[[ -f "$VHOST_FILE" ]] && cp -a "$VHOST_FILE" "${VHOST_FILE}.bak.$(date +%Y%m%d%H%M%S)"
cat > "$VHOST_FILE" <<EOF
# VCF 9.1 offline depot - generated by setup-vcf-offline-depot.sh
$( [[ "${NEED_LISTEN:-0}" -eq 1 ]] && echo "Listen 443 https" )
<VirtualHost *:443>
    ServerName ${FQDN}
    ServerAlias ${FQDN%%.*} ${IPADDR} localhost
    DocumentRoot ${DEPOT_DIR}

    SSLEngine on
    SSLCertificateFile    ${CERT_FILE}
    SSLCertificateKeyFile ${KEY_FILE}

    <Directory ${DEPOT_DIR}>
        Options -Indexes +FollowSymLinks
        AllowOverride None
        AuthType Basic
        AuthName "VCF Offline Depot"
        AuthUserFile ${HTPASSWD_FILE}
        Require valid-user
    </Directory>

    # vSAN HCL metadata is fetched without credentials
    <Directory ${DEPOT_DIR}/PROD/vsan/hcl>
        Require all granted
    </Directory>

    # ESX patch store used by UMDS / depot service
    <Directory ${DEPOT_DIR}/umds-patch-store>
        Require all granted
    </Directory>

    ErrorLog  /var/log/httpd/vcf-depot_error.log
    CustomLog /var/log/httpd/vcf-depot_access.log combined
</VirtualHost>
EOF

# ---------- 7. start httpd ----------
log "Validating Apache configuration..."
httpd -t || die "httpd config test failed; see output above."
systemctl enable httpd >/dev/null 2>&1
systemctl restart httpd
log "httpd is $(systemctl is-active httpd)."

# ---------- 8. self-test ----------
log "Running local tests..."
test_url() {
  local url="$1"; shift
  local code
  code=$(curl -sk -o /dev/null -w '%{http_code}' --resolve "${FQDN}:443:127.0.0.1" "$@" "$url" || true)
  printf "    %-75s -> %s\n" "$url" "$code"
}
test_url "https://${FQDN}/PROD/" -u "${AUTH_USER}:${AUTH_PASS}"
test_url "https://${FQDN}/PROD/metadata/productVersionCatalog/v1/productVersionCatalog.json" -u "${AUTH_USER}:${AUTH_PASS}"
test_url "https://${FQDN}/PROD/vsan/hcl/lastupdatedtime.json"
echo "    (403 on /PROD/ is expected with Indexes off; expect 200 on the other two)"
test_url "https://${IPADDR}/PROD/vsan/hcl/lastupdatedtime.json"

cat <<EOF

=============================================================================
 Offline depot ready
   URL      : https://${FQDN}   (port 443)
   User     : ${AUTH_USER}
   Root     : ${DEPOT_DIR}
   Cert     : ${CERT_FILE}

 Next steps:
   1. In VCF Installer > Depot settings > Offline Depot, enter the URL,
      port 443 and the credentials above.
   2. If self-signed, import ${CERT_FILE} into the VCF Installer trust store.
   3. After any future VDT download, re-run this script (or at least:
      chown -R apache:apache ${DEPOT_DIR} && restorecon -R ${DEPOT_DIR}).
   4. Troubleshoot: /var/log/httpd/vcf-depot_error.log
                    ausearch -m avc -ts recent
=============================================================================
EOF
