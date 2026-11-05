#!/usr/bin/env python3
"""Publish VPN Edition resolvers through the local ZeroTier controller."""
import argparse
import json
import os
import sys

from gateway import api, network_id, GatewayError

SERVERS = ['8.8.8.8', '1.1.1.1']


def current_dns(nwid):
    row = api('controller/network/' + network_id(nwid))
    dns = row.get('dns') or {}
    if not isinstance(dns, dict) or not isinstance(dns.get('servers', []), list):
        raise GatewayError('Controller вернул некорректную конфигурацию DNS.')
    return dns


def plan(nwid):
    dns = current_dns(nwid)
    return {'dns': dns, 'conflict': bool(dns.get('servers') and dns['servers'] != SERVERS)}


def apply(nwid, expected):
    current = current_dns(nwid)
    if current != expected:
        raise GatewayError('Настройки DNS изменились после показа плана. Запустите VPN Edition повторно.')
    if current.get('servers') == SERVERS:
        return {'changed': False, 'servers': SERVERS}
    desired = dict(current, servers=SERVERS)
    desired.setdefault('domain', '')
    path = 'controller/network/' + network_id(nwid)
    try:
        api(path, {'dns': desired})
        actual = current_dns(nwid)
        if actual.get('servers') != SERVERS or actual.get('domain', '') != desired['domain']:
            raise GatewayError('Controller не подтвердил настройку DNS.')
    except Exception as error:
        try:
            if current_dns(nwid) == desired:
                api(path, {'dns': dict(current, domain=current.get('domain', ''), servers=current.get('servers', []))})
        except Exception:
            raise GatewayError('Не удалось подтвердить или восстановить DNS; проверьте настройки сети в ZTNCUI.') from error
        raise
    return {'changed': True, 'servers': SERVERS}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('command', choices=('plan', 'apply'))
    parser.add_argument('--network', required=True)
    parser.add_argument('--expected-dns')
    args = parser.parse_args()
    if os.geteuid() != 0:
        raise GatewayError('Для настройки DNS нужен root/sudo.')
    if args.command == 'plan':
        result = plan(args.network)
    else:
        if args.expected_dns is None:
            raise GatewayError('Сначала получите план DNS.')
        result = apply(args.network, json.loads(args.expected_dns))
    print(json.dumps(result, ensure_ascii=False))


if __name__ == '__main__':
    try:
        main()
    except (GatewayError, OSError, ValueError, KeyError) as error:
        print(f'[ОШИБКА] DNS VPN Edition: {error}', file=sys.stderr)
        sys.exit(1)
