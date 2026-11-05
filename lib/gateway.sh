#!/usr/bin/env bash

gateway_backend() {
  run_sudo_quiet python3 "${REPO_ROOT}/lib/gateway.py" "$@"
}

gateway_print_status() {
  local state
  echo "Шлюз ZeroTier (IPv4):"
  if ! command -v python3 >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    echo "- Для проверки требуются python3 и jq."
    return 0
  fi
  if ! state="$(gateway_backend status)"; then
    echo "- Не удалось проверить состояние шлюза."
    return 0
  fi
  if [[ "$(jq -r '.configured' <<< "${state}")" != true ]]; then
    echo "- Не настроен."
    return 0
  fi
  jq -r '"- Сеть: \(.network)", "- Адрес шлюза: \(.gateway)", "- Подсеть: \(.subnet)", "- Интерфейсы: \(.zt_interface) → \(.wan_interface)", "- Служба активна: \(.active)", "- Правила на месте: \(.rules_present)", "- IPv4 forwarding: \(.ipv4_forwarding)"' <<< "${state}"
}

gateway_setup_interactive() {
  local replace="${1:-no}" choices selection count network="${2:-}" plan wan
  local -a apply_flags=()
  NAIT_ZTR_GATEWAY_COMPLETED=0
  if ! choices="$(gateway_backend networks)"; then
    return 0
  fi
  if [[ -z "${network}" ]]; then
    count="$(jq 'length' <<< "${choices}")"
    printf '\nВыберите сеть для выхода в интернет:\n'
    jq -r 'to_entries[] | "\(.key + 1)) \(.value.name) — \(.value.id), \(.value.status)" + (if .value.status == "NOT_JOINED" then " (этот VPS ещё не подключён к выбранной сети ZeroTier как участник)" else "" end)' <<< "${choices}"
    while true; do
      selection="$(prompt_with_default "Номер сети (0 — назад)" "1")"
      [[ "${selection}" == 0 ]] && return 0
      if [[ "${selection}" =~ ^[0-9]{1,3}$ ]] && (( 10#${selection} >= 1 && 10#${selection} <= count )); then
        break
      fi
      log_warn "Введите номер сети из списка."
    done
    network="$(jq -r --argjson i "$((10#${selection} - 1))" '.[$i].id' <<< "${choices}")"
  fi
  if ! plan="$(gateway_backend plan --network "${network}")"; then
    return 0
  fi
  wan="$(prompt_with_default "Внешний интерфейс для выхода в интернет" "$(jq -r '.wan_interface' <<< "${plan}")")"
  if ! plan="$(gateway_backend plan --network "${network}" --wan "${wan}")"; then
    return 0
  fi
  printf '\nПлан настройки шлюза:\n'
  jq -r '"- Сеть: \(.name) (\(.network))", "- Адрес шлюза: \(.gateway)", "- Подсеть: \(.subnet)", "- Внешний интерфейс: \(.wan_interface)"' <<< "${plan}"
  if [[ "$(jq -r '.controller' <<< "${plan}")" == true ]]; then
    echo "- Текущий VPS будет подключён к выбранной сети и авторизован с адресом шлюза."
    echo "- Маршрут 0.0.0.0/0 через адрес шлюза будет настроен автоматически."
  else
    echo "- Будет использован уже назначенный этому узлу адрес шлюза."
  fi
  cat <<'EOF'
- Будут включены IPv4 forwarding, NAT и правила прохода из выбранной ZeroTier-сети в интернет.
- Правила сохранятся после перезагрузки. Существующие правила Docker, UFW и SSH сохраняются.
- Для самого шлюза Allow Default будет выключен, чтобы он выходил через провайдера.
- Настройки удалённых клиентов автоматически не меняются.
- Поддерживается IPv4. IPv6 и DNS этим пунктом не настраиваются.
EOF
  [[ "${replace}" != yes ]] || echo "- Прежняя настройка шлюза будет заменена; при ошибке будет предпринято её восстановление."
  if [[ "$(jq -r '.default_conflict' <<< "${plan}")" == true ]]; then
    jq -r '.current_defaults[] | "Текущий маршрут: \(.target) → \(.via // "без шлюза")"' <<< "${plan}"
    confirm "Заменить существующий маршрут по умолчанию этой сети?" "N" || return 0
    apply_flags+=(--replace-default)
  fi
  confirm "Применить этот план?" "N" || return 0
  if [[ "${replace}" == yes ]]; then
    if ! gateway_backend apply --network "${network}" --wan "${wan}" --replace "${apply_flags[@]}" >/dev/null; then
      return 0
    fi
  elif ! gateway_backend apply --network "${network}" --wan "${wan}" "${apply_flags[@]}" >/dev/null; then
    return 0
  fi
  gateway_print_status
  NAIT_ZTR_GATEWAY_COMPLETED=1
  if [[ "$(jq -r '.controller' <<< "${plan}")" == true ]] && ztncui_container_exists; then
    log_info "Заполняю пустое имя VPS в ZTNCUI; при изменении будет перезапущена только веб-панель."
    run_sudo_quiet python3 "${REPO_ROOT}/lib/panel_name.py" "$(jq -r '.node' <<< "${plan}")" >/dev/null \
      || log_warn "Имя VPS можно задать вручную в ZTNCUI. Шлюз настроен."
  fi
  cat <<EOF

Шлюз настроен. Network ID: ${network}
На клиенте: подключитесь к сети, одобрите устройство и включите Allow Default Route Override.

EOF
  if [[ "$(jq -r '.controller' <<< "${plan}")" != true ]]; then
    echo "На удалённом Controller добавьте маршрут 0.0.0.0/0 через $(jq -r '.gateway' <<< "${plan}")."
  fi
}

configure_gateway_interactive() {
  local state choice message command_name
  for command_name in python3 jq; do
    if ! command -v "${command_name}" >/dev/null 2>&1; then
      log_error "Для мастера шлюза требуется ${command_name}. Установите зависимости, затем повторите пункт 8."
      return 0
    fi
  done
  if ! state="$(gateway_backend status)"; then
    return 0
  fi
  if [[ "$(jq -r '.configured' <<< "${state}")" != true ]]; then
    gateway_setup_interactive
    return 0
  fi
  gateway_print_status
  cat <<'EOF'

1) Проверить и восстановить правила текущего шлюза
2) Изменить настройку шлюза
3) Отключить шлюз
0) Назад
EOF
  choice="$(prompt_with_default "Действие" "0")"
  case "${choice}" in
    1)
      gateway_setup_interactive no "$(jq -r '.network' <<< "${state}")"
      ;;
    2) gateway_setup_interactive yes ;;
    3)
      echo "Перед отключением выключите Allow Default на клиентах или смените шлюз в Routes."
      confirm "Удалить только правила шлюза этого установщика?" "N" || return 0
      if message="$(gateway_backend disable)"; then
        jq -r '.message' <<< "${message}"
      fi
      ;;
    0) ;;
    *) log_warn "Неизвестное действие." ;;
  esac
  return 0
}
