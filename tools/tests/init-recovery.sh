#!/bin/sh
# init-recovery.sh — 网关"停了不回来"的两条根因与 schema 自检
#
# 用户实测（2026-10-23）：
#   dmesg: openclaw-gatewa segfault ...  ubus: running=false, exit_code=139
#   → 一小时内崩 5 次后 procd 彻底放弃，表现为"停了再也不回来"。
#   另一次是恢复备份后 schema 24 < 25，网关每次 exit 1、端口不开。
#
# 断言：
#   1. respawn 的 retry 是 0（永不放弃），timeout 与 threshold 合理
#   2. term_timeout 已设（procd 默认 5 秒，插件收尾来不及）
#   3. core dump 是**可选**的：默认不设 limits、不改全局 core_pattern
#   4. oc_schema_heal 只在日志同时出现 "schema version" 与 "doctor --fix" 时才动手
#   5. 每次开机最多修一次（标记文件生效）
#   6. 日志里没有那两条特征时，绝不调用 doctor
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
import pathlib
import re
import subprocess
import sys
import tempfile

proj = pathlib.Path(sys.argv[1])
NL = chr(10)
init = (proj / 'root/etc/init.d/openclaw').read_text(encoding='utf-8')
defaults = (proj / 'root/usr/share/openclaw/config.default').read_text(encoding='utf-8')

total = 0
failed = 0


def check(ok, desc, detail=''):
    global total, failed
    total += 1
    print('    %s  %s%s' % ('ok  ' if ok else 'FAIL', desc, ('  ' + detail) if detail else ''))
    if not ok:
        failed += 1


# ---------------------------------------------------------------- 静态断言
m = re.search(r'(?m)^\s*procd_set_param respawn ([0-9]+) ([0-9]+) ([0-9]+)', init)
check(m is not None, '有 respawn 参数')
if m:
    thr, tmo, retry = m.group(1), m.group(2), m.group(3)
    check(retry == '0', 'respawn 的 retry 为 0（永不放弃）', 'retry=%s' % retry)
    check(int(tmo) >= 5, 'respawn timeout 不小于 5 秒', 'timeout=%s' % tmo)
    check(int(thr) >= 600, 'respawn threshold 足够大（退避封顶）', 'threshold=%s' % thr)

check(re.search(r'(?m)^\s*procd_set_param term_timeout ([0-9]+)', init) is not None,
      'term_timeout 已设置')
m2 = re.search(r'(?m)^\s*procd_set_param term_timeout ([0-9]+)', init)
if m2:
    check(int(m2.group(1)) >= 20, 'term_timeout >= 20 秒', 'value=%s' % m2.group(1))

# core dump 必须在开关里，不能无条件设置
check('config_get_bool core_dumps main core_dumps 0' in init,
      'core dump 由 UCI 开关控制（默认 0）')
check("option core_dumps '0'" in defaults, 'config.default 里 core_dumps 默认为 0')
# 无条件出现 = 每次启动都改全局 core_pattern
# 只数**真的写** /proc/sys/kernel/core_pattern 的行：
# 注释与 logger 文案里也会出现这个词，不能一起算。
core_line = [l for l in init.splitlines()
             if '/proc/sys/kernel/core_pattern' in l and not l.strip().startswith('#')]
check(len(core_line) == 1, 'core_pattern 只在开关分支里写一次', 'hits=%d' % len(core_line))
if core_line:
    idx = init.index(core_line[0])
    before = init[max(0, idx - 600):idx]
    check('if [ "$core_dumps" = "1" ]' in before, 'core_pattern 写在 core_dumps 分支内')

# ---------------------------------------------------------------- 行为断言
def func(name):
    lines = init.splitlines()
    starts = [(i, mm.group(1)) for i, l in enumerate(lines)
              for mm in [re.match(r'^([a-z_][a-z0-9_]*)\(\)\s*\{', l)] if mm]
    for idx, (ln, nm) in enumerate(starts):
        if nm == name:
            end = starts[idx + 1][0] if idx + 1 < len(starts) else len(lines)
            return NL.join(lines[ln:end])
    raise AssertionError('取不到函数 ' + name)


def msys_tmp():
    """MSYS 视角下 /tmp 的真实 Windows 路径。"""
    try:
        r = subprocess.run(['sh', '-c', 'cd /tmp && pwd -W'],
                           capture_output=True, text=True, timeout=30)
        out = r.stdout.strip()
        if out:
            return out
    except Exception:
        pass
    return '/tmp'


work = pathlib.Path(tempfile.mkdtemp())


def P(p):
    s = pathlib.Path(p).as_posix()
    return '/c' + s[2:] if len(s) > 1 and s[1] == ':' else s


# 假 node：只记录自己被调用过（参数里含 doctor 时写标记）
fake_node = work / 'node'
fake_node.write_text(NL.join([
    '#!/bin/sh',
    'printf "%s\\n" "$*" >>"$DOCTOR_CALLS"',
    'exit 0',
    '',
]), encoding='utf-8', newline=NL)
calls = work / 'calls.txt'

runner = work / 'heal.sh'
runner.write_text(NL.join([
    '#!/bin/sh',
    'logger() { :; }',
    func('oc_schema_heal'),
    'oc_schema_heal "$1" "$2" "$3" "$4" "$5"',
    '',
]), encoding='utf-8', newline=NL)


def heal(log_body=None, marker_exists=False):
    """准备一个假 base，跑一次 oc_schema_heal，返回 doctor 被调用次数。"""
    base = work / 'base'
    tmp = base / 'tmp' / 'openclaw-0'
    tmp.mkdir(parents=True, exist_ok=True)
    if log_body is not None:
        (tmp / 'openclaw-2026-10-23.log').write_text(log_body, encoding='utf-8')
    # 标记文件在 /tmp/.openclaw 下。MSYS 的 /tmp 并不是 Windows 的 C://tmp，
    # 必须先问出它的真实位置，否则这里的删除/创建落在另一个目录上，
    # "每次开机只修一次"那条断言会假失败（实测踩过）。
    mk = pathlib.Path(msys_tmp()) / '.openclaw' / 'schema-healed'
    if mk.exists():
        mk.unlink()
    if marker_exists:
        mk.parent.mkdir(parents=True, exist_ok=True)
        mk.write_text('', encoding='utf-8')
    if calls.exists():
        calls.unlink()
    env = {'PATH': '/usr/bin:/bin', 'DOCTOR_CALLS': str(calls)}
    subprocess.run(['sh', P(runner), P(base), P(work / 'state'), P(work / 'home'),
                    P(fake_node), P(work / 'entry.mjs')],
                   capture_output=True, text=True, env=env, timeout=120)
    if not calls.exists():
        return 0
    return len([l for l in calls.read_text(encoding='utf-8').splitlines() if 'doctor' in l])


SCHEMA_LOG = NL.join([
    '13:33:09 uses schema version 24; the bundled version is 25.',
    '13:33:09 Sessions remain unavailable. run openclaw doctor --fix',
    '',
])

check(heal(log_body=None) == 0, '没有日志 → 不调用 doctor')
check(heal(log_body='all good' + NL) == 0, '日志无特征 → 不调用 doctor')
check(heal(log_body='uses schema version 24' + NL) == 0,
      '只有 schema version、没有 doctor --fix → 不调用 doctor')
check(heal(log_body='run openclaw doctor --fix' + NL) == 0,
      '只有 doctor --fix、没有 schema version → 不调用 doctor')
check(heal(log_body=SCHEMA_LOG) == 1, '两条特征都在 → 调用一次 doctor')
check(heal(log_body=SCHEMA_LOG, marker_exists=True) == 0,
      '本次开机已修过 → 不再调用（防死循环）')

print('    共 %s 项，%s 项失败' % (total, failed))
sys.exit(1 if failed else 0)
PYEOF
