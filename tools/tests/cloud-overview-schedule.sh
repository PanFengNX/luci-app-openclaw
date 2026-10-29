#!/bin/sh
# cloud-overview-schedule.sh — overview 端点 schedule 子对象的输出契约回归测试
#
# 历史事故：cmd_overview 把 schedule.enabled 输出成数字 1/0（直接用了
# $OC_SCH_ENABLED），而 cmd_schedule_status 输出的是 JSON 布尔 true/false。
# 前端勾选框判定是 d.enabled === true（严格相等），JS 里 1 !== true，
# 于是「定时备份·启用」每次打开页面都被强制清空 —— 保存是成功的
# （crontab 行在），只是显示丢了。
#
# 同时 overview 漏了 keep_local 字段，前端会把它回落显示成默认值 2。
#
# 本测试把 cmd_overview 从 cloud.sh 里抽出来，桩掉它的全部依赖后真跑一遍，
# 用 json.loads 解析真实输出做行为级断言（静态字符串断言防不住类型问题）。
#
# 退出码：0 = 全部通过；1 = 有失败

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
PROJ="$(cd "$HERE/../.." && pwd)"

PY=""
for cand in python3 python "$HOME/.workbuddy/binaries/python/versions/3.13.12/python.exe"; do
	if command -v "$cand" >/dev/null 2>&1 || [ -x "$cand" ]; then PY="$cand"; break; fi
done
[ -n "$PY" ] || { echo "    跳过：找不到 python"; exit 0; }

"$PY" - "$PROJ" <<'PYEOF'
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile

proj = pathlib.Path(sys.argv[1])
src = (proj / 'root/usr/libexec/openclaw/cloud.sh').read_text(encoding='utf-8')

total = 0
failed = 0


def check(ok, desc, detail=''):
    global total, failed
    total += 1
    if ok:
        print('    ok    %s' % desc)
    else:
        failed += 1
        print('    FAIL  %s%s' % (desc, ('（%s）' % detail) if detail else ''))


def func(name):
    lines = src.splitlines()
    starts = [(i, m.group(1)) for i, l in enumerate(lines)
              for m in [re.match(r'^([a-zA-Z_][a-zA-Z0-9_]*)\(\)\s*\{', l)] if m]
    for pos, (ln, nm) in enumerate(starts):
        if nm == name:
            end = starts[pos + 1][0] if pos + 1 < len(starts) else len(lines)
            return '\n'.join(lines[ln:end])
    raise SystemExit('找不到函数：' + name)


def run_overview(enabled, keep_local, cron_line):
    """桩掉依赖后真跑 cmd_overview，返回解析后的 schedule 子对象。"""
    work = pathlib.Path(tempfile.mkdtemp(prefix='oc-ov-'))
    stub_status = (
        '#!/bin/sh\n'
        'printf \'%s\\n\' \'{"ok":true,"cli":{"installed":false}}\'\n'
    )
    # cmd_status 是 cloud.sh 里的函数，这里桩成同名函数（比外部脚本更接近真实调用）
    parts = [
        '#!/bin/sh',
        'cmd_status() { printf \'%s\\n\' \'{"ok":true,"cli":{"installed":false}}\'; }',
        'cloud_pass_present() { return 1; }',
        'cloud_encrypt_enabled() { printf 0; }',
        'oc_delpass_present() { return 1; }',
        'cloud_cron_line() { printf \'%s\' "$OC_CRON_LINE_STUB"; }',
        'jstr() { printf \'%s\' "$1"; }',
        # cloud_sched_vals 桩：只设本测试关心的变量
        'cloud_sched_vals() {',
        '  OC_SCH_ENABLED="%s"' % enabled,
        '  OC_SCH_PERIOD=weekly OC_SCH_WEEKDAY=0 OC_SCH_HOUR=4',
        '  OC_SCH_MINUTE=30 OC_SCH_KEEP=7 OC_SCH_KEEP_LOCAL=%s' % keep_local,
        '}',
        func('cmd_overview'),
        'cmd_overview',
    ]
    j = work / 't.sh'
    j.write_text('\n'.join(parts) + '\n', encoding='utf-8')
    env = os.environ.copy()
    env['OC_CRON_LINE_STUB'] = cron_line
    r = subprocess.run(['sh', str(j)], capture_output=True, text=True,
                       env=env, timeout=30)
    if r.returncode != 0:
        return None, 'rc=%d stderr=%s' % (r.returncode, r.stderr[:200])
    try:
        return json.loads(r.stdout), ''
    except Exception as e:
        return None, 'JSON 解析失败：%s（输出前 120 字节：%r）' % (e, r.stdout[:120])


# ---- 1) enabled=1 时输出布尔 true，而不是数字 1 -------------------------
d, err = run_overview('1', '2', '30 4 * * 0 /x backup-run # m')
check(d is not None, 'overview（enabled=1）输出可解析为 JSON', err)
if d is not None:
    sch = d.get('schedule') or {}
    check(sch.get('enabled') is True,
          'overview schedule.enabled 是 JSON 布尔 true（非数字 1）',
          '实际：%r' % (sch.get('enabled'),))
    check(sch.get('keep_local') == 2,
          'overview schedule 带 keep_local 字段',
          '实际：%r' % (sch.get('keep_local'),))

# ---- 2) enabled=0 时输出布尔 false -------------------------------------
d, err = run_overview('0', '5', '')
check(d is not None, 'overview（enabled=0）输出可解析为 JSON', err)
if d is not None:
    sch = d.get('schedule') or {}
    check(sch.get('enabled') is False,
          'overview schedule.enabled 是 JSON 布尔 false（非数字 0）',
          '实际：%r' % (sch.get('enabled'),))

# ---- 3) 两个端点的 schedule 字段集合保持一致 ------------------------------
m = re.search(r'"schedule":\{([^}]*)\}', func('cmd_overview'))
ov_keys = re.findall(r'\\?"([a-z_]+)\\?"\s*:', m.group(1)) if m else []
m2 = re.search(r'printf \'\{"ok":true,("enabled":[^}]*)\}', func('cmd_schedule_status'))
st_keys = re.findall(r'"([a-z_]+)":', m2.group(1)) if m2 else []
check(bool(ov_keys) and set(ov_keys) == set(st_keys),
      'overview 与 schedule-status 的 schedule 字段集合一致',
      'overview=%s schedule-status=%s' % (sorted(ov_keys), sorted(st_keys)))

print('    共 %d 项，失败 %d 项' % (total, failed))
sys.exit(1 if failed else 0)
PYEOF
