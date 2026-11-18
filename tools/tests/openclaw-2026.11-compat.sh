#!/bin/sh
# openclaw-2026.11-compat.sh — 适配 OpenClaw 2026.11.x 的三处行为回归
#
# 背景（2026-11-17 真机）：
#   1) `openclaw gateway recover-lock` 在 2026.11.4 已被移除
#      （`gateway --help` 里没有这个命令）。新版锁协议是「死进程/启动身份变化
#      的锁在启动时自动回收」。插件仍按旧协议 fail-closed，于是升级后网关
#      永远起不来，页面显示「运行中（端口未应答）」，只能人工跑 doctor。
#   2) 以 root 跑 openclaw 会用到 <cache>/openclaw-0；该目录被 chown -R 翻成
#      网关用户后，root 侧一律被拒（Unsafe fallback OpenClaw temp dir）。
#      诊断/终端/一键修复里都有这种 root 调用。
#   3) 2026.11 启动要 15-40 秒，状态页在启动途中探测会把「还在起」误报成
#      「端口未应答」。
#
# 退出码：0 = 全部通过；1 = 有失败

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
PROJ="${1:-$(cd "$HERE/../.." && pwd)}"
PY=""
for cand in python3 python "${HOME:-}/.workbuddy/binaries/python/versions/3.13.12/python.exe"; do
	if command -v "$cand" >/dev/null 2>&1 || [ -x "$cand" ]; then PY="$cand"; break; fi
done
[ -n "$PY" ] || { echo "    跳过：找不到 python"; exit 0; }

"$PY" - "$PROJ" <<'PYEOF'
import pathlib
import subprocess
import sys
import tempfile

PROJ = pathlib.Path(sys.argv[1])
LIB = PROJ / 'root/usr/libexec/openclaw/lib.sh'
CLI = PROJ / 'root/usr/libexec/openclaw/cli.sh'
REP = PROJ / 'root/usr/libexec/openclaw/repair.sh'
INS = PROJ / 'root/usr/libexec/openclaw/install.sh'
lib = LIB.read_text(encoding='utf-8') if LIB.exists() else ''
ins = INS.read_text(encoding='utf-8') if INS.exists() else ''
cli = CLI.read_text(encoding='utf-8') if CLI.exists() else ''
rep = REP.read_text(encoding='utf-8') if REP.exists() else ''

fails = []
total = 0


def check(name, cond, extra=''):
    global total
    total += 1
    print(('  ok   ' if cond else '  FAIL ') + name)
    if not cond:
        fails.append(name)
        if extra:
            print('       ' + str(extra)[:240])


def func(src, name):
    i = src.find('\n' + name + '() {')
    if i < 0:
        return ''
    i += 1
    j = src.find('\n}\n', i)
    return src[i:j + 3] if j > i else ''


# ---------------------------------------------------------------- 静态契约
lock_fn = func(lib, 'oc_clear_stale_state_lock')
check('锁检查识别「recover-lock 已移除」', 'has no command' in lock_fn
      and '自动回收' in lock_fn)
check('锁检查不再用 root 直接跑 CLI',
      'oc_as_user env HOME=' not in lock_fn)
check('锁检查带 TMPDIR（网关用户可用的临时目录）',
      'TMPDIR="$(oc_base_dir)/tmp"' in lock_fn)
check('缓存自愈会清「名字与属主不一致」的目录',
      'name_uid' in func(lib, 'oc_heal_openclaw_cache_dirs'))
check('诊断 doctor-fix 以网关用户执行',
      'oc_as_user_timeout 300 env HOME=' in cli
      and 'oc_timeout 300 "$(oc_oc_bin)" doctor --fix' not in cli)
check('导出诊断的 doctor 以网关用户执行',
      'oc_as_user_timeout 120 env HOME=' in cli)
check('终端 run 以网关用户执行',
      'oc_as_user_timeout 120 env HOME=' in cli
      and 'oc_pty_run 120' in cli and 'oc_as_user env HOME=' in cli)
check('一键修复的 doctor --fix 以网关用户执行',
      'oc_as_user_timeout 300 env HOME="$HOME_DIR"' in rep)
check('新增启动宽限期函数', func(lib, 'oc_gateway_age_ok') != '')
check('状态探测在宽限期内返回 null',
      'oc_gateway_age_ok 150' in func(cli, '_reachable_flag')
      and "printf 'null'" in func(cli, '_reachable_flag'))
check('安装期 CLI 统一走网关用户入口',
      'oc_cli() {' in ins and '"$OC" config set' not in ins
      and '"$OC" onboard' not in ins)
check('安装时关闭 OpenClaw 自带的 npm 自更新',
      'update.auto.enabled false' in ins and 'oc_cli config set update.auto.enabled' in ins)
check('config set 失败不再静默',
      'WARN: 写入 gateway.port 失败' in ins)
check('chown 失败日志不再被 ! 吞成「退出码 0」',
      'if ! chown -R "$OC_USER":"$OC_GROUP" "$real"' not in lib
      and 'chown -R $OC_USER $real 失败（退出码 $crc）' in lib)
check('心跳遗留键解析函数存在',
      func(lib, 'oc_obsolete_heartbeat_paths') != '')

# ---------------------------------------------------------------- 行为：锁
LOCKBODY = func(lib, 'oc_clear_stale_state_lock')
CASES = [
    ('新版移除 recover-lock -> 放行（不再 fail-closed）',
     'OpenClaw gateway has no command "recover-lock".\nTry: openclaw gateway --help',
     0),
    ('正式的人工确认线索 -> 仍需人工（rc=1）',
     'holder pid=1234 fingerprint=abc\nRun: openclaw gateway recover-lock --confirm abc', 1),
    ('无关输出 + 非 0 -> 保持 fail-closed（rc=2）',
     'some unexpected failure', 2),
]

for name, out_text, want_rc in CASES:
    with tempfile.TemporaryDirectory() as td:
        d = pathlib.Path(td)
        state = d / 'state'
        (state / 'tmp/openclaw-998').mkdir(parents=True)
        (state / 'tmp/openclaw-998/state.deadbeef.lock').write_text(
            '{"pid":999999}', encoding='utf-8')
        binp = d / 'openclaw'
        binp.write_text('#!/bin/sh\nexit 1\n', encoding='utf-8')
        binp.chmod(0o755)
        posix = lambda p: str(p).replace('\\', '/')
        judge = d / 'j.sh'
        lines = [
            '#!/bin/sh',
            'oc_home_dir() { printf %s ' + repr(posix(d)) + '; }',
            'oc_base_dir() { printf %s ' + repr(posix(d)) + '; }',
            'oc_gateway_pids() { printf %s ' + repr('1') + '; }',
            'oc_state_lock_pid() { printf %s ' + repr('999999') + '; }',
            'oc_warn() { printf "%s\\n" "$*" >/dev/null; }',
            # 以网关用户执行：这里直接用桩模拟「CLI 输出了什么、返回几」
            'oc_as_user() { shift; printf %b ' + repr(out_text) + '; return 1; }',
            'oc_as_user_timeout() { shift 2; shift; printf %b ' + repr(out_text)
            + '; return 1; }',
            LOCKBODY,
            'oc_clear_stale_state_lock ' + repr(posix(state)) + ' ' + repr(posix(binp)),
            'printf "RC=%s\\n" "$?"',
        ]
        judge.write_text('\n'.join(lines) + '\n', encoding='utf-8')
        p = subprocess.run(['sh', str(judge)], capture_output=True, text=True,
                           timeout=60)
        rc = None
        for line in p.stdout.splitlines():
            if line.startswith('RC='):
                rc = line[3:].strip()
        check(name, rc == str(want_rc), 'RC=%s 期望 %s' % (rc, want_rc))

# ------------------------------------------------------------ 行为：心跳遗留键
HBFN = func(lib, 'oc_obsolete_heartbeat_paths')
HBCASES = [
    ('defaults', '- agents.defaults: Unrecognized key: "heartbeat"',
     ['agents.defaults.heartbeat']),
    ('entry', '- agents.entries.main: Unrecognized key: "heartbeat"',
     ['agents.entries.main.heartbeat']),
    ('dup', '- agents.defaults: Unrecognized key: "heartbeat"\n'
            '- agents.defaults: Unrecognized key: "heartbeat"',
     ['agents.defaults.heartbeat']),
    ('别的未知键不动', '- agents.defaults: Unrecognized key: "foo"', []),
    ('校验通过 -> 无输出', 'Config is valid', []),
]
for name, text, want in HBCASES:
    with tempfile.TemporaryDirectory() as td:
        d = pathlib.Path(td)
        script = d / 'hb.sh'
        script.write_text(
            '#!/bin/sh\n' + HBFN + '\nprintf %b ' + repr(text)
            + ' | oc_obsolete_heartbeat_paths\n', encoding='utf-8')
        got = subprocess.run(['sh', str(script)], capture_output=True,
                             text=True, timeout=60).stdout.split()
        check('心跳键解析：' + name, got == want, got)

# ---------------------------------------------------------------- 行为：宽限期
with tempfile.TemporaryDirectory() as td:
    d = pathlib.Path(td)
    judge = d / 'j.sh'
    lines = [
        '#!/bin/sh',
        'oc_gateway_pids() { printf "%s\\n" "$$"; }',
        func(lib, 'oc_gateway_age_ok'),
        'oc_gateway_age_ok 150 && echo YOUNG || echo OLD',
        'oc_gateway_age_ok 0 && echo YOUNG || echo OLD',
    ]
    judge.write_text('\n'.join(lines) + '\n', encoding='utf-8')
    out = subprocess.run(['sh', str(judge)], capture_output=True, text=True,
                         timeout=60).stdout.split()
    check('刚启动的网关算「宽限期内」', out[:1] == ['YOUNG'], out)
    check('宽限期为 0 时不再放行', out[1:2] == ['OLD'], out)

print('共 %d 项，失败 %d 项' % (total, len(fails)))
sys.exit(1 if fails else 0)
PYEOF
