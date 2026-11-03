#!/bin/sh
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; PROJ="$(cd "$HERE/../.." && pwd)"
python3 - "$PROJ" <<'PY'
from pathlib import Path
import sys
s = (Path(sys.argv[1]) / 'luasrc/controller/openclaw.lua').read_text(encoding='utf-8')

n = 0
def ok(cond, name):
    global n
    assert cond, name
    n += 1

ok('local RUN_DENY' in s, 'RUN_DENY 存在')
ok('if not run_argv_allowed(argv)' in s, 'api_run 走 run_argv_allowed')
for bad in ('reset', 'uninstall', 'migrate', 'tui', 'chat', 'browser', 'exec-policy', 'node'):
    key = '["%s"] = true' % bad if '-' in bad else '%s = true' % bad
    ok(key in s, 'RUN_DENY 缺少 %s' % bad)
for gone in ('local RUN_TOP', 'local RUN_SUB', 'RUN_BACKUP_FILE'):
    ok(gone not in s, '残留窄白名单：%s' % gone)
ok('q(argv[i])' in s, 'argv 未逐 token 转义')

# 计数与实际断言数一致（早先打印 12 而实际 14，自述与代码不符）
print('    共 %d 项，0 项失败' % n)
PY
