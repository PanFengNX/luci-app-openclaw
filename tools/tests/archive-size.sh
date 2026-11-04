#!/bin/sh
# archive-size.sh —— 解压体积上限必须是动态的，不能写死
#
# 真机事故（2026-11-04）：`MAX_RESTORE_MB=512` 写死，而实际数据目录 3.3GB
# （agents 2.6GB + workspace 680MB）。于是**插件自己产出的备份，自己的
# verify/restore 全部拒绝**：
#   {"ok":false,"error":"归档解压体积超过 512MB 上限，已拒绝"}
# 用户以为有备份，实际一个都恢复不了 —— 这比"没有备份"更危险，因为它给了
# 虚假的安全感。
#
# 现在的判据（保留防 zip bomb / 防撑爆磁盘的初衷）：
#   * 压缩比：解压体积 <= 归档大小 × RESTORE_RATIO_MAX（默认 40）
#   * 可用空间：解压体积 <= 目标盘可用空间 × 80%
#   * 两者取较小值；RESTORE_MIN_MB 是压缩比判据的下限
#
# 本测试用桩函数控制"归档大小"和"可用空间"，覆盖三种关键情形。

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
PROJ="$(cd "$HERE/../.." && pwd)"
PY=""
for cand in python3 python "$HOME/.workbuddy/binaries/python/versions/3.13.12/python.exe"; do
	if command -v "$cand" >/dev/null 2>&1 || [ -x "$cand" ]; then PY="$cand"; break; fi
done
[ -n "$PY" ] || { echo "    跳过：找不到 python"; exit 0; }

"$PY" - "$PROJ" <<'PYEOF'
import os
import pathlib
import re
import subprocess
import sys
import tempfile

proj = pathlib.Path(sys.argv[1])
NL = chr(10)
src = (proj / 'root/usr/libexec/openclaw/backup.sh').read_text(encoding='utf-8')

total = 0
failed = 0


def check(ok, desc, detail=''):
    global total, failed
    total += 1
    print('    %s  %s%s' % ('ok  ' if ok else 'FAIL', desc, ('  ' + detail) if detail else ''))
    if not ok:
        failed += 1


def grab(pattern, text=None):
    text = src if text is None else text
    m = re.search(pattern, text, re.M | re.S)   # 函数体跨行，必须 DOTALL
    return m.group(0) if m else ''


consts = grab(r'^RESTORE_RATIO_MAX=\d+$') + NL + grab(r'^RESTORE_MIN_MB=\d+$')
check('RESTORE_RATIO_MAX=' in consts and 'RESTORE_MIN_MB=' in consts,
      '常量改为压缩比 + 下限（不再是固定 512MB 绝对上限）')
check('MAX_RESTORE_MB' not in src, '旧的固定上限常量已彻底移除')

body = grab(r'^oc_archive_ok_size\(\) \{.*?^\}', None)
check('oc_free_mb' in body, '判据里考虑了目标盘可用空间')
check('RESTORE_RATIO_MAX' in body, '判据里考虑了压缩比（防 zip bomb）')
check('OC_ARC_LIMIT_MSG' in body, '超限时带回具体原因（空间不够还是归档可疑）')

work = pathlib.Path(tempfile.mkdtemp())


def P(p):
    s = pathlib.Path(p).as_posix()
    return '/c' + s[2:] if len(s) > 1 and s[1] == ':' else s


harness = work / 'ok.sh'
harness.write_text(NL.join([
    '#!/bin/sh',
    consts,
    # 桩：可用空间由 FREE_MB 控制
    'oc_free_mb() { printf "%s" "${FREE_MB:-60000}"; }',
    'oc_base_dir() { printf "%s" /tmp; }',
    # 桩：tar -tzvf 输出一行，第三个字段就是"解压后大小"
    'tar() { printf "%s\\n" "-rw-r--r-- 0/0 ${FAKE_BYTES:-0} 2026-01-01 00:00 ./x"; }',
    grab(r'^oc_archive_ok_size\(\) \{.*?^\}'),
    'oc_archive_ok_size "$1"',
    '_rc=$?',                      # 先存返回码：printf 会把它覆盖成 0
    'printf "%s" "${OC_ARC_LIMIT_MSG:-}"',
    'exit "$_rc"',
    '',
]), encoding='utf-8', newline=NL)


def run_case(fake_bytes, arch_mb, free_mb):
    f = work / 'a.tar.gz'
    # 造一个真实大小可控的文件当"归档"（内容无所谓，大小由 stat 读）
    with open(f, 'wb') as fh:
        fh.truncate(int(arch_mb) * 1048576)
    env = dict(os.environ, FAKE_BYTES=str(fake_bytes), FREE_MB=str(free_mb))
    r = subprocess.run(['sh', P(harness), P(f)], capture_output=True, text=True, env=env)
    return r.returncode == 0, r.stdout.strip()


GB = 1024 ** 3
MB = 1024 ** 2

# 1) 真机真实场景：3.3GB 解压 / 900MB 归档 / 60GB 可用 -> 必须放行
ok, msg = run_case(3_300 * MB, 900, 60000)
check(ok, '真实规模（3.3GB 解压、900MB 归档）放行 —— 这正是之前被误拒的备份', msg[:90])

# 2) zip bomb：10GB 解压 / 1MB 归档 -> 压缩比拦下
ok, msg = run_case(10 * GB, 1, 60000)
check(not ok, 'zip bomb（1MB 归档解出 10GB）被拒绝', msg[:90])
check('压缩比' in msg, '拒绝理由指出是压缩比问题', msg[:90])

# 3) 空间不足：5GB 解压 / 900MB 归档 / 2GB 可用 -> 空间拦下
ok, msg = run_case(5 * GB, 900, 2000)
check(not ok, '可用空间不足时拒绝（2GB 可用解不出 5GB）', msg[:90])
check('可用空间' in msg, '拒绝理由指出是空间问题', msg[:90])

# 4) 小归档不受 RESTORE_MIN_MB 之外的额外限制
ok, msg = run_case(200 * MB, 100, 60000)
check(ok, '正常小归档放行', msg[:90])

print('    共 %s 项，%s 项失败' % (total, failed))
sys.exit(1 if failed else 0)
PYEOF
