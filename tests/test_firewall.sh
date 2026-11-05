#!/usr/bin/env bash
# Run ONLY in a fresh network namespace; never on the host namespace.
set -Eeuo pipefail
[[ -n "${NAIT_HOST_NETNS:-}" ]] || { echo 'Missing host namespace marker' >&2; exit 1; }
[[ "$(readlink /proc/self/ns/net)" != "${NAIT_HOST_NETNS}" ]] || { echo 'Refusing host namespace' >&2; exit 1; }
cd "$(dirname "$0")/.."
scratch="$(mktemp -d)"
trap 'rm -rf -- "${scratch}"' EXIT
ip link add ztunit0 type veth peer name wanunit0
iptables -P FORWARD DROP
iptables -N DOCKER-USER
iptables -A FORWARD -j DOCKER-USER
iptables -N ufw-before-forward
iptables -A FORWARD -j ufw-before-forward
iptables -t nat -N DOCKER
iptables -t nat -A POSTROUTING -s 172.17.0.0/16 -j MASQUERADE
iptables-save > "${scratch}/before"
python3 - "${scratch}/runtime" <<'PY'
import importlib.util
from pathlib import Path
import sys
spec = importlib.util.spec_from_file_location('gateway', 'lib/gateway.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
path = Path(sys.argv[1])
path.write_text(module.firewall_script({'zt_interface':'ztunit0','wan_interface':'wanunit0','subnet':'10.77.77.0/24'}))
path.chmod(0o700)
PY
"${scratch}/runtime" start
"${scratch}/runtime" start
[[ "$(iptables -S FORWARD | grep -c -- '-j NAIT-ZTR-FWD')" == 1 ]]
[[ "$(iptables -t nat -S POSTROUTING | grep -c -- '-j NAIT-ZTR-NAT')" == 1 ]]
iptables -C NAIT-ZTR-FWD -i ztunit0 -o wanunit0 -s 10.77.77.0/24 -j ACCEPT
iptables -C NAIT-ZTR-FWD -i wanunit0 -o ztunit0 -d 10.77.77.0/24 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -t nat -C NAIT-ZTR-NAT -s 10.77.77.0/24 -o wanunit0 -j MASQUERADE
"${scratch}/runtime" stop
"${scratch}/runtime" stop
iptables -C FORWARD -j DOCKER-USER
iptables -C FORWARD -j ufw-before-forward
iptables -t nat -C POSTROUTING -s 172.17.0.0/16 -j MASQUERADE
! iptables -nL NAIT-ZTR-FWD >/dev/null 2>&1
! iptables -t nat -nL NAIT-ZTR-NAT >/dev/null 2>&1
# Ignore iptables-save timestamps when comparing untouched rules.
diff -u <(grep -v '^#' "${scratch}/before") <(iptables-save | grep -v '^#')
echo 'Isolated firewall lifecycle passed: repeat start/stop; Docker and UFW rules preserved.'
