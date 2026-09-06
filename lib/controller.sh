#!/usr/bin/env bash

controller_api_available() {
  local token

  token="$(get_zt_token_quiet)"
  [[ -n "${token}" ]] || return 1
  curl -fsS --max-time 3 -H "X-ZT1-Auth: ${token}" "${ZT_LOCAL_API}/status" >/dev/null 2>&1
}

is_controller_host() {
  local network_ids=""

  if run_sudo_quiet test -f "${NAIT_ZTR_CONTROLLER_MARKER}"; then
    return 0
  fi

  is_zerotier_installed || return 1
  controller_api_available || return 1
  network_ids="$(list_controller_network_ids 2>/dev/null || true)"
  [[ -n "${network_ids}" ]]
}

wait_for_controller_api() {
  local attempt

  for attempt in {1..20}; do
    if controller_api_available; then
      [[ "${attempt}" -eq 1 ]] || printf '\n'
      return 0
    fi
    printf '.'
    sleep 1
  done

  printf '\n'
  return 1
}

enable_local_controller() {
  id zerotier-one >/dev/null 2>&1 || die "Системный пользователь zerotier-one не найден."
  run_sudo install -d -o zerotier-one -g zerotier-one -m 0700 /var/lib/zerotier-one/controller.d
  run_sudo systemctl restart zerotier-one
  wait_for_controller_api || die "Локальный API ZeroTier недоступен на ${ZT_LOCAL_API}."
  ensure_dir "${NAIT_ZTR_CONFIG_DIR}" "0750"
  run_sudo install -m 0640 /dev/null "${NAIT_ZTR_CONTROLLER_MARKER}"
}

require_controller_host() {
  is_controller_host \
    || die "[ОШИБКА] На этом хосте не установлен ZeroTier Controller. Сначала выберите пункт 1."
  controller_api_available \
    || die "[ОШИБКА] Локальный API ZeroTier Controller недоступен на ${ZT_LOCAL_API}."
}

install_controller_interactive() {
  preflight_common
  install_zerotier
  ensure_zerotier_service

  cat <<'EOF'

План развёртывания:
- ZeroTier One будет установлен и запущен.
- На этом хосте будет включён self-hosted ZeroTier Controller.
- Сеть сейчас не создаётся: используйте пункт 3 или ZTNCUI.
- Существующие сети и подключённые узлы не изменяются.

EOF
  confirm "Продолжить?" "N" || die "Отменено пользователем."

  enable_local_controller

  if confirm "Установить ZTNCUI (веб-интерфейс)?" "Y"; then
    install_ztncui
  fi

  cat <<'EOF'

Следующий шаг:
  Создайте сеть через ZTNCUI или пункт 3 этого меню.

EOF
}

create_network_interactive() {
  local network_name
  local network_cidr
  local controller_ip

  preflight_common
  require_controller_host

  network_name="$(prompt_with_default "Имя сети" "${NAIT_ZTR_DEFAULT_NETWORK_NAME}")"
  [[ -n "${network_name}" ]] || die "Имя сети не может быть пустым."

  while true; do
    network_cidr="$(prompt_with_default "Адрес сети (CIDR)" "${NAIT_ZTR_DEFAULT_NETWORK_CIDR}")"
    if validate_cidr "${network_cidr}"; then
      break
    fi
    log_warn "Некорректный адрес сети: ${network_cidr}"
  done

  controller_ip="$(first_usable_ip_from_cidr "${network_cidr}")" \
    || die "Для ${network_cidr} нет доступного IPv4-адреса."

  cat <<EOF

План создания сети:
- Имя: ${network_name}
- Адрес сети (CIDR): ${network_cidr}
- IP Controller: ${controller_ip}
- Автоматический пул адресов: ${controller_ip}–$(last_usable_ip_from_cidr "${network_cidr}")
- Сеть: private

EOF
  confirm "Создать сеть?" "N" || die "Создание сети отменено."

  create_network "${network_name}" "${network_cidr}" "${controller_ip}"
}

create_network() {
  local network_name="${1:?network name обязателен}"
  local network_cidr="${2:?network cidr обязателен}"
  local controller_ip="${3:?controller ip обязателен}"
  local controller_node_id
  local network_id
  local pool_end

  controller_node_id="$(get_zt_node_id_quiet)"
  pool_end="$(last_usable_ip_from_cidr "${network_cidr}")"
  network_id="$(create_controller_network)"
  [[ -n "${network_id}" ]] || die "Controller API не вернул Network ID."

  update_controller_network "${network_id}" "${network_name}" "${network_cidr}" "${controller_ip}" "${pool_end}" >/dev/null
  authorize_zt_node_with_ip "${network_id}" "${controller_node_id}" "${controller_ip}" >/dev/null
  zt_join_network "${network_id}"

  cat <<EOF

Сеть создана.
- Network ID: ${network_id}
- Имя: ${network_name}
- Адрес сети: ${network_cidr}
- IP Controller: ${controller_ip}

EOF
}
