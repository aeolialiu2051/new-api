#!/usr/bin/env bash
set -Eeuo pipefail

readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly INSTALL_DIR="${TRAEFIK_INSTALL_DIR:-/opt/traefik-edge}"
readonly ENV_FILE="${ENV_FILE:-${SCRIPT_DIR}/.env}"
readonly TRAEFIK_IMAGE="${TRAEFIK_IMAGE:-traefik:v3.6}"
readonly APT_LOCK_WAIT_SECONDS="${APT_LOCK_WAIT_SECONDS:-600}"
readonly PUBLIC_CHECK_TIMEOUT_SECONDS="${PUBLIC_CHECK_TIMEOUT_SECONDS:-240}"

ROLLBACK_REQUIRED=false
TRAEFIK_STARTED=false
TRAEFIK_WAS_RUNNING=false
BACKUP_DIR=""

# Per-route arrays, indexed from 0 internally.
declare -a ROUTE_DOMAINS=()
declare -a ROUTE_IPS=()
declare -a ROUTE_PORTS=()
declare -a ROUTE_SCHEMES=()
declare -a ROUTE_SNIS=()
declare -a ROUTE_VERIFY_TLS=()

usage() {
  cat <<EOF
Usage: sudo ./${SCRIPT_NAME}

Install and configure Traefik for one or more domains from ${ENV_FILE}.
Numbering must start at 1 and be continuous.

Example with one domain:
  DOMAIN_1=xxx1.com
  SERVICE_IP_1=127.0.0.1
  SERVICE_PORT_1=443

Example with three domains:
  DOMAIN_1=xxx1.com
  SERVICE_IP_1=127.0.0.1
  SERVICE_PORT_1=443

  DOMAIN_2=xxx2.com
  SERVICE_IP_2=127.0.0.2
  SERVICE_PORT_2=443

  DOMAIN_3=xxx3.com
  SERVICE_IP_3=127.0.0.3
  SERVICE_PORT_3=8080
  ORIGIN_SCHEME_3=http

Global optional values:
  ACME_EMAIL=you@example.com
  DEFAULT_SERVICE_IP=127.0.0.1
  DEFAULT_SERVICE_PORT=443
  DEFAULT_ORIGIN_SCHEME=https
  REQUIRE_PUBLIC_BEFORE=false
  PUBLIC_CHECK_TIMEOUT_SECONDS=240

Per-domain optional values:
  SERVICE_IP_N       Falls back to DEFAULT_SERVICE_IP
  SERVICE_PORT_N     Falls back to DEFAULT_SERVICE_PORT, then 443
  ORIGIN_SCHEME_N    http or https; falls back to DEFAULT_ORIGIN_SCHEME, then https
  ORIGIN_SNI_N       TLS server name; defaults to DOMAIN_N
  VERIFY_ORIGIN_TLS_N=true|false; defaults to true

Optional process overrides:
  ENV_FILE=/path/to/.env
  TRAEFIK_INSTALL_DIR=/opt/traefik-edge
  TRAEFIK_IMAGE=traefik:v3.6
  APT_LOCK_WAIT_SECONDS=600
EOF
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '\n==> %s\n' "$*"
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

is_domain() {
  local domain="$1"
  [[ ${#domain} -le 253 ]] || return 1
  [[ "$domain" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
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

is_hostname_or_ip() {
  is_ipv4 "$1" || is_domain "$1"
}

is_bool() {
  [[ "$1" == "true" || "$1" == "false" ]]
}

read_dotenv_value() {
  local key="$1" file="$2" line value=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="$(trim "$line")"
    [[ -z "$line" || "$line" == \#* ]] && continue
    [[ "$line" == "${key}="* ]] || continue
    value="${line#*=}"
  done <"$file"

  value="$(trim "$value")"
  if (( ${#value} >= 2 )) && { [[ "$value" == \"*\" ]] || [[ "$value" == \'*\' ]]; }; then
    value="${value:1:${#value}-2}"
  fi
  printf '%s' "$value"
}

sanitize_name() {
  local value="$1"
  value="${value,,}"
  value="${value//./-}"
  value="${value//_/-}"
  value="$(printf '%s' "$value" | tr -cd 'a-z0-9-')"
  value="${value#-}"
  value="${value%-}"
  printf '%s' "$value"
}

yaml_single_quote() {
  local value="$1"
  value="${value//\'/\'\'}"
  printf "'%s'" "$value"
}

run_apt() {
  local deadline=$((SECONDS + APT_LOCK_WAIT_SECONDS))
  local log_file remaining status sleep_seconds
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
      ((remaining > 0)) || die "apt lock timeout after ${APT_LOCK_WAIT_SECONDS}s"
      sleep_seconds=10
      ((remaining < sleep_seconds)) && sleep_seconds=$remaining
      printf 'APT is locked; retrying in %d seconds...\n' "$sleep_seconds"
      sleep "$sleep_seconds"
      continue
    fi
    rm -f "$log_file"
    return "$status"
  done
}

http_status() {
  local url="$1"
  shift
  local status
  status="$(curl --silent --show-error --output /dev/null \
    --connect-timeout 10 --max-time 30 \
    --write-out '%{http_code}' "$@" "$url" 2>/dev/null || true)"
  [[ "$status" =~ ^[0-9]{3}$ ]] && printf '%s' "$status" || printf '000'
}

reachable_status() {
  [[ "$1" =~ ^[1-4][0-9][0-9]$ ]]
}

compose() {
  docker compose --project-directory "$INSTALL_DIR" -f "$INSTALL_DIR/docker-compose.yml" "$@"
}

rollback() {
  local status=$?
  trap - EXIT INT TERM

  if ((status != 0)) && [[ "$ROLLBACK_REQUIRED" == true ]]; then
    printf '\nDeployment failed; attempting rollback...\n' >&2
    if [[ "$TRAEFIK_STARTED" == true ]]; then
      compose down >/dev/null 2>&1 || true
    fi
    if [[ -n "$BACKUP_DIR" && -d "$BACKUP_DIR" ]]; then
      rm -rf "$INSTALL_DIR"
      cp -a "$BACKUP_DIR" "$INSTALL_DIR"
      if [[ "$TRAEFIK_WAS_RUNNING" == true ]]; then
        compose up -d >/dev/null 2>&1 || true
      fi
    else
      rm -rf "$INSTALL_DIR"
    fi
    printf 'Rollback attempted. Check Traefik status and logs.\n' >&2
  fi
  exit "$status"
}
trap rollback EXIT INT TERM

load_routes() {
  local default_ip default_port default_scheme
  local n=1 domain ip port scheme sni verify
  local -A seen_domains=()

  default_ip="$(read_dotenv_value DEFAULT_SERVICE_IP "$ENV_FILE")"
  default_port="$(read_dotenv_value DEFAULT_SERVICE_PORT "$ENV_FILE")"
  default_scheme="$(read_dotenv_value DEFAULT_ORIGIN_SCHEME "$ENV_FILE")"
  default_port="${default_port:-443}"
  default_scheme="${default_scheme:-https}"

  while true; do
    domain="$(read_dotenv_value "DOMAIN_${n}" "$ENV_FILE")"
    if [[ -z "$domain" ]]; then
      break
    fi

    ip="$(read_dotenv_value "SERVICE_IP_${n}" "$ENV_FILE")"
    port="$(read_dotenv_value "SERVICE_PORT_${n}" "$ENV_FILE")"
    scheme="$(read_dotenv_value "ORIGIN_SCHEME_${n}" "$ENV_FILE")"
    sni="$(read_dotenv_value "ORIGIN_SNI_${n}" "$ENV_FILE")"
    verify="$(read_dotenv_value "VERIFY_ORIGIN_TLS_${n}" "$ENV_FILE")"

    ip="${ip:-$default_ip}"
    port="${port:-$default_port}"
    scheme="${scheme:-$default_scheme}"
    sni="${sni:-$domain}"
    verify="${verify:-true}"

    is_domain "$domain" || die "invalid DOMAIN_${n}: $domain"
    [[ -z "${seen_domains[$domain]:-}" ]] || die "duplicate domain: $domain"
    seen_domains[$domain]=1
    [[ -n "$ip" ]] || die "SERVICE_IP_${n} or DEFAULT_SERVICE_IP is required"
    is_hostname_or_ip "$ip" || die "invalid SERVICE_IP_${n}: $ip"
    [[ "$port" =~ ^[0-9]+$ ]] || die "SERVICE_PORT_${n} must be numeric"
    ((port >= 1 && port <= 65535)) || die "SERVICE_PORT_${n} must be between 1 and 65535"
    [[ "$scheme" == "http" || "$scheme" == "https" ]] || die "ORIGIN_SCHEME_${n} must be http or https"
    is_domain "$sni" || die "invalid ORIGIN_SNI_${n}: $sni"
    is_bool "$verify" || die "VERIFY_ORIGIN_TLS_${n} must be true or false"

    ROUTE_DOMAINS+=("$domain")
    ROUTE_IPS+=("$ip")
    ROUTE_PORTS+=("$port")
    ROUTE_SCHEMES+=("$scheme")
    ROUTE_SNIS+=("$sni")
    ROUTE_VERIFY_TLS+=("$verify")
    ((n++))
  done

  ((${#ROUTE_DOMAINS[@]} >= 1)) || die "no domains configured; add DOMAIN_1 to $ENV_FILE"

  # Catch accidental gaps such as DOMAIN_1 and DOMAIN_3 without DOMAIN_2.
  if grep -Eq '^DOMAIN_[0-9]+=' "$ENV_FILE"; then
    local highest
    highest="$(grep -E '^DOMAIN_[0-9]+=' "$ENV_FILE" | sed -E 's/^DOMAIN_([0-9]+)=.*/\1/' | sort -n | tail -1)"
    ((highest == ${#ROUTE_DOMAINS[@]})) || die "DOMAIN_N numbering must be continuous from 1; found a gap before DOMAIN_${highest}"
  fi
}

write_traefik_static_config() {
  local acme_email="$1"
  cat >"$INSTALL_DIR/traefik.yml" <<EOF
api:
  dashboard: false

log:
  level: INFO

accessLog: {}

entryPoints:
  web:
    address: ":80"
    http:
      redirections:
        entryPoint:
          to: websecure
          scheme: https
          permanent: true
  websecure:
    address: ":443"
    transport:
      respondingTimeouts:
        readTimeout: 3600s
        writeTimeout: 3600s
        idleTimeout: 3600s

providers:
  file:
    directory: /etc/traefik/dynamic
    watch: true

certificatesResolvers:
  letsencrypt:
    acme:
      email: "${acme_email}"
      storage: /letsencrypt/acme.json
      httpChallenge:
        entryPoint: web
EOF
}

write_dynamic_routes() {
  local file="$INSTALL_DIR/dynamic/routes.yml"
  local i domain ip port scheme sni verify name insecure

  printf 'http:\n  routers:\n' >"$file"
  for i in "${!ROUTE_DOMAINS[@]}"; do
    domain="${ROUTE_DOMAINS[$i]}"
    name="route-$((i + 1))-$(sanitize_name "$domain")"
    cat >>"$file" <<EOF
    ${name}:
      rule: 'Host(\`${domain}\`)'
      entryPoints:
        - websecure
      service: ${name}-origin
      tls:
        certResolver: letsencrypt

EOF
  done

  printf '  services:\n' >>"$file"
  for i in "${!ROUTE_DOMAINS[@]}"; do
    domain="${ROUTE_DOMAINS[$i]}"
    ip="${ROUTE_IPS[$i]}"
    port="${ROUTE_PORTS[$i]}"
    scheme="${ROUTE_SCHEMES[$i]}"
    name="route-$((i + 1))-$(sanitize_name "$domain")"

    cat >>"$file" <<EOF
    ${name}-origin:
      loadBalancer:
        passHostHeader: true
EOF
    if [[ "$scheme" == "https" ]]; then
      cat >>"$file" <<EOF
        serversTransport: ${name}-tls
EOF
    fi
    cat >>"$file" <<EOF
        servers:
          - url: '${scheme}://${ip}:${port}'

EOF
  done

  local wrote_transport=false
  for scheme in "${ROUTE_SCHEMES[@]}"; do
    [[ "$scheme" == "https" ]] && wrote_transport=true
  done

  if [[ "$wrote_transport" == true ]]; then
    printf '  serversTransports:\n' >>"$file"
    for i in "${!ROUTE_DOMAINS[@]}"; do
      scheme="${ROUTE_SCHEMES[$i]}"
      [[ "$scheme" == "https" ]] || continue
      domain="${ROUTE_DOMAINS[$i]}"
      sni="${ROUTE_SNIS[$i]}"
      verify="${ROUTE_VERIFY_TLS[$i]}"
      name="route-$((i + 1))-$(sanitize_name "$domain")"
      [[ "$verify" == "true" ]] && insecure=false || insecure=true
      cat >>"$file" <<EOF
    ${name}-tls:
      serverName: '${sni}'
      insecureSkipVerify: ${insecure}
      forwardingTimeouts:
        dialTimeout: 30s
        responseHeaderTimeout: 3600s
        idleConnTimeout: 3600s

EOF
    done
  fi
}

write_compose_file() {
  cat >"$INSTALL_DIR/docker-compose.yml" <<EOF
services:
  traefik:
    image: ${TRAEFIK_IMAGE}
    container_name: traefik-edge
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./traefik.yml:/etc/traefik/traefik.yml:ro
      - ./dynamic:/etc/traefik/dynamic:ro
      - ./letsencrypt:/letsencrypt
EOF
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
[[ $# -eq 0 ]] || die "unexpected arguments; use --help"
[[ $EUID -eq 0 ]] || die "run with sudo"
[[ -f "$ENV_FILE" ]] || die "environment file not found: $ENV_FILE"
command -v apt-get >/dev/null 2>&1 || die "only Ubuntu/Debian is supported"
[[ "$APT_LOCK_WAIT_SECONDS" =~ ^[0-9]+$ ]] || die "APT_LOCK_WAIT_SECONDS must be numeric"
[[ "$PUBLIC_CHECK_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] && ((PUBLIC_CHECK_TIMEOUT_SECONDS >= 10)) || die "PUBLIC_CHECK_TIMEOUT_SECONDS must be at least 10"

load_routes

ACME_EMAIL="$(read_dotenv_value ACME_EMAIL "$ENV_FILE")"
REQUIRE_PUBLIC_BEFORE="$(read_dotenv_value REQUIRE_PUBLIC_BEFORE "$ENV_FILE")"
REQUIRE_PUBLIC_BEFORE="${REQUIRE_PUBLIC_BEFORE:-false}"
is_bool "$REQUIRE_PUBLIC_BEFORE" || die "REQUIRE_PUBLIC_BEFORE must be true or false"

log "Loaded ${#ROUTE_DOMAINS[@]} domain route(s)"
for i in "${!ROUTE_DOMAINS[@]}"; do
  printf '%d. https://%s -> %s://%s:%s' \
    "$((i + 1))" "${ROUTE_DOMAINS[$i]}" "${ROUTE_SCHEMES[$i]}" \
    "${ROUTE_IPS[$i]}" "${ROUTE_PORTS[$i]}"
  if [[ "${ROUTE_SCHEMES[$i]}" == "https" ]]; then
    printf ' (SNI %s, verify=%s)' "${ROUTE_SNIS[$i]}" "${ROUTE_VERIFY_TLS[$i]}"
  fi
  printf '\n'
done

if [[ "$REQUIRE_PUBLIC_BEFORE" == "true" ]]; then
  log "Checking current public domains"
  for domain in "${ROUTE_DOMAINS[@]}"; do
    status="$(http_status "https://${domain}/")"
    printf '%s: %s\n' "$domain" "$status"
    reachable_status "$status" || die "$domain is not currently reachable"
  done
else
  log "Skipping required pre-migration public checks"
  printf 'Set REQUIRE_PUBLIC_BEFORE=true to require every domain to be reachable before migration.\n'
fi

log "Checking configured origins"
for i in "${!ROUTE_DOMAINS[@]}"; do
  domain="${ROUTE_DOMAINS[$i]}"
  ip="${ROUTE_IPS[$i]}"
  port="${ROUTE_PORTS[$i]}"
  scheme="${ROUTE_SCHEMES[$i]}"
  sni="${ROUTE_SNIS[$i]}"
  verify="${ROUTE_VERIFY_TLS[$i]}"

  if [[ "$scheme" == "https" ]]; then
    curl_args=(--resolve "${sni}:${port}:${ip}")
    [[ "$verify" == "false" ]] && curl_args+=(-k)
    status="$(http_status "https://${sni}:${port}/" "${curl_args[@]}")"
  else
    status="$(http_status "http://${ip}:${port}/" -H "Host: ${domain}")"
  fi
  printf '%s origin: %s\n' "$domain" "$status"
  reachable_status "$status" || die "origin check failed for $domain"
done

log "Installing Docker and supporting packages"
export DEBIAN_FRONTEND=noninteractive
run_apt update
run_apt install -y ca-certificates curl docker.io
if ! run_apt install -y docker-compose-v2; then
  run_apt install -y docker-compose-plugin
fi
systemctl enable --now docker
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is unavailable"

log "Preparing Traefik configuration"
if docker inspect -f '{{.State.Running}}' traefik-edge 2>/dev/null | grep -q true; then
  TRAEFIK_WAS_RUNNING=true
fi
if [[ -d "$INSTALL_DIR" && -f "$INSTALL_DIR/docker-compose.yml" ]]; then
  BACKUP_DIR="${INSTALL_DIR}.backup.$(date +%Y%m%d%H%M%S)"
  cp -a "$INSTALL_DIR" "$BACKUP_DIR"
  printf 'Existing Traefik configuration backed up to %s\n' "$BACKUP_DIR"
fi
mkdir -p "$INSTALL_DIR/dynamic" "$INSTALL_DIR/letsencrypt"
chmod 700 "$INSTALL_DIR/letsencrypt"
touch "$INSTALL_DIR/letsencrypt/acme.json"
chmod 600 "$INSTALL_DIR/letsencrypt/acme.json"

write_traefik_static_config "$ACME_EMAIL"
write_dynamic_routes
write_compose_file

compose config >/dev/null
docker run --rm "$TRAEFIK_IMAGE" version >/dev/null

ROLLBACK_REQUIRED=true

log "Starting Traefik"
if [[ "$TRAEFIK_WAS_RUNNING" == true ]]; then
  compose down
fi

if ss -ltnp '( sport = :80 or sport = :443 )' | grep -q LISTEN; then
  ss -ltnp '( sport = :80 or sport = :443 )' >&2 || true
  die "ports 80 or 443 are still occupied"
fi

compose pull
compose up -d
TRAEFIK_STARTED=true

log "Waiting for Traefik and public HTTPS"
all_ready=false
for _ in $(seq 1 $((PUBLIC_CHECK_TIMEOUT_SECONDS / 5))); do
  sleep 5
  if ! docker inspect -f '{{.State.Running}}' traefik-edge 2>/dev/null | grep -q true; then
    docker logs --tail 150 traefik-edge >&2 || true
    die "Traefik container stopped unexpectedly"
  fi

  all_ready=true
  for domain in "${ROUTE_DOMAINS[@]}"; do
    status="$(http_status "https://${domain}/")"
    if ! reachable_status "$status"; then
      all_ready=false
      break
    fi
  done
  [[ "$all_ready" == true ]] && break
done

for domain in "${ROUTE_DOMAINS[@]}"; do
  status="$(http_status "https://${domain}/")"
  if ! reachable_status "$status"; then
    docker logs --tail 200 traefik-edge >&2 || true
    die "$domain failed after deployment: HTTP $status"
  fi
  printf '%s: HTTP %s\n' "$domain" "$status"
done

ROLLBACK_REQUIRED=false

log "Deployment completed"
printf 'Traefik image: %s\n' "$TRAEFIK_IMAGE"
printf 'Routes: %d\n' "${#ROUTE_DOMAINS[@]}"
printf 'Config directory: %s\n' "$INSTALL_DIR"
printf 'Logs: docker logs -f traefik-edge\n'
printf 'Restart: cd %s && docker compose up -d\n' "$INSTALL_DIR"