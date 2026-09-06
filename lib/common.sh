#!/usr/bin/env bash

NAIT_ZTR_INSTALLER_VERSION="0.5.0"
NAIT_ZTR_DEFAULT_NETWORK_NAME="ztr_net"
NAIT_ZTR_DEFAULT_NETWORK_CIDR="10.147.17.0/24"
NAIT_ZTR_DEFAULT_CORE_IP="10.147.17.1"
NAIT_ZTR_CONFIG_DIR="/etc/naitlab/ztr"
NAIT_ZTR_CONFIG_FILE="${NAIT_ZTR_CONFIG_DIR}/ztr.env"
NAIT_ZTR_LOG_DIR="/var/log/naitlab"
NAIT_ZTR_LOG_FILE="${NAIT_ZTR_LOG_DIR}/ztr-installer.log"
NAIT_ZTNCUI_DEFAULT_VERSION="0.8.14"
NAIT_ZTNCUI_DIR="/opt/key-networks/ztncui"
NAIT_ZTNCUI_ENV_FILE="${NAIT_ZTNCUI_DIR}/.env"
NAIT_ZTNCUI_SERVICE="ztncui.service"
NAIT_ZTR_OFFLINE_DIR="${REPO_ROOT}/offline"
ZT_LOCAL_API="http://127.0.0.1:9993"

log_info() {
  printf '[INFO] %s\n' "$*"
  write_log "INFO" "$*"
}

log_warn() {
  printf '[WARN] %s\n' "$*" >&2
  write_log "WARN" "$*"
}

log_error() {
  printf '[ERROR] %s\n' "$*" >&2
  write_log "ERROR" "$*"
}

die() {
  log_error "$*"
  exit 1
}

write_log() {
  local level="${1:-INFO}"
  local message="${2:-}"
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || true)"

  if [[ -d "${NAIT_ZTR_LOG_DIR}" && -w "${NAIT_ZTR_LOG_DIR}" ]]; then
    printf '%s [%s] %s\n' "${ts}" "${level}" "${message}" >> "${NAIT_ZTR_LOG_FILE}" || true
  fi
}

normalize_user_input() {
  local value="${1:-}"
  printf '%s' "${value}" | tr -d '[:cntrl:]' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'
}

read_user_input() {
  local prompt="${1:?prompt обязателен}"
  local answer

  if [[ -t 0 ]]; then
    read -e -r -p "${prompt}" answer
  else
    read -r -p "${prompt}" answer
  fi

  normalize_user_input "${answer}"
}

read_secret_input() {
  local prompt="${1:?prompt обязателен}"
  local answer

  if [[ -t 0 ]]; then
    read -r -s -p "${prompt}" answer
    printf '\n' >&2
  else
    read -r answer
  fi

  normalize_user_input "${answer}"
}

confirm() {
  local prompt="${1:-Продолжить?}"
  local default="${2:-N}"
  local answer
  local suffix

  case "${default}" in
    Y|y) suffix='[Y/n]' ;;
    *) suffix='[y/N]' ;;
  esac

  answer="$(read_user_input "${prompt} ${suffix}: ")"
  answer="${answer:-${default}}"

  case "${answer}" in
    Y|y|yes|YES|Yes|Д|д|да|ДА|Да|Н|н) return 0 ;;
    N|n|no|NO|No|Т|т|нет|НЕТ|Нет) return 1 ;;
    *) return 1 ;;
  esac
}

prompt_with_default() {
  local prompt="${1:?prompt обязателен}"
  local default="${2:-}"
  local answer

  if [[ -n "${default}" ]]; then
    answer="$(read_user_input "${prompt} [${default}]: ")"
    printf '%s\n' "${answer:-${default}}"
  else
    answer="$(read_user_input "${prompt}: ")"
    printf '%s\n' "${answer}"
  fi
}

require_sudo() {
  command -v sudo >/dev/null 2>&1 || die "sudo обязателен."
}

run_sudo() {
  if [[ "${EUID}" -eq 0 ]]; then
    printf '[INFO] Выполнение от root: %s\n' "$*" >&2
    write_log "INFO" "Выполнение от root: $*"
    "$@"
    return
  fi

  require_sudo
  printf '[INFO] Выполнение через обычный sudo: %s\n' "$*" >&2
  write_log "INFO" "Выполнение через обычный sudo: $*"
  sudo "$@"
}

run_sudo_quiet() {
  if [[ "${EUID}" -eq 0 ]]; then
    "$@"
    return
  fi

  require_sudo
  sudo "$@"
}

ensure_dir() {
  local dir="${1:?dir обязателен}"
  local mode="${2:-}"

  if [[ -d "${dir}" ]]; then
    return 0
  fi

  if [[ -n "${mode}" ]]; then
    run_sudo install -d -m "${mode}" "${dir}"
  else
    run_sudo install -d "${dir}"
  fi
}

backup_file_if_exists() {
  local file="${1:?file обязателен}"
  local ts
  local backup

  if [[ ! -f "${file}" ]]; then
    return 0
  fi

  ts="$(date '+%Y%m%d_%H%M%S')"
  backup="${file}.bak.${ts}"
  log_warn "Существующий файл будет сохранён в backup: ${file} -> ${backup}"
  run_sudo cp -a "${file}" "${backup}"
}

load_config_if_exists() {
  if [[ -f "${NAIT_ZTR_CONFIG_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${NAIT_ZTR_CONFIG_FILE}"
  fi
}

show_existing_config_if_any() {
  if [[ ! -f "${NAIT_ZTR_CONFIG_FILE}" ]]; then
    return 0
  fi

  log_warn "Найден существующий ZTR config: ${NAIT_ZTR_CONFIG_FILE}"
  run_sudo sed -E 's/(TOKEN|PASSWORD|SECRET)=.*/\1=***REDACTED***/' "${NAIT_ZTR_CONFIG_FILE}"
}

confirm_existing_config_change() {
  if [[ ! -f "${NAIT_ZTR_CONFIG_FILE}" ]]; then
    return 0
  fi

  show_existing_config_if_any
  confirm "Продолжить и обновить этот ZTR config после создания backup?" "N" || die "Отменено пользователем."
}

write_config_file() {
  local tmp_file="${1:?tmp file обязателен}"

  ensure_dir "${NAIT_ZTR_CONFIG_DIR}" "0750"
  backup_file_if_exists "${NAIT_ZTR_CONFIG_FILE}"
  run_sudo install -m 0640 "${tmp_file}" "${NAIT_ZTR_CONFIG_FILE}"
  log_info "Config сохранён: ${NAIT_ZTR_CONFIG_FILE}"
}

validate_ipv4() {
  local ip="${1:?ip обязателен}"
  python3 - "${ip}" <<'PY'
import ipaddress
import sys

try:
    ipaddress.IPv4Address(sys.argv[1])
except Exception:
    sys.exit(1)
PY
}

validate_cidr() {
  local cidr="${1:?cidr обязателен}"
  python3 - "${cidr}" <<'PY'
import ipaddress
import sys

try:
    ipaddress.IPv4Network(sys.argv[1], strict=False)
except Exception:
    sys.exit(1)
PY
}

ip_in_cidr() {
  local ip="${1:?ip обязателен}"
  local cidr="${2:?cidr обязателен}"
  python3 - "${ip}" "${cidr}" <<'PY'
import ipaddress
import sys

ip = ipaddress.IPv4Address(sys.argv[1])
network = ipaddress.IPv4Network(sys.argv[2], strict=False)
sys.exit(0 if ip in network else 1)
PY
}

first_usable_ip_from_cidr() {
  local cidr="${1:?cidr обязателен}"
  python3 - "${cidr}" <<'PY'
import ipaddress
import sys

network = ipaddress.IPv4Network(sys.argv[1], strict=False)
hosts = list(network.hosts())
if not hosts:
    sys.exit(1)
print(hosts[0])
PY
}

last_usable_ip_from_cidr() {
  local cidr="${1:?cidr обязателен}"
  python3 - "${cidr}" <<'PY'
import ipaddress
import sys

network = ipaddress.IPv4Network(sys.argv[1], strict=False)
hosts = list(network.hosts())
if not hosts:
    sys.exit(1)
print(hosts[-1])
PY
}

network_prefix_from_cidr() {
  local cidr="${1:?cidr обязателен}"
  python3 - "${cidr}" <<'PY'
import ipaddress
import sys

network = ipaddress.IPv4Network(sys.argv[1], strict=False)
print(network.prefixlen)
PY
}

recommended_client_range_for_cidr() {
  local cidr="${1:?cidr обязателен}"
  python3 - "${cidr}" <<'PY'
import ipaddress
import sys

network = ipaddress.IPv4Network(sys.argv[1], strict=False)
hosts = list(network.hosts())
if len(hosts) >= 99:
    print(f"{hosts[20]}-{hosts[98]}")
elif len(hosts) >= 2:
    print(f"{hosts[1]}-{hosts[-1]}")
else:
    print("")
PY
}

ip_in_recommended_client_range() {
  local ip="${1:?ip обязателен}"
  local cidr="${2:?cidr обязателен}"
  python3 - "${ip}" "${cidr}" <<'PY'
import ipaddress
import sys

ip = ipaddress.IPv4Address(sys.argv[1])
network = ipaddress.IPv4Network(sys.argv[2], strict=False)
hosts = list(network.hosts())
if len(hosts) >= 99:
    allowed = set(hosts[20:99])
else:
    allowed = set(hosts[1:])
sys.exit(0 if ip in allowed else 1)
PY
}

cidr_from_ip_assignment() {
  local ip_assignment="${1:?ip assignment обязателен}"
  python3 - "${ip_assignment}" <<'PY'
import ipaddress
import sys

try:
    interface = ipaddress.IPv4Interface(sys.argv[1])
except Exception:
    sys.exit(1)

print(interface.network.with_prefixlen)
PY
}

ip_without_prefix() {
  local ip_assignment="${1:?ip assignment обязателен}"
  python3 - "${ip_assignment}" <<'PY'
import ipaddress
import sys

try:
    interface = ipaddress.IPv4Interface(sys.argv[1])
except Exception:
    sys.exit(1)

print(interface.ip)
PY
}

next_available_client_ip() {
  local cidr="${1:?cidr обязателен}"
  shift

  python3 - "${cidr}" "$@" <<'PY'
import ipaddress
import sys

network = ipaddress.IPv4Network(sys.argv[1], strict=False)
used = {ipaddress.IPv4Address(value) for value in sys.argv[2:] if value}
hosts = list(network.hosts())

if len(hosts) >= 99:
    candidates = hosts[20:99]
else:
    candidates = hosts[1:]

for candidate in candidates:
    if candidate not in used:
        print(candidate)
        sys.exit(0)

sys.exit(1)
PY
}

json_escape() {
  local value="${1:-}"
  python3 - "${value}" <<'PY'
import json
import sys

print(json.dumps(sys.argv[1]))
PY
}
