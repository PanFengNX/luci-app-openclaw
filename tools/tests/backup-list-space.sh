#!/bin/sh
# backup-list-space.sh — 备份列表在含空格的安装目录下必须照常工作
#
# 实机故障（2026-10-22 审计发现）：
#   cmd_list 原来写 `for f in $(ls -1t "$dir"/openclaw-backup-*.tar.gz)`,
#   命令替换的结果按 IFS 分词 —— 安装目录含空格时每个路径被拆成多段，
#   后面的 [ -f "$f" ] 全部失败，列表返回 []。
#   用户看到"备份页一片空白"，但磁盘上备份其实都在。
#
# 而 oc_validate_base_dir **放行**含空格的路径，所以这条能真实触发。
#
# 断言：
#   1. 普通目录：列出全部备份，且按时间倒序（名字倒序）
#   2. 含空格目录：同样列出全部，顺序一致
#   3. 含空格 + 中文目录：同上（多字节也靠 glob 原样保留）
#   4. 空目录：输出合法 JSON 数组 []
#   5. 源码里不再出现 `$(ls` 形式的目录列表循环（防回归）
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
import shutil
import subprocess
import sys
import tempfile

proj = pathlib.Path(sys.argv[1])
src = (proj / 'root/usr/libexec/openclaw/backup.sh').read_text(encoding='utf-8')

total = 0
failed = 0


def check(ok, desc):
    global total, failed
    total += 1
    print('    %s  %s' % ('ok  ' if ok else 'FAIL', desc))
    if not ok:
        failed += 1


def extract(text, name):
    """取函数体：必须括号配对，非贪婪正则会截在第一个 } 上。"""
    m = re.search(r'(?m)^%s\(\)\s*\{' % name, text)
    if not m:
        return None
    i, depth = m.end(), 1
    while i < len(text) and depth:
        if text[i] == '{':
            depth += 1
        elif text[i] == '}':
            depth -= 1
        i += 1
    return text[m.start():i]


fn = extract(src, 'cmd_list')
lib_src = (proj / 'root/usr/libexec/openclaw/lib.sh').read_text(encoding='utf-8')
json_fn = extract(lib_src, 'oc_json_str')
check(json_fn is not None, '取到 oc_json_str（供转义用例）')
# cmd_list 现在用 oc_mtime 取排序键（原来是 date -r，busybox 不支持）。
# 桩里必须一并提供，否则排序键全空、列表变成 []。
mtime_fn = extract(lib_src, 'oc_mtime')
check(mtime_fn is not None, '取到 oc_mtime（cmd_list 的排序键来源）')
check(fn is not None, '取到 cmd_list 函数体')
if fn is None:
    print('    共 %s 项，%s 项失败' % (total, failed))
    sys.exit(1)


def P(p):
    s = pathlib.Path(p).as_posix()
    mm = re.match(r'^([A-Za-z]):/', s)
    return '/' + mm.group(1).lower() + s[2:] if mm else s


def run_list(dirpath, real_jstr=False):
    """在给定目录上跑真实 cmd_list，返回 (解析结果, 原始输出)。"""
    runner = dirpath.parent / ('run_%d.sh' % abs(hash(str(dirpath))))
    # 桩：backup_dir 返回被测目录。jstr 默认透传（测试文件名不含需转义字符时
    # 够用）；real_jstr=True 时用项目里真实的 oc_json_str，覆盖转义路径。
    jstr_def = ('jstr() { oc_json_str "$1"; }\n' if real_jstr
                else 'jstr() { printf "%s" "$1"; }\n')
    runner.write_text(
        '#!/bin/sh\n'
        'backup_dir() { printf "%s" "' + P(dirpath) + '"; }\n'
        + (mtime_fn + '\n' if mtime_fn else '')
        + (json_fn + '\n' if real_jstr and json_fn else '')
        + jstr_def + fn + '\ncmd_list\n',
        encoding='utf-8', newline='\n')
    r = subprocess.run(['sh', P(runner)], capture_output=True, text=True)
    try:
        return json.loads(r.stdout.strip()), r.stdout.strip()
    except Exception:
        return None, r.stdout.strip()


NAMES = ('openclaw-backup-20261021-043000.tar.gz',
         'openclaw-backup-20261020-043000.tar.gz',
         'openclaw-backup-20261022-043000-myname.tar.gz')
EXPECT = ('openclaw-backup-20261022-043000-myname.tar.gz',
          'openclaw-backup-20261021-043000.tar.gz',
          'openclaw-backup-20261020-043000.tar.gz')

work = pathlib.Path(tempfile.mkdtemp())
# 三个文件必须给出**互不相同**的 mtime。
# cmd_list 的排序键就是 mtime（等价于 `ls -1t`）；若三个文件在同一秒内
# 创建，mtime 全相等，排序退化成按路径比较，断言时而通过时而失败 ——
# 这是测试的不确定性，不是产品缺陷（实测：单跑 5 次全过，全量回归偶发失败）。
MTIMES = {
    'openclaw-backup-20261022-043000-myname.tar.gz': 1793200000,
    'openclaw-backup-20261021-043000.tar.gz': 1793100000,
    'openclaw-backup-20261020-043000.tar.gz': 1793000000,
}
try:
    for label, dirname in (('普通', 'backups'),
                           ('含空格', 'My Backups'),
                           ('含空格+中文', '我的 备份')):
        d = work / dirname / 'openclaw-backup'
        d.mkdir(parents=True, exist_ok=True)
        for n in NAMES:
            p = d / n
            p.write_bytes(b'x' * 64)
            os.utime(p, (MTIMES[n], MTIMES[n]))
        arr, raw = run_list(d)
        ok = isinstance(arr, list) and tuple(x['file'] for x in arr) == EXPECT
        detail = '' if ok else ('  实际=%s' % (raw[:90] if raw else '(空)'))
        check(ok, '%s目录列出全部 %d 个备份且按时间倒序%s' % (label, len(NAMES), detail))


    # JSON 转义：文件名里可能带引号/反斜杠（例如 --name 用了特殊字符），
    # cmd_list 靠 jstr → oc_json_str 兜住。Windows 不允许文件名含 "，
    # 所以这里直接对 oc_json_str 做往返测试，覆盖同一条代码路径。
    if json_fn:
        vals = ['plain', 'q"uote', 'back\\slash', 'tab\there']
        script = ['#!/bin/sh', json_fn, '']
        for i, v in enumerate(vals):
            f = work / ('jv%d.txt' % i)
            f.write_bytes(v.encode('utf-8'))
            script.append('printf \'{"v":"%%s"}\\n\' "$(oc_json_str "$(cat %s)")"'
                          % P(f))
        # 写成脚本文件再跑：用 sh -c 传多行脚本时，oc_json_str 里 awk 的
        # 反斜杠会被多解释一层，导致 gsub(/\\/) 变成 gsub(/\/) 报
        # "unterminated regexp"。这是测试脚手架的问题，不是被测代码的问题。
        jsp = work / 'json_roundtrip.sh'
        jsp.write_text('\n'.join(script), encoding='utf-8', newline='\n')
        r = subprocess.run(['sh', P(jsp)], capture_output=True, text=True)
        ok_all = True
        for i, line in enumerate(r.stdout.strip().splitlines()):
            try:
                if json.loads(line)['v'] != vals[i]:
                    ok_all = False
            except Exception:
                ok_all = False
        check(ok_all and len(r.stdout.strip().splitlines()) == len(vals),
              'oc_json_str 往返保持内容（引号 / 反斜杠 / 制表符）')

    # 空目录
    empty = work / 'empty' / 'openclaw-backup'
    empty.mkdir(parents=True, exist_ok=True)
    arr, raw = run_list(empty)
    check(arr == [], '空目录返回合法 JSON 数组 []')

    # 源码层面防回归：不允许再出现 $(ls 做目录列表
    bad = re.findall(r'(?m)^\s*for\s+\w+\s+in\s+\$\(ls\b', src)
    check(not bad, '源码里没有 `for x in $(ls ...)` 形式的循环')
finally:
    shutil.rmtree(work, ignore_errors=True)

print('    共 %s 项，%s 项失败' % (total, failed))
sys.exit(1 if failed else 0)
PYEOF
