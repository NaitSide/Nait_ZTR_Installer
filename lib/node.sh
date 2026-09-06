#!/usr/bin/env bash

install_client_interactive() {
  preflight_common
  install_zerotier
  ensure_zerotier_service

  cat <<EOF

Клиент ZeroTier установлен.
- Сервис zerotier-one: запущен
- Локальный Node ID: $(get_zt_node_id_quiet)

Следующий шаг:
  4) Подключить узел к сети ZeroTier (CLI)

EOF
}

join_network_interactive() {
  local network_id

  preflight_common
  is_zerotier_installed || die "ZeroTier не установлен. Сначала выберите пункт 2."
  ensure_zerotier_service

  if run_sudo_quiet test -d /var/lib/zerotier-one/controller.d; then
    log_error "Это хост с ZeroTier Controller."
    cat <<EOF

Пункт 4 запускается на узле, который хотите подключить к сети.
На этом Controller используйте пункт 5: Одобрить узел в сети ZeroTier (CLI).

EOF
    return 0
  fi

  network_id="$(prompt_with_default "Network ID" "")"
  while [[ ! "${network_id}" =~ ^[0-9a-fA-F]{16}$ ]]; do
    log_warn "Network ID должен состоять из 16 шестнадцатеричных символов."
    network_id="$(prompt_with_default "Network ID" "")"
  done

  zt_join_network "${network_id}"

  cat <<EOF

Запрос на вступление в сеть отправлен.
- Network ID: ${network_id}
- Node ID текущего узла: $(get_zt_node_id_quiet)

Для private-сети одобрите этот узел:
- в ZTNCUI на Controller; или
- пунктом 5 на Controller.

Оставьте это окно открытым и одобрите узел на Controller.

EOF

  if zt_network_has_assigned_ip "${network_id}"; then
    log_info "Узел подключён к сети ${network_id}; IP назначен."
    return 0
  fi

  if confirm "Ждать одобрение и назначение IP?" "Y"; then
    if zt_refresh_until_ip "${network_id}" 120 10; then
      log_info "Узел подключён к сети ${network_id}; IP назначен."
    else
      cat <<EOF

IP пока не назначен. Проверьте одобрение узла на Controller
или повторно откройте пункт 7: Статус.

EOF
    fi
  fi
}
