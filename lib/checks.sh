#!/usr/bin/env bash

check_required_commands() {
  local missing=()
  local packages=()
  local command_name

  for command_name in curl jq ip ss systemctl sudo python3; do
    if ! command -v "${command_name}" >/dev/null 2>&1; then
      missing+=("${command_name}")
    fi
  done

  if [[ "${#missing[@]}" -eq 0 ]]; then
    return 0
  fi

  log_warn "Не найдены обязательные команды: ${missing[*]}"
  if confirm "Установить недостающие пакеты через apt?" "N"; then
    local item
    for item in "${missing[@]}"; do
      case "${item}" in
        ip|ss) packages+=("iproute2") ;;
        systemctl) die "systemctl не найден. Вероятно, система не использует systemd." ;;
        *) packages+=("${item}") ;;
      esac
    done
    run_sudo apt-get update
    run_sudo apt-get install -y "${packages[@]}"
  else
    die "Отсутствуют обязательные команды: ${missing[*]}"
  fi
}

check_os() {
  if [[ ! -r /etc/os-release ]]; then
    log_warn "Не удалось прочитать /etc/os-release."
    confirm "Продолжить на неизвестной ОС?" "N" || die "Отменено пользователем."
    return 0
  fi

  # shellcheck disable=SC1091
  source /etc/os-release
  log_info "Обнаружена ОС: ${PRETTY_NAME:-unknown}"
}

check_ubuntu_2404() {
  if [[ ! -r /etc/os-release ]]; then
    log_warn "Не удалось проверить Ubuntu 24.04 LTS."
    confirm "Продолжить без проверки ОС?" "N" || die "Отменено пользователем."
    return 0
  fi

  # shellcheck disable=SC1091
  source /etc/os-release
  if [[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == "24.04" ]]; then
    return 0
  fi

  log_warn "Целевая ОС — Ubuntu 24.04 LTS, обнаружено: ${PRETTY_NAME:-unknown}."
  confirm "Всё равно продолжить?" "N" || die "Отменено пользователем."
}

check_root_or_sudo() {
  if [[ "${EUID}" -eq 0 ]]; then
    log_info "Запущено от root."
    return 0
  fi

  require_sudo
}

check_network_tools() {
  local missing=()

  command -v ip >/dev/null 2>&1 || missing+=("iproute2")
  command -v ss >/dev/null 2>&1 || missing+=("iproute2")

  if [[ "${#missing[@]}" -eq 0 ]]; then
    return 0
  fi

  log_warn "Не найдены сетевые инструменты: ${missing[*]}"
  if confirm "Установить сетевые инструменты через apt?" "N"; then
    run_sudo apt-get update
    run_sudo apt-get install -y "${missing[@]}"
  else
    die "Отсутствуют обязательные сетевые инструменты."
  fi
}

check_ufw_status() {
  if ! command -v ufw >/dev/null 2>&1; then
    log_warn "UFW не установлен. Firewall helper будет недоступен."
    return 0
  fi

  log_info "Статус UFW:"
  run_sudo ufw status verbose || true
}

preflight_common() {
  check_os
  check_ubuntu_2404
  check_root_or_sudo
  check_required_commands
  check_network_tools
}
