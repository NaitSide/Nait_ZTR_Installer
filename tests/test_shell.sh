#!/usr/bin/env bash
# Run as an ordinary user. All package and service mutations are mocked.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
REPO_ROOT="${PWD}"
source lib/common.sh
source lib/zerotier.sh
source lib/ztncui.sh
source lib/controller.sh
source lib/gateway.sh
write_log() { :; }
test_tmp="$(mktemp -d)"
trap 'rm -rf -- "${test_tmp}"' EXIT

assert_equal() { [[ "$1" == "$2" ]] || { printf 'Expected <%s>, got <%s>\n' "$2" "$1" >&2; exit 1; }; }
assert_equal "$(prompt_with_default 'Подсеть' '10.77.77.0/24' <<< '')" '10.77.77.0/24'
assert_equal "$(prompt_with_default 'Подсеть' '10.77.77.0/24' <<< '10.88.0.0/24')" '10.88.0.0/24'
assert_equal "$(first_usable_ip_from_cidr '10.88.0.0/16')" '10.88.0.1'
assert_equal "$(last_usable_ip_from_cidr '10.88.0.0/16')" '10.88.255.254'

(
  create_controller_network() { echo aaaaaaaaaa123456; }
  update_controller_network() { printf '%s\n' "$@" > "${test_tmp}/network-args"; }
  authorize_zt_node_with_ip() { echo 'Unexpected authorization in step 3' >&2; exit 1; }
  zt_join_network() { echo 'Unexpected join in step 3' >&2; exit 1; }
  create_network test 10.77.77.0/24 10.77.77.1 >/dev/null
  assert_equal "$(sed -n '4p' "${test_tmp}/network-args")" '10.77.77.2'
)

# Existing Compose must not invoke apt or touch Docker.
(
  docker_compose_available() { return 0; }
  run_sudo() { echo 'Unexpected mutation' >&2; exit 1; }
  ensure_docker_compose
)

# A compatible official local package is installed without downloading dependencies.
(
  marker="${test_tmp}/compose-installed"
  docker_compose_available() { [[ -f "${marker}" ]]; }
  compose_package_for_docker() { echo docker-compose-v2; }
  run_sudo_quiet() { [[ "$1" == apt-get && "$2" == -s ]] || exit 1; echo 'Inst docker-compose-v2 (test)'; }
  run_sudo() {
    [[ "$1" == apt-get && "$*" == *--no-download* ]] || exit 1
    touch "${marker}"
  }
  ensure_docker_compose
  [[ -f "${marker}" ]]
)

# Corrupt local bytes must stop instead of silently falling back to online.
(
  mkdir "${test_tmp}/corrupt"
  package="${test_tmp}/corrupt/docker-compose-v2_test_amd64.deb"
  printf corrupted > "${package}"
  printf '%064d  %s\n' 0 "$(basename "${package}")" > "${test_tmp}/corrupt/SHA256SUMS"
  NAIT_ZTR_OFFLINE_DIR="${test_tmp}/corrupt"
  if (verify_offline_compose_package "${package}") 2>/dev/null; then
    echo 'Corrupt package was accepted' >&2
    exit 1
  fi
)

# Absent package falls back to the matching Docker CE package, not docker.io.
(
  marker="${test_tmp}/ce-installed"
  docker_compose_available() { [[ -f "${marker}" ]]; }
  compose_package_for_docker() { echo docker-compose-plugin; }
  find_offline_compose_package() { return 1; }
  run_sudo_quiet() { echo 'Inst docker-compose-plugin (test)'; }
  run_sudo() {
    if [[ "$2" == install ]]; then
      [[ "${*: -1}" == docker-compose-plugin ]] || exit 1
      touch "${marker}"
    else
      [[ "$2" == update ]] || exit 1
    fi
  }
  ensure_docker_compose
  [[ -f "${marker}" ]]
)

# An apt plan that replaces the Docker engine must be rejected before mutation.
(
  run_sudo_quiet() { printf '%s\n' 'Remv docker.io [29.1.3]' 'Inst docker-ce (test)'; }
  if compose_install_plan_is_safe docker-compose-plugin; then
    echo 'Unsafe apt plan accepted' >&2
    exit 1
  fi
)

# Expected gateway prerequisite errors return to the caller/menu.
(
  gateway_backend() {
    if [[ "$1" == status ]]; then echo '{"configured":false}'; return 0; fi
    echo '[ОШИБКА] Сначала создайте сеть: пункт 3.' >&2
    return 1
  }
  configure_gateway_interactive
  echo menu-survived > "${test_tmp}/menu-result"
)
[[ -f "${test_tmp}/menu-result" ]]

bash install.sh help | grep -F './install.sh gateway' >/dev/null
printf '10\n' | bash install.sh | grep -F '10) Выход' >/dev/null
echo 'Shell workflow checks passed.'
