#!/bin/sh
# github-update-filelist.sh — apk/opkg 清单归一化与随机标识兜底回归
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
PROJ="$(cd "$HERE/../.." && pwd)"
PY=""
for cand in python3 python "${HOME:-}/.workbuddy/binaries/python/versions/3.13.12/python.exe"; do
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
NL = chr(10)
gh_src = (proj / 'root/usr/libexec/openclaw/github-update.sh').read_text(encoding='utf-8')
lib_src = (proj / 'root/usr/libexec/openclaw/lib.sh').read_text(encoding='utf-8')
work = pathlib.Path(tempfile.mkdtemp())
total = 0
failed = 0

def check(ok, desc, detail=''):
    global total, failed
    total += 1
    print('    %s  %s%s' % ('ok  ' if ok else 'FAIL', desc, ('  ' + detail) if detail else ''))
    if not ok:
        failed += 1

def func(src, name):
    lines = src.splitlines()
    starts = [(i, m.group(1)) for i, line in enumerate(lines)
              for m in [re.match(r'^([a-z_][a-z0-9_]*)\(\)\s*\{', line)] if m]
    for pos, (line_no, found) in enumerate(starts):
        if found == name:
            end = starts[pos + 1][0] if pos + 1 < len(starts) else len(lines)
            return NL.join(lines[line_no:end])
    raise AssertionError('取不到函数 ' + name)

def P(path):
    s = pathlib.Path(path).as_posix()
    return '/c' + s[2:] if len(s) > 1 and s[1] == ':' else s

def run_list(kind, output, rc=0, no_apk=False, db_file=None, db_func=False):
    bind = work / ('bin-' + kind + str(rc) + str(len(output)) + str(bool(db_file)) + str(db_func) + str(len(list(work.iterdir()))))
    bind.mkdir()
    if kind == 'apk':
        (bind / 'apk').write_text('#!/bin/sh\nprintf %s "$OUTPUT"\nexit "$RC"\n', encoding='utf-8')
        apk_path = P(bind)
    else:
        # 注意：这里**不能**再放一个 apk 桩。实测发现即便桩没有可执行权限，
        # MSYS 的 `command -v apk` 仍然找得到它，于是 installed_files_list 会走
        # apk 分支、桩 exit 1、清单拿不到 —— 反而把"无 apk"用例变成了别的用例。
        # 走没走 opkg 分支改用 OPKG_MARK 标记文件来证明。
        (bind / 'opkg').write_text('#!/bin/sh\nprintf %s opkg >"$OPKG_MARK"\nprintf %s "$OUTPUT"\nexit "$RC"\n', encoding='utf-8')
        apk_path = ''
    for name in ('apk', 'opkg'):
        p = bind / name
        if p.exists(): p.chmod(0o755)
    judge = work / ('judge-' + kind + str(rc) + str(len(output)) + '.sh')
    judge.write_text(NL.join([
        '#!/bin/sh',
        'PKG_NAME=luci-app-openclaw',
        'APK_DB_FILE=' + repr(P(db_file)) if db_file else 'APK_DB_FILE="/lib/apk/db/installed"',
        'LOG=/dev/null',
        'msg() { :; }',
        func(gh_src, 'apk_db_files'),
        func(gh_src, 'installed_files_list'),
        'installed_files_list',
    ]) + NL, encoding='utf-8')
    judge.chmod(0o755)
    env = os.environ.copy()
    env['OUTPUT'] = output
    env['RC'] = str(rc)
    env['OPKG_MARK'] = P(work / 'opkg-used')
    if no_apk:
        env['PATH'] = P(bind) + os.pathsep + '/usr/bin:/bin'
    else:
        env['PATH'] = P(bind) + os.pathsep + env.get('PATH', '')
    return subprocess.run(['sh', P(judge)], capture_output=True, text=True, env=env, timeout=30)

apk_listing = 'luci-app-openclaw-1.8.52-r1 contains:\netc/config/openclaw\nusr/libexec/openclaw/main.sh\n\n'
r = run_list('apk', apk_listing)
check(r.returncode == 0 and r.stdout == 'etc/config/openclaw\nusr/libexec/openclaw/main.sh\n', 'apk v3 清单归一化、头部与空行剔除')

apk_absolute = 'luci-app-openclaw-1.8.52-r1 contains:\n/etc/config/openclaw\n/usr/libexec/openclaw/main.sh\n'
r = run_list('apk', apk_absolute)
check(r.returncode == 0 and r.stdout == 'etc/config/openclaw\nusr/libexec/openclaw/main.sh\n', 'apk 带前导斜杠清单仍归一化为相对路径')

apk_db = work / 'apk-installed'
apk_db.write_text('''P:other-package\nF:etc/config\nR:other\nM:0644\n\nP:luci-app-openclaw\nF:etc/config\nM:0755\na:0644\nR:openclaw\nR:..\nZ:deadbeef\nF:\nR:toplevel\nF:/abs\nR:x\n\nP:after-package\nF:usr/share\nR:after\n''', encoding='utf-8')
r = run_list('apk', '', rc=1, db_file=apk_db, db_func=True)
check(r.returncode == 0 and r.stdout == 'etc/config/openclaw\ntoplevel\nabs/x\n', 'apk_db_files 丢弃 .. 段并按归一化绝对路径规则得到 abs/x')
r = run_list('apk', '', rc=1, db_file=apk_db)
check(r.returncode == 0 and r.stdout == 'etc/config/openclaw\ntoplevel\nabs/x\n', 'apk info 失败时从已安装库兜底')
r = run_list('apk', '', rc=1, db_file=work / 'missing-installed')
check(r.returncode != 0 and r.stdout == '', 'apk info 与已安装库都不可用时失败且 stdout 为空')

opkg_listing = 'Package luci-app-openclaw is installed on root and has the following files:\n/etc/config/openclaw\n/usr/libexec/openclaw/main.sh\n'
opkg_mark = work / 'opkg-used'
if opkg_mark.exists():
    opkg_mark.unlink()
r = run_list('opkg', opkg_listing, no_apk=True)
check(r.returncode == 0 and r.stdout == 'etc/config/openclaw\nusr/libexec/openclaw/main.sh\n', 'opkg 清单归一化并剔除头部')
check(opkg_mark.exists() and opkg_mark.read_text(encoding='utf-8') == 'opkg',
      '无 apk 环境确实走 opkg 分支（apk 桩已存在也不会被误用）')


mixed = 'luci-app-openclaw-1.8.52-r1 contains:\n  etc/config/openclaw\n../evil\n/etc/passwd\n-rf\n   \nusr/bin/openclaw\n'
r = run_list('apk', mixed)
check(r.returncode == 0 and r.stdout == 'etc/config/openclaw\netc/passwd\nusr/bin/openclaw\n', '清单丢弃越界、选项行与空白行并归一化绝对路径')
r = run_list('apk', 'etc/config/openclaw\n', rc=1)
check(r.returncode != 0, 'apk 非零退出码不能视为空清单成功')

def rnd_left(d, label):
    """返回 (是否干净, 说明)。

    Windows 上刚创建又被删除的文件有时会被 Defender/索引短暂占用，rm -f 会静默失败；
    这里重试一次并保留可见信号，避免把平台噪音当成代码缺陷，也不把它伪装成通过。
    """
    left = [p.name for p in d.iterdir() if p.name.startswith('rnd.')]
    if not left:
        return True, ''
    time.sleep(0.3)
    for name in left:
        try:
            (d / name).unlink()
        except Exception:
            pass
    again = [p.name for p in d.iterdir() if p.name.startswith('rnd.')]
    if not again:
        print('    note  %s：首次检查仍有 %s，重试后已删除（疑似 Windows 文件占用）' % (label, left))
        return True, ''
    return False, '残留 %s' % again


REAL_SHA = shutil.which('sha256sum') or ''
fail = '#!/bin/sh\nexit 1\n'
if REAL_SHA and shutil.which('dd'):
    rdir = work / 'rundir'
    rdir.mkdir()
    missing = work / 'no-such-rundir'
    rand_src = func(lib_src, 'oc_rand_hex')

    def rand_run(tag, stubs, rundir, body='oc_rand_hex', side=None):
        b = work / ('rb-' + tag)
        b.mkdir()
        for name, text in stubs.items():
            p = b / name
            p.write_text(text, encoding='utf-8')
            p.chmod(0o755)
        j = work / ('rj-' + tag + '.sh')
        j.write_text(NL.join(['#!/bin/sh', rand_src, body]) + NL, encoding='utf-8')
        j.chmod(0o755)
        e = os.environ.copy()
        e['PATH'] = P(b) + os.pathsep + e.get('PATH', '')
        e['OC_RUNDIR'] = P(rundir)
        if side is not None:
            e['SIDE'] = P(side)
        return subprocess.run(['sh', P(j)], capture_output=True, text=True, env=e, timeout=30)

    fail = '#!/bin/sh\nexit 1\n'

    # A：读随机字节的工具全挂（含 dd）-> 必须整体失败，不许输出任何东西
    r = rand_run('a', {'od': fail, 'hexdump': fail, 'dd': fail}, rdir)
    check(r.returncode != 0 and r.stdout == '', '随机源读取失败时 oc_rand_hex 失败且 stdout 为空')

    # B：私有临时目录不存在 -> 不许退化到文件系统根或可预测路径，必须失败
    r = rand_run('b', {'od': fail, 'hexdump': fail}, missing)
    check(r.returncode != 0 and r.stdout == '', 'OC_RUNDIR 不可用时摘要兜底被跳过（不退化到根目录）')

    # C：od/hexdump 不可用时摘要候选仍使用强随机文件输入
    r = rand_run('c', {'od': fail, 'hexdump': fail}, rdir,
                 body='a="$(oc_rand_hex)" || exit 1\nb="$(oc_rand_hex)" || exit 1\nprintf "%s\\n%s\\n" "$a" "$b"')
    vals = (r.stdout or '').splitlines()
    check(r.returncode == 0 and len(vals) == 2 and all(re.fullmatch(r'[0-9a-f]{64}', v) for v in vals) and vals[0] != vals[1],
          '摘要候选连续输出均为 64 位小写十六进制且不相等')
    ok_clean, detail = rnd_left(rdir, '成功路径')
    check(ok_clean, '成功路径已清理随机临时文件', detail)

    # D：送进摘要的必须是"已核对长度的那同一份数据"，不是另一次读取、也不是空输入。
    #    桩 sha256sum 把自己收到的文件字节数写进旁路文件，断言恰好 32。
    side = work / 'side.txt'
    stub_sha = '#!/bin/sh\nwc -c <"$1" | tr -d " \\n" > "$SIDE"\nexec ' + REAL_SHA + ' "$@"\n'
    r = rand_run('d', {'od': fail, 'hexdump': fail, 'sha256sum': stub_sha}, rdir, side=side)
    got = side.read_text(encoding='utf-8').strip() if side.exists() else ''
    check(r.returncode == 0 and r.stdout.strip() != '' and got == '32',
          '摘要输入就是已核对长度的那 32 字节（旁路记录=%r）' % got)
else:
    print('    skip  sha256sum 或 dd 不可用')

# 长度对了不等于内容合法：od / hexdump 若吐出 64 个非十六进制字符（这里是 z），
# 绝不能被当成 token 返回 —— 调用方只判空，会把它原样写进网关配置。
bad_od = '#!/bin/sh\nprintf %s "' + 'z' * 64 + '"\n'
if REAL_SHA and shutil.which('dd'):
    rd_e = work / 'rundir-e'
    rd_f = work / 'rundir-f'
    rd_e.mkdir()
    rd_f.mkdir()
    r = rand_run('e', {'od': bad_od, 'hexdump': bad_od}, rd_e)
    out = r.stdout.strip()
    check(r.returncode == 0 and bool(re.fullmatch(r'[0-9a-f]{64}', out)) and out != 'z' * 64,
          'od/hexdump 输出非十六进制时不采用（改走摘要候选，输出=%s…）' % out[:12])
    r = rand_run('f', {'od': bad_od, 'hexdump': bad_od, 'sha256sum': fail, 'md5sum': fail}, rd_f)
    check(r.returncode != 0 and r.stdout == '', '非法输出且摘要工具均不可用时整体失败')

# md5sum 兜底必须也是 64 位：调用方按 64 位用（网关 token / 候选标识），
# 而单次 md5 只有 32 位 —— 历史上正是这里会产出"短一截"的 token。
if shutil.which('md5sum') and shutil.which('dd'):
    rd_g = work / 'rundir-g'
    rd_g.mkdir()
    r = rand_run('g', {'od': fail, 'hexdump': fail, 'sha256sum': fail}, rd_g,
                 body='a="$(oc_rand_hex)" || exit 1\nb="$(oc_rand_hex)" || exit 1\nprintf "%s\\n%s\\n" "$a" "$b"')
    vals = (r.stdout or '').splitlines()
    check(r.returncode == 0 and len(vals) == 2 and all(re.fullmatch(r'[0-9a-f]{64}', v) for v in vals) and vals[0] != vals[1],
          'md5sum 兜底同样输出 64 位小写十六进制且两次不同')

# 弱随机回落依赖 srand，无法仅靠本机桩掉 /dev/urandom 可读性，因此这里使用源码静态断言。
check('srand' not in func(lib_src, 'oc_rand_hex'), 'oc_rand_hex 已删除 srand 弱随机回落')

# mktemp 失败与 dd 失败都必须失败、无 stdout、无 rnd.* 残留。
for tag, stubs in [('mktemp-fail', {'od': fail, 'hexdump': fail, 'mktemp': fail}),
                   ('dd-fail', {'od': fail, 'hexdump': fail, 'dd': fail})]:
    d = work / ('cleanup-' + tag); d.mkdir()
    r = rand_run(tag, stubs, d)
    ok_clean, detail = rnd_left(d, tag)
    check(r.returncode != 0 and r.stdout == '' and ok_clean, tag + ' 失败路径无临时文件残留', detail)

# backup_current 的判定必须**实测**：静态字符串断言会放过"给模式加了引号"这种
# 写法 —— POSIX 里被引号包住的模式字符失去通配意义，'../*' 会退化成匹配字面量，
# 实测中加引号的版本放行了 a/../b、../y、x/.. 三种穿越形态却依然"看起来对"。
case_line = next((line for line in gh_src.splitlines() if '可疑路径' in line), '')
pat = case_line.split('case "$f" in')[-1].split(')')[0].strip()
probe = work / 'case-probe.sh'
probe.write_text(NL.join([
    '#!/bin/sh',
    'for f in foo..bar etc/config/openclaw usr/libexec/openclaw/main.sh /abs/x .. ../y a/../b x/.. ; do',
    '  case "$f" in',
    '    ' + pat + ') echo "REJECT $f" ;;',
    '    *) echo "ACCEPT $f" ;;',
    '  esac',
    'done',
]) + NL, encoding='utf-8')
probe.chmod(0o755)
r = subprocess.run(['sh', P(probe)], capture_output=True, text=True, timeout=30)
verdicts = {}
for ln in (r.stdout or '').splitlines():
    if ' ' in ln:
        v, p = ln.split(' ', 1)
        verdicts[p] = v
expect_reject = ['/abs/x', '..', '../y', 'a/../b', 'x/..']
expect_accept = ['foo..bar', 'etc/config/openclaw', 'usr/libexec/openclaw/main.sh']
check(all(verdicts.get(p) == 'REJECT' for p in expect_reject),
      'backup_current 拒绝绝对路径与四种 .. 穿越形态',
      ' '.join('%s=%s' % (p, verdicts.get(p)) for p in expect_reject))
check(all(verdicts.get(p) == 'ACCEPT' for p in expect_accept),
      'backup_current 不误伤含连续两点的正常文件名（foo..bar）',
      ' '.join('%s=%s' % (p, verdicts.get(p)) for p in expect_accept))

print('    共 %s 项，%s 项失败' % (total, failed))
sys.exit(1 if failed else 0)
PYEOF
