#!/bin/sh
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; PROJ="$(cd "$HERE/../.." && pwd)"
python3 - "$PROJ" <<'PY'
from pathlib import Path
import sys
s = (Path(sys.argv[1]) / 'luasrc/controller/openclaw.lua').read_text(encoding='utf-8')
assert 'local RUN_DENY' in s, 'RUN_DENY 缺失'
assert 'if not run_argv_allowed(argv)' in s, 'api_run 未走 run_argv_allowed'
for bad in ('reset', 'uninstall', 'migrate', 'tui', 'chat', 'browser', 'exec-policy', 'node'):
    key = '["%s"] = true' % bad if '-' in bad else '%s = true' % bad
    assert key in s, 'RUN_DENY 缺少 %s' % bad
for gone in ('local RUN_TOP', 'local RUN_SUB', 'RUN_BACKUP_FILE'):
    assert gone not in s, '残留窄白名单：%s' % gone
assert 'q(argv[i])' in s, 'argv 未逐 token 转义'
print('    共 12 项，0 项失败')
PY
