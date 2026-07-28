#!/usr/bin/env bash

set -Eeuo pipefail

readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_VERSION="2026.07.28"
readonly PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# User-provided configuration file. This is intentionally separate from the
# generated Docker Compose environment file.
INPUT_ENV_FILE="${ENV_FILE:-${PROJECT_ROOT}/.env}"

TRAEFIK_INSTALL_DIR="${TRAEFIK_INSTALL_DIR:-/opt/traefik-service}"
TRAEFIK_IMAGE="${TRAEFIK_IMAGE:-traefik:v3.6}"
TRAEFIK_DOCKER_NETWORK="${TRAEFIK_DOCKER_NETWORK:-traefik-service}"
ACME_CA_SERVER="${ACME_CA_SERVER:-https://acme-v02.api.letsencrypt.org/directory}"
APT_LOCK_WAIT_SECONDS="${APT_LOCK_WAIT_SECONDS:-600}"
MAX_DOMAINS="${MAX_DOMAINS:-100}"

readonly COMPOSE_FILE="${TRAEFIK_INSTALL_DIR}/docker-compose.yml"
readonly STATIC_CONFIG="${TRAEFIK_INSTALL_DIR}/traefik.yml"
readonly DYNAMIC_CONFIG="${TRAEFIK_INSTALL_DIR}/dynamic/services.yml"
readonly COMPOSE_ENV_FILE="${TRAEFIK_INSTALL_DIR}/traefik.env"
readonly ACME_FILE="${TRAEFIK_INSTALL_DIR}/letsencrypt/acme.json"

usage() {
  cat <<EOF_USAGE
Usage:
  sudo env ENV_FILE=/path/to/.env ${SCRIPT_NAME}

Deploy Traefik on an Oracle VM as an HTTPS origin reverse proxy.

Required global variables:
  ACME_EMAIL
  VPS_IP
  CLOUDFLARE_API_TOKEN

Required variables for each route:
  DOMAIN_1
  SERVICE_IP_1
  SERVICE_PORT_1

Optional per-route variables:
  SERVICE_SCHEME_1          http or https; inferred from port when omitted
  INSECURE_SKIP_VERIFY_1   true by default for HTTPS backends
  PASS_HOST_HEADER_1       true by default

Optional shared edge variable:
  TRAEFIK_DOCKER_NETWORK  Docker network shared by Traefik and Vibrail apps;
                          defaults to traefik-service

Example .env:
  ACME_EMAIL=you@example.com
  VPS_IP=127.0.0.1
  CLOUDFLARE_API_TOKEN=replace_me

  DOMAIN_1=xxx.com
  SERVICE_IP_1=host
  SERVICE_PORT_1=3000
  SERVICE_SCHEME_1=http

  DOMAIN_2=xxx.com
  SERVICE_IP_2=host
  SERVICE_PORT_2=3011
  SERVICE_SCHEME_2=http
EOF_USAGE
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

warn() {
  printf 'Warning: %s\n' "$*" >&2
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

read_dotenv_value() {
  local key="$1" file="$2" line value=""

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    line="${line#"${line%%[![:space:]]*}"}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    [[ "$line" == export[[:space:]]* ]] && line="${line#export }"
    [[ "$line" == "${key}="* ]] || continue
    value="${line#*=}"
  done <"$file"

  value="$(trim "$value")"
  if (( ${#value} >= 2 )); then
    if [[ "$value" == \"*\" || "$value" == \'*\' ]]; then
      value="${value:1:${#value}-2}"
    fi
  fi
  printf '%s' "$value"
}

load_env_file() {
  printf '[%s] Loading configuration: %s\n' "$SCRIPT_VERSION" "$INPUT_ENV_FILE"
  [[ -f "$INPUT_ENV_FILE" ]] || die "environment file not found: $INPUT_ENV_FILE"
  [[ -r "$INPUT_ENV_FILE" ]] || die "environment file is not readable: $INPUT_ENV_FILE"

  local key value index
  local -a global_keys=(
    ACME_EMAIL VPS_IP CLOUDFLARE_API_TOKEN TRAEFIK_IMAGE
    TRAEFIK_INSTALL_DIR TRAEFIK_DOCKER_NETWORK ACME_CA_SERVER
    APT_LOCK_WAIT_SECONDS MAX_DOMAINS
  )

  for key in "${global_keys[@]}"; do
    value="$(read_dotenv_value "$key" "$INPUT_ENV_FILE")"
    if [[ -n "$value" ]]; then
      printf -v "$key" '%s' "$value"
      export "$key"
    fi
  done

  for ((index=1; index<=MAX_DOMAINS; index++)); do
    for key in \
      "DOMAIN_${index}" \
      "SERVICE_IP_${index}" \
      "SERVICE_PORT_${index}" \
      "SERVICE_SCHEME_${index}" \
      "INSECURE_SKIP_VERIFY_${index}" \
      "PASS_HOST_HEADER_${index}"; do
      value="$(read_dotenv_value "$key" "$INPUT_ENV_FILE")"
      if [[ -n "$value" ]]; then
        printf -v "$key" '%s' "$value"
        export "$key"
      fi
    done
  done

  [[ -n "${DOMAIN_1:-}" ]] || die "DOMAIN_1 was not found in $INPUT_ENV_FILE"
  [[ -n "${SERVICE_IP_1:-}" ]] || die "SERVICE_IP_1 was not found in $INPUT_ENV_FILE"
  [[ -n "${SERVICE_PORT_1:-}" ]] || die "SERVICE_PORT_1 was not found in $INPUT_ENV_FILE"

  printf 'Loaded DOMAIN_1=%s, SERVICE_IP_1=%s, SERVICE_PORT_1=%s\n' \
    "$DOMAIN_1" "$SERVICE_IP_1" "$SERVICE_PORT_1"
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

is_ip_or_hostname() {
  local value="$1"
  [[ -n "$value" && "$value" != *[[:space:]]* && "$value" != *:* && "$value" != */* ]]
}

is_bool() {
  [[ "$1" == "true" || "$1" == "false" ]]
}

yaml_quote() {
  local value="$1"
  value="${value//\'/\'\'}"
  printf "'%s'" "$value"
}

safe_name() {
  local value="$1"
  value="${value,,}"
  value="${value//[^a-z0-9-]/-}"
  value="${value#-}"
  value="${value%-}"
  printf '%s' "$value"
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
      ((remaining > 0)) || die "apt lock was not released within ${APT_LOCK_WAIT_SECONDS} seconds"
      sleep_seconds=10
      ((remaining < sleep_seconds)) && sleep_seconds=$remaining
      printf 'System package updates are active; retrying in %d seconds...\n' "$sleep_seconds"
      sleep "$sleep_seconds"
      continue
    fi

    rm -f "$log_file"
    return "$status"
  done
}

install_docker_if_needed() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    return 0
  fi

  command -v apt-get >/dev/null 2>&1 || die "Docker Compose is missing and automatic installation requires Ubuntu/Debian"
  export DEBIAN_FRONTEND=noninteractive
  run_apt update
  run_apt install -y ca-certificates curl docker.io docker-compose-v2
  systemctl enable --now docker
}

check_port_conflict() {
  local listeners
  listeners="$(ss -H -ltnp 'sport = :443' 2>/dev/null || true)"
  [[ -z "$listeners" ]] && return 0

  if grep -qE 'docker-proxy|traefik' <<<"$listeners"; then
    return 0
  fi

  printf '%s\n' "$listeners" >&2
  die "TCP port 443 is already occupied by another process"
}

validate_inputs() {
  ACME_EMAIL="$(trim "${ACME_EMAIL:-}")"
  VPS_IP="$(trim "${VPS_IP:-}")"
  CLOUDFLARE_API_TOKEN="$(trim "${CLOUDFLARE_API_TOKEN:-}")"

  [[ "$ACME_EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || die "ACME_EMAIL is missing or invalid"
  is_ipv4 "$VPS_IP" || die "VPS_IP is missing or is not a valid IPv4 address"
  [[ -n "$CLOUDFLARE_API_TOKEN" ]] || die "CLOUDFLARE_API_TOKEN is missing or empty"
  [[ "$TRAEFIK_DOCKER_NETWORK" =~ ^[A-Za-z0-9_.-]+$ ]] || die "TRAEFIK_DOCKER_NETWORK contains invalid characters"
  [[ "$APT_LOCK_WAIT_SECONDS" =~ ^[0-9]+$ ]] && ((APT_LOCK_WAIT_SECONDS >= 1)) || die "APT_LOCK_WAIT_SECONDS must be a positive integer"
  [[ "$MAX_DOMAINS" =~ ^[0-9]+$ ]] && ((MAX_DOMAINS >= 1)) || die "MAX_DOMAINS must be a positive integer"

  local index domain ip port scheme insecure pass_host count=0
  declare -A seen_domains=()

  for ((index=1; index<=MAX_DOMAINS; index++)); do
    local domain_var="DOMAIN_${index}"
    local ip_var="SERVICE_IP_${index}"
    local port_var="SERVICE_PORT_${index}"
    local scheme_var="SERVICE_SCHEME_${index}"
    local insecure_var="INSECURE_SKIP_VERIFY_${index}"
    local pass_host_var="PASS_HOST_HEADER_${index}"

    domain="$(trim "${!domain_var:-}")"
    ip="$(trim "${!ip_var:-}")"
    port="$(trim "${!port_var:-}")"

    if [[ -z "$domain" && -z "$ip" && -z "$port" ]]; then
      break
    fi

    [[ -n "$domain" && -n "$ip" && -n "$port" ]] || die "${domain_var}, ${ip_var}, and ${port_var} must all be set"
    is_domain "$domain" || die "invalid ${domain_var}: $domain"
    is_ip_or_hostname "$ip" || die "invalid ${ip_var}: $ip"
    [[ "$port" =~ ^[0-9]+$ ]] && ((port >= 1 && port <= 65535)) || die "${port_var} must be between 1 and 65535"
    [[ -z "${seen_domains[$domain]:-}" ]] || die "duplicate domain: $domain"
    seen_domains[$domain]=1

    printf -v "$domain_var" '%s' "$domain"
    printf -v "$ip_var" '%s' "$ip"
    printf -v "$port_var" '%s' "$port"
    export "$domain_var" "$ip_var" "$port_var"

    scheme="$(trim "${!scheme_var:-}")"
    if [[ -z "$scheme" ]]; then
      [[ "$port" == "443" ]] && scheme="https" || scheme="http"
    fi
    [[ "$scheme" == "http" || "$scheme" == "https" ]] || die "${scheme_var} must be http or https"
    printf -v "$scheme_var" '%s' "$scheme"
    export "$scheme_var"

    insecure="$(trim "${!insecure_var:-}")"
    if [[ -z "$insecure" ]]; then
      [[ "$scheme" == "https" ]] && insecure="true" || insecure="false"
    fi
    is_bool "$insecure" || die "${insecure_var} must be true or false"
    printf -v "$insecure_var" '%s' "$insecure"
    export "$insecure_var"

    pass_host="$(trim "${!pass_host_var:-true}")"
    is_bool "$pass_host" || die "${pass_host_var} must be true or false"
    printf -v "$pass_host_var" '%s' "$pass_host"
    export "$pass_host_var"

    count=$index
  done

  ((count >= 1)) || die "configure at least DOMAIN_1, SERVICE_IP_1, and SERVICE_PORT_1"
  DOMAIN_COUNT=$count
}

write_static_config() {
  cat >"$STATIC_CONFIG" <<EOF_STATIC
api:
  dashboard: false

entryPoints:
  websecure:
    address: ':443'
    transport:
      respondingTimeouts:
        readTimeout: 0s
        writeTimeout: 0s
        idleTimeout: 3600s

providers:
  docker:
    endpoint: unix:///var/run/docker.sock
    exposedByDefault: false
    network: $(yaml_quote "$TRAEFIK_DOCKER_NETWORK")

  file:
    directory: /etc/traefik/dynamic
    watch: true

certificatesResolvers:
  letsencrypt:
    acme:
      email: $(yaml_quote "$ACME_EMAIL")
      storage: /letsencrypt/acme.json
      caServer: $(yaml_quote "$ACME_CA_SERVER")
      dnsChallenge:
        provider: cloudflare
        delayBeforeCheck: 30s
        resolvers:
          - '1.1.1.1:53'
          - '8.8.8.8:53'

log:
  level: INFO

accessLog:
  format: json
  bufferingSize: 0
EOF_STATIC
}

write_dynamic_config() {
  local index domain ip port scheme insecure pass_host name transport_name
  local temp_config
  temp_config="$(mktemp "${TRAEFIK_INSTALL_DIR}/dynamic/.services.yml.tmp.XXXXXX")"

  {
    printf 'http:\n'
    printf '  routers:\n'

    for ((index=1; index<=DOMAIN_COUNT; index++)); do
      local domain_var="DOMAIN_${index}"
      domain="${!domain_var}"
      name="$(safe_name "$domain")-${index}"
      printf '    %s:\n' "$name"
      printf '      rule: %s\n' "$(yaml_quote "Host(\`${domain}\`)")"
      printf '      entryPoints:\n'
      printf '        - websecure\n'
      printf '      service: %s\n' "$name"
      printf '      tls:\n'
      printf '        certResolver: letsencrypt\n'
    done

    printf '  services:\n'
    for ((index=1; index<=DOMAIN_COUNT; index++)); do
      local domain_var="DOMAIN_${index}"
      local ip_var="SERVICE_IP_${index}"
      local port_var="SERVICE_PORT_${index}"
      local scheme_var="SERVICE_SCHEME_${index}"
      local insecure_var="INSECURE_SKIP_VERIFY_${index}"
      local pass_host_var="PASS_HOST_HEADER_${index}"

      domain="${!domain_var}"
      ip="${!ip_var}"
      port="${!port_var}"
      scheme="${!scheme_var}"
      insecure="${!insecure_var}"
      pass_host="${!pass_host_var}"
      name="$(safe_name "$domain")-${index}"
      transport_name="${name}-transport"

      printf '    %s:\n' "$name"
      printf '      loadBalancer:\n'
      printf '        passHostHeader: %s\n' "$pass_host"
      printf '        servers:\n'
      printf '          - url: %s\n' "$(yaml_quote "${scheme}://${ip}:${port}")"
      if [[ "$scheme" == "https" ]]; then
        printf '        serversTransport: %s\n' "$transport_name"
      fi
    done

    local has_https=false
    for ((index=1; index<=DOMAIN_COUNT; index++)); do
      local scheme_var="SERVICE_SCHEME_${index}"
      [[ "${!scheme_var}" == "https" ]] && has_https=true
    done

    if [[ "$has_https" == true ]]; then
      printf '  serversTransports:\n'
      for ((index=1; index<=DOMAIN_COUNT; index++)); do
        local domain_var="DOMAIN_${index}"
        local scheme_var="SERVICE_SCHEME_${index}"
        local insecure_var="INSECURE_SKIP_VERIFY_${index}"
        [[ "${!scheme_var}" == "https" ]] || continue
        domain="${!domain_var}"
        insecure="${!insecure_var}"
        name="$(safe_name "$domain")-${index}"
        printf '    %s-transport:\n' "$name"
        printf '      insecureSkipVerify: %s\n' "$insecure"
      done
    fi
  } >"$temp_config"

  chmod 0644 "$temp_config"
  mv -f "$temp_config" "$DYNAMIC_CONFIG"
}

write_compose_file() {
  cat >"$COMPOSE_FILE" <<'EOF_COMPOSE'
services:
  traefik:
    image: ${TRAEFIK_IMAGE}
    container_name: traefik-service
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    ports:
      - '443:443'
    extra_hosts:
      - 'host.docker.internal:host-gateway'
    environment:
      CF_DNS_API_TOKEN: ${CF_DNS_API_TOKEN}
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./traefik.yml:/etc/traefik/traefik.yml:ro
      - ./dynamic:/etc/traefik/dynamic:ro
      - ./letsencrypt:/letsencrypt
    networks:
      - shared-edge

networks:
  shared-edge:
    external: true
    name: ${TRAEFIK_DOCKER_NETWORK}
EOF_COMPOSE

  umask 077
  cat >"$COMPOSE_ENV_FILE" <<EOF_ENV
TRAEFIK_IMAGE=${TRAEFIK_IMAGE}
TRAEFIK_DOCKER_NETWORK=${TRAEFIK_DOCKER_NETWORK}
CF_DNS_API_TOKEN=${CLOUDFLARE_API_TOKEN}
EOF_ENV
  chmod 0600 "$COMPOSE_ENV_FILE"
}

backup_existing_config() {
  if [[ -d "$TRAEFIK_INSTALL_DIR" && -n "$(find "$TRAEFIK_INSTALL_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
    local backup_dir="${TRAEFIK_INSTALL_DIR}.backup.$(date +%Y%m%d%H%M%S)"
    cp -a "$TRAEFIK_INSTALL_DIR" "$backup_dir"
    printf 'Existing configuration backed up to %s\n' "$backup_dir"
  fi
}

configure_firewall() {
  if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
    while ufw status numbered 2>/dev/null | grep -Eq '443/tcp.*ALLOW IN.*Anywhere'; do
      local rule_number
      rule_number="$(ufw status numbered | awk '/443\/tcp/ && /ALLOW IN/ && /Anywhere/ {gsub(/\[|\]/,"",$1); print $1; exit}')"
      [[ -n "$rule_number" ]] || break
      yes | ufw delete "$rule_number" >/dev/null
    done
    ufw allow from "$VPS_IP" to any port 443 proto tcp >/dev/null
    printf 'UFW: allowed TCP 443 only from %s\n' "$VPS_IP"
  else
    warn "UFW is not active; restrict Oracle Cloud Security List/NSG TCP 443 to ${VPS_IP}/32"
  fi
}

deploy() {
  install_docker_if_needed
  command -v ss >/dev/null 2>&1 || run_apt install -y iproute2
  check_port_conflict

  backup_existing_config
  install -d -m 0755 "$TRAEFIK_INSTALL_DIR" "$TRAEFIK_INSTALL_DIR/dynamic" "$TRAEFIK_INSTALL_DIR/letsencrypt"
  touch "$ACME_FILE"
  chmod 0600 "$ACME_FILE"

  if ! docker network inspect "$TRAEFIK_DOCKER_NETWORK" >/dev/null 2>&1; then
    docker network create "$TRAEFIK_DOCKER_NETWORK" >/dev/null
    printf 'Created shared Docker network: %s\n' "$TRAEFIK_DOCKER_NETWORK"
  else
    printf 'Reusing shared Docker network: %s\n' "$TRAEFIK_DOCKER_NETWORK"
  fi

  write_static_config
  write_dynamic_config
  write_compose_file

  docker compose --env-file "$COMPOSE_ENV_FILE" -f "$COMPOSE_FILE" config >/dev/null
  docker compose --env-file "$COMPOSE_ENV_FILE" -f "$COMPOSE_FILE" pull
  # Static Traefik configuration is only read during process startup. Force a
  # container recreation so changes to ACME resolvers always take effect.
  docker compose --env-file "$COMPOSE_ENV_FILE" -f "$COMPOSE_FILE" up -d --remove-orphans --force-recreate

  configure_firewall

  sleep 2
  if ! docker inspect --format '{{.State.Running}}' traefik-service 2>/dev/null | grep -qx true; then
    docker compose --env-file "$COMPOSE_ENV_FILE" -f "$COMPOSE_FILE" logs --tail=100 >&2 || true
    die "Traefik container failed to start"
  fi
}

print_summary() {
  local index domain ip port scheme
  printf '\nTraefik deployment completed.\n'
  printf 'Input environment: %s\n' "$INPUT_ENV_FILE"
  printf 'Install directory: %s\n' "$TRAEFIK_INSTALL_DIR"
  printf 'Shared Docker network: %s\n' "$TRAEFIK_DOCKER_NETWORK"
  printf 'Trusted Edge VPS: %s\n' "$VPS_IP"
  printf 'HTTPS entrypoint: TCP 443\n'
  printf 'Access logs: JSON to container stdout (live/unbuffered)\n'
  printf 'ACME: Cloudflare DNS-01 via 1.1.1.1/8.8.8.8 (%s)\n\n' "$ACME_EMAIL"
  printf 'Configured routes:\n'

  for ((index=1; index<=DOMAIN_COUNT; index++)); do
    local domain_var="DOMAIN_${index}"
    local ip_var="SERVICE_IP_${index}"
    local port_var="SERVICE_PORT_${index}"
    local scheme_var="SERVICE_SCHEME_${index}"
    domain="${!domain_var}"
    ip="${!ip_var}"
    port="${!port_var}"
    scheme="${!scheme_var}"
    printf '  https://%s -> %s://%s:%s\n' "$domain" "$scheme" "$ip" "$port"
  done

  printf '\nUseful commands:\n'
  printf '  cd %s && docker compose --env-file %s logs -f\n' "$TRAEFIK_INSTALL_DIR" "$COMPOSE_ENV_FILE"
  printf '  cd %s && docker compose --env-file %s restart\n' "$TRAEFIK_INSTALL_DIR" "$COMPOSE_ENV_FILE"
  printf '\nOracle Cloud ingress should allow TCP 443 from %s/32 only.\n' "$VPS_IP"
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
[[ $# -eq 0 ]] || die "unexpected arguments; use --help for usage"
[[ $EUID -eq 0 ]] || die "run this script with sudo"

load_env_file
validate_inputs
deploy
print_summary
