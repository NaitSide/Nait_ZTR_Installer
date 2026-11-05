#!/usr/bin/env python3
"""Fill the local gateway's empty ZTNCUI 0.8.14 display name."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import sys
import tempfile

CONTAINER = 'ztncui_box'
DATA = Path('/opt/naitlab/ztncui_box/data')


def fill_name(storage, node, name):
    if not re.fullmatch('[0-9a-f]{10}', node):
        raise ValueError('Некорректный Node ID.')
    if storage.is_symlink() or not storage.is_dir():
        raise ValueError('Хранилище имён ZTNCUI не найдено.')
    # node-persist 2.x uses MD5(key) as a filename, not as a security mechanism.
    target = storage / hashlib.md5(node.encode(), usedforsecurity=False).hexdigest()
    if target.is_symlink():
        raise ValueError('Хранилище имени содержит символьную ссылку.')
    if target.exists():
        previous = json.loads(target.read_text(encoding='utf-8'))
        if previous.get('key') != node:
            raise ValueError('Файл имени принадлежит другому участнику.')
        if previous.get('value'):
            return False
    owner = storage.stat()
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', dir=storage, delete=False) as stream:
            temporary = Path(stream.name)
            json.dump({'key': node, 'value': name, 'ttl': None}, stream, ensure_ascii=False)
        if hasattr(os, 'chown'):
            os.chown(temporary, owner.st_uid, owner.st_gid)
        temporary.chmod(0o600)
        temporary.replace(target)
    finally:
        if temporary:
            temporary.unlink(missing_ok=True)
    return True


def sync(node):
    result = subprocess.run(['docker', 'inspect', '--type', 'container', CONTAINER],
        capture_output=True, text=True, check=True, timeout=15)
    info = json.loads(result.stdout)[0]
    labels = info.get('Config', {}).get('Labels') or {}
    if labels.get('com.naitlab.component') != 'ztncui' or labels.get('com.naitlab.version') != '0.8.14':
        raise ValueError('Автозаполнение имени поддерживает контейнер ZTNCUI 0.8.14 этого установщика.')
    if not any(m.get('Type') == 'bind' and m.get('Source') == str(DATA)
               and m.get('Destination') == '/opt/key-networks/ztncui/etc' for m in info.get('Mounts', [])):
        raise ValueError('Неизвестный каталог данных контейнера ZTNCUI.')
    if fill_name(DATA / 'storage', node, socket.gethostname()[:128]):
        # node-persist 2.x caches values in memory; reload only the web panel.
        subprocess.run(['docker', 'restart', CONTAINER], capture_output=True, text=True, check=True, timeout=45)
        return True
    return False


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('node')
    args = parser.parse_args()
    try:
        if os.geteuid() != 0:
            raise ValueError('Нужен root/sudo.')
        print(json.dumps({'changed': sync(args.node)}))
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f'[WARN] Имя VPS в ZTNCUI не обновлено: {error}', file=sys.stderr)
        sys.exit(1)
