#!/usr/bin/env python3
import os
import re
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]
lines = (root / '.env.core').read_text().splitlines()
token = next((line.partition('=')[2].strip() for line in lines if line.startswith('BENCH_API_TOKEN=')), '')
if token and not re.fullmatch(r'[a-fA-F0-9]{64}', token):
    raise SystemExit('BENCH_API_TOKEN must be empty or a 64-character hexadecimal token.')
body = 'map $http_authorization $bench_ok {\n    default 0;\n'
if token:
    body += f'    "~^[Bb]earer {token}$" 1;\n'
body += '}\n'
folder = root / 'state'
folder.mkdir(exist_ok=True)
fd, temporary = tempfile.mkstemp(dir=folder)
with os.fdopen(fd, 'w') as fp:
    fp.write(body)
os.chmod(temporary, 0o600)
os.replace(temporary, folder / 'bench.conf')
print('Benchmark map generated from the backend token. Recreate core and edge to apply it.')
