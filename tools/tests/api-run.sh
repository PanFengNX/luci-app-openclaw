#!/bin/sh
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; PROJ="$(cd "$HERE/../.." && pwd)"
python3 - "$PROJ" <<'PY'
from pathlib import Path
import re, sys
s=(Path(sys.argv[1])/'luasrc/controller/openclaw.lua').read_text(encoding='utf-8')
assert 'local RUN_TOP' in s and 'local RUN_SUB' in s
assert 'if not run_argv_allowed(argv)' in s
for bad in ('agent = true','message = true','system = true','update = true','table.remove(argv, 1)'):
    assert bad not in s, bad
assert 'RUN_BACKUP_FILE' in s
print('    共 5 项，0 项失败')
PY
