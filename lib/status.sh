#!/usr/bin/env bash

status_separator() {
  printf '%s\n' '------------------------------------------------------------'
}

status_get_zt_node_id() {
  run_sudo_quiet zerotier-cli info | awk '{print $3}'
}

status_list_networks() {
  run_sudo_quiet zerotier-cli listnetworks || true
}

status_has_ztr_network() {
  local networks_output="${1:-}"

  printf '%s\n' "${networks_output}" | awk '
    $1 == "200" && $2 == "listnetworks" && $3 ~ /^[0-9a-fA-F]{16}$/ {
      found = 1
    }
    END {exit found ? 0 : 1}
  '
}

status_infer_ztr_role() {
  local networks_output="${1:-}"
  local core_ip="${NAIT_ZTR_CORE_IP:-${NAIT_ZTR_DEFAULT_CORE_IP}}"

  if is_controller_host; then
    echo "ZeroTier Controller"
    return 0
  fi

  if [[ -n "${NAIT_ZTR_ROLE:-}" ]]; then
    echo "${NAIT_ZTR_ROLE}"
    return 0
  fi

  printf '%s\n' "${networks_output}" | awk -v core_ip="${core_ip}" '
    $1 == "200" && $2 == "listnetworks" && $3 ~ /^[0-9a-fA-F]{16}$/ {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+$/) {
          split($i, parts, "/")
          if (parts[1] == core_ip) {
            print "ZeroTier Controller"
            exit
          }
          role = "ZeroTier node"
        }
      }
    }
    END {
      if (role != "") {
        print role
      }
    }
  '
}

status_print_zerotier_block() {
  local node_id="${1:-}"
  local inferred_role="${2:-неизвестно}"
  local id_label="Локальный NODE_ID"
  local service_state="недоступен"
  local service_substate=""

  if [[ "${inferred_role}" == "ZeroTier Controller" ]]; then
    id_label="Controller ID"
  fi

  echo "ZeroTier:"
  if ! is_zerotier_installed; then
    echo "- Роль: ${inferred_role:-неизвестно}"
    echo "- Установлен: нет"
    echo "- Сервис: недоступен"
    echo "- ${id_label}: не удалось определить"
    return 0
  fi

  if command -v systemctl >/dev/null 2>&1; then
    service_state="$(systemctl is-active zerotier-one 2>/dev/null || true)"
    service_substate="$(systemctl show -p SubState --value zerotier-one 2>/dev/null || true)"
    if [[ -n "${service_substate}" && "${service_state}" != "${service_substate}" ]]; then
      service_state="${service_state}/${service_substate}"
    fi
  fi

  echo "- Роль: ${inferred_role:-неизвестно}"
  echo "- Установлен: да"
  echo "- Сервис: ${service_state:-неизвестно}"
  echo "- ${id_label}: ${node_id:-не удалось определить}"
}

status_print_processed_ztr_block() {
  local networks_output="${1:-}"
  local inferred_role="${2:-неизвестно}"
  local network_count
  local missing_network_text="Сеть ZeroTier: не подключена"

  if [[ "${inferred_role}" == "ZeroTier Controller" ]]; then
    missing_network_text="Сеть ZeroTier: не создана"
  fi

  if ! is_zerotier_installed; then
    echo "${missing_network_text}"
    return 0
  fi

  if ! printf '%s\n' "${networks_output}" | awk '$1 == "200" && $2 == "listnetworks" && $3 ~ /^[0-9a-fA-F]{16}$/ {found=1} END {exit found ? 0 : 1}'; then
    echo "${missing_network_text}"
    return 0
  fi

  network_count="$(printf '%s\n' "${networks_output}" | awk '$1 == "200" && $2 == "listnetworks" && $3 ~ /^[0-9a-fA-F]{16}$/ {count++} END {print count + 0}')"

  printf '%s\n' "${networks_output}" | awk '
    function is_mac(value) {
      return value ~ /^[0-9a-fA-F]{2}(:[0-9a-fA-F]{2}){5}$/
    }
    BEGIN {
      total = '"${network_count}"'
    }
    $1 == "200" && $2 == "listnetworks" && $3 ~ /^[0-9a-fA-F]{16}$/ {
      count++
      network_id = $3
      if (is_mac($4)) {
        name = "ещё не получено"
        mac = $4
        status = (NF >= 5 ? $5 : "неизвестно")
        type = (NF >= 6 ? $6 : "неизвестно")
        zt_interface = (NF >= 7 ? $7 : "неизвестно")
        ip_start = 8
      } else {
        name = (NF >= 4 ? $4 : "неизвестно")
        mac = (NF >= 5 ? $5 : "неизвестно")
        status = (NF >= 6 ? $6 : "неизвестно")
        type = (NF >= 7 ? $7 : "неизвестно")
        zt_interface = (NF >= 8 ? $8 : "неизвестно")
        ip_start = 9
      }

      ips = ""
      for (ip in seen_ips) {
        delete seen_ips[ip]
      }

      for (i = ip_start; i <= NF; i++) {
        if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+$/ && !seen_ips[$i]) {
          seen_ips[$i] = 1
          ips = ips (ips == "" ? "" : ", ") $i
        }
      }

      if (ips == "") {
        ips = "не назначены"
      }

      if (total > 1) {
        print "Сеть ZTR #" count ":"
      } else {
        print "Сеть ZTR:"
      }
      print "- Network ID: " network_id
      print "- Имя сети: " name
      print "- Статус: " status
      print "- Тип: " type
      print "- Интерфейс: " zt_interface
      print "- MAC: " mac
      print "- IP: " ips
      print ""
    }
  '
}

status_print_ztncui_block() {
  local service_state=""
  local version=""

  echo "ZTNCUI:"

  if [[ ! -f "/etc/systemd/system/${NAIT_ZTNCUI_SERVICE}" ]] \
    && [[ ! -f "/lib/systemd/system/${NAIT_ZTNCUI_SERVICE}" ]] \
    && [[ ! -f "/usr/lib/systemd/system/${NAIT_ZTNCUI_SERVICE}" ]]; then
    echo "- Статус: не установлен"
    return 0
  fi

  service_state="$(systemctl is-active "${NAIT_ZTNCUI_SERVICE}" 2>/dev/null || true)"
  version="$(get_installed_ztncui_version 2>/dev/null || true)"
  echo "- Статус: ${service_state:-неизвестно}"
  echo "- Версия: ${version:-не удалось определить}"
  if [[ "${service_state}" == "active" ]]; then
    echo "- Веб-интерфейс доступен: http://127.0.0.1:3000 (после прокидывания SSH-туннеля)"
  else
    echo "- Веб-интерфейс недоступен: сервис не запущен"
  fi
}

status_print_ufw_block() {
  local ufw_output=""
  local ufw_status="недоступен"
  local incoming_policy="неизвестно"

  echo "UFW:"
  if ! command -v ufw >/dev/null 2>&1; then
    echo "- Статус: не установлен"
    echo "- Политика входящих: неизвестно"
    echo "- Разрешённые правила: нет данных"
    return 0
  fi

  ufw_output="$(run_sudo_quiet ufw status verbose || true)"
  ufw_status="$(printf '%s\n' "${ufw_output}" | awk -F': ' '/^Status:/ {print $2; exit}')"
  incoming_policy="$(printf '%s\n' "${ufw_output}" | awk -F': ' '
    /^Default:/ {
      split($2, parts, ",")
      gsub(/^ +| +$/, "", parts[1])
      sub(/ .*/, "", parts[1])
      print parts[1]
      exit
    }
  ')"

  echo "- Статус: ${ufw_status:-неизвестно}"
  echo "- Политика входящих: ${incoming_policy:-неизвестно}"
  echo "- Разрешённые правила:"

  if ! printf '%s\n' "${ufw_output}" | awk '
    /(ALLOW|LIMIT) IN/ {
      line = $0
      gsub(/[[:space:]]+/, " ", line)
      gsub(/^ +| +$/, "", line)
      print "  - " line
      found = 1
    }
    END {exit found ? 0 : 1}
  '; then
    echo "  - нет"
  fi
}

show_status() {
  local node_id=""
  local networks_output=""
  local inferred_role="неизвестно"

  if is_zerotier_installed; then
    node_id="$(status_get_zt_node_id || true)"
    networks_output="$(status_list_networks)"
  fi

  if [[ -f "${NAIT_ZTR_CONFIG_FILE}" ]]; then
    load_config_if_exists
  fi
  inferred_role="$(status_infer_ztr_role "${networks_output}")"
  inferred_role="${inferred_role:-неизвестно}"

  status_separator
  echo "Статус ZTR Installer"
  status_separator
  echo

  status_print_zerotier_block "${node_id}" "${inferred_role}"
  echo

  status_print_processed_ztr_block "${networks_output}" "${inferred_role}"
  echo
  status_print_ztncui_block
  echo
  status_print_ufw_block
  echo

  status_separator
}
