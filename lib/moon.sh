#!/usr/bin/env bash

detect_public_ipv4() {
  local route_ip=""
  local detected_ip=""

  route_ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "src") {print $(i + 1); exit}}' || true)"
  if [[ -n "${route_ip}" ]] && python3 - "${route_ip}" <<'PY'
import ipaddress
import sys

try:
    address = ipaddress.IPv4Address(sys.argv[1])
except Exception:
    sys.exit(1)

sys.exit(0 if address.is_global else 1)
PY
  then
    printf '%s\n' "${route_ip}"
    return 0
  fi

  detected_ip="$(curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  if [[ -z "${detected_ip}" ]]; then
    detected_ip="$(curl -4fsS --max-time 5 https://checkip.amazonaws.com 2>/dev/null || true)"
  fi
  detected_ip="$(normalize_user_input "${detected_ip}")"

  if [[ -n "${detected_ip}" ]] && validate_ipv4 "${detected_ip}"; then
    printf '%s\n' "${detected_ip}"
    return 0
  fi

  return 1
}

moon_id_is_valid() {
  [[ "${1:-}" =~ ^[0-9a-fA-F]{10}$ ]]
}

moon_public_filename() {
  local moon_id="${1:?moon id обязателен}"
  printf '000000%s.moon\n' "${moon_id,,}"
}

moon_export_dir() {
  printf '%s/Nait_ZTR_Moon\n' "${HOME:-/root}"
}

moon_list_ids() {
  is_zerotier_installed || return 0
  run_sudo_quiet zerotier-cli listmoons 2>/dev/null | awk '
    {
      for (i = 1; i <= NF; i++) {
        value = tolower($i)
        if (value ~ /^000000[0-9a-f]{10}$/) {
          print substr(value, 7)
        } else if (value ~ /^[0-9a-f]{10}$/) {
          print value
        }
      }
    }
  ' | sort -u
}

moon_is_listed() {
  local moon_id="${1:?moon id обязателен}"
  moon_list_ids | grep -Fqx "${moon_id,,}"
}

wait_for_moon() {
  local moon_id="${1:?moon id обязателен}"
  local attempt

  for attempt in {1..15}; do
    if moon_is_listed "${moon_id}"; then
      return 0
    fi
    sleep 1
  done

  return 1
}

zt_root_peer_rows() {
  is_zerotier_installed || return 0
  run_sudo_quiet zerotier-cli -j listpeers 2>/dev/null | jq -r '
    .[]?
    | (.role // "" | ascii_upcase) as $role
    | select($role == "MOON" or $role == "PLANET")
    | [
        $role,
        ((.address // .id // "неизвестно") | tostring | ascii_downcase),
        (.paths[0].address // .path // "")
      ]
    | @tsv
  '
}

print_root_connectivity_summary() {
  local configured_moons=""
  local root_rows=""
  local role=""
  local peer_id=""
  local path=""
  local moon_count=0
  local planet_count=0

  echo "Связь с Root-серверами:"
  if ! is_zerotier_installed; then
    echo "- ZeroTier не установлен"
    return 0
  fi

  configured_moons="$(moon_list_ids || true)"
  root_rows="$(zt_root_peer_rows || true)"

  while IFS=$'\t' read -r role peer_id path; do
    [[ -n "${role}" ]] || continue
    case "${role}" in
      MOON)
        moon_count=$((moon_count + 1))
        ;;
      PLANET)
        planet_count=$((planet_count + 1))
        ;;
    esac
  done <<< "${root_rows}"

  if run_sudo_quiet test -f "${NAIT_ZTR_MOON_CONFIG_FILE}"; then
    echo "- Резервная Moon: размещена на этом Controller"
  elif [[ -z "${configured_moons}" ]]; then
    echo "- Резервная Moon: не настроена"
  elif [[ "${moon_count}" -gt 0 ]]; then
    echo "- Резервная Moon: доступна (${moon_count} активн. root-пир.)"
  else
    echo "- Резервная Moon: настроена, активная связь пока не обнаружена"
  fi

  if [[ "${planet_count}" -gt 0 ]]; then
    echo "- Официальная Planet: доступна (${planet_count} активн. root-пир.)"
  else
    echo "- Официальная Planet: активные root-пиры сейчас не обнаружены"
  fi

  echo "- Moon помогает найти Controller; трафик между узлами после подключения идёт напрямую."
}

controller_moon_id() {
  run_sudo_quiet jq -r '.id // empty' "${NAIT_ZTR_MOON_CONFIG_FILE}" 2>/dev/null
}

controller_moon_endpoint() {
  run_sudo_quiet jq -r '.roots[0].stableEndpoints[0] // empty' "${NAIT_ZTR_MOON_CONFIG_FILE}" 2>/dev/null
}

show_existing_controller_moon() {
  local moon_id
  local endpoint
  local public_file

  moon_id="$(controller_moon_id)"
  endpoint="$(controller_moon_endpoint)"
  [[ -n "${moon_id}" ]] || die "Сохранённая конфигурация Moon повреждена: ${NAIT_ZTR_MOON_CONFIG_FILE}"
  public_file="${NAIT_ZTR_MOON_CONFIG_DIR}/$(moon_public_filename "${moon_id}")"

  cat <<EOF

Резервная Moon уже создана.
- Moon ID: ${moon_id}
- Endpoint: ${endpoint:-не удалось определить}
- Публичный файл: ${public_file}

EOF
}

open_moon_ufw_port_if_needed() {
  local ufw_status=""

  command -v ufw >/dev/null 2>&1 || return 0
  ufw_status="$(run_sudo_quiet ufw status 2>/dev/null | awk -F': ' '/^Status:/ {print $2; exit}' || true)"
  [[ "${ufw_status}" == "active" ]] || return 0

  run_sudo ufw allow "${NAIT_ZTR_MOON_PORT}/udp" comment 'ZeroTier Moon'
}

create_controller_moon_interactive() {
  local detected_ip=""
  local public_ip=""
  local temp_dir=""
  local raw_config=""
  local moon_config=""
  local generated_file=""
  local moon_id=""
  local public_filename=""
  local public_file=""
  local export_dir=""
  local export_file=""

  if run_sudo_quiet test -f "${NAIT_ZTR_MOON_CONFIG_FILE}"; then
    show_existing_controller_moon
    return 0
  fi

  command -v zerotier-idtool >/dev/null 2>&1 || die "zerotier-idtool не найден. Переустановите ZeroTier One."
  run_sudo_quiet test -f /var/lib/zerotier-one/identity.public \
    || die "ZeroTier identity.public не найден."

  detected_ip="$(detect_public_ipv4 || true)"
  while true; do
    public_ip="$(prompt_with_default "Публичный IPv4 этого VPS" "${detected_ip}")"
    if [[ -n "${public_ip}" ]] && validate_ipv4 "${public_ip}"; then
      break
    fi
    log_warn "Введите корректный публичный IPv4."
  done

  cat <<EOF

План создания резервной Moon:
- Хост: текущий ZeroTier Controller
- Публичный адрес: ${public_ip}:${NAIT_ZTR_MOON_PORT}/UDP
- Официальная Planet останется включена
- Moon станет резервным Root
- Если UFW активен, будет открыт ${NAIT_ZTR_MOON_PORT}/udp

EOF
  confirm "Создать резервную Moon?" "N" || die "Создание Moon отменено."

  temp_dir="$(mktemp -d)"
  chmod 0700 "${temp_dir}"
  trap 'rm -rf -- "${temp_dir}"' EXIT
  raw_config="${temp_dir}/moon.raw.json"
  moon_config="${temp_dir}/moon.json"

  run_sudo_quiet zerotier-idtool initmoon /var/lib/zerotier-one/identity.public > "${raw_config}"
  jq --arg endpoint "${public_ip}/${NAIT_ZTR_MOON_PORT}" \
    '.roots[0].stableEndpoints = [$endpoint]' \
    "${raw_config}" > "${moon_config}"
  jq -e '.id and .signingKey_SECRET and (.roots | length > 0)' "${moon_config}" >/dev/null \
    || die "zerotier-idtool создал некорректную конфигурацию Moon."

  (
    cd "${temp_dir}"
    zerotier-idtool genmoon moon.json >/dev/null
  )

  generated_file="$(find "${temp_dir}" -maxdepth 1 -type f -name '*.moon' -print -quit)"
  [[ -n "${generated_file}" ]] || die "Не удалось создать публичный .moon файл."

  moon_id="$(jq -r '.id // empty' "${moon_config}")"
  moon_id_is_valid "${moon_id}" || die "Получен некорректный Moon ID: ${moon_id}"
  public_filename="$(moon_public_filename "${moon_id}")"
  public_file="${NAIT_ZTR_MOON_CONFIG_DIR}/${public_filename}"
  export_dir="$(moon_export_dir)"
  export_file="${export_dir}/${public_filename}"

  run_sudo install -d -m 0700 "${NAIT_ZTR_MOON_CONFIG_DIR}"
  run_sudo install -m 0600 "${moon_config}" "${NAIT_ZTR_MOON_CONFIG_FILE}"
  run_sudo install -m 0644 "${generated_file}" "${public_file}"
  run_sudo install -d -o zerotier-one -g zerotier-one -m 0755 "${NAIT_ZTR_MOONS_DIR}"
  run_sudo install -o zerotier-one -g zerotier-one -m 0644 \
    "${generated_file}" "${NAIT_ZTR_MOONS_DIR}/${public_filename}"

  install -d -m 0755 "${export_dir}"
  install -m 0644 "${generated_file}" "${export_file}"
  open_moon_ufw_port_if_needed
  run_sudo systemctl restart zerotier-one

  if ! wait_for_moon "${moon_id}"; then
    log_warn "Moon создана, но пока не появилась в списке ZeroTier. Проверьте ${NAIT_ZTR_MOONS_DIR}/${public_filename}."
  fi

  rm -rf -- "${temp_dir}"
  trap - EXIT

  cat <<EOF

Резервная Moon создана.
- Moon ID: ${moon_id}
- Endpoint: ${public_ip}:${NAIT_ZTR_MOON_PORT}/UDP
- Файл для клиентов: ${export_file}

На остальных устройствах установите клиент ZeroTier и выберите пункт 7.
Если у VPS есть внешний firewall, разрешите ${NAIT_ZTR_MOON_PORT}/udp.

EOF
}

connect_moon_by_id_interactive() {
  local moon_id=""

  while true; do
    moon_id="$(prompt_with_default "Moon ID" "")"
    if moon_id_is_valid "${moon_id}"; then
      moon_id="${moon_id,,}"
      break
    fi
    log_warn "Moon ID должен состоять из 10 шестнадцатеричных символов."
  done

  if moon_is_listed "${moon_id}"; then
    log_info "Moon ${moon_id} уже подключена."
    return 0
  fi

  run_sudo zerotier-cli orbit "${moon_id}" "${moon_id}"
  run_sudo systemctl restart zerotier-one
  if wait_for_moon "${moon_id}"; then
    log_info "Резервная Moon ${moon_id} добавлена в конфигурацию клиента."
  else
    log_warn "Команда принята, но Moon пока не появилась в конфигурации клиента. Проверьте её публичный адрес и ${NAIT_ZTR_MOON_PORT}/udp."
  fi

  print_root_connectivity_summary
}

connect_moon_by_file_interactive() {
  local moon_file=""
  local filename=""
  local moon_id=""

  cat <<EOF

Загрузите файл Moon через SFTP в домашнюю папку обычного пользователя.
Пример: /home/<username>/000000<moon-id>.moon

Укажите полный путь к загруженному файлу ниже.
Инсталлер сам скопирует его в системную папку ZeroTier и перезапустит сервис.

EOF
  moon_file="$(prompt_with_default "Путь к файлу .moon" "")"
  [[ -f "${moon_file}" ]] || die "Файл не найден: ${moon_file}"
  filename="$(basename "${moon_file}")"

  if [[ "${filename}" =~ ^000000([0-9a-fA-F]{10})\.moon$ ]]; then
    moon_id="${BASH_REMATCH[1],,}"
  else
    die "Некорректное имя .moon файла: ${filename}"
  fi

  run_sudo install -d -o zerotier-one -g zerotier-one -m 0755 "${NAIT_ZTR_MOONS_DIR}"
  run_sudo install -o zerotier-one -g zerotier-one -m 0644 \
    "${moon_file}" "${NAIT_ZTR_MOONS_DIR}/${filename}"
  run_sudo systemctl restart zerotier-one

  if wait_for_moon "${moon_id}"; then
    log_info "Файл Moon добавлен в конфигурацию клиента."
  else
    log_warn "Файл Moon установлен, но пока не появился в конфигурации клиента. Проверьте endpoint и ${NAIT_ZTR_MOON_PORT}/udp."
  fi

  print_root_connectivity_summary
}

connect_moon_interactive() {
  local choice=""

  cat <<'EOF'

Подключение резервной Moon:
1) По Moon ID
2) Из файла .moon
3) Назад

EOF
  choice="$(read_user_input "Выберите пункт [1-3]: ")"
  case "${choice}" in
    1) connect_moon_by_id_interactive ;;
    2) connect_moon_by_file_interactive ;;
    3) return 0 ;;
    *) log_warn "Неизвестный пункт меню: ${choice}" ;;
  esac
}

configure_moon_interactive() {
  preflight_common
  is_zerotier_installed || die "ZeroTier не установлен. Сначала выберите пункт 1 или 2."
  ensure_zerotier_service

  if is_controller_host; then
    log_info "Режим Controller: создание резервной Moon."
    create_controller_moon_interactive
  else
    log_info "Режим клиента: подключение резервной Moon."
    connect_moon_interactive
  fi
}

status_print_moon_block() {
  local moon_ids=""
  local moon_id=""
  local endpoint=""

  echo "Moon:"
  if ! is_zerotier_installed; then
    echo "- Статус: ZeroTier не установлен"
    return 0
  fi

  if run_sudo_quiet test -f "${NAIT_ZTR_MOON_CONFIG_FILE}"; then
    moon_id="$(controller_moon_id)"
    endpoint="$(controller_moon_endpoint)"
    echo "- Статус: создана на этом Controller"
    echo "- Moon ID: ${moon_id:-не удалось определить}"
    echo "- Endpoint: ${endpoint:-не удалось определить}"
    return 0
  fi

  moon_ids="$(moon_list_ids)"
  if [[ -z "${moon_ids}" ]]; then
    echo "- Статус: не настроена"
    return 0
  fi

  echo "- Статус: подключена"
  while IFS= read -r moon_id; do
    [[ -n "${moon_id}" ]] || continue
    echo "- Moon ID: ${moon_id}"
    if run_sudo_quiet test -f "${NAIT_ZTR_MOONS_DIR}/$(moon_public_filename "${moon_id}")"; then
      echo "- Файл Moon: ${NAIT_ZTR_MOONS_DIR}/$(moon_public_filename "${moon_id}")"
    fi
  done <<< "${moon_ids}"
}
