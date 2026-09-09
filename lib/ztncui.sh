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

  for command_name in curl dpkg-deb sha256sum ss systemctl; do
    command -v "${command_name}" >/dev/null 2>&1 \
      || die "Для ZTNCUI требуется команда: ${command_name}"
  done

  [[ "$(dpkg --print-architecture)" == "amd64" ]] \
    || die "Закреплённый DEB-пакет ZTNCUI поддерживает только amd64."
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
  is_controller_host \
    || die "Локальный ZeroTier Controller не найден. Сначала выберите пункт 1."
  run_sudo_quiet test -r /var/lib/zerotier-one/authtoken.secret \
    || die "Не удалось прочитать token локального ZeroTier Controller."
  controller_token="$(run_sudo_quiet cat /var/lib/zerotier-one/authtoken.secret)"
  [[ -n "${controller_token}" ]] || die "Token локального ZeroTier Controller пуст."
  curl -fsS --max-time 3 -H "X-ZT1-Auth: ${controller_token}" "${ZT_LOCAL_API}/status" >/dev/null \
    || die "Локальный ZeroTier Controller API недоступен на ${ZT_LOCAL_API}."
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

native_ztncui_is_installed() {
  dpkg-query -W -f='${db:Status-Status}' ztncui 2>/dev/null | grep -qx installed
}

ztncui_container_exists() {
  command -v docker >/dev/null 2>&1 || return 1
  run_sudo_quiet docker container inspect "${NAIT_ZTNCUI_CONTAINER_NAME}" >/dev/null 2>&1
}

docker_compose_available() {
  command -v docker >/dev/null 2>&1 || return 1
  run_sudo_quiet docker compose version >/dev/null 2>&1
}

install_docker_from_official_repo() {
  local architecture
  local codename
  local os_id
  local sources_file

  # shellcheck disable=SC1091
  os_id="$(. /etc/os-release && printf '%s' "${ID:-}")"
  # shellcheck disable=SC1091
  codename="$(. /etc/os-release && printf '%s' "${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}")"
  architecture="$(dpkg --print-architecture)"

  [[ "${os_id}" == "ubuntu" ]] \
    || die "Автоматическая установка Docker поддерживается только на Ubuntu."
  [[ -n "${codename}" ]] || die "Не удалось определить codename Ubuntu для Docker repository."

  log_info "Подключаю официальный Docker APT repository."
  run_sudo apt-get update
  run_sudo apt-get install -y ca-certificates curl
  run_sudo install -m 0755 -d /etc/apt/keyrings
  run_sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    -o /etc/apt/keyrings/docker.asc
  run_sudo chmod a+r /etc/apt/keyrings/docker.asc

  sources_file="$(mktemp)"
  cat > "${sources_file}" <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${codename}
Components: stable
Architectures: ${architecture}
Signed-By: /etc/apt/keyrings/docker.asc
EOF
  run_sudo install -m 0644 "${sources_file}" /etc/apt/sources.list.d/docker.sources
  rm -f "${sources_file}"

  run_sudo apt-get update
  run_sudo apt-get install -y \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

ensure_docker_for_ztncui() {
  if ! command -v docker >/dev/null 2>&1; then
    install_docker_from_official_repo
  fi

  run_sudo_quiet systemctl enable --now docker >/dev/null 2>&1 \
    || die "Docker установлен, но сервис docker не удалось запустить."
  run_sudo_quiet docker info >/dev/null 2>&1 \
    || die "Docker daemon недоступен."
  docker_compose_available \
    || die "Не найден Docker Compose plugin. Установите docker-compose-plugin и повторите попытку."
}

write_ztncui_container_files() {
  local build_dir="${1:?build dir обязателен}"
  local controller_token

  controller_token="$(run_sudo_quiet cat /var/lib/zerotier-one/authtoken.secret)"
  [[ -n "${controller_token}" ]] || die "Token локального ZeroTier Controller пуст."

  cat > "${build_dir}/Dockerfile" <<'EOF'
FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates libstdc++6 openssl passwd \
    && rm -rf /var/lib/apt/lists/*

COPY ztncui.deb /tmp/ztncui.deb
RUN dpkg-deb -x /tmp/ztncui.deb / \
    && rm -f /tmp/ztncui.deb \
    && groupadd --gid 10001 ztncui \
    && useradd --uid 10001 --gid 10001 --home-dir /opt/key-networks/ztncui --no-create-home ztncui \
    && mkdir -p /usr/share/ztncui-defaults \
    && cp -a /opt/key-networks/ztncui/etc/. /usr/share/ztncui-defaults/ \
    && chown -R ztncui:ztncui /opt/key-networks/ztncui \
    && chown -R ztncui:ztncui /usr/share/ztncui-defaults \
    && chmod 0755 /opt/key-networks /opt/key-networks/ztncui \
    && rm -rf /opt/key-networks/ztncui/etc \
    && install -d -o ztncui -g ztncui -m 0750 /opt/key-networks/ztncui/etc

COPY entrypoint.sh /usr/local/bin/ztncui-entrypoint
RUN chmod 0755 /usr/local/bin/ztncui-entrypoint

USER 10001:10001
WORKDIR /opt/key-networks/ztncui
ENTRYPOINT ["/usr/local/bin/ztncui-entrypoint"]
CMD ["/opt/key-networks/ztncui/ztncui"]
EOF

  cat > "${build_dir}/entrypoint.sh" <<'EOF'
#!/bin/sh
set -eu

install -d -m 0750 etc/storage etc/tls

if [ ! -f etc/default.passwd ]; then
  install -m 0600 /usr/share/ztncui-defaults/default.passwd etc/default.passwd
fi

if [ ! -f etc/passwd ]; then
  cp etc/default.passwd etc/passwd
  chmod 0600 etc/passwd
fi

if [ ! -f etc/tls/privkey.pem ] || [ ! -f etc/tls/fullchain.pem ]; then
  openssl req -x509 -sha256 -nodes -days 3650 -newkey rsa:4096 \
    -keyout etc/tls/privkey.pem \
    -out etc/tls/fullchain.pem \
    -subj '/CN=localhost' >/dev/null 2>&1
  chmod 0600 etc/tls/privkey.pem etc/tls/fullchain.pem
fi

exec "$@"
EOF
  chmod 0755 "${build_dir}/entrypoint.sh"

  cat > "${build_dir}/.dockerignore" <<'EOF'
*
!Dockerfile
!entrypoint.sh
!ztncui.deb
EOF

  cat > "${build_dir}/docker-compose.yml" <<EOF
services:
  ztncui:
    container_name: ${NAIT_ZTNCUI_CONTAINER_NAME}
    image: ${NAIT_ZTNCUI_CONTAINER_IMAGE}
    network_mode: host
    restart: unless-stopped
    env_file:
      - .env
    volumes:
      - ./data:/opt/key-networks/ztncui/etc
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    labels:
      com.naitlab.component: ztncui
      com.naitlab.version: "${NAIT_ZTNCUI_DEFAULT_VERSION}"
EOF

  cat > "${build_dir}/.env" <<EOF
ZT_TOKEN=${controller_token}
ZT_ADDR=127.0.0.1:9993
NODE_ENV=production
HTTP_PORT=3000
EOF
  chmod 0600 "${build_dir}/.env"
}

install_ztncui_container_files() {
  local build_dir="${1:?build dir обязателен}"

  run_sudo install -d -m 0750 "${NAIT_ZTNCUI_CONTAINER_DIR}"
  run_sudo install -d -m 0750 "${NAIT_ZTNCUI_CONTAINER_DATA_DIR}"
  run_sudo chown 10001:10001 "${NAIT_ZTNCUI_CONTAINER_DATA_DIR}"
  run_sudo install -m 0644 "${build_dir}/Dockerfile" "${NAIT_ZTNCUI_CONTAINER_DIR}/Dockerfile"
  run_sudo install -m 0755 "${build_dir}/entrypoint.sh" "${NAIT_ZTNCUI_CONTAINER_DIR}/entrypoint.sh"
  run_sudo install -m 0644 "${build_dir}/.dockerignore" "${NAIT_ZTNCUI_CONTAINER_DIR}/.dockerignore"
  run_sudo install -m 0644 "${build_dir}/docker-compose.yml" "${NAIT_ZTNCUI_CONTAINER_COMPOSE_FILE}"
  run_sudo install -m 0600 "${build_dir}/.env" "${NAIT_ZTNCUI_CONTAINER_ENV_FILE}"
  run_sudo install -m 0644 "${build_dir}/ztncui.deb" "${NAIT_ZTNCUI_CONTAINER_DIR}/ztncui.deb"
}

build_ztncui_container_image() {
  local build_log
  local build_pid
  local build_status

  build_log="$(mktemp)"
  printf '[INFO] Собираю контейнер ZTNCUI'
  run_sudo docker build \
    --tag "${NAIT_ZTNCUI_CONTAINER_IMAGE}" \
    "${NAIT_ZTNCUI_CONTAINER_DIR}" >"${build_log}" 2>&1 &
  build_pid=$!

  while kill -0 "${build_pid}" 2>/dev/null; do
    sleep 1
    kill -0 "${build_pid}" 2>/dev/null && printf '.'
  done

  if wait "${build_pid}"; then
    printf ' готово\n'
    rm -f "${build_log}"
    return 0
  else
    build_status=$?
  fi

  printf ' ошибка\n'
  log_error "Не удалось собрать контейнер ZTNCUI. Технические подробности:"
  tail -n 80 "${build_log}" >&2 || true
  rm -f "${build_log}"
  return "${build_status}"
}

wait_for_ztncui_container_ready() {
  local attempt

  for attempt in {1..30}; do
    if [[ "$(run_sudo_quiet docker inspect -f '{{.State.Running}}' "${NAIT_ZTNCUI_CONTAINER_NAME}" 2>/dev/null || true)" == "true" ]] \
      && curl -fsS --max-time 2 http://127.0.0.1:3000/ >/dev/null 2>&1; then
      [[ "${attempt}" -eq 1 ]] || printf '\n'
      return 0
    fi
    printf '.'
    sleep 1
  done

  printf '\n'
  log_warn "ZTNCUI не стал доступен на http://127.0.0.1:3000. Последние строки журнала:"
  run_sudo docker logs --tail 60 "${NAIT_ZTNCUI_CONTAINER_NAME}" || true
  return 1
}

verify_ztncui_container_local_bind() {
  local endpoints
  local endpoint

  endpoints="$(run_sudo_quiet ss -H -ltn 'sport = :3000' | awk '{print $4}')"
  [[ -n "${endpoints}" ]] || die "ZTNCUI запущен, но TCP port 3000 не найден."

  while IFS= read -r endpoint; do
    [[ "${endpoint}" == "127.0.0.1:3000" || "${endpoint}" == "[::1]:3000" ]] && continue
    run_sudo docker stop "${NAIT_ZTNCUI_CONTAINER_NAME}" >/dev/null || true
    die "ZTNCUI открыл port 3000 не только на localhost (${endpoint}). Контейнер остановлен."
  done <<< "${endpoints}"
}

get_installed_ztncui_version() {
  dpkg-query -W -f='${Version}\n' ztncui 2>/dev/null | sed 's/^[0-9]*://; s/-.*$//'
}

get_container_ztncui_version() {
  command -v docker >/dev/null 2>&1 || return 1
  run_sudo_quiet docker inspect \
    -f '{{index .Config.Labels "com.naitlab.version"}}' \
    "${NAIT_ZTNCUI_CONTAINER_NAME}" 2>/dev/null
}

install_ztncui_interactive() {
  preflight_common
  install_ztncui
}

install_ztncui() {
  local version
  local build_dir
  local docker_plan

  require_ztncui_prerequisites
  require_local_controller_for_ztncui

  native_ztncui_is_installed \
    && die "На хосте уже установлен ZTNCUI через DEB. Сначала удалите нативную установку, чтобы избежать конфликта port 3000."
  ztncui_container_exists \
    && die "Контейнер ${NAIT_ZTNCUI_CONTAINER_NAME} уже существует. Инструкцию по обновлению смотрите в README."
  run_sudo_quiet test ! -e "${NAIT_ZTNCUI_CONTAINER_DIR}" \
    || die "Каталог ${NAIT_ZTNCUI_CONTAINER_DIR} уже существует. Проверьте его содержимое перед повторной установкой."
  [[ -z "$(run_sudo_quiet ss -H -ltn 'sport = :3000' || true)" ]] \
    || die "TCP port 3000 уже занят. ZTNCUI не устанавливался."

  version="${NAIT_ZTNCUI_DEFAULT_VERSION}"
  validate_ztncui_version "${version}" || die "Некорректная версия ZTNCUI: ${version}"

  if command -v docker >/dev/null 2>&1; then
    docker_plan="будет использован установленный Docker"
  else
    docker_plan="будет установлен из официального Docker APT repository"
  fi

  cat <<EOF

План установки ZTNCUI:
- ZeroTier One, Controller и Moon остаются на хосте
- ZTNCUI ${version}: отдельный контейнер ${NAIT_ZTNCUI_CONTAINER_NAME}
- Каталог контейнера: ${NAIT_ZTNCUI_CONTAINER_DIR}
- Docker: ${docker_plan}
- Web UI: http://127.0.0.1:3000
- Внешние порты ZTNCUI: не открываются
- Доступ: через SSH-туннель
- Существующие сети ZeroTier: не изменяются

EOF
  confirm "Развернуть ZTNCUI по этому плану?" "N" || die "Установка ZTNCUI отменена."

  ensure_docker_for_ztncui

  build_dir="$(mktemp -d)"
  prepare_ztncui_package "${version}" "${build_dir}/ztncui.deb"
  write_ztncui_container_files "${build_dir}"
  install_ztncui_container_files "${build_dir}"
  rm -rf "${build_dir}"

  build_ztncui_container_image || die "Сборка ZTNCUI завершилась с ошибкой. ZeroTier One не изменялся."
  log_info "Запускаю контейнер ${NAIT_ZTNCUI_CONTAINER_NAME}."
  run_sudo docker compose -f "${NAIT_ZTNCUI_CONTAINER_COMPOSE_FILE}" up -d \
    || die "Не удалось запустить контейнер ${NAIT_ZTNCUI_CONTAINER_NAME}."
  wait_for_ztncui_container_ready \
    || die "ZTNCUI не запустился; ZeroTier One и Controller не изменялись."
  verify_ztncui_container_local_bind
  log_info "ZTNCUI установлен и работает в контейнере ${NAIT_ZTNCUI_CONTAINER_NAME}."

  cat <<EOF

Веб-интерфейс ZTNCUI установлен и подключён к ZeroTier Controller.
- Контейнер: ${NAIT_ZTNCUI_CONTAINER_NAME}
- Файлы: ${NAIT_ZTNCUI_CONTAINER_DIR}

Прокинь SSH-туннель: (смотри README)
Браузер: http://127.0.0.1:3000
Первый вход: admin / password
EOF
}
