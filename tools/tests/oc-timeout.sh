#!/bin/sh
# oc-timeout.sh — oc_timeout 在没有 timeout applet 时必须自己兜底
#
# 实机事故：那台设备的 busybox 没有 timeout。旧实现是"直接执行、不设上限"，
# 于是 `openclaw models list --all` 一旦卡住，模型页的下拉框永远是空的 ——
# 前端 20 秒就超时，后端却可能跑几分钟。
#
# 这个测试把 PATH 收紧到只留我们自己的桩（不含 timeout），验证：
#   1. 命令正常结束时，退出码与输出原样透传；
#   2. 命令卡住时到点被杀掉，不会永远挂着；
#   3. 看门狗不会把命令自己的 stdout 弄脏。
#
# 用 2 秒的上限测，不真的等 20 秒。
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
import shutil
import subprocess
import sys
import tempfile
import time

proj = pathlib.Path(sys.argv[1])
src = (proj / 'root/usr/libexec/openclaw/lib.sh').read_text(encoding='utf-8')

total = 0
failed = 0


def check(ok, desc):
    global total, failed
    total += 1
    print('    %s  %s' % ('ok  ' if ok else 'FAIL', desc))
    if not ok:
        failed += 1


m = re.search(r'(?ms)^oc_timeout\(\)\s*\{.*?\n\}', src)
assert m, '取不到 oc_timeout'
fn = m.group(0)

work = pathlib.Path(tempfile.mkdtemp())


def P(p):
    s = pathlib.Path(p).as_posix()
    mm = re.match(r'^([A-Za-z]):/', s)
    return '/' + mm.group(1).lower() + s[2:] if mm else s


def sh_path():
    """给 MSYS 用的 sh（Linux 上就是 /bin/sh）。"""
    for cand in ('/bin/sh', '/usr/bin/sh', shutil.which('sh') or ''):
        if cand and pathlib.Path(cand).exists():
            return cand
    return 'sh'


try:
    # 桩目录：只有 echo / sleep / true，**没有 timeout** —— 复现实机情况
    bindir = work / 'bin'
    bindir.mkdir()
    (bindir / 'echo').write_text('#!/bin/sh\nprintf "%s\\n" "$*"\n', encoding='utf-8', newline='\n')
    (bindir / 'sleep').write_text('#!/bin/sh\nexec /bin/sleep "$@"\n', encoding='utf-8', newline='\n')
    for f in bindir.iterdir():
        f.chmod(0o755)

    runner = work / 't.sh'
    runner.write_text("\n".join([
        '#!/bin/sh',
        '# 只留桩目录：PATH 里因此没有 timeout / kill / sleep 之外的东西',
        'PATH="' + P(bindir) + '"',   # 只留桩目录：里面没有 timeout
        'oc_warn() { printf "WARN %s\\n" "$*" >&2; }',
        fn,
        'case "$1" in',
        '  quick) shift; oc_timeout "$@"; printf "rc=%s\\n" "$?" ;;',
        '  hang)  shift; oc_timeout "$@" >/dev/null; printf "rc=%s\\n" "$?" ;;',
        'esac',
        '',
    ]), encoding='utf-8', newline='\n')

    SH = sh_path()

    # 0) 前提：确认这个环境里真的没有 timeout（否则测的是另一条分支）
    probe = subprocess.run([SH, '-c', 'PATH="%s"; command -v timeout' % P(bindir)],
                           capture_output=True, text=True)
    have_timeout = bool(probe.stdout.strip())
    if have_timeout:
        print('    跳过：本机有 timeout，无法复现缺失分支')
        print('    共 0 项，0 项失败')
        sys.exit(0)

    # 1) 正常结束：输出与退出码原样透传
    r = subprocess.run([SH, P(runner), 'quick', '5', 'echo', 'hello'],
                       capture_output=True, text=True, timeout=30)
    check('hello' in r.stdout and 'rc=0' in r.stdout,
          '没有 timeout 时正常命令照常返回（输出与 rc 透传）')

    # 2) 卡住的命令必须被杀掉
    t0 = time.time()
    r = subprocess.run([SH, P(runner), 'hang', '2', 'sleep', '60'],
                       capture_output=True, text=True, timeout=40)
    dt = time.time() - t0
    check(dt < 20, '卡住的命令被终止（上限 2 秒，实际 %.0f 秒）' % dt)
    check('rc=' in r.stdout, '被终止时仍返回，不会挂住调用方')

    # 3) 看门狗不弄脏 stdout
    r = subprocess.run([SH, P(runner), 'quick', '5', 'echo', 'clean'],
                       capture_output=True, text=True, timeout=30)
    first = r.stdout.strip().splitlines()[0] if r.stdout.strip() else ''
    check(first == 'clean', 'stdout 第一行就是命令自己的输出（看门狗不插队）')
finally:
    shutil.rmtree(work, ignore_errors=True)

print('    共 %s 项，%s 项失败' % (total, failed))
sys.exit(1 if failed else 0)
PYEOF
