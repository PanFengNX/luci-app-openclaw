#!/bin/sh
# cmd_install_status 的 idle/lost 判定测试
# 退出码：0 = 全部通过；1 = 有失败

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
PROJ="$(cd "$HERE/../.." && pwd)"

PY=""
for cand in python3 python; do
	if command -v "$cand" >/dev/null 2>&1; then PY="$cand"; break; fi
done
[ -n "$PY" ] || { echo "    跳过：找不到 python"; exit 0; }

"$PY" - "$PROJ" <<'PYEOF'
import pathlib
import re
import subprocess
import sys
import tempfile

proj = pathlib.Path(sys.argv[1])
NL = chr(10)
src = (proj / 'root/usr/libexec/openclaw/cli.sh').read_text(encoding='utf-8')


def func(name):
    lines = src.splitlines()
    starts = [(i, m.group(1)) for i, line in enumerate(lines)
              for m in [re.match(r'^([a-z_][a-z0-9_]*)\(\)\s*\{', line)] if m]
    for idx, (line_no, function_name) in enumerate(starts):
        if function_name == name:
            end = starts[idx + 1][0] if idx + 1 < len(starts) else len(lines)
            return NL.join(lines[line_no:end])
    raise AssertionError('取不到函数 ' + name)


def P(path):
    value = pathlib.Path(path).as_posix()
    return '/c' + value[2:] if len(value) > 1 and value[1] == ':' else value


total = 0
failed = 0

def check(ok, desc, detail=''):
    global total, failed
    total += 1
    print('    %s  %s%s' % ('ok  ' if ok else 'FAIL', desc,
                           ('  ' + detail) if detail else ''))
    if not ok:
        failed += 1


def run_case(label, marker, alive=False, extra=None):
    work = pathlib.Path(tempfile.mkdtemp())
    rundir = work / 'run'
    rundir.mkdir()
    paths = {
        'done': rundir / 'install.done',
        'rc': rundir / 'install.rc',
        'start': rundir / 'install.start',
        'pid': rundir / 'install.pid',
    }
    for key, value in marker.items():
        paths[key].write_text(value, encoding='utf-8', newline='\n')
    stub = 'return 0' if alive else 'return 1'
    script = NL.join([
        '#!/bin/sh',
        'OC_INST_DONE="%s"' % P(paths['done']),
        'OC_INST_RC="%s"' % P(paths['rc']),
        'OC_INST_START="%s"' % P(paths['start']),
        'OC_INST_PID="%s"' % P(paths['pid']),
        'OC_INST_LOGPATH="%s"' % P(rundir / 'install.logpath'),
        'oc_inst_alive() { %s; }' % stub,
        'oc_inst_starting() { return 1; }',
        'oc_json_str() { printf \'%s\' "$1"; }',
        func('cmd_install_status'),
        'cmd_install_status',
        '',
    ])
    path = work / 'case.sh'
    path.write_text(script, encoding='utf-8', newline='\n')
    result = subprocess.run(['sh', P(path)], capture_output=True, text=True)
    output = result.stdout.strip()
    check('"state":"%s"' % label in output,
          '%s → state=%s' % (label, label), output[:140])
    if extra:
        check(extra in output, '%s 字段契约' % label, output[:140])
        if label == 'idle':
            check('"rc":""' in output, '%s 字段契约' % label, output[:140])


run_case('idle', {}, extra='"msg":""')
run_case('lost', {'start': '1'}, extra='"msg":"后台安装进程已退出')
run_case('lost', {'pid': '12345'}, extra='"msg":"后台安装进程已退出')
run_case('done', {'done': '', 'rc': '0'})
run_case('failed', {'done': '', 'rc': '3'})
run_case('running', {}, alive=True)

print('    共 %s 项，%s 项失败' % (total, failed))
sys.exit(1 if failed else 0)
PYEOF
