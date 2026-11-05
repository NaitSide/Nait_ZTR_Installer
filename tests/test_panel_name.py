import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location('panel_name', Path(__file__).parents[1] / 'lib/panel_name.py')
p = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(p)


class PanelNameTests(unittest.TestCase):
    def test_name_uses_node_persist_2_format_and_keeps_manual_name(self):
        with tempfile.TemporaryDirectory() as temp:
            storage = Path(temp)
            node = 'aaaaaaaaaa'
            self.assertTrue(p.fill_name(storage, node, 'vps-hostname'))
            filename = storage / hashlib.md5(node.encode(), usedforsecurity=False).hexdigest()
            self.assertEqual(json.loads(filename.read_text()), {'key': node, 'value': 'vps-hostname', 'ttl': None})
            filename.write_text(json.dumps({'key': node, 'value': 'My server', 'ttl': None}))
            self.assertFalse(p.fill_name(storage, node, 'another-name'))
            self.assertEqual(json.loads(filename.read_text())['value'], 'My server')

    def test_empty_name_filled_and_malformed_storage_left_untouched(self):
        with tempfile.TemporaryDirectory() as temp:
            storage = Path(temp)
            node = 'aaaaaaaaaa'
            filename = storage / hashlib.md5(node.encode(), usedforsecurity=False).hexdigest()
            filename.write_text(json.dumps({'key': node, 'value': ''}))
            self.assertTrue(p.fill_name(storage, node, 'vps'))
            filename.write_text('invalid json')
            with self.assertRaises(ValueError): p.fill_name(storage, node, 'other')
            self.assertEqual(filename.read_text(), 'invalid json')
            with self.assertRaises(ValueError): p.fill_name(storage, '../x', 'vps')


if __name__ == '__main__':
    unittest.main()
