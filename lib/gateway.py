#!/usr/bin/env python3
"""ZeroTier IPv4 gateway. No third-party Python modules are required."""
import argparse
import datetime
import ipaddress
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request

BASE = Path('/etc/naitlab/zerotier/gateway')
STATE = BASE / 'state.json'
TOKEN = Path('/var/lib/zerotier-one/authtoken.secret')
CONTROLLER_MARKER = Path('/etc/naitlab/zerotier/controller.enabled')
SCRIPT = Path('/usr/local/sbin/nait-ztr-gateway')
UNIT = Path('/etc/systemd/system/nait-ztr-gateway.service')
SYSCTL = Path('/etc/sysctl.d/90-nait-ztr-gateway.conf')
SERVICE = 'nait-ztr-gateway.service'
FWD = 'NAIT-ZTR-FWD'
NAT = 'NAIT-ZTR-NAT'
PRIVATE = tuple(ipaddress.IPv4Network(n) for n in ('10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16'))


class GatewayError(Exception):
    pass


def run(args, check=True):
    result = subprocess.run(args, text=True, capture_output=True)
    if check and result.returncode:
        raise GatewayError(f'{args[0]}: {result.stderr.strip()[:400] or "команда не выполнена"}')
    return result


def api(path, data=None, optional=False, method=None):
    try:
        token = TOKEN.read_text().strip()
        request = urllib.request.Request('http://127.0.0.1:9993/' + path,
            data=None if data is None else json.dumps(data).encode(), method=method,
            headers={'X-ZT1-Auth': token, 'Content-Type': 'application/json'})
        with urllib.request.urlopen(request, timeout=8) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        if optional and error.code == 404:
            return None
        raise GatewayError(f'ZeroTier API: HTTP {error.code}.') from None
    except (OSError, ValueError) as error:
        raise GatewayError('Локальный API ZeroTier недоступен. Проверьте службу zerotier-one.') from error


def prerequisite():
    if not shutil.which('zerotier-cli'):
        raise GatewayError('ZeroTier не установлен. Сначала выберите пункт 1 (Controller) или 2 (клиент).')
    if run(['systemctl', 'is-active', '--quiet', 'zerotier-one'], check=False).returncode:
        raise GatewayError('Служба zerotier-one не запущена. Запустите её перед настройкой шлюза.')


def network_id(value):
    if not re.fullmatch('[0-9a-fA-F]{16}', value):
        raise GatewayError('Network ID должен содержать 16 шестнадцатеричных символов.')
    return value.lower()


def interface_name(value):
    if not re.fullmatch(r'[a-zA-Z0-9_.:-]{1,15}', value):
        raise GatewayError('Некорректное имя сетевого интерфейса.')
    return value


def local_networks():
    rows = api('network')
    if not isinstance(rows, list):
        raise GatewayError('Некорректный список локальных сетей ZeroTier.')
    return {r.get('nwid', r.get('id')): r for r in rows}


def networks():
    prerequisite()
    rows = local_networks()
    managed = api('controller/network', optional=True) or []
    ids = list(managed) if isinstance(managed, dict) else [r if isinstance(r, str) else r.get('nwid', r.get('id')) for r in managed]
    result = []
    for nwid in sorted(set(ids) | set(rows)):
        if not isinstance(nwid, str) or not re.fullmatch('[0-9a-f]{16}', nwid):
            continue
        controlled = nwid in ids
        row = api('controller/network/' + nwid) if controlled else rows[nwid]
        result.append({'id': nwid, 'name': row.get('name') or '(без имени)',
            'controller': controlled, 'status': rows.get(nwid, {}).get('status', 'NOT_JOINED')})
    if not result:
        if CONTROLLER_MARKER.exists():
            raise GatewayError('На Controller нет ZeroTier-сетей. Сначала создайте сеть: пункт 3 или ZTNCUI.')
        raise GatewayError('Этот узел не подключён ни к одной сети. Используйте пункт 4, затем авторизуйте узел на Controller.')
    return result


def subnet_from_network(row, local=None):
    candidates = set()
    for route in row.get('routes', []):
        if route.get('via'):
            continue
        try:
            net = ipaddress.IPv4Network(route.get('target', ''), strict=False)
        except ValueError:
            continue
        if 8 <= net.prefixlen <= 30 and any(net.subnet_of(p) for p in PRIVATE):
            candidates.add(net.with_prefixlen)
    if not candidates and local:
        for address in local.get('assignedAddresses', []):
            try:
                net = ipaddress.IPv4Interface(address).network
            except ValueError:
                continue
            if 8 <= net.prefixlen <= 30 and any(net.subnet_of(p) for p in PRIVATE):
                candidates.add(net.with_prefixlen)
    if len(candidates) != 1:
        raise GatewayError('Для шлюза нужна одна однозначная IPv4-подсеть RFC1918 (/8–/30) с прямым маршрутом в выбранной сети.')
    return ipaddress.IPv4Network(candidates.pop())


def members(nwid):
    rows = api('controller/network/' + nwid + '/member')
    if isinstance(rows, dict):
        for node, value in rows.items():
            if not re.fullmatch('[0-9a-f]{10}', node):
                continue
            yield node, value if isinstance(value, dict) else api('controller/network/' + nwid + '/member/' + node)
    elif isinstance(rows, list):
        for row in rows:
            node = row if isinstance(row, str) else row.get('address', row.get('id', ''))
            if re.fullmatch('[0-9a-f]{10}', node):
                yield node, api('controller/network/' + nwid + '/member/' + node)


def check_overlap(subnet, zt_interface):
    routes = json.loads(run(['ip', '-j', '-4', 'route', 'show', 'table', 'main']).stdout)
    for route in routes:
        if route.get('dst', 'default') == 'default' or route.get('dev') == zt_interface:
            continue
        try:
            other = ipaddress.IPv4Network(route['dst'], strict=False)
        except (ValueError, KeyError):
            continue
        # Ignore default-equivalent VPN routes, but reject overlapping LANs.
        if other.prefixlen > 1 and subnet.overlaps(other):
            raise GatewayError(f'Подсеть {subnet} пересекается с маршрутом {other} на {route.get("dev", "?")}. Выберите другую сеть.')


def plan(nwid, wan=None):
    nwid = network_id(nwid)
    choices = {n['id']: n for n in networks()}
    if nwid not in choices:
        raise GatewayError('Выберите сеть из списка текущего узла/контроллера.')
    controlled = choices[nwid]['controller']
    local = local_networks().get(nwid)
    row = api('controller/network/' + nwid) if controlled else local
    if controlled and row.get('private') is not True:
        raise GatewayError('Для интернет-шлюза используйте private-сеть с авторизацией участников.')
    subnet = subnet_from_network(row, local)
    address = str(subnet.network_address + 1)
    node = api('status')['address']
    if controlled:
        for member_id, member in members(nwid):
            if member_id != node and address in member.get('ipAssignments', []):
                raise GatewayError(f'Адрес шлюза {address} уже назначен другому узлу ({member_id}). Освободите его на Controller.')
    else:
        if local.get('type') != 'PRIVATE':
            raise GatewayError('Для интернет-шлюза используйте private-сеть.')
        if local.get('status') != 'OK':
            raise GatewayError(f'Сеть имеет статус {local.get("status", "UNKNOWN")}. Проверьте одобрение, Controller и Moon.')
        if not any(a.split('/')[0] == address for a in local.get('assignedAddresses', [])):
            raise GatewayError(f'На удалённом Controller закрепите за этим узлом {address}; затем повторите пункт 8.')
    zt_interface = (local or {}).get('portDeviceName')
    if zt_interface:
        interface_name(zt_interface)
    check_overlap(subnet, zt_interface)
    defaults = json.loads(run(['ip', '-j', '-4', 'route', 'show', 'default']).stdout)
    if not wan:
        usable = [r for r in defaults if r.get('dev') and not r['dev'].startswith('zt')]
        if len(usable) != 1:
            raise GatewayError('Не удалось однозначно определить внешний интерфейс. Проверьте основной маршрут IPv4.')
        wan = usable[0]['dev']
    wan = interface_name(wan)
    if wan == zt_interface or wan.startswith(('zt', 'docker', 'veth')):
        raise GatewayError('Внешний интерфейс не должен быть интерфейсом ZeroTier или Docker.')
    run(['ip', 'link', 'show', 'dev', wan])
    return {'network': nwid, 'name': choices[nwid]['name'], 'controller': controlled, 'node': node,
        'subnet': subnet.with_prefixlen, 'gateway': address, 'zt_interface': zt_interface, 'wan_interface': wan}


def write(path, content, mode):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)
    path.chmod(mode)


def firewall_script(p):
    zt, wan, subnet = (shlex.quote(p[k]) for k in ('zt_interface', 'wan_interface', 'subnet'))
    return f'''#!/bin/sh
# Managed by Nait ZTR Installer. Only its dedicated chains are modified.
set -eu
ipt() {{ /usr/sbin/iptables -w "$@"; }}
chain() {{ ipt -t "$1" -nL "$2" >/dev/null 2>&1 || ipt -t "$1" -N "$2"; }}
rule() {{ table="$1"; shift; ipt -t "$table" -C "$@" 2>/dev/null || ipt -t "$table" -A "$@"; }}
unhook() {{ while ipt -t "$1" -C "$2" -j "$3" 2>/dev/null; do ipt -t "$1" -D "$2" -j "$3"; done; }}
drop_chain() {{ if ipt -t "$1" -nL "$2" >/dev/null 2>&1; then ipt -t "$1" -F "$2"; ipt -t "$1" -X "$2"; fi; }}
case "${{1:-start}}" in
start)
  /usr/sbin/sysctl -w net.ipv4.ip_forward=1 >/dev/null
  chain nat {NAT}
  chain filter {FWD}
  rule nat {NAT} -s {subnet} -o {wan} -j MASQUERADE
  rule filter {FWD} -i {zt} -o {wan} -s {subnet} -j ACCEPT
  rule filter {FWD} -i {wan} -o {zt} -d {subnet} -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  ipt -t filter -C FORWARD -j {FWD} 2>/dev/null || ipt -t filter -I FORWARD 1 -j {FWD}
  rule nat POSTROUTING -j {NAT}
  ;;
stop)
  unhook filter FORWARD {FWD}
  unhook nat POSTROUTING {NAT}
  drop_chain filter {FWD}
  drop_chain nat {NAT}
  ;;
*) exit 2 ;;
esac
'''


def unit_text():
    return f'''[Unit]
Description=Nait ZTR ZeroTier IPv4 internet gateway
After=network-online.target zerotier-one.service ufw.service docker.service
Wants=network-online.target zerotier-one.service

[Service]
Type=oneshot
ExecStart={SCRIPT} start
ExecStop={SCRIPT} stop
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
'''


def load_state():
    if not STATE.exists():
        return None
    state = json.loads(STATE.read_text())
    if state.get('owner') != 'Nait_ZTR_Installer' or state.get('schema') != 1:
        raise GatewayError('Неизвестный формат состояния шлюза. Автоматическое изменение запрещено.')
    network_id(state['network'])
    interface_name(state['zt_interface'])
    interface_name(state['wan_interface'])
    return state


def backup_dir():
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
    path = BASE / 'backups' / stamp
    path.mkdir(parents=True, mode=0o700)
    return path


def restore_membership(p, previous_local, previous_member):
    if p['controller']:
        member_path = 'controller/network/' + p['network'] + '/member/' + p['node']
        if previous_member is None:
            api(member_path, method='DELETE', optional=True)
        else:
            payload = {k: previous_member[k] for k in ('authorized', 'ipAssignments', 'noAutoAssignIps', 'name') if k in previous_member}
            api(member_path, payload)
    if previous_local is None:
        api('network/' + p['network'], method='DELETE', optional=True)
    else:
        api('network/' + p['network'], {k: previous_local[k] for k in ('allowManaged', 'allowDefault') if k in previous_local})


def cleanup_files():
    for path in (UNIT, SCRIPT, SYSCTL, STATE):
        path.unlink(missing_ok=True)
    run(['systemctl', 'daemon-reload'])


def disable():
    state = load_state()
    if not state:
        return {'configured': False, 'message': 'Шлюз не настроен.'}
    backup = backup_dir()
    shutil.copyfile(STATE, backup / 'disabled-state.json')
    # ExecStop removes only this installer's chains and hooks.
    run(['systemctl', 'disable', '--now', SERVICE])
    if SCRIPT.exists():
        run([str(SCRIPT), 'stop'])
    cleanup_files()
    return {'configured': False, 'message': 'Правила шлюза удалены. Сеть, адрес узла, Controller и Moon сохранены. Удалите маршрут 0.0.0.0/0 через этот узел из ZTNCUI. Общий ip_forward оставлен без изменения.'}


def apply(nwid, wan=None, replace=False):
    p = plan(nwid, wan)
    previous = load_state()
    if previous:
        same = all(previous[k] == p[k] for k in ('network', 'subnet', 'gateway', 'wan_interface'))
        if same and p['zt_interface'] == previous['zt_interface']:
            run(['systemctl', 'restart', SERVICE])
            return status()
        if not replace:
            raise GatewayError('Шлюз уже настроен для другой сети/интерфейса. Используйте «Изменить настройку».')
        disable()
        try:
            return apply(nwid, wan)
        except Exception as error:
            try:
                apply(previous['network'], previous['wan_interface'])
            except Exception as restore_error:
                raise GatewayError(f'Изменение не выполнено; прежний шлюз также не восстановлен: {restore_error}') from error
            raise GatewayError('Изменение не выполнено. Прежняя конфигурация шлюза восстановлена.') from error
    for command in ('iptables', 'iptables-save', 'sysctl', 'systemctl', 'ip'):
        if not shutil.which(command):
            raise GatewayError(f'Не найдена команда {command}. Установите необходимый системный пакет перед настройкой шлюза.')
    for path in (SCRIPT, UNIT, SYSCTL):
        if path.exists():
            raise GatewayError(f'Уже существует {path}, но нет состояния установщика. Чужие файлы не перезаписываются.')
    for table, chain in (('filter', FWD), ('nat', NAT)):
        if run(['iptables', '-w', '-t', table, '-nL', chain], check=False).returncode == 0:
            raise GatewayError(f'Цепочка {chain} уже существует. Без состояния установщика она не изменяется.')
    saved_local = local_networks().get(p['network'])
    member_path = 'controller/network/' + p['network'] + '/member/' + p['node']
    saved_member = api(member_path, optional=True) if p['controller'] else None
    backup = backup_dir()
    write(backup / 'before.json', json.dumps({'local': saved_local, 'member': saved_member}, indent=2), 0o600)
    write(backup / 'iptables.rules', run(['iptables-save']).stdout, 0o600)
    changed_membership = False
    try:
        changed_membership = True
        if p['controller']:
            subnet = ipaddress.IPv4Network(p['subnet'])
            retained = [a for a in (saved_member or {}).get('ipAssignments', [])
                if ipaddress.ip_address(a).version == 6 or ipaddress.ip_address(a) not in subnet]
            api(member_path, {'authorized': True, 'noAutoAssignIps': True, 'ipAssignments': [p['gateway']] + retained})
        api('network/' + p['network'], {'allowManaged': True, 'allowDefault': False})
        for _ in range(30):
            local = local_networks().get(p['network'], {})
            addresses = [a.split('/')[0] for a in local.get('assignedAddresses', [])]
            if local.get('status') == 'OK' and p['gateway'] in addresses and local.get('portDeviceName'):
                p['zt_interface'] = interface_name(local['portDeviceName'])
                break
            time.sleep(1)
        else:
            raise GatewayError('Узел не получил адрес шлюза за 30 секунд. Проверьте авторизацию и доступность Controller/Moon.')
        check_overlap(ipaddress.IPv4Network(p['subnet']), p['zt_interface'])
        state = dict(p, owner='Nait_ZTR_Installer', schema=1, backup=str(backup))
        write(STATE, json.dumps(state, indent=2), 0o600)
        write(SCRIPT, firewall_script(p), 0o755)
        write(SYSCTL, '# Managed by Nait ZTR Installer\nnet.ipv4.ip_forward=1\n', 0o644)
        write(UNIT, unit_text(), 0o644)
        run(['systemctl', 'daemon-reload'])
        run(['systemctl', 'enable', '--now', SERVICE])
        result = status()
        if not result['active'] or not result['rules_present'] or not result['ipv4_forwarding']:
            raise GatewayError('Служба шлюза или её правила не прошли проверку.')
        return result
    except Exception as error:
        cleanup_errors = []
        for args in (['systemctl', 'disable', '--now', SERVICE], [str(SCRIPT), 'stop'] if SCRIPT.exists() else None):
            if args:
                result = run(args, check=False)
                if result.returncode and args[0] != 'systemctl':
                    cleanup_errors.append('не удалось удалить правила шлюза')
        if not cleanup_errors:
            cleanup_files()
        if changed_membership:
            try:
                restore_membership(p, saved_local, saved_member)
            except Exception:
                cleanup_errors.append('проверьте восстановление членства узла на Controller')
        suffix = '; '.join(cleanup_errors) or 'изменения шлюза отменены; общий ip_forward сохранён'
        raise GatewayError(f'{error}; {suffix}. Резервная копия: {backup}') from error


def status():
    state = load_state()
    if not state:
        return {'configured': False, 'active': False}
    active = run(['systemctl', 'is-active', '--quiet', SERVICE], check=False).returncode == 0
    rules = [
        ['iptables', '-w', '-t', 'filter', '-C', 'FORWARD', '-j', FWD],
        ['iptables', '-w', '-t', 'nat', '-C', 'POSTROUTING', '-j', NAT],
        ['iptables', '-w', '-t', 'nat', '-C', NAT, '-s', state['subnet'], '-o', state['wan_interface'], '-j', 'MASQUERADE'],
        ['iptables', '-w', '-C', FWD, '-i', state['zt_interface'], '-o', state['wan_interface'], '-s', state['subnet'], '-j', 'ACCEPT'],
        ['iptables', '-w', '-C', FWD, '-i', state['wan_interface'], '-o', state['zt_interface'], '-d', state['subnet'], '-m', 'conntrack', '--ctstate', 'ESTABLISHED,RELATED', '-j', 'ACCEPT'],
    ]
    present = all(run(args, check=False).returncode == 0 for args in rules)
    return dict(state, configured=True, active=active, rules_present=present,
        ipv4_forwarding=run(['sysctl', '-n', 'net.ipv4.ip_forward']).stdout.strip() == '1')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('command', choices=('networks', 'plan', 'apply', 'status', 'disable'))
    parser.add_argument('--network')
    parser.add_argument('--wan')
    parser.add_argument('--replace', action='store_true')
    args = parser.parse_args()
    if os.geteuid() != 0:
        raise GatewayError('Для настройки и чтения состояния шлюза нужны root/sudo.')
    os.umask(0o077)
    if args.command == 'networks':
        result = networks()
    elif args.command == 'plan':
        result = plan(args.network or '', args.wan)
    elif args.command == 'apply':
        result = apply(args.network or '', args.wan, args.replace)
    elif args.command == 'disable':
        result = disable()
    else:
        result = status()
    print(json.dumps(result, ensure_ascii=False))


if __name__ == '__main__':
    try:
        main()
    except (GatewayError, OSError, ValueError, KeyError) as error:
        print(f'[ОШИБКА] {error}', file=sys.stderr)
        sys.exit(1)
