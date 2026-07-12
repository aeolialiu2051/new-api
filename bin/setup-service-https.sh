#!/usr/bin/env bash

set -Eeuo pipefail

readonly SCRIPT_NAME="$(basename "$0")"
readonly SITE_NAME="new-api-origin"
readonly PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ENV_FILE="${ENV_FILE:-${PROJECT_ROOT}/.env}"
DNS_PROPAGATION_SECONDS="${DNS_PROPAGATION_SECONDS:-30}"
APT_LOCK_WAIT_SECONDS="${APT_LOCK_WAIT_SECONDS:-600}"

usage() {
  cat <<EOF
Usage: sudo ./${SCRIPT_NAME}

Run this script on the Oracle VM origin. It obtains a public Let's Encrypt
certificate through Cloudflare DNS-01, accepts HTTPS only from the trusted VPS,
and proxies requests to the local new-api service.

Environment variables:
  ENV_FILE        Environment file containing DOMAIN, VPS_IP, PORT and
                  CLOUDFLARE_API_TOKEN
                  (default: <project-root>/.env)
  DNS_PROPAGATION_SECONDS  DNS-01 propagation wait (default: 30)
  APT_LOCK_WAIT_SECONDS  Maximum apt lock wait (default: 600)
EOF
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

is_ipv4() {
  local ip="$1" octet
  local -a octets

  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -r -a octets <<<"$ip"
  for octet in "${octets[@]}"; do
    ((10#$octet <= 255)) || return 1
  done
}

is_domain() {
  local domain="$1"

  [[ ${#domain} -le 253 ]] || return 1
  [[ "$domain" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}

read_dotenv_value() {
  local key="$1" file="$2" line value=""

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"
    [[ "$line" == "${key}="* ]] || continue
    value="${line#*=}"
  done <"$file"

  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  if (( ${#value} >= 2 )) && { [[ "$value" == \"*\" ]] || [[ "$value" == \'*\' ]]; }; then
    value="${value:1:${#value}-2}"
  fi
  printf '%s' "$value"
}

backup_if_present() {
  local path="$1"
  if [[ -e "$path" || -L "$path" ]]; then
    cp -a --dereference "$path" "${path}.backup.$(date +%Y%m%d%H%M%S)"
  fi
}

run_apt() {
  local deadline=$((SECONDS + APT_LOCK_WAIT_SECONDS))
  local log_file remaining sleep_seconds status

  while true; do
    log_file="$(mktemp)"
    set +e
    apt-get -o DPkg::Lock::Timeout=1 "$@" 2>&1 | tee "$log_file"
    status=${PIPESTATUS[0]}
    set -e

    if ((status == 0)); then
      rm -f "$log_file"
      return 0
    fi

    if grep -Eq 'Could not get lock|Unable to (acquire|lock)' "$log_file"; then
      rm -f "$log_file"
      remaining=$((deadline - SECONDS))
      if ((remaining <= 0)); then
        die "apt lock was not released within ${APT_LOCK_WAIT_SECONDS} seconds"
      fi
      sleep_seconds=10
      if ((remaining < sleep_seconds)); then
        sleep_seconds=$remaining
      fi
      printf 'Ubuntu system updates are running; retrying in %d seconds (timeout in %d seconds)...\n' "$sleep_seconds" "$remaining"
      sleep "$sleep_seconds"
      continue
    fi

    rm -f "$log_file"
    return "$status"
  done
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
[[ $EUID -eq 0 ]] || die "run this script with sudo"
[[ "$DNS_PROPAGATION_SECONDS" =~ ^[0-9]+$ ]] && ((DNS_PROPAGATION_SECONDS >= 1)) || die "DNS_PROPAGATION_SECONDS must be a positive integer"
[[ "$APT_LOCK_WAIT_SECONDS" =~ ^[0-9]+$ ]] && ((APT_LOCK_WAIT_SECONDS >= 1)) || die "APT_LOCK_WAIT_SECONDS must be a positive integer"
[[ -f "$ENV_FILE" ]] || die "environment file not found: $ENV_FILE"

DOMAIN="$(read_dotenv_value DOMAIN "$ENV_FILE")"
[[ -n "$DOMAIN" ]] || die "DOMAIN is missing or empty in $ENV_FILE"
is_domain "$DOMAIN" || die "invalid DOMAIN in $ENV_FILE: $DOMAIN"

VPS_IP="$(read_dotenv_value VPS_IP "$ENV_FILE")"
[[ -n "$VPS_IP" ]] || die "VPS_IP is missing or empty in $ENV_FILE"
is_ipv4 "$VPS_IP" || die "VPS_IP in $ENV_FILE must be a valid IPv4 address"

PORT="$(read_dotenv_value PORT "$ENV_FILE")"
[[ -n "$PORT" ]] || die "PORT is missing or empty in $ENV_FILE"
[[ "$PORT" =~ ^[0-9]+$ ]] || die "PORT in $ENV_FILE must be a number"
((PORT >= 1 && PORT <= 65535)) || die "PORT in $ENV_FILE must be between 1 and 65535"
CLOUDFLARE_API_TOKEN="${CLOUDFLARE_API_TOKEN:-$(read_dotenv_value CLOUDFLARE_API_TOKEN "$ENV_FILE")}"
[[ -n "$CLOUDFLARE_API_TOKEN" ]] || die "CLOUDFLARE_API_TOKEN is missing or empty in $ENV_FILE"
[[ "$CLOUDFLARE_API_TOKEN" =~ ^[A-Za-z0-9_-]+$ ]] || die "CLOUDFLARE_API_TOKEN contains invalid characters"

command -v apt-get >/dev/null 2>&1 || die "this script only supports Ubuntu/Debian systems"

export DEBIAN_FRONTEND=noninteractive
run_apt update
run_apt install -y nginx ca-certificates certbot python3-certbot-dns-cloudflare

readonly SITE_FILE="/etc/nginx/sites-available/${SITE_NAME}"
readonly SITE_LINK="/etc/nginx/sites-enabled/${SITE_NAME}"
readonly CERT_NAME="${DOMAIN}-origin"
readonly CERT_FILE="/etc/letsencrypt/live/${CERT_NAME}/fullchain.pem"
readonly KEY_FILE="/etc/letsencrypt/live/${CERT_NAME}/privkey.pem"
readonly CLOUDFLARE_CREDENTIALS="/etc/letsencrypt/cloudflare.ini"
readonly RENEWAL_HOOK="/etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh"

install -d -m 0700 "$(dirname "$CLOUDFLARE_CREDENTIALS")"
umask 077
printf 'dns_cloudflare_api_token = %s\n' "$CLOUDFLARE_API_TOKEN" >"$CLOUDFLARE_CREDENTIALS"
unset CLOUDFLARE_API_TOKEN
certbot certonly \
  --dns-cloudflare \
  --dns-cloudflare-credentials "$CLOUDFLARE_CREDENTIALS" \
  --dns-cloudflare-propagation-seconds "$DNS_PROPAGATION_SECONDS" \
  --non-interactive \
  --agree-tos \
  --register-unsafely-without-email \
  --keep-until-expiring \
  --cert-name "$CERT_NAME" \
  --domain "$DOMAIN"

[[ -s "$CERT_FILE" && -s "$KEY_FILE" ]] || die "Let's Encrypt certificate files were not created for $DOMAIN"

install -d -m 0755 "$(dirname "$RENEWAL_HOOK")"
cat >"$RENEWAL_HOOK" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
nginx -t
systemctl reload nginx
EOF
chmod 0755 "$RENEWAL_HOOK"
if systemctl list-unit-files certbot.timer --no-legend 2>/dev/null | grep -q '^certbot.timer'; then
  systemctl enable --now certbot.timer
fi

backup_if_present "$SITE_FILE"
cat >"$SITE_FILE" <<EOF
server {
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;
    server_name ${DOMAIN};

    ssl_certificate ${CERT_FILE};
    ssl_certificate_key ${KEY_FILE};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;

    # Public TLS terminates on the VPS; this separate TLS listener protects the
    # cross-cloud origin hop. Only the trusted VPS may reach it.
    allow ${VPS_IP};
    deny all;

    client_max_body_size 100m;

    location / {
        proxy_pass http://127.0.0.1:${PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$http_host;
        # The network peer is restricted above, so these client headers are
        # accepted only from the trusted VPS and forwarded without duplication.
        proxy_set_header X-Real-IP \$http_x_real_ip;
        proxy_set_header X-Forwarded-For \$http_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_buffering off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
EOF

for link in /etc/nginx/sites-enabled/*; do
  [[ -e "$link" || -L "$link" ]] || continue
  rm -f "$link"
done
ln -sfn "$SITE_FILE" "$SITE_LINK"

nginx -t
systemctl enable nginx
if systemctl is-active --quiet nginx; then
  systemctl reload nginx
elif ! systemctl start nginx; then
  printf '\nNginx failed to start. Service status:\n' >&2
  systemctl status nginx --no-pager --full >&2 || true
  printf '\nRecent Nginx logs:\n' >&2
  journalctl -u nginx.service --no-pager -n 30 >&2 || true
  die "nginx could not start; resolve the reported conflict, then run this script again"
fi

if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
  ufw delete allow 'Nginx Full' >/dev/null 2>&1 || true
  ufw delete allow 'Nginx HTTP' >/dev/null 2>&1 || true
  ufw allow from "$VPS_IP" to any port 443 proto tcp
elif command -v iptables >/dev/null 2>&1; then
  while iptables -C INPUT -p tcp --dport 80 -j ACCEPT >/dev/null 2>&1; do
    iptables -D INPUT -p tcp --dport 80 -j ACCEPT
  done
  while iptables -C INPUT -p tcp --dport 443 -j ACCEPT >/dev/null 2>&1; do
    iptables -D INPUT -p tcp --dport 443 -j ACCEPT
  done
  iptables -C INPUT -p tcp -s "$VPS_IP" --dport 443 -j ACCEPT >/dev/null 2>&1 || \
    iptables -I INPUT 1 -p tcp -s "$VPS_IP" --dport 443 -j ACCEPT

  if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save
  else
    printf 'Warning: iptables rules are active but not persistent; install iptables-persistent to retain them after reboot.\n' >&2
  fi
fi

printf '\nOrigin Nginx deployment completed.\n'
printf 'Trusted VPS: %s\n' "$VPS_IP"
printf 'Origin endpoint for the VPS: https://<oracle-vm-ip>:443\n'
printf 'Application upstream: http://127.0.0.1:%s\n' "$PORT"
printf 'Public certificate: %s\n' "$CERT_FILE"
printf 'Automatic renewal: Certbot renewal scheduler + %s\n' "$RENEWAL_HOOK"
printf '\nIn the Oracle cloud security list, allow TCP port 443 from %s/32 only and remove all other public ingress for ports 80 and 443.\n' "$VPS_IP"
