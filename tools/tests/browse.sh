#!/bin/sh
# browse.sh — 迁移页目录浏览（openclaw.sh browse）的回归测试
#
# 这一段是**只读**的，所以危险点不在破坏性，而在两处很容易写错的地方：
#
#   1. 名字里带空格 / 中文 / 引号时，拼出来的 JSON 必须仍然能 parse。
#      一旦坏掉，前端整块列表都渲染不出来，而且看起来像"这个目录是空的"。
#   2. 空目录、传了文件、传了 /proc 这些边界必须明确返回 ok:false，
#      而不是返回空列表 —— 空列表会让用户以为"这里真的没有子文件夹"。
#
# 转义用的是 lib.sh 里真实的 oc_json_str（不另写桩），这样测的就是线上那份。
# 断言在 python 里做：解析 helper 的 stdout，检查结构而不是字符串长相。
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
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

proj = pathlib.Path(sys.argv[1])
src = (proj / 'root/usr/libexec/openclaw/cli.sh').read_text(encoding='utf-8')
lib = (proj / 'root/usr/libexec/openclaw/lib.sh').read_text(encoding='utf-8')

total = 0
failed = 0


def check(ok, desc):
    global total, failed
    total += 1
    print('    %s  %s' % ('ok  ' if ok else 'FAIL', desc))
    if not ok:
        failed += 1


def grab(text, name):
    m = re.search(r'(?ms)^' + re.escape(name) + r'\(\)\s*\{.*?\n\}', text)
    assert m, '取不到函数 ' + name
    return m.group(0)


def const(name):
    m = re.search(r'(?m)^' + re.escape(name) + r'=(\d+)', src)
    assert m, '取不到常量 ' + name
    return m.group(1)


JSONFN = grab(lib, 'oc_json_str')

# 只抽出被浏览用到的部分：常量 + 两个小函数 + cmd_browse。
# oc_probe_openclaw_dir 用最简单的布局判断当桩（真实实现只做几次文件存在性检查）。
PROBE_STUB = r'''
oc_probe_openclaw_dir() {
	[ -f "$1/data/.openclaw/openclaw.json" ] && { printf 'istore'; return 0; }
	return 1
}
'''

browse_script = '\n'.join([
    '#!/bin/sh',
    'BROWSE_PATH_MAX=%s' % const('BROWSE_PATH_MAX'),
    'BROWSE_MAX=%s' % const('BROWSE_MAX'),
    JSONFN,
    PROBE_STUB,
    grab(src, 'browse_esc'),
    grab(src, 'browse_fail'),
    grab(src, 'cmd_browse'),
    'cmd_browse "$@"',
    '',
])

esc_script = '\n'.join([
    '#!/bin/sh',
    JSONFN,
    grab(src, 'browse_esc'),
    'browse_esc "$1"',
    '',
])

work = pathlib.Path(tempfile.mkdtemp())


def P(p):
    """把 Windows 盘符路径转成 sh 能用的 POSIX 路径（Linux 上原样返回）。

    helper 的绝对路径判断是 case "/*"，而 MSYS 下 tempfile 给的是 C:/...，
    直接传进去会被判成"不是绝对路径" —— 测试会全线误报。
    """
    s = pathlib.Path(p).as_posix()
    m = re.match(r'^([A-Za-z]):/', s)
    return '/' + m.group(1).lower() + s[2:] if m else s


try:
    runner = work / 'browse.sh'
    runner.write_text(browse_script, encoding='utf-8', newline='\n')
    esc_runner = work / 'esc.sh'
    esc_runner.write_text(esc_script, encoding='utf-8', newline='\n')

    def run(path=None, show='0'):
        argv = ['sh', runner.as_posix()]
        if path is not None:
            argv += ['', path, show]
        r = subprocess.run(argv, capture_output=True, text=True)
        body = r.stdout.strip()
        try:
            return json.loads(body) if body else {}, r.returncode
        except Exception:
            print('      输出不是 JSON：%r' % body[:200])
            return {}, r.returncode

    # ── 夹具：目录树 ────────────────────────────────────────────
    root = work / 'mnt'
    (root / 'data' / 'OpenClaw' / 'data' / '.openclaw').mkdir(parents=True)
    (root / 'data' / 'OpenClaw' / 'data' / '.openclaw' / 'openclaw.json').write_text('{}', encoding='utf-8')
    (root / 'data' / '普通 目录').mkdir()
    (root / 'data' / '.hidden').mkdir()
    (root / 'data' / 'notadir.txt').write_text('x', encoding='utf-8')

    d = run(P(root / 'data'))[0]
    names = [e['name'] for e in d.get('entries', [])]
    check(d.get('ok') is True, '目录列表返回 ok:true')
    check('notadir.txt' not in names, '只列目录，不列文件')
    check('.hidden' not in names, '默认不列 . 开头的隐藏目录')
    check(d.get('hidden_count') == 1, '默认时报告被隐藏的个数（hidden_count）')
    check(d.get('hidden') is False, '默认时 hidden 标志为 false')

    # ── 显示隐藏目录：.openclaw 本身就是数据目录名，必须能点进去 ──
    dh = run(P(root / 'data'), '1')[0]
    hnames = [e['name'] for e in dh.get('entries', [])]
    check('.hidden' in hnames, 'show=1 时列出隐藏目录')
    check(dh.get('hidden') is True, 'show=1 时 hidden 标志为 true')
    check(dh.get('hidden_count') == 1, 'show=1 时 hidden_count 仍然报告个数')
    check('普通 目录' in hnames, 'show=1 时普通目录仍在')

    # 参数白名单：非 1 一律当 0
    for weird in ('yes', '2', 'x', ''):
        dw = run(P(root / 'data'), weird)[0]
        wn = [e['name'] for e in dw.get('entries', [])]
        check('.hidden' not in wn, 'show=%r 被当成 0（不列隐藏）' % weird)
    check('普通 目录' in names, '名字含空格与中文的目录能原样出现')
    check(names == sorted(names), '条目按名字排序')
    check(d.get('parent') == P(root), 'parent 指向上一级')

    oc = [e for e in d.get('entries', []) if e['name'] == 'OpenClaw']
    check(oc and oc[0].get('kind') == 'istore', 'OpenClaw 安装被标记为 istore')
    check(oc and oc[0].get('path') == P(root / 'data' / 'OpenClaw'), '条目的 path 是完整路径')
    plain = [e for e in d.get('entries', []) if e['name'] == '普通 目录']
    check(plain and plain[0].get('kind') == '', '普通目录的 kind 为空串')

    # ── 转义（用真实 oc_json_str；Windows 建不出带引号的目录，直接测函数）──
    for name in ('with "quote"', 'back\\slash', '普通 名字', 'a/b'):
        r = subprocess.run(['sh', esc_runner.as_posix(), name], capture_output=True, text=True)
        try:
            back = json.loads('{"n":"%s"}' % r.stdout)['n']
            ok = back == name
        except Exception:
            ok = False
        check(ok, 'browse_esc 转义 %r' % name)

    # ── 边界 ───────────────────────────────────────────────────
    bad = run(P(root / 'data' / 'notadir.txt'))[0]
    check(bad.get('ok') is False and '不是目录' in bad.get('error', ''), '传文件 → ok:false「不是目录」')

    bad = run(P(root / 'nope'))[0]
    check(bad.get('ok') is False and '不存在' in bad.get('error', ''), '不存在的目录 → ok:false')

    bad = run('/proc')[0]
    check(bad.get('ok') is False and '不支持浏览' in bad.get('error', ''), '/proc → ok:false「不支持浏览」')

    bad = run('/proc/self')[0]
    check(bad.get('ok') is False, '/proc 的子目录同样拒绝')

    bad = run('relative/path')[0]
    check(bad.get('ok') is False, '相对路径 → ok:false')

    d = run(P(root / 'data') + '/')[0]
    check(d.get('path') == P(root / 'data'), '尾斜杠被规范化')

    d = run('/')[0]
    check(d.get('ok') is True and d.get('parent') == '', '/ 的 parent 为空串')

    # ── 超过上限要标 truncated ────────────────────────────────
    many = work / 'many'
    many.mkdir()
    for i in range(305):
        (many / ('d%03d' % i)).mkdir()
    d = run(P(many))[0]
    check(d.get('truncated') is True, '超过 %s 条时 truncated:true' % const('BROWSE_MAX'))
    check(len(d.get('entries', [])) == int(const('BROWSE_MAX')), '条目数被截到上限')

    # ── 默认起点（不传参数）────────────────────────────────────
    d = run()[0]
    check(d.get('ok') is True and d.get('path') in ('/mnt', '/'), '不传参数时用默认起点')
finally:
    shutil.rmtree(work, ignore_errors=True)

print('    共 %s 项，%s 项失败' % (total, failed))
sys.exit(1 if failed else 0)
PYEOF
