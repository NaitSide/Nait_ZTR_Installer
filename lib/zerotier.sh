#!/usr/bin/env bash

is_zerotier_installed() {
  command -v zerotier-cli >/dev/null 2>&1
}

find_offline_zerotier_package() {
  local package_dir="${NAIT_ZTR_OFFLINE_DIR}"
  local system_arch
  local package
  local package_name
  local package_arch

  [[ -d "${package_dir}" ]] || return 1
  command -v dpkg-deb >/dev/null 2>&1 || return 1

  system_arch="$(dpkg --print-architecture)"
  while IFS= read -r package; do
    package_name="$(dpkg-deb -f "${package}" Package 2>/dev/null || true)"
    package_arch="$(dpkg-deb -f "${package}" Architecture 2>/dev/null || true)"
    if [[ "${package_name}" == "zerotier-one" && ( "${package_arch}" == "${system_arch}" || "${package_arch}" == "all" ) ]]; then
      printf '%s\n' "${package}"
      return 0
    fi
  done < <(find "${package_dir}" -maxdepth 1 -type f -name 'zerotier-one_*.deb' -print | sort -Vr)

  return 1
}

verify_offline_zerotier_package() {
  local package="${1:?package обязателен}"
  local package_dir
  local package_name
  local checksum_file

  package_dir="$(dirname "${package}")"
  package_name="$(basename "${package}")"
  checksum_file="${package_dir}/SHA256SUMS"

  command -v sha256sum >/dev/null 2>&1 || die "sha256sum обязателен для проверки offline package."
  [[ -f "${checksum_file}" ]] || die "Для offline package отсутствует SHA256SUMS: ${checksum_file}"
  if ! (cd "${package_dir}" && sha256sum --check --status --ignore-missing SHA256SUMS && grep -Fq "  ${package_name}" SHA256SUMS); then
    die "SHA-256 offline package не совпадает: ${package}"
  fi
}

install_zerotier() {
  local offline_package
  local offline_install_dir
  local offline_install_package
  local installer_file

  if is_zerotier_installed; then
    log_info "ZeroTier уже установлен."
    return 0
  fi

  log_warn "ZeroTier не установлен."

  offline_package="$(find_offline_zerotier_package || true)"
  if [[ -n "${offline_package}" ]]; then
    verify_offline_zerotier_package "${offline_package}"
    log_info "Установка ZeroTier из локального offline package: ${offline_package}"
    offline_install_dir="$(mktemp -d)"
    chmod 0755 "${offline_install_dir}"
    offline_install_package="${offline_install_dir}/$(basename "${offline_package}")"
    install -m 0644 "${offline_package}" "${offline_install_package}"
    if ! run_sudo apt-get install -y "${offline_install_package}"; then
      rm -f "${offline_install_package}"
      rmdir "${offline_install_dir}"
      die "Не удалось установить локальный package ZeroTier."
    fi
    rm -f "${offline_install_package}"
    rmdir "${offline_install_dir}"
    is_zerotier_installed || die "Локальный package установлен, но zerotier-cli не найден."
    return 0
  fi

  log_info "Локальный package ZeroTier не найден. Автоматическая установка с официального сервера."
  installer_file="$(mktemp)"
  if ! curl -fsSL https://install.zerotier.com -o "${installer_file}"; then
    rm -f "${installer_file}"
    die "Официальный сервер ZeroTier недоступен. Добавьте .deb в ${NAIT_ZTR_OFFLINE_DIR}/."
  fi
  run_sudo bash "${installer_file}"
  rm -f "${installer_file}"
  is_zerotier_installed || die "Официальный installer завершился, но zerotier-cli не найден."
}

ensure_zerotier_service() {
  log_info "Включение и запуск zerotier-one."
  run_sudo_quiet systemctl enable zerotier-one >/dev/null 2>&1 \
    || die "Не удалось включить автозапуск zerotier-one."
  run_sudo_quiet systemctl start zerotier-one >/dev/null 2>&1 \
    || die "Не удалось запустить zerotier-one."

  local attempt
  for attempt in {1..20}; do
    if get_zt_node_id >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done

  die "ZeroTier identity не была создана вовремя."
}

get_zt_node_id() {
  run_sudo zerotier-cli info | awk '{print $3}'
}

get_zt_node_id_quiet() {
  run_sudo_quiet zerotier-cli info | awk '{print $3}'
}

get_zt_token() {
  run_sudo cat /var/lib/zerotier-one/authtoken.secret
}

get_zt_token_quiet() {
  run_sudo_quiet cat /var/lib/zerotier-one/authtoken.secret
}

zt_api_get() {
  local path="${1:?API path обязателен}"
  local token
  token="$(get_zt_token_quiet)"
  curl -sS \
    -H "X-ZT1-Auth: ${token}" \
    "${ZT_LOCAL_API}${path}"
}

zt_api_post() {
  local path="${1:?API path обязателен}"
  local payload="${2:?payload обязателен}"
  local token
  token="$(get_zt_token_quiet)"
  curl -sS -X POST \
    -H "X-ZT1-Auth: ${token}" \
    -H "Content-Type: application/json" \
    -d "${payload}" \
    "${ZT_LOCAL_API}${path}"
}

list_controller_network_ids() {
  zt_api_get "/controller/network" | jq -r '
    if type == "array" then
      .[] | if type == "string" then . else (.nwid // .id // empty) end
    elif type == "object" then
      keys[]
    else
      empty
    end
  '
}

zt_join_network() {
  local network_id="${1:?network id обязателен}"
  local response

  response="$(run_sudo_quiet zerotier-cli join "${network_id}")"
  if [[ "${NAIT_ZTR_DEBUG:-}" == "1" ]]; then
    printf '%s\n' "${response}"
  fi
}

zt_list_networks() {
  run_sudo zerotier-cli listnetworks
}

zt_list_networks_quiet() {
  run_sudo_quiet zerotier-cli listnetworks
}

zt_get_network_status() {
  local network_id="${1:?network id обязателен}"
  zt_list_networks | awk -v nwid="${network_id}" '$3 == nwid {print $6}'
}

zt_get_interface_name_for_network() {
  local network_id="${1:?network id обязателен}"
  zt_list_networks | awk -v nwid="${network_id}" '$3 == nwid {print $8}'
}

zt_network_has_assigned_ip() {
  local network_id="${1:?network id обязателен}"
  local line

  line="$(zt_list_networks_quiet | awk -v nwid="${network_id}" '$3 == nwid {print}')"
  [[ "${line}" == *" OK "* && "${line}" =~ ([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2} ]]
}

zt_wait_for_ip() {
  local network_id="${1:?network id обязателен}"
  local timeout_seconds="${2:-60}"
  local elapsed=0
  local interval=10
  local display_elapsed
  local line

  log_info "Ожидание IP."
  while [[ "${elapsed}" -lt "${timeout_seconds}" ]]; do
    line="$(zt_list_networks_quiet | awk -v nwid="${network_id}" '$3 == nwid {print}')"
    if [[ "${line}" == *" OK "* && "${line}" =~ ([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2} ]]; then
      return 0
    fi

    if [[ "${line}" == *"ACCESS_DENIED"* ]]; then
      log_warn "ZeroTier ответил ACCESS_DENIED. Проверьте, что этот узел одобрен на Controller."
    elif [[ "${line}" == *"REQUESTING_CONFIGURATION"* ]]; then
      display_elapsed=$((elapsed + interval))
      if [[ "${display_elapsed}" -gt "${timeout_seconds}" ]]; then
        display_elapsed="${timeout_seconds}"
      fi
      log_info "Ожидание IP. (${display_elapsed}/${timeout_seconds} сек)"
    fi

    sleep "${interval}"
    elapsed=$((elapsed + interval))
  done

  log_warn "Истекло время ожидания назначенного ZTR IP (${timeout_seconds} сек)."
  return 1
}

zt_refresh_until_ip() {
  local network_id="${1:?network id обязателен}"
  local timeout_seconds="${2:-60}"
  local interval="${3:-10}"
  local elapsed=0

  while [[ "${elapsed}" -lt "${timeout_seconds}" ]]; do
    log_info "Обновляю состояние ZeroTier."
    run_sudo_quiet systemctl restart zerotier-one

    sleep "${interval}"
    elapsed=$((elapsed + interval))

    if zt_network_has_assigned_ip "${network_id}"; then
      return 0
    fi

    log_info "Ожидание IP. (${elapsed}/${timeout_seconds} сек)"
  done

  log_warn "Истекло время ожидания назначенного ZTR IP (${timeout_seconds} сек)."
  return 1
}

create_controller_network() {
  local response
  response="$(zt_api_post "/controller/network/$(get_zt_node_id)______" "{}")"
  printf '%s\n' "${response}" | jq -r '.nwid // .id // empty'
}

update_controller_network() {
  local network_id="${1:?network id обязателен}"
  local network_name="${2:?network name обязательно}"
  local cidr="${3:?cidr обязателен}"
  local pool_start="${4:?pool start обязателен}"
  local pool_end="${5:?pool end обязателен}"
  local network_name_json
  local cidr_json
  local pool_start_json
  local pool_end_json
  local payload

  network_name_json="$(json_escape "${network_name}")"
  cidr_json="$(json_escape "${cidr}")"
  pool_start_json="$(json_escape "${pool_start}")"
  pool_end_json="$(json_escape "${pool_end}")"

  payload="$(cat <<JSON
{
  "name": ${network_name_json},
  "private": true,
  "enableBroadcast": true,
  "v4AssignMode": {
    "zt": true
  },
  "routes": [
    {
      "target": ${cidr_json},
      "via": null
    }
  ],
  "ipAssignmentPools": [
    {
      "ipRangeStart": ${pool_start_json},
      "ipRangeEnd": ${pool_end_json}
    }
  ]
}
JSON
)"

  zt_api_post "/controller/network/${network_id}" "${payload}"
}

authorize_zt_node_with_ip() {
  local network_id="${1:?network id обязателен}"
  local node_id="${2:?node id обязателен}"
  local ip="${3:?ip обязателен}"
  local ip_json
  local payload

  ip_json="$(json_escape "${ip}")"
  payload="$(cat <<JSON
{
  "authorized": true,
  "noAutoAssignIps": true,
  "ipAssignments": [
    ${ip_json}
  ]
}
JSON
)"

  zt_api_post "/controller/network/${network_id}/member/${node_id}" "${payload}"
}

authorize_zt_node() {
  local network_id="${1:?network id обязателен}"
  local node_id="${2:?node id обязателен}"

  zt_api_post "/controller/network/${network_id}/member/${node_id}" '{"authorized":true}'
}
