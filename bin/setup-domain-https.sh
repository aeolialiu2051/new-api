#!/usr/bin/env bash

set -Eeuo pipefail

readonly SCRIPT_NAME="$(basename "$0")"
readonly SITE_NAME="new-api-domain-https"
readonly PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ENV_FILE="${ENV_FILE:-${PROJECT_ROOT}/.env}"
APT_LOCK_WAIT_SECONDS="${APT_LOCK_WAIT_SECONDS:-600}"

usage() {
  cat <<EOF
Usage: sudo ./${SCRIPT_NAME}

Example:
  sudo ./${SCRIPT_NAME}

Environment variables:
  ENV_FILE        Environment file containing DOMAIN and PORT (default: <project-root>/.env)
  APT_LOCK_WAIT_SECONDS  Maximum apt lock wait (default: 600)
EOF
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
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
[[ "$APT_LOCK_WAIT_SECONDS" =~ ^[0-9]+$ ]] && ((APT_LOCK_WAIT_SECONDS >= 1)) || die "APT_LOCK_WAIT_SECONDS must be a positive integer"
[[ -f "$ENV_FILE" ]] || die "environment file not found: $ENV_FILE"
DOMAIN="$(read_dotenv_value DOMAIN "$ENV_FILE")"
[[ -n "$DOMAIN" ]] || die "DOMAIN is missing or empty in $ENV_FILE"
is_domain "$DOMAIN" || die "invalid DOMAIN in $ENV_FILE: $DOMAIN"
PORT="$(read_dotenv_value PORT "$ENV_FILE")"
[[ -n "$PORT" ]] || die "PORT is missing or empty in $ENV_FILE"
[[ "$PORT" =~ ^[0-9]+$ ]] || die "PORT in $ENV_FILE must be a number"
((PORT >= 1 && PORT <= 65535)) || die "PORT in $ENV_FILE must be between 1 and 65535"

command -v apt-get >/dev/null 2>&1 || die "this script only supports Ubuntu/Debian systems"

export DEBIAN_FRONTEND=noninteractive
run_apt update
run_apt install -y nginx ca-certificates certbot python3-certbot-nginx

readonly SITE_FILE="/etc/nginx/sites-available/${SITE_NAME}"
readonly SITE_LINK="/etc/nginx/sites-enabled/${SITE_NAME}"
readonly DENY_SITE_NAME="new-api-deny-direct-access"
readonly DENY_SITE_FILE="/etc/nginx/sites-available/${DENY_SITE_NAME}"
readonly DENY_SITE_LINK="/etc/nginx/sites-enabled/${DENY_SITE_NAME}"
readonly IP_SITE_LINK="/etc/nginx/sites-enabled/new-api-ip-https"

backup_if_present "$SITE_FILE"
cat >"$SITE_FILE" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    client_max_body_size 100m;

    location / {
        proxy_pass http://127.0.0.1:${PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_buffering off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
EOF

backup_if_present "$DENY_SITE_FILE"
cat >"$DENY_SITE_FILE" <<'EOF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    return 444;
}

server {
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;
    server_name _;

    ssl_reject_handshake on;
}
EOF

rm -f "$IP_SITE_LINK" /etc/nginx/sites-enabled/default
ln -sfn "$SITE_FILE" "$SITE_LINK"
ln -sfn "$DENY_SITE_FILE" "$DENY_SITE_LINK"

nginx -t
systemctl enable nginx
if systemctl is-active --quiet nginx; then
  systemctl reload nginx
elif ! systemctl start nginx; then
  printf '\nNginx failed to start. Service status:\n' >&2
  systemctl status nginx --no-pager --full >&2 || true
  printf '\nRecent Nginx logs:\n' >&2
  journalctl -u nginx.service --no-pager -n 30 >&2 || true
  printf '\nProcesses listening on ports 80 and 443:\n' >&2
  ss -ltnp '( sport = :80 or sport = :443 )' >&2 || true
  die "nginx could not start; resolve the reported port or service conflict, then run this script again"
fi

if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
  ufw allow 'Nginx Full'
elif command -v iptables >/dev/null 2>&1; then
  for port in 80 443; do
    while iptables -C INPUT -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1; do
      iptables -D INPUT -p tcp --dport "$port" -j ACCEPT
    done
    iptables -I INPUT 1 -p tcp --dport "$port" -j ACCEPT
  done

  if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save
  else
    printf 'Warning: iptables rules are active but not persistent; install iptables-persistent to retain them after reboot.\n' >&2
  fi
fi

certbot --nginx --non-interactive --agree-tos --register-unsafely-without-email \
  --redirect --domain "$DOMAIN"
nginx -t
systemctl reload nginx

printf '\nHTTPS deployment completed.\n'
printf 'URL: https://%s\n' "$DOMAIN"
printf 'Upstream: http://127.0.0.1:%s\n' "$PORT"
printf 'Certificate: /etc/letsencrypt/live/%s/fullchain.pem\n' "$DOMAIN"
printf '\nSet the Cloudflare SSL/TLS encryption mode to Full (strict).\n'
printf 'Direct HTTP and HTTPS access by public IP is disabled.\n'
printf 'Also ensure TCP ports 80 and 443 are open in the cloud security group.\n'
