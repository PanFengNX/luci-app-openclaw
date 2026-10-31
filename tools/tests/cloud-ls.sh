#!/bin/sh
# cloud-ls.sh — 云端备份列表（cloud.sh ls）的空状态判定
#
# 背景：远端目录 openclaw-backups 只在**首次上传时**才创建（cmd_upload 里的
# mkdir）。所以一台从未传过备份的设备，`bdpan ls openclaw-backups` 必然失败。
# 这是正常的初始状态，不该报错 —— 否则新装用户第一次打开备份页看到的是
# 「读取云端列表失败」，而这句话完全不指向「你还没传过备份」。
#
# 判定同时覆盖三种形状：
#   * 中文 / 英文的"不存在"
#   * JSON 里的 errno（百度 PCS 用 -9 / -3 表示路径不存在）
#   * 未登录（由 cloud_ls_not_logged_in 单独判定：未登录不是空状态，
#     页面必须提示「重新登录」而不是显示「暂无备份」）
#
# 反向也要守住：**真实错误不能被当成空列表**，否则用户以为备份都丢了。
# 磁盘满、网络超时、组件损坏都必须仍然报错。
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
import subprocess
import sys
import tempfile

proj = pathlib.Path(sys.argv[1])
NL = chr(10)
src = (proj / 'root/usr/libexec/openclaw/cloud.sh').read_text(encoding='utf-8')

total = 0
failed = 0


def check(ok, desc, detail=''):
    global total, failed
    total += 1
    print('    %s  %s%s' % ('ok  ' if ok else 'FAIL', desc, ('  ' + detail) if detail else ''))
    if not ok:
        failed += 1


def func(name):
    """按行号切函数体：下一个顶层函数定义即为结束。

    不能用大括号配对 —— cloud_ls_tsv 里的 awk 程序含 `c == "{"` 这类
    字符串比较，配对会被字符串里的花括号带偏（实测取到半截函数，
    整组断言全部误报 rc=2）。
    """
    lines = src.splitlines()
    starts = [(i, m.group(1)) for i, l in enumerate(lines)
              for m in [re.match(r'^([a-z_][a-z0-9_]*)\(\)\s*\{', l)] if m]
    for idx, (ln, nm) in enumerate(starts):
        if nm == name:
            end = starts[idx + 1][0] if idx + 1 < len(starts) else len(lines)
            return NL.join(lines[ln:end])
    raise AssertionError('取不到函数 ' + name)


work = pathlib.Path(tempfile.mkdtemp())


def P(p):
    s = pathlib.Path(p).as_posix()
    return '/c' + s[2:] if len(s) > 1 and s[1] == ':' else s


# ---------------------------------------------------------------- 判定函数
judge = NL.join([
    '#!/bin/sh',
    func('cloud_ls_empty_state'),
    func('cloud_ls_not_logged_in'),
    'if [ "$JUDGE_MODE" = login ]; then cloud_ls_not_logged_in "$JUDGE_INPUT"; else cloud_ls_empty_state "$JUDGE_INPUT"; fi',
    '',
])
jf = work / 'judge.sh'
jf.write_text(judge, encoding='utf-8', newline=NL)

EMPTY = [
    ('空输出', ''),
    ('中文不存在', 'Error: 目录不存在'),
    ('英文 not exist', 'Error: file not exist'),
    ('英文 does not exist', 'path does not exist'),
    ('No such file', 'ls: No such file or directory'),
    ('路径无效', '{"error":"路径无效（错误码 -3）"}'),
]
for label, text in EMPTY:
    r = subprocess.run(['sh', P(jf)], capture_output=True, text=True,
                           env=dict(os.environ, JUDGE_INPUT=text, JUDGE_MODE='empty'))
    check(r.returncode == 0, '判为空状态：%s' % label, ('rc=%d' % r.returncode) if r.returncode else '')

NOT_LOGGED_IN = [
    ('未登录中文', '请先登录'),
    ('未登录英文', 'Error: not logged in'),
    ('login required', 'login required'),
]
for label, text in NOT_LOGGED_IN:
    r = subprocess.run(['sh', P(jf)], capture_output=True, text=True,
                           env=dict(os.environ, JUDGE_INPUT=text, JUDGE_MODE='login'))
    check(r.returncode == 0, '判为未登录：%s' % label)
for label, text in [('目录不存在', 'Error: 目录不存在'), ('磁盘满', 'Error: 磁盘空间不足')]:
    r = subprocess.run(['sh', P(jf)], capture_output=True, text=True,
                           env=dict(os.environ, JUDGE_INPUT=text, JUDGE_MODE='login'))
    check(r.returncode == 1, '未登录判定排除：%s' % label)

# 用户真机实测的原文（1.8.17 就是漏了这条：措辞是「找不到」不是「不存在」，
# 错误码是文本里的「错误码 -9」而不是 JSON 字段 "errno":-9）
EMPTY += [
    ('实测：找不到指定的文件或目录',
     '{"code":1,"data":null,"error":"找不到指定的文件或目录（错误码 -9），请检查路径是否正确。"}'),
    ('实测：错误码 -9 变体', 'Error: 找不到指定的文件（错误码 -9）'),
    ('实测：错误码 -3', '{"error":"路径无效（错误码 -3）"}'),
    ('errno -9', '{"errno":-9,"error":"x"}'),
    ('errno -9 带空格', '{"errno": -9}'),
    ('errno -3', '{"errno":-3}'),
]
for label, text in EMPTY:
    r = subprocess.run(['sh', P(jf)], capture_output=True, text=True,
                           env=dict(os.environ, JUDGE_INPUT=text, JUDGE_MODE='empty'))
    check(r.returncode == 0, '判为空状态：%s' % label, ('rc=%d' % r.returncode) if r.returncode else '')

REAL = [
    ('磁盘满', 'Error: 磁盘空间不足'),
    ('网络超时', 'Error: network timeout'),
    ('权限拒绝', 'Error: permission denied'),
    ('组件损坏', 'Error: invalid ELF header'),
    ('普通报错', 'Error: something went wrong'),
]
for label, text in REAL:
    r = subprocess.run(['sh', P(jf)], capture_output=True, text=True,
                       env=dict(os.environ, JUDGE_INPUT=text, JUDGE_MODE='empty'))
    check(r.returncode != 0, '真实错误不被当成空状态：%s' % label)

# ---------------------------------------------------------------- cmd_ls 端到端
ls_script = NL.join([
    '#!/bin/sh',
    'OC_RUNDIR="$1"; OC_CLOUD_REMOTE="openclaw-backups"',
    # 桩：bin 永远就绪，cloud_run 执行第二个参数之后的命令
    'cloud_bin_ready() { printf %s /bin/true; }',
    'cloud_run() { shift; "$@"; }',
    'oc_warn() { :; }',
    'jstr() { printf "%s" "$1"; }',
    'cloud_fail() { printf \'{"ok":false,"error":"%s"}\\n\' "$1"; exit "${2:-1}"; }',
    'cloud_tail_err() { tail -n "${2:-5}" "$1" 2>/dev/null; }',
    'oc_cut_utf8() { cat; }',
    'cloud_redact() { cat; }',
    func('cloud_ls_tsv'),
    func('cloud_ls_empty_state'),
    func('cloud_ls_not_logged_in'),
    func('cmd_ls'),
    'cmd_ls',
    '',
])

# 假的 bdpan：用环境变量决定输出什么
FAKE = work / 'bdpan'
FAKE.write_text(NL.join([
    '#!/bin/sh',
    'printf "%s\\n" "$FAKE_OUT"',
    '[ "${FAKE_RC:-0}" -eq 0 ] || exit "$FAKE_RC"',
    'exit 0',
    '',
]), encoding='utf-8', newline=NL)

# 假 bdpan 的输出来自环境变量。**不要**用中间 shell 脚本转发参数：
# `sh runner out rc script rundir` 这种写法在 MSYS 下会以
# 0xC0000005（访问冲突）退出，stdout 全空，看起来像被测代码坏了。
# 直接把环境变量传给 subprocess 最稳。


def run_ls(out, rc=0):
    rundir = work / 'rundir'
    rundir.mkdir(exist_ok=True)
    env_script = work / 'ls_runner.sh'
    stub = 'cloud_bin_ready() { printf %%s "%s"; }' % P(FAKE)
    env_script.write_text(ls_script.replace('cloud_bin_ready() { printf %s /bin/true; }', stub),
                          encoding='utf-8', newline=NL)
    env = dict(os.environ)
    env['FAKE_OUT'] = out
    env['FAKE_RC'] = str(rc)
    r = subprocess.run(['sh', P(env_script), P(rundir)],
                       capture_output=True, text=True, env=env)
    return r.stdout.strip()


r = run_ls('Error: 目录不存在', 1)
check('"ok":true' in r and '"data":[]' in r,
      '目录不存在（rc=1）→ 空列表而不是报错', r[:80])

r = run_ls('{"errno":-9,"error":"file not found"}', 0)
check('"ok":true' in r and '"data":[]' in r,
      '错误 JSON 无数组 → 空列表', r[:80])

r = run_ls('[]', 0)
check('"ok":true' in r and '"data":[]' in r, '空数组 → 空列表', repr(r)[:120])

r = run_ls('[{"server_filename":"openclaw-a.tar.gz","size":123,"server_mtime":1760000000,"isdir":0}]', 0)
check('"ok":true' in r and 'openclaw-a.tar.gz' in r, '正常列表原样返回', repr(r)[:140])

r = run_ls('Error: not logged in', 1)
check('"note":"尚未登录' in r, '未登录 → 提示重新登录', r[:100])

r = run_ls('Error: 磁盘空间不足', 1)
check('"ok":false' in r and '磁盘空间不足' in r, '真实错误仍然报错', r[:100])

# 组件未安装：cloud_bin_ready 失败时也要给出可操作提示。
no_bin_script = ls_script.replace(
    'cloud_bin_ready() { printf %s /bin/true; }',
    'cloud_bin_ready() { return 1; }')
no_bin = work / 'no-bin.sh'
no_bin.write_text(no_bin_script, encoding='utf-8', newline=NL)
r = subprocess.run(['sh', P(no_bin), P(work / 'rundir')], capture_output=True, text=True)
check('"note":"网盘组件未安装' in r.stdout, '组件未安装 → 提示安装并登录', r.stdout[:100])

print('    共 %s 项，%s 项失败' % (total, failed))
sys.exit(1 if failed else 0)
PYEOF
