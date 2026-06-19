#!/usr/bin/env bash

set -Eeuo pipefail

readonly SCRIPT_NAME="$(basename "$0")"
readonly SITE_NAME="new-api-ip-https"

PUBLIC_IP="${1:-${PUBLIC_IP:-}}"
UPSTREAM_PORT="${2:-${UPSTREAM_PORT:-3000}}"
CERT_DAYS="${CERT_DAYS:-365}"
APT_LOCK_WAIT_SECONDS="${APT_LOCK_WAIT_SECONDS:-600}"

usage() {
  cat <<EOF
Usage: sudo ./${SCRIPT_NAME} [public-ipv4] [upstream-port]

Example:
  sudo ./${SCRIPT_NAME}
  sudo ./${SCRIPT_NAME} 203.0.113.10 3000

Environment variables:
  PUBLIC_IP       Public IPv4 address (alternative to the first argument)
  UPSTREAM_PORT   Local application port (default: 3000)
  CERT_DAYS       Certificate validity in days (default: 365)
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

is_private_or_reserved_ipv4() {
  local ip="$1"

  [[ "$ip" =~ ^10\. ]] ||
    [[ "$ip" =~ ^127\. ]] ||
    [[ "$ip" =~ ^169\.254\. ]] ||
    [[ "$ip" =~ ^192\.168\. ]] ||
    [[ "$ip" =~ ^172\.(1[6-9]|2[0-9]|3[01])\. ]] ||
    [[ "$ip" =~ ^0\. ]] ||
    [[ "$ip" =~ ^22[4-9]\. ]] ||
    [[ "$ip" =~ ^23[0-9]\. ]] ||
    [[ "$ip" =~ ^24[0-9]\. ]] ||
    [[ "$ip" =~ ^25[0-5]\. ]]
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

detect_public_ipv4() {
  local endpoint candidate
  local -a endpoints=(
    "https://api.ipify.org"
    "https://checkip.amazonaws.com"
    "https://ifconfig.me/ip"
  )

  for endpoint in "${endpoints[@]}"; do
    candidate="$(curl --proto '=https' --tlsv1.2 -fsS --max-time 8 "$endpoint" 2>/dev/null | tr -d '[:space:]' || true)"
    if is_ipv4 "$candidate" && ! is_private_or_reserved_ipv4 "$candidate"; then
      printf '%s' "$candidate"
      return 0
    fi
  done

  return 1
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
[[ $EUID -eq 0 ]] || die "run this script with sudo"
[[ "$UPSTREAM_PORT" =~ ^[0-9]+$ ]] || die "upstream port must be a number"
((UPSTREAM_PORT >= 1 && UPSTREAM_PORT <= 65535)) || die "upstream port must be between 1 and 65535"
[[ "$CERT_DAYS" =~ ^[0-9]+$ ]] && ((CERT_DAYS >= 1)) || die "CERT_DAYS must be a positive integer"
[[ "$APT_LOCK_WAIT_SECONDS" =~ ^[0-9]+$ ]] && ((APT_LOCK_WAIT_SECONDS >= 1)) || die "APT_LOCK_WAIT_SECONDS must be a positive integer"

command -v apt-get >/dev/null 2>&1 || die "this script only supports Ubuntu/Debian systems"

export DEBIAN_FRONTEND=noninteractive
run_apt update
run_apt install -y nginx openssl ca-certificates curl

if [[ -z "$PUBLIC_IP" ]]; then
  printf 'Detecting public IPv4 address...\n'
  PUBLIC_IP="$(detect_public_ipv4)" || die "could not detect a public IPv4 address; pass it as the first argument"
  printf 'Detected public IPv4 address: %s\n' "$PUBLIC_IP"
fi

is_ipv4 "$PUBLIC_IP" || die "invalid IPv4 address: $PUBLIC_IP"
is_private_or_reserved_ipv4 "$PUBLIC_IP" && die "$PUBLIC_IP is not a public IPv4 address"

readonly CERT_DIR="/etc/nginx/ssl/${SITE_NAME}"
readonly CERT_FILE="${CERT_DIR}/server.crt"
readonly KEY_FILE="${CERT_DIR}/server.key"
readonly SITE_FILE="/etc/nginx/sites-available/${SITE_NAME}"
readonly SITE_LINK="/etc/nginx/sites-enabled/${SITE_NAME}"

install -d -m 0755 "$CERT_DIR"

certificate_matches_ip=false
if [[ -s "$CERT_FILE" ]] && openssl x509 -in "$CERT_FILE" -noout -checkend 86400 >/dev/null 2>&1; then
  if openssl x509 -in "$CERT_FILE" -noout -ext subjectAltName 2>/dev/null | grep -Fq "IP Address:${PUBLIC_IP}"; then
    certificate_matches_ip=true
  fi
fi

if [[ "$certificate_matches_ip" != true ]]; then
  backup_if_present "$CERT_FILE"
  backup_if_present "$KEY_FILE"
  openssl req -x509 -nodes -newkey rsa:2048 -sha256 \
    -keyout "$KEY_FILE" \
    -out "$CERT_FILE" \
    -days "$CERT_DAYS" \
    -subj "/CN=${PUBLIC_IP}" \
    -addext "subjectAltName=IP:${PUBLIC_IP}" \
    -addext "keyUsage=critical,digitalSignature,keyEncipherment" \
    -addext "extendedKeyUsage=serverAuth"
  chmod 0600 "$KEY_FILE"
  chmod 0644 "$CERT_FILE"
fi

backup_if_present "$SITE_FILE"
cat >"$SITE_FILE" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${PUBLIC_IP};

    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${PUBLIC_IP};

    ssl_certificate ${CERT_FILE};
    ssl_certificate_key ${KEY_FILE};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;

    client_max_body_size 100m;

    location / {
        proxy_pass http://127.0.0.1:${UPSTREAM_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_buffering off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
EOF

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

printf '\nHTTPS deployment completed.\n'
printf 'URL: https://%s\n' "$PUBLIC_IP"
printf 'Upstream: http://127.0.0.1:%s\n' "$UPSTREAM_PORT"
printf 'Certificate: %s\n' "$CERT_FILE"
printf '\nThis is a self-signed certificate. Browsers and API clients will warn until the certificate is trusted manually.\n'
printf 'Also ensure TCP ports 80 and 443 are open in the cloud security group.\n'
