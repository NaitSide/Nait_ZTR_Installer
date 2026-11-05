#!/usr/bin/env bash

# A separate Bash process keeps errexit active inside the individual masters.
# Cancel/error stops this workflow without closing the parent menu.
vpn_edition_interactive() {
  if bash "${REPO_ROOT}/install.sh" vpn-edition-run; then
    return 0
  else
    log_warn "VPN Edition остановлен. Успешно выполненные этапы сохранены."
    return 0
  fi
}

vpn_select_network() {
  local ids network name selection index=0
  local -a networks=()
  ids="$(list_controller_network_ids)"
  if [[ -n "${ids}" ]]; then
    printf '\nВыберите существующую сеть или создайте новую:\n'
    while IFS= read -r network; do
      [[ "${network}" =~ ^[0-9a-f]{16}$ ]] || die "Controller вернул некорректный Network ID."
      networks+=("${network}")
      index=$((index + 1))
      name="$(zt_api_get "/controller/network/${network}" | jq -r '.name // "(без имени)"')"
      printf '%s) %s — %s\n' "${index}" "${name}" "${network}"
    done <<< "${ids}"
    echo '0) Создать новую сеть'
    while true; do
      selection="$(prompt_with_default "Номер сети (q — отмена)" "1")"
      [[ "${selection}" != q ]] || die "Выбор сети отменён."
      [[ "${selection}" != 0 ]] || break
      if [[ "${selection}" =~ ^[0-9]{1,3}$ ]] && (( 10#${selection} >= 1 && 10#${selection} <= index )); then
        NAIT_ZTR_VPN_NETWORK="${networks[$((10#${selection} - 1))]}"
        return 0
      fi
      log_warn "Введите номер сети, 0 или q."
    done
  fi
  NAIT_ZTR_CREATED_NETWORK_ID=""
  create_network_interactive ZTR_VPN
  [[ "${NAIT_ZTR_CREATED_NETWORK_ID}" =~ ^[0-9a-f]{16}$ ]] || die "Сеть не создана."
  NAIT_ZTR_VPN_NETWORK="${NAIT_ZTR_CREATED_NETWORK_ID}"
}

vpn_configure_dns() {
  local network="${1:?Network ID обязателен}" plan expected
  plan="$(run_sudo_quiet python3 "${REPO_ROOT}/lib/vpn_dns.py" plan --network "${network}")"
  expected="$(jq -c '.dns' <<< "${plan}")"
  if [[ "$(jq -r '.conflict' <<< "${plan}")" == true ]]; then
    jq -r '"Текущие DNS сети: " + (.dns.servers | join(", "))' <<< "${plan}"
    if ! confirm "Заменить DNS этой сети на 8.8.8.8 и 1.1.1.1?" "N"; then
      log_info "Существующие DNS сети сохранены."
      return 0
    fi
  fi
  run_sudo_quiet python3 "${REPO_ROOT}/lib/vpn_dns.py" apply --network "${network}" --expected-dns "${expected}" >/dev/null
  log_info "DNS сети: 8.8.8.8 и 1.1.1.1."
  echo 'На клиенте рекомендуется включить Allow DNS Configuration.'
}

vpn_edition_run() {
  local state replace=no
  preflight_common
  log_info "VPN Edition — этап 1/4: Controller (пункт 1)."
  if is_controller_host; then
    require_controller_host
    log_info "Controller уже установлен."
    if ! ztncui_container_exists && ! native_ztncui_is_installed; then
      if confirm "Установить ZTNCUI (веб-интерфейс)?" "Y"; then
        install_ztncui
      fi
    fi
  else
    install_controller_interactive
    require_controller_host
  fi
  log_info "VPN Edition — этап 2/4: сеть (пункт 3)."
  vpn_select_network
  log_info "VPN Edition — этап 3/4: резервная Moon (пункт 7)."
  configure_moon_interactive
  run_sudo_quiet test -f "${NAIT_ZTR_MOON_CONFIG_FILE}" || die "Moon не создана."
  log_info "VPN Edition — этап 4/4: шлюз (пункт 8)."
  state="$(gateway_backend status)"
  if [[ "$(jq -r '.configured' <<< "${state}")" == true ]]; then
    replace=yes
  fi
  gateway_setup_interactive "${replace}" "${NAIT_ZTR_VPN_NETWORK}"
  [[ "${NAIT_ZTR_GATEWAY_COMPLETED:-0}" == 1 ]] || die "Настройка шлюза не завершена."
  vpn_configure_dns "${NAIT_ZTR_VPN_NETWORK}"
  log_info "VPN Edition: серверная настройка завершена."
}
