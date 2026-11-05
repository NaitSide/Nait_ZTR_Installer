#!/usr/bin/env python3
"""Serve one public Moon file using a short-lived systemd service."""
import argparse
import functools
from http.server import BaseHTTPRequestHandler, HTTPServer
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import signal
import subprocess
import sys
import time

ROOT = Path('/run')
MOON_DIR = Path('/etc/naitlab/zerotier/moon')
PREFIX = 'nait-ztr-moon-'
TTL = 300


def run(args, check=True):
    return subprocess.run(args, check=check, capture_output=True, text=True, timeout=15)


def directory(value):
    path = Path(value)
    if path.parent != ROOT or not re.fullmatch(PREFIX + '[0-9a-f]{24}', path.name) or path.is_symlink():
        raise ValueError('Некорректный временный каталог Moon.')
    return path


def firewall_rule(info):
    return ['-p', 'tcp', '--dport', str(info['port']), '-m', 'comment',
            '--comment', info['unit'], '-j', 'ACCEPT']


def save_json(path, value):
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(value))
    temporary.replace(path)


def cleanup(value):
    path = directory(value)
    if not path.exists():
        return
    config = path / 'firewall.json'
    if config.exists():
        info = json.loads(config.read_text())
        if info['unit'] != path.name or not isinstance(info['port'], int) or not 1024 <= info['port'] <= 65535:
            raise ValueError('Некорректное состояние временного firewall.')
        rule = firewall_rule(info)
        result = run(['iptables', '-w', '5', '-C', 'INPUT'] + rule, check=False)
        if result.returncode == 0:
            run(['iptables', '-w', '5', '-D', 'INPUT'] + rule)
        elif result.returncode != 1:
            raise RuntimeError('Не удалось проверить временное правило firewall.')
    # Only this explicitly validated, installer-owned directory is removed.
    shutil.rmtree(path)


class MoonHandler(BaseHTTPRequestHandler):
    def __init__(self, *args, content, filename, token, expires, **kwargs):
        self.content, self.filename, self.token, self.expires = content, filename, token, expires
        super().__init__(*args, **kwargs)

    def setup(self):
        super().setup()
        self.connection.settimeout(2)

    def do_GET(self):
        expected = '/' + self.token + '/' + self.filename
        if time.monotonic() >= self.expires or self.path != expected:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header('Content-Type', 'application/octet-stream')
        self.send_header('Content-Disposition', 'attachment; filename="' + self.filename + '"')
        self.send_header('Content-Length', str(len(self.content)))
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.end_headers()
        self.wfile.write(self.content)

    def log_message(self, *_):
        pass


def serve(value):
    path = directory(value)
    info = json.loads((path / 'config.json').read_text())
    filename = info['filename']
    if not re.fullmatch(r'000000[0-9a-f]{10}\.moon', filename):
        raise ValueError('Некорректное имя публичного файла Moon.')
    expires = time.monotonic() + TTL
    handler = functools.partial(MoonHandler, content=(path / filename).read_bytes(),
        filename=filename, token=info['token'], expires=expires)
    stopped = False

    def stop(*_):
        nonlocal stopped
        stopped = True

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    with HTTPServer(('0.0.0.0', 0), handler) as server:
        info['port'] = server.server_port
        info['unit'] = path.name
        save_json(path / 'firewall.json', info)
        run(['iptables', '-w', '5', '-I', 'INPUT', '1'] + firewall_rule(info))
        save_json(path / 'ready.json', {'port': server.server_port})
        server.timeout = 0.5
        while not stopped and time.monotonic() < expires:
            server.handle_request()


def start(filename, public_ip):
    if not re.fullmatch(r'000000[0-9a-f]{10}\.moon', filename):
        raise ValueError('Разрешена выдача только публичного файла .moon.')
    public_ip = str(ipaddress.IPv4Address(public_ip))
    source = MOON_DIR / filename
    if not source.is_file() or source.is_symlink():
        raise ValueError('Публичный файл Moon не найден.')
    unit = PREFIX + secrets.token_hex(12)
    path = ROOT / unit
    path.mkdir(mode=0o700)
    helper = path / 'download.py'
    try:
        shutil.copyfile(source, path / filename)
        shutil.copyfile(Path(__file__), helper)
        token = secrets.token_urlsafe(32)
        save_json(path / 'config.json', {'filename': filename, 'token': token})
        run(['systemd-run', '--quiet', '--collect', '--unit=' + unit,
             '--property=Type=exec', '--property=RuntimeMaxSec=300', '--property=TimeoutStopSec=5',
             '--property=UMask=0077',
             '--property=ExecStopPost=/usr/bin/python3 ' + str(helper) + ' cleanup ' + str(path),
             '/usr/bin/python3', str(helper), 'serve', str(path)])
        for _ in range(100):
            if (path / 'ready.json').exists():
                port = json.loads((path / 'ready.json').read_text())['port']
                return {'url': f'http://{public_ip}:{port}/{token}/{filename}', 'seconds': TTL}
            if not path.exists():
                break
            time.sleep(0.1)
        raise RuntimeError('Временный сервер Moon не запустился. Проверьте журнал systemd.')
    except Exception:
        run(['systemctl', 'stop', unit + '.service'], check=False)
        cleanup(path)
        raise


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('command', choices=('start', 'serve', 'cleanup'))
    parser.add_argument('value')
    parser.add_argument('--public-ip')
    args = parser.parse_args()
    if os.geteuid() != 0:
        raise ValueError('Для временной выдачи Moon нужен root/sudo.')
    os.umask(0o077)
    if args.command == 'start':
        print(json.dumps(start(args.value, args.public_ip), ensure_ascii=False))
    elif args.command == 'serve':
        serve(args.value)
    else:
        cleanup(args.value)


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(f'[ОШИБКА] Временная ссылка Moon: {error}', file=sys.stderr)
        sys.exit(1)
