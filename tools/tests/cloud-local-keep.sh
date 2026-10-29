#!/bin/sh
# cloud-local-keep.sh — 定时备份的本地副本轮转（br_prune_local）
#
# 需求（2026-10-29）：备份本地与云端都要留存。定时备份 backup-run 原来
# 上传成功后删除本机副本；现在改为本地按 main.cloud_keep_local 份数轮转，
# 核心就是这个函数。它删除的是用户磁盘上的备份，属于破坏性路径，
# 必须有机械回归盯住：
#
# 断言：
#   1. keep=2、5 份备份 → 只删最旧 3 份，返回 3，2 份最新的还在
#   2. except 指名的归档（本次任务的产物）绝不删，哪怕它是最旧的
#   3. keep=0 → 不删任何东西，返回 0（= 旧行为的开关）
#   4. 不符合 openclaw-backup-*.tar.gz 的文件（别的名字 / .enc / 子目录）
#      一律不碰
#   5. 目录不存在 → 返回 0
#   6. 含空格的备份目录 → 照常工作（glob 不按空白分词）
#   7. 源码防回归：backup-run 里 a0/d 两处调用了 br_prune_local；
#      cmd_list 与 backup-run worker 不再用 wc -c 统计归档大小
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
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import time

proj = pathlib.Path(sys.argv[1])
cloud_src = (proj / 'root/usr/libexec/openclaw/cloud.sh').read_text(encoding='utf-8')
lib_src = (proj / 'root/usr/libexec/openclaw/lib.sh').read_text(encoding='utf-8')

total = 0
failed = 0


def check(ok, desc):
    global total, failed
    total += 1
    print('    %s  %s' % ('ok  ' if ok else 'FAIL', desc))
    if not ok:
        failed += 1


def extract(text, name):
    m = re.search(r'(?m)^%s\(\)\s*\{' % re.escape(name), text)
    if not m:
        raise SystemExit('找不到函数 %s' % name)
    i = m.end()
    depth = 1
    while i < len(text) and depth > 0:
        if text[i] == '{':
            depth += 1
        elif text[i] == '}':
            depth -= 1
        i += 1
    return text[m.start():i]


fn = extract(cloud_src, 'br_prune_local')
mtime_fn = extract(lib_src, 'oc_mtime')

runner = r'''#!/bin/sh
# 测试桩：只带被测函数与最小依赖
br_log() { :; }
''' + mtime_fn + "\n" + fn + r'''

dir="$1"; keep="$2"; except="$3"
br_prune_local "$dir" "$keep" "$except"
'''


def run_case(tmp, files, keep, except_name, base_ts):
    """files: list of (name, mtime_offset_minutes). 返回 (删除数, 剩余文件集合)."""
    d = pathlib.Path(tmp)
    for name, off in files:
        p = d / name
        p.write_bytes(b'x' * 16)
        os.utime(str(p), (base_ts + off * 60, base_ts + off * 60))
    rf = d / 'runner.sh'
    rf.write_text(runner, encoding='utf-8', newline='\n')
    # as_posix()：Windows 反斜杠路径传给 MSYS sh 会让 glob 匹配失败
    r = subprocess.run(['sh', rf.as_posix(), d.as_posix(), str(keep), except_name or ''],
                       capture_output=True, text=True)
    out = r.stdout.strip()
    remain = {p.name for p in d.iterdir() if p.name != 'runner.sh' and p.is_file()}
    return out, remain


base = int(time.time()) - 86400 * 10
names = ['openclaw-backup-202610%d-040000.tar.gz' % (20 + i) for i in range(5)]

# 1. 基本轮转：keep=2，5 份 → 删最旧 3 份
with tempfile.TemporaryDirectory() as tmp:
    out, remain = run_case(tmp, list(zip(names, [0, 60, 120, 180, 240])), 2, '', base)
    check(out == '3', 'keep=2 删 3 份（返回值=%r）' % out)
    check(remain == set(names[3:]), '保留的是最新 2 份（实际=%r）' % sorted(remain))

# 2. except 保护：本次归档是最旧的也不能删（且不计入保留份数：
#    4 份候选保 2 份 → 删 2；剩 except + 2 最新 = 3 份）
with tempfile.TemporaryDirectory() as tmp:
    out, remain = run_case(tmp, list(zip(names, [0, 60, 120, 180, 240])), 2, names[0], base)
    check(names[0] in remain, 'except 指名的归档未被删除')
    check(out == '2', 'except 不计入保留份数（返回值=%r，期望 2）' % out)
    check(remain == {names[0], names[3], names[4]},
          'except + 最新 2 份存活（实际=%r）' % sorted(remain))

# 3. keep=0：不删（= 旧「不保留本地」行为的开关）
with tempfile.TemporaryDirectory() as tmp:
    out, remain = run_case(tmp, list(zip(names, [0, 60, 120, 180, 240])), 0, '', base)
    check(out == '0' and len(remain) == 5, 'keep=0 时函数直接返回不动任何文件')

# 4. 非匹配文件不碰
extra = ['manual.tar.gz', 'openclaw-backup-x.tar.gz.enc', 'notes.txt']
with tempfile.TemporaryDirectory() as tmp:
    files = list(zip(names, [0, 60, 120, 180, 240])) + [(e, 300) for e in extra]
    out, remain = run_case(tmp, files, 1, '', base)
    check(set(extra) <= remain, '其它命名 / .enc 文件未被触碰')
    check('openclaw-backup-20261024-040000.tar.gz' in remain, 'keep=1 保留最新一份')

# 5. 目录不存在（独立小脚本：不带 runner 尾部的正常调用，避免多输出一行）
with tempfile.TemporaryDirectory() as tmp:
    probe = pathlib.Path(tmp) / 'probe.sh'
    probe.write_text('#!/bin/sh\nbr_log() { :; }\n' + mtime_fn + '\n' + fn
                     + '\nbr_prune_local /nonexistent-dir-xyz 2 ""\n',
                     encoding='utf-8', newline='\n')
    r = subprocess.run(['sh', probe.as_posix()], capture_output=True, text=True)
    check(r.stdout.strip() == '0' and r.returncode == 0, '目录不存在返回 0 且不报错')

# 6. 含空格目录
with tempfile.TemporaryDirectory() as tmp:
    spaced = pathlib.Path(tmp) / 'my backups'
    spaced.mkdir()
    out, remain = run_case(str(spaced), list(zip(names, [0, 60, 120, 180, 240])), 2, '', base)
    check(out == '3' and remain == set(names[3:]), '含空格目录照常轮转')

# 7. 源码防回归
check(re.search(r'br_prune_local "\$pre_dir"', cloud_src) is not None,
      'backup-run 打包前调用 br_prune_local（a0 腾位）')
check(re.search(r'pruned_local="\$\(br_prune_local "\$dir"', cloud_src) is not None,
      'backup-run 上传后调用 br_prune_local（d 兜底轮转）')
check(re.search(r'cloud_keep_local', cloud_src) is not None,
      'cloud_keep_local 配置键已接入 cloud.sh')

bk_src = (proj / 'root/usr/libexec/openclaw/backup.sh').read_text(encoding='utf-8')
list_body = extract(bk_src, 'cmd_list')
# 注意：源码注释里提到 wc -c 是历史说明，真正的用法是 `wc -c <`
check('stat -c %s' in list_body and 'wc -c <' not in list_body,
      'cmd_list 用 stat 取大小（不再整读归档）')

worker = re.search(r'(?m)^backup_bg_worker\(\)\s*\{', cloud_src)
ok_worker = False
if worker:
    i = worker.end(); depth = 1
    while i < len(cloud_src) and depth > 0:
        if cloud_src[i] == '{': depth += 1
        elif cloud_src[i] == '}': depth -= 1
        i += 1
    body = cloud_src[worker.start():i]
    ok_worker = 'stat -c %s' in body and 'wc -c' not in body
check(ok_worker, '手动云备份 worker 用 stat 取大小')

print('    ----')
print('    %d 项检查，%d 失败' % (total, failed))
sys.exit(1 if failed else 0)
PYEOF
