import functools
from http.server import HTTPServer
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import threading
import time
import unittest
from unittest.mock import patch, MagicMock
import urllib.error
import urllib.request

SPEC = importlib.util.spec_from_file_location('moon_download', Path(__file__).parents[1] / 'lib/moon_download.py')
m = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(m)


class MoonDownloadTests(unittest.TestCase):
    def test_only_exact_public_file_url_is_served(self):
        handler = functools.partial(m.MoonHandler, content=b'public moon', filename='000000aaaaaaaaaa.moon',
            token='random-token', expires=time.monotonic() + 30)
        with HTTPServer(('127.0.0.1', 0), handler) as server:
            worker = threading.Thread(target=server.serve_forever, daemon=True)
            worker.start()
            base = 'http://127.0.0.1:' + str(server.server_port)
            try:
                with urllib.request.urlopen(base + '/random-token/000000aaaaaaaaaa.moon') as response:
                    self.assertEqual(response.read(), b'public moon')
                    self.assertEqual(response.headers['Cache-Control'], 'no-store')
                for path in ('/', '/moon.json', '/random-token/../moon.json', '/wrong/000000aaaaaaaaaa.moon'):
                    with self.assertRaises(urllib.error.HTTPError) as error:
                        urllib.request.urlopen(base + path)
                    self.assertEqual(error.exception.code, 404)
            finally:
                server.shutdown()
                worker.join()

    def test_expired_link_stops_serving_file(self):
        handler = functools.partial(m.MoonHandler, content=b'moon', filename='000000aaaaaaaaaa.moon',
            token='token', expires=time.monotonic() - 1)
        with HTTPServer(('127.0.0.1', 0), handler) as server:
            worker = threading.Thread(target=server.handle_request, daemon=True)
            worker.start()
            with self.assertRaises(urllib.error.HTTPError) as error:
                urllib.request.urlopen(f'http://127.0.0.1:{server.server_port}/token/000000aaaaaaaaaa.moon')
            self.assertEqual(error.exception.code, 404)
            worker.join()

    def test_cleanup_deletes_only_own_rule_and_directory(self):
        with tempfile.TemporaryDirectory() as root, patch.object(m, 'ROOT', Path(root)):
            folder = Path(root) / (m.PREFIX + 'a' * 24)
            folder.mkdir()
            (folder / 'firewall.json').write_text(json.dumps({'port': 23456, 'unit': folder.name}))
            sibling = Path(root) / 'unrelated'
            sibling.mkdir()
            with patch.object(m, 'run', return_value=subprocess.CompletedProcess([], 0)) as command:
                m.cleanup(folder)
                calls = [args.args[0] for args in command.call_args_list]
                self.assertEqual(calls[1][:5], ['iptables', '-w', '5', '-D', 'INPUT'])
                self.assertIn(folder.name, calls[1])
            self.assertFalse(folder.exists())
            self.assertTrue(sibling.exists())
            for invalid in (sibling, Path(root), Path(root) / '../wrong'):
                with self.assertRaises(ValueError): m.cleanup(invalid)

    def test_private_files_cannot_be_offered(self):
        for filename in ('moon.json', '../authtoken.secret', 'identity.secret', '000000aaaaaaaaaa.moon/../moon.json'):
            with self.assertRaises(ValueError): m.start(filename, '192.0.2.1')

    def test_start_creates_independent_five_minute_service_with_cleanup(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            moon = root / 'public'
            moon.mkdir()
            filename = '000000aaaaaaaaaa.moon'
            (moon / filename).write_bytes(b'public signed moon')
            (moon / 'moon.json').write_text('PRIVATE SIGNING KEY')
            calls = []

            def command(args, check=True):
                calls.append(args)
                folder = Path(args[-1])
                (folder / 'ready.json').write_text('{"port":34567}')
                return subprocess.CompletedProcess(args, 0)

            with patch.object(m, 'ROOT', root), patch.object(m, 'MOON_DIR', moon), patch.object(m, 'run', command):
                result = m.start(filename, '192.0.2.1')
            self.assertTrue(result['url'].startswith('http://192.0.2.1:34567/'))
            self.assertEqual(result['seconds'], 300)
            self.assertIn('--property=RuntimeMaxSec=300', calls[0])
            self.assertTrue(any('ExecStopPost=' in arg and 'cleanup' in arg for arg in calls[0]))
            folder = Path(calls[0][-1])
            self.assertTrue((folder / filename).is_file())
            self.assertFalse((folder / 'moon.json').exists())

    def test_serve_records_firewall_before_opening_and_expires(self):
        with tempfile.TemporaryDirectory() as temp, patch.object(m, 'ROOT', Path(temp)):
            folder = Path(temp) / (m.PREFIX + 'b' * 24)
            folder.mkdir()
            (folder / 'config.json').write_text(json.dumps({'filename': '000000aaaaaaaaaa.moon', 'token': 'token'}))
            (folder / '000000aaaaaaaaaa.moon').write_bytes(b'public')
            server = MagicMock()
            server.server_port = 34567
            manager = MagicMock()
            manager.__enter__.return_value = server

            def command(args):
                self.assertTrue((folder / 'firewall.json').is_file())
                self.assertFalse((folder / 'ready.json').exists())
                self.assertEqual(args[:6], ['iptables', '-w', '5', '-I', 'INPUT', '1'])

            with patch.object(m, 'HTTPServer', return_value=manager), patch.object(m.signal, 'signal'), \
                 patch.object(m.time, 'monotonic', side_effect=[0, 0, 301]), patch.object(m, 'run', command):
                m.serve(folder)
            server.handle_request.assert_called_once()
            self.assertEqual(json.loads((folder / 'ready.json').read_text())['port'], 34567)


if __name__ == '__main__':
    unittest.main()
