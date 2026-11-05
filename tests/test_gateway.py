import copy
import importlib.util
import ipaddress
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('gateway', Path(__file__).parents[1] / 'lib/gateway.py')
g = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(g)
NW = 'aaaaaaaaaa123456'
NODE = 'aaaaaaaaaa'


class FakeHost:
    def __init__(self):
        self.local = []
        self.member = None
        self.controlled = True
        self.member_rows = {}
        self.active = False
        self.fail_enable = False
        self.overlap = False
        self.commands = []
        self.requests = []

    def api(self, path, data=None, optional=False, method=None):
        self.requests.append((path, copy.deepcopy(data), method))
        if path == 'status': return {'address': NODE}
        if path == 'network': return copy.deepcopy(self.local)
        if path == 'controller/network': return [NW] if self.controlled else []
        if path == 'controller/network/' + NW:
            return {'id': NW, 'name': 'test', 'private': True, 'routes': [{'target': '10.77.77.0/24', 'via': None}, {'target': '0.0.0.0/0', 'via': '10.77.77.1'}]}
        if path == 'controller/network/' + NW + '/member': return copy.deepcopy(self.member_rows)
        if path.endswith('/member/' + NODE):
            if method == 'DELETE': self.member = None
            elif data is not None: self.member = copy.deepcopy(data)
            return copy.deepcopy(self.member)
        if '/member/' in path:
            return copy.deepcopy(self.member_rows[path.rsplit('/', 1)[1]])
        if path == 'network/' + NW:
            if method == 'DELETE':
                self.local = []
                return {}
            row = {'nwid': NW, 'name': 'test', 'type': 'PRIVATE', 'status': 'OK', 'portDeviceName': 'ztfake0', 'assignedAddresses': ['10.77.77.1/24']}
            row.update(data or {})
            self.local = [row]
            return copy.deepcopy(row)
        raise AssertionError(path)

    def run(self, args, check=True):
        self.commands.append(list(args))
        code, out = 0, ''
        if args[:5] == ['ip', '-j', '-4', 'route', 'show']:
            if args[-1] == 'default': out = json.dumps([{'dst': 'default', 'dev': 'eth0', 'gateway': '192.0.2.1'}])
            else: out = json.dumps([{'dst': '10.77.77.0/24', 'dev': 'eth0'}] if self.overlap else [])
        elif args[:2] == ['iptables', '-w'] and '-nL' in args: code = int(not self.active)
        elif args[0] == 'iptables-save': out = 'DOCKER and UFW snapshot\n'
        elif args[:2] == ['systemctl', 'enable']:
            if self.fail_enable:
                self.fail_enable -= 1
                raise g.GatewayError('simulated activation failure')
            self.active = True
        elif args[:2] == ['systemctl', 'disable']: self.active = False
        elif args[:2] == ['systemctl', 'is-active'] and args[-1] == g.SERVICE: code = int(not self.active)
        elif args[0] == 'iptables' and '-C' in args: code = int(not self.active)
        elif args[0] == 'sysctl': out = '1\n'
        if check and code: raise g.GatewayError('simulated command error')
        return subprocess.CompletedProcess(args, code, out, '')


class GatewayTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.host = FakeHost()
        self.patches = [patch.object(g, 'BASE', self.root/'gateway'), patch.object(g, 'STATE', self.root/'gateway/state.json'),
            patch.object(g, 'SCRIPT', self.root/'bin/nait-ztr-gateway'), patch.object(g, 'UNIT', self.root/'systemd/nait-ztr-gateway.service'),
            patch.object(g, 'SYSCTL', self.root/'sysctl/gateway.conf'), patch.object(g, 'CONTROLLER_MARKER', self.root/'controller.enabled'),
            patch.object(g, 'api', self.host.api), patch.object(g, 'run', self.host.run),
            patch.object(g.shutil, 'which', lambda command: '/usr/bin/' + command), patch.object(g.time, 'sleep', lambda _: None)]
        for item in self.patches: item.start()

    def tearDown(self):
        for item in reversed(self.patches): item.stop()
        self.temp.cleanup()

    def test_no_zerotier(self):
        with patch.object(g.shutil, 'which', return_value=None):
            with self.assertRaisesRegex(g.GatewayError, 'пункт 1'): g.networks()

    def test_controller_without_network(self):
        g.CONTROLLER_MARKER.touch()
        self.host.controlled = False
        with self.assertRaisesRegex(g.GatewayError, 'пункт 3'): g.networks()

    def test_created_network_can_be_selected_before_join(self):
        result = g.plan(NW)
        self.assertEqual(result['gateway'], '10.77.77.1')
        self.assertIsNone(result['zt_interface'])
        self.assertFalse(any(data is not None for _, data, _ in self.host.requests))

    def test_reserved_gateway_address_collision(self):
        self.host.member_rows = {'bbbbbbbbbb': {'ipAssignments': ['10.77.77.1']}}
        with self.assertRaisesRegex(g.GatewayError, 'уже назначен'): g.plan(NW)

    def test_overlapping_lan_rejected(self):
        self.host.overlap = True
        with self.assertRaisesRegex(g.GatewayError, 'пересекается'): g.plan(NW)

    def test_pending_remote_client_not_silently_authorized(self):
        self.host.controlled = False
        self.host.local = [{'nwid': NW, 'type': 'PRIVATE', 'status': 'ACCESS_DENIED', 'routes': [{'target': '10.77.77.0/24'}]}]
        with self.assertRaisesRegex(g.GatewayError, 'ACCESS_DENIED'): g.plan(NW)

    def test_remote_gateway_needs_first_address(self):
        self.host.controlled = False
        self.host.local = [{'nwid': NW, 'type': 'PRIVATE', 'status': 'OK', 'routes': [{'target': '10.77.77.0/24'}], 'assignedAddresses': ['10.77.77.40/24']}]
        with self.assertRaisesRegex(g.GatewayError, 'закрепите'): g.plan(NW)

    def test_invalid_network_and_interface_never_reach_commands(self):
        for value in ('; reboot', 'eth0;id', 'a'*16, 'eth0\n'):
            with self.assertRaises(g.GatewayError): g.interface_name(value)
        with self.assertRaises(g.GatewayError): g.network_id('../status')

    def test_ipv4_subnet_selection_does_not_treat_default_as_lan(self):
        row = {'routes': [{'target': '0.0.0.0/0', 'via': '10.77.77.1'}, {'target': '10.77.77.0/24'}]}
        self.assertEqual(str(g.subnet_from_network(row)), '10.77.77.0/24')
        for cidr in ('0.0.0.0/0', '192.0.2.0/24', '10.1.1.0/31'):
            with self.assertRaises(g.GatewayError): g.subnet_from_network({'routes': [{'target': cidr}]})

    def test_apply_joins_authorizes_and_keeps_provider_default(self):
        result = g.apply(NW)
        self.assertTrue(result['rules_present'])
        self.assertEqual(self.host.member['ipAssignments'], ['10.77.77.1'])
        self.assertTrue(self.host.member['noAutoAssignIps'])
        self.assertFalse(self.host.local[0]['allowDefault'])
        self.assertTrue(g.UNIT.exists())
        script = g.SCRIPT.read_text()
        self.assertIn('-s 10.77.77.0/24 -o eth0 -j MASQUERADE', script)
        self.assertNotIn('ufw disable', script)
        self.assertNotIn('iptables -F', script)

    def test_repeat_application_does_not_duplicate_membership(self):
        g.apply(NW)
        self.host.requests.clear()
        g.apply(NW)
        self.assertFalse(any(data is not None for _, data, _ in self.host.requests))

    def test_failed_activation_restores_membership_and_removes_files(self):
        self.host.member = {'authorized': False, 'ipAssignments': ['10.77.77.99'], 'noAutoAssignIps': False}
        old = copy.deepcopy(self.host.member)
        self.host.fail_enable = True
        with self.assertRaisesRegex(g.GatewayError, 'отменены'): g.apply(NW)
        self.assertEqual(self.host.member, old)
        self.assertEqual(self.host.local, [])
        self.assertFalse(g.STATE.exists())
        self.assertFalse(g.UNIT.exists())

    def test_disable_preserves_network_and_does_not_reset_shared_forwarding(self):
        g.apply(NW)
        self.host.requests.clear()
        self.host.commands.clear()
        result = g.disable()
        self.assertFalse(result['configured'])
        self.assertTrue(self.host.local)
        self.assertEqual(self.host.requests, [])
        self.assertFalse(any('net.ipv4.ip_forward=0' in arg for cmd in self.host.commands for arg in cmd))
        self.assertFalse(g.STATE.exists())

    def test_existing_unmanaged_file_not_overwritten(self):
        g.UNIT.parent.mkdir(parents=True)
        g.UNIT.write_text('user configuration')
        with self.assertRaisesRegex(g.GatewayError, 'не перезаписываются'): g.apply(NW)
        self.assertEqual(g.UNIT.read_text(), 'user configuration')

    def test_existing_ipv6_assignment_preserved(self):
        self.host.member = {'authorized': True, 'ipAssignments': ['10.77.77.90', 'fd00::10']}
        g.apply(NW)
        self.assertEqual(self.host.member['ipAssignments'], ['10.77.77.1', 'fd00::10'])

    def test_failed_reconfiguration_restores_previous_gateway(self):
        g.apply(NW)
        self.host.fail_enable = 1
        with self.assertRaisesRegex(g.GatewayError, 'Прежняя конфигурация шлюза восстановлена'):
            g.apply(NW, wan='eth1', replace=True)
        state = g.load_state()
        self.assertEqual(state['wan_interface'], 'eth0')
        self.assertTrue(self.host.active)


if __name__ == '__main__':
    unittest.main()
