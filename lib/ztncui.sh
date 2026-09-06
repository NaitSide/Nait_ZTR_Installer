#!/usr/bin/env bash

normalize_ztncui_version() {
  local version="${1:-}"
  printf '%s\n' "${version#v}"
}

validate_ztncui_version() {
  local version="${1:-}"
  [[ "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

require_ztncui_prerequisites() {
  local command_name

  for command_name in curl dpkg-query sha256sum ss systemctl; do
    command -v "${command_name}" >/dev/null 2>&1 \
      || die "Для ZTNCUI требуется команда: ${command_name}"
  done

  [[ "$(dpkg --print-architecture)" == "amd64" ]] \
    || die "Официальный DEB-пакет ZTNCUI поддерживает только amd64."
}

ztncui_expected_checksum() {
  local version="${1:?version обязателен}"

  case "${version}" in
    0.8.14) printf '%s\n' '8e340eec7d5421bbf73c4fc2cbf0e260e250dbf2f164bb9a086be36df239bcb2' ;;
    *) return 1 ;;
  esac
}

require_local_controller_for_ztncui() {
  local controller_token

  is_zerotier_installed \
    || die "ZTNCUI устанавливается только на ZeroTier Controller с уже установленным ZeroTier One."
  run_sudo_quiet test -d /var/lib/zerotier-one/controller.d \
    || die "Локальный ZeroTier Controller не найден: отсутствует /var/lib/zerotier-one/controller.d."
  run_sudo_quiet test -r /var/lib/zerotier-one/authtoken.secret \
    || die "Не удалось прочитать token локального ZeroTier controller."
  controller_token="$(run_sudo_quiet cat /var/lib/zerotier-one/authtoken.secret)"
  [[ -n "${controller_token}" ]] || die "Token локального ZeroTier controller пуст."
  curl -fsS --max-time 3 -H "X-ZT1-Auth: ${controller_token}" "${ZT_LOCAL_API}/status" >/dev/null \
    || die "Локальный ZeroTier controller API недоступен на ${ZT_LOCAL_API}."
}

ztncui_deb_filename() {
  local version="${1:?version обязателен}"
  printf 'ztncui_%s_amd64.deb\n' "${version}"
}

prepare_ztncui_package() {
  local version="${1:?version обязателен}"
  local output_file="${2:?output file обязателен}"
  local filename
  local offline_package
  local expected_checksum
  local actual_checksum

  filename="$(ztncui_deb_filename "${version}")"
  offline_package="${NAIT_ZTR_OFFLINE_DIR}/${filename}"

  if [[ -f "${offline_package}" ]]; then
    cp "${offline_package}" "${output_file}"
  else
    log_info "Загрузка официального DEB-пакета ZTNCUI ${version}."
    curl -fL --retry 3 --connect-timeout 15 -o "${output_file}" \
      "https://s3-us-west-1.amazonaws.com/key-networks/deb/ztncui/1/x86_64/${filename}"
  fi

  dpkg-deb --field "${output_file}" Package Version Architecture >/dev/null \
    || die "Загруженный файл ZTNCUI не является корректным DEB-пакетом."
  [[ "$(dpkg-deb --field "${output_file}" Package)" == "ztncui" ]] \
    || die "Загруженный DEB-пакет не является ZTNCUI."
  [[ "$(dpkg-deb --field "${output_file}" Architecture)" == "amd64" ]] \
    || die "Архитектура DEB-пакета ZTNCUI не соответствует amd64."

  expected_checksum="$(ztncui_expected_checksum "${version}" || true)"
  if [[ -n "${expected_checksum}" ]]; then
    actual_checksum="$(sha256sum "${output_file}" | awk '{print $1}')"
    [[ "${actual_checksum,,}" == "${expected_checksum}" ]] \
      || die "SHA-256 DEB-пакета ZTNCUI не совпадает. Установка остановлена."
  else
    log_warn "Для ZTNCUI ${version} в installer нет закреплённого SHA-256; проверены только поля DEB-пакета."
  fi
}

write_ztncui_env() {
  local controller_token
  local tmp_env

  controller_token="$(run_sudo_quiet cat /var/lib/zerotier-one/authtoken.secret)"
  [[ -n "${controller_token}" ]] || die "Token локального ZeroTier controller пуст."
  tmp_env="$(mktemp)"
  cat > "${tmp_env}" <<EOF
ZT_TOKEN=${controller_token}
ZT_ADDR=127.0.0.1:9993
NODE_ENV=production
HTTP_PORT=3000
EOF

  backup_ztncui_env_if_exists
  run_sudo install -o ztncui -g ztncui -m 0400 "${tmp_env}" "${NAIT_ZTNCUI_ENV_FILE}"
  rm -f "${tmp_env}"
}

backup_ztncui_env_if_exists() {
  local timestamp
  local backup_file

  run_sudo_quiet test -f "${NAIT_ZTNCUI_ENV_FILE}" || return 0
  timestamp="$(date '+%Y%m%d_%H%M%S')"
  backup_file="${NAIT_ZTNCUI_ENV_FILE}.bak.${timestamp}"
  log_warn "Существующий ZTNCUI config будет сохранён в backup: ${backup_file}"
  run_sudo cp -a "${NAIT_ZTNCUI_ENV_FILE}" "${backup_file}"
}

wait_for_ztncui_ready() {
  for _ in {1..20}; do
    if run_sudo_quiet systemctl is-active --quiet "${NAIT_ZTNCUI_SERVICE}" \
      && curl -fsS --max-time 2 http://127.0.0.1:3000/ >/dev/null; then
      return 0
    fi
    sleep 1
  done

  log_warn "ZTNCUI не стал доступен на http://127.0.0.1:3000. Последние строки журнала:"
  run_sudo journalctl -u "${NAIT_ZTNCUI_SERVICE}" -n 50 --no-pager || true
  return 1
}

verify_ztncui_local_bind() {
  local endpoints
  local endpoint

  endpoints="$(run_sudo_quiet ss -H -ltn 'sport = :3000' | awk '{print $4}')"
  [[ -n "${endpoints}" ]] || die "ZTNCUI запущен, но TCP port 3000 не найден."

  while IFS= read -r endpoint; do
    [[ "${endpoint}" == "127.0.0.1:3000" || "${endpoint}" == "[::1]:3000" ]] && continue
    run_sudo systemctl stop "${NAIT_ZTNCUI_SERVICE}" || true
    die "ZTNCUI открыл port 3000 не только на localhost (${endpoint}). Сервис остановлен."
  done <<< "${endpoints}"
}

get_installed_ztncui_version() {
  dpkg-query -W -f='${Version}\n' ztncui 2>/dev/null | sed 's/^[0-9]*://; s/-.*$//'
}

install_ztncui_interactive() {
  preflight_common
  install_ztncui
}

install_ztncui() {
  local version
  local staged_package

  require_ztncui_prerequisites
  require_local_controller_for_ztncui
  if dpkg-query -W -f='${db:Status-Status}' ztncui 2>/dev/null | grep -qx installed; then
    die "ZTNCUI уже установлен. Инструкцию по обновлению смотрите в README."
  fi

  version="${NAIT_ZTNCUI_DEFAULT_VERSION}"
  validate_ztncui_version "${version}" || die "Некорректная версия ZTNCUI: ${version}"

  cat <<EOF

План установки ZTNCUI:
- Версия: ${version} (проверенная этим установщиком)
- Источник: официальный DEB-пакет Key Networks или local offline package
- Systemd service: ${NAIT_ZTNCUI_SERVICE}
- ZeroTier controller: существующий ${ZT_LOCAL_API}
- Web UI: http://127.0.0.1:3000
- Внешние порты ZTNCUI: не открываются
- Docker и PostgreSQL: не требуются
- Изменение zerotier-one и существующих сетей: нет

EOF
  confirm "Установить ZTNCUI по этому плану?" "N" || die "Установка ZTNCUI отменена."

  staged_package="$(mktemp --suffix=.deb)"
  prepare_ztncui_package "${version}" "${staged_package}"
  chmod 0644 "${staged_package}"
  run_sudo apt-get install -y "${staged_package}"
  rm -f "${staged_package}"

  log_info "↑ Предупреждение chown выше можно игнорировать."

  run_sudo_quiet test -d "${NAIT_ZTNCUI_DIR}" \
    || die "DEB-пакет не создал каталог ZTNCUI: ${NAIT_ZTNCUI_DIR}."
  id ztncui >/dev/null 2>&1 || die "DEB-пакет не создал системного пользователя ztncui."
  write_ztncui_env
  run_sudo systemctl enable --now "${NAIT_ZTNCUI_SERVICE}"
  wait_for_ztncui_ready || die "ZTNCUI не запустился; ZeroTier One не изменялся."
  verify_ztncui_local_bind

  cat <<'EOF'

Веб-интерфейс ZTNCUI установлен и подключён к ZeroTier Controller.
Прокинь SSH-туннель: (смотри README)
Браузер: http://127.0.0.1:3000
Первый вход: admin / password
EOF
}
