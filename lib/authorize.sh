#!/usr/bin/env bash

parse_authorize_args() {
  AUTHORIZE_NETWORK_ID=""
  AUTHORIZE_NODE_ID=""
  AUTHORIZE_IP=""

  while [[ "$#" -gt 0 ]]; do
    case "${1}" in
      --network-id)
        [[ -n "${2:-}" ]] || die "--network-id требует значение."
        AUTHORIZE_NETWORK_ID="${2}"
        shift 2
        ;;
      --node-id)
        [[ -n "${2:-}" ]] || die "--node-id требует значение."
        AUTHORIZE_NODE_ID="${2}"
        shift 2
        ;;
      --ip)
        [[ -n "${2:-}" ]] || die "--ip требует значение."
        AUTHORIZE_IP="${2}"
        shift 2
        ;;
      *) die "Неизвестный аргумент authorize-node: ${1}" ;;
    esac
  done
}

authorize_node_interactive() {
  local network_id
  local node_id
  local ip

  network_id="$(prompt_with_default "Network ID" "")"
  node_id="$(prompt_with_default "Node ID" "")"
  ip="$(prompt_with_default "Ручной IPv4-адрес (необязательно)" "")"

  if [[ -n "${ip}" ]]; then
    authorize_node --network-id "${network_id}" --node-id "${node_id}" --ip "${ip}"
  else
    authorize_node --network-id "${network_id}" --node-id "${node_id}"
  fi
}

authorize_node() {
  parse_authorize_args "$@"

  local network_id="${AUTHORIZE_NETWORK_ID}"
  local node_id="${AUTHORIZE_NODE_ID}"
  local ip="${AUTHORIZE_IP}"

  preflight_common
  require_controller_host
  [[ "${network_id}" =~ ^[0-9a-fA-F]{16}$ ]] || die "Network ID должен состоять из 16 шестнадцатеричных символов."
  [[ "${node_id}" =~ ^[0-9a-fA-F]{10}$ ]] || die "Node ID должен состоять из 10 шестнадцатеричных символов."
  [[ -z "${ip}" ]] || validate_ipv4 "${ip}" || die "Некорректный IPv4-адрес: ${ip}"

  cat <<EOF

План одобрения узла:
- Network ID: ${network_id}
- Node ID: ${node_id}
- IP: $([[ -n "${ip}" ]] && echo "${ip} (ручной)" || echo "автоматический из пула сети")

EOF
  confirm "Одобрить узел?" "N" || die "Одобрение отменено."

  if [[ -n "${ip}" ]]; then
    authorize_zt_node_with_ip "${network_id}" "${node_id}" "${ip}" >/dev/null
  else
    authorize_zt_node "${network_id}" "${node_id}" >/dev/null
  fi

  log_info "Узел ${node_id} одобрен в сети ${network_id}."
}
