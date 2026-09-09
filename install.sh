#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}"

# shellcheck source=lib/common.sh
source "${REPO_ROOT}/lib/common.sh"
# shellcheck source=lib/checks.sh
source "${REPO_ROOT}/lib/checks.sh"
# shellcheck source=lib/zerotier.sh
source "${REPO_ROOT}/lib/zerotier.sh"
# shellcheck source=lib/ztncui.sh
source "${REPO_ROOT}/lib/ztncui.sh"
# shellcheck source=lib/controller.sh
source "${REPO_ROOT}/lib/controller.sh"
# shellcheck source=lib/moon.sh
source "${REPO_ROOT}/lib/moon.sh"
# shellcheck source=lib/node.sh
source "${REPO_ROOT}/lib/node.sh"
# shellcheck source=lib/authorize.sh
source "${REPO_ROOT}/lib/authorize.sh"
# shellcheck source=lib/status.sh
source "${REPO_ROOT}/lib/status.sh"

print_help() {
  cat <<'EOF'
Nait_ZTR_Installer

Использование:
  ./install.sh
  ./install.sh controller
  ./install.sh client
  ./install.sh create-network
  ./install.sh join-network
  ./install.sh authorize-node --network-id <NETWORK_ID> --node-id <NODE_ID> [--ip <IP>]
  ./install.sh ztncui-install
  ./install.sh moon
  ./install.sh status
  ./install.sh help

Сценарии:
  controller       Развернуть self-hosted ZeroTier Controller.
  client           Установить ZeroTier на текущий узел.
  create-network   Создать сеть через локальный Controller.
  join-network     Подключить текущий узел к сети по Network ID.
  authorize-node   Одобрить узел на локальном Controller.
  moon             Создать Moon на Controller или подключить её на узле.
EOF
}

show_menu() {
  cat <<EOF

========================================
Nait ZTR Installer v${NAIT_ZTR_INSTALLER_VERSION} (MVP)
========================================

1) Развернуть self-hosted ZeroTier Controller + ZTNCUI (веб-интерфейс)
2) Установить клиент ZeroTier
3) Мастер создания сети ZeroTier (CLI)
4) Подключить узел к сети ZeroTier (CLI)
5) Одобрить узел в сети ZeroTier (CLI)
6) Установить ZTNCUI (в контейнере)
7) Резервная Moon: создать на Controller / подключить на клиенте
8) Статус
9) Выход

EOF
}

interactive_menu() {
  while true; do
    show_menu
    choice="$(read_user_input "Выберите пункт [1-9]: ")"
    case "${choice}" in
      1) install_controller_interactive ;;
      2) install_client_interactive ;;
      3) create_network_interactive ;;
      4) join_network_interactive ;;
      5) authorize_node_interactive ;;
      6) install_ztncui_interactive ;;
      7) configure_moon_interactive ;;
      8) show_status ;;
      9) log_info "Выход."; return 0 ;;
      *) log_warn "Неизвестный пункт меню: ${choice}" ;;
    esac
  done
}

dispatch() {
  local command="${1:-}"

  case "${command}" in
    "")
      interactive_menu
      ;;
    controller)
      shift
      if [[ "$#" -ne 0 ]]; then
        print_help
        die "Команда controller не принимает аргументы."
      fi
      install_controller_interactive
      ;;
    client)
      shift
      if [[ "$#" -ne 0 ]]; then
        print_help
        die "Команда client в v1 не принимает аргументы."
      fi
      install_client_interactive
      ;;
    create-network)
      shift
      if [[ "$#" -ne 0 ]]; then
        print_help
        die "Команда create-network не принимает аргументы."
      fi
      create_network_interactive
      ;;
    join-network)
      shift
      if [[ "$#" -ne 0 ]]; then
        print_help
        die "Команда join-network не принимает аргументы."
      fi
      join_network_interactive
      ;;
    authorize-node)
      shift
      authorize_node "$@"
      ;;
    ztncui-install)
      shift
      [[ "$#" -eq 0 ]] || die "Команда ztncui-install не принимает аргументы."
      install_ztncui_interactive
      ;;
    moon)
      shift
      [[ "$#" -eq 0 ]] || die "Команда moon не принимает аргументы."
      configure_moon_interactive
      ;;
    status)
      shift
      if [[ "$#" -ne 0 ]]; then
        print_help
        die "Команда status не принимает аргументы."
      fi
      show_status
      ;;
    help|-h|--help)
      print_help
      ;;
    *)
      print_help
      die "Неизвестная команда: ${command}"
      ;;
  esac
}

dispatch "$@"
