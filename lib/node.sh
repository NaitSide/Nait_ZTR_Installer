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

Проверка состояния:
  sudo zerotier-cli listnetworks

EOF
}
