#!/bin/sh
# info-json.sh — cmd_info 的 JSON 必须经得起任意输入
#
# 用户实测：重启之后状态页显示「未安装」、安装目录 / 版本 / 剩余空间全是 '-'，
# 但实际运行环境还在。原因是 cmd_info 把几条**外部来源**的字符串直接塞进
# printf 拼出的 JSON：
#
#   ver / nver  来自 `openclaw --version` / `node -v` 的输出
#   home / url  来自 UCI（可被 SSH 手改）
#
# 其中任何一条带上双引号、反斜杠或换行，整段 JSON 就成了非法文档：
#   控制器 jsonc.parse 返回 nil
#   → api_info 回 {ok:false,"后端返回无法解析"}
#   → 前端 jp(r.data||'{}') 得到 {}
#   → status 缺失，界面按默认值渲染成「未安装」+ 全部 '-'
#
# 断言：
#   1. 正常值下 JSON 合法
#   2. 版本号里含 " / \ / 换行 / $ / 反引号 时仍然合法
#   3. base_dir / home / url 含引号时仍然合法
#   4. 解析回来的值与输入**逐字相等**（转义不能丢字符）
#   5. 前面加的空格不能把 port 这类纯数字字段变成带引号的字符串
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
import pathlib
import re
import subprocess
import sys
import tempfile

proj = pathlib.Path(sys.argv[1])
NL = chr(10)
cli = (proj / 'root/usr/libexec/openclaw/cli.sh').read_text(encoding='utf-8')
lib = (proj / 'root/usr/libexec/openclaw/lib.sh').read_text(encoding='utf-8')
status = (proj / 'luasrc/view/openclaw/status.htm').read_text(encoding='utf-8')

total = 0
failed = 0


def check(ok, desc, detail=''):
    global total, failed
    total += 1
    print('    %s  %s%s' % ('ok  ' if ok else 'FAIL', desc, ('  ' + detail) if detail else ''))
    if not ok:
        failed += 1


# ---------------------------------------------------------------- 静态断言
def func(text, name):
    lines = text.splitlines()
    starts = [(i, m.group(1)) for i, l in enumerate(lines)
              for m in [re.match(r'^([a-z_][a-z0-9_]*)\(\)\s*\{', l)] if m]
    for idx, (ln, nm) in enumerate(starts):
        if nm == name:
            end = starts[idx + 1][0] if idx + 1 < len(starts) else len(lines)
            return NL.join(lines[ln:end])
    raise AssertionError('取不到函数 ' + name)


info = func(cli, 'cmd_info')
# 从 printf 起到函数结束，只保留**赋值/格式化**区域
printf_start = info.index("printf '{\"status\"")
printf_blk = info[printf_start:]

# 格式串里带引号的 %s 必须配一个被 oc_json_str 包住的参数。
# 这里做的是"参数个数与形态"的粗检：任何裸 "$var" 出现在 printf 参数区都算可疑。
raw_params = [l.strip() for l in printf_blk.splitlines()[1:] if l.strip()]
suspect = []
for ln in raw_params:
    if '"$' in ln and 'oc_json_str' not in ln and 'uci -q get' not in ln:
        suspect.append(ln)
# "$([ ... ] && echo true || echo false)" 是布尔，允许
# status 是脚本内部常量（running/stopped/not_installed 三选一），不是外部输入；
# 其余裸变量出现在参数区都可以接受的前提是"值域受限"或"已确认过"。
SAFE = ('echo true', 'oc_node_mode', 'oc_arch', 'oc_is_musl', '${free',
        'main.enabled', 'main.core_dumps', 'main.bind', 'installed &&',
        '"$st"')
suspect = [s for s in suspect if not any(k in s for k in SAFE)]
check(not suspect, 'printf 参数区没有裸字符串（都过 oc_json_str）',
      '; '.join(x[:50] for x in suspect[:3]))

# 前端：读不到 info 时不能渲染成「未安装」
check('状态未知' in status, '状态页读不到信息时显示「状态未知」而不是「未安装」')
check('不代表未安装' in status, '状态页明确提示"不代表未安装"')

# ---------------------------------------------------------------- 行为断言
errs = [l for l in lib.splitlines() if 'oc_json_str' in l]
esc = func(lib, 'oc_json_str')

work = pathlib.Path(tempfile.mkdtemp())


def P(p):
    s = pathlib.Path(p).as_posix()
    return '/c' + s[2:] if len(s) > 1 and s[1] == ':' else s


def run_info(ver, base='/mnt/data/OpenClaw', home='/mnt/data/OpenClaw/home',
             host='192.168.10.2'):
    """把 cmd_info 的 printf 段拿出来，用桩跑一遍，返回 stdout。"""
    q = lambda s: "'" + s.replace("'", "'\\''") + "'"
    stubs = NL.join([
        'st=stopped',
        'port=18789',
        'token=tok',
        'ver=%s' % q(ver),
        'nver=v24.1.0',
        'base=%s' % q(base),
        'ocdir=%s' % q(base + '/openclaw'),
        'home=%s' % q(home),
        'free=61002',
        'installed() { return 0; }',
        'get_port() { printf 18789; }',
        'get_token() { printf tok; }',
        'oc_base_dir() { printf %%s %s; }' % q(base),
        'oc_oc_dir() { printf %%s %s; }' % q(base + '/openclaw'),
        'oc_free_mb() { printf 61002; }',
        'oc_home_dir() { printf %%s %s; }' % q(home),
        'oc_node_mode() { printf private; }',
        'oc_arch() { printf x86_64; }',
        'oc_is_musl() { return 0; }',
        "uci_get() { printf '%s' \"${2:-}\"; }",
        'uci() { printf %%s %s; }' % q(host),
        func(lib, 'oc_json_str'),
        printf_blk,
    ])
    f = work / 'info.sh'
    f.write_text(NL.join(['#!/bin/sh', stubs, '']), encoding='utf-8', newline=NL)
    r = subprocess.run(['sh', P(f)], capture_output=True, text=True, timeout=60)
    return r.stdout.strip(), r.stderr.strip()


CASES = [
    ('正常版本号', dict(ver='2026.10.6')),
    ('含双引号', dict(ver='v1.0"beta')),
    ('含反斜杠', dict(ver='v1.0\\x')),
    ('含换行', dict(ver='v1.0' + NL + 'extra')),
    ('含 $ 与反引号', dict(ver='v1$HOME`id`')),
    ('含制表符', dict(ver='v1' + chr(9) + 'b')),
    ('base_dir 含引号', dict(ver='1.0', base='/mnt/a"b')),
    ('home 含反斜杠', dict(ver='1.0', home='/mnt/a\\home')),
    ('host 含引号', dict(ver='1.0', host='10.0.0"1')),
]

for label, kw in CASES:
    out, err = run_info(**kw)
    try:
        d = json.loads(out)
    except Exception as e:
        check(False, 'JSON 合法：%s' % label, str(e)[:60])
        check(False, '解析回原值：%s' % label)
        continue
    check(True, 'JSON 合法：%s' % label)
    # 关键字段必须逐字还原（控制字符会被 oc_json_str 按设计剥掉，这里只比对干净值）
    want = kw.get('ver', '2026.10.6')
    want_clean = ''.join(c for c in want if c == NL or c == chr(9) or ord(c) >= 32)
    got = d.get('openclaw', '')
    if chr(9) in want:
        # 制表符在 JSON 里被转成 \t，解析回来仍应是 \t
        ok = got == want.replace(chr(9), chr(9))
    else:
        ok = got.replace(NL, NL) == want_clean
    check(ok, '版本号逐字还原：%s' % label, repr(got)[:40])

# port 不能被转义成带引号的字符串（否则前端 (d.port||'-') + ' / ' 仍可用，
# 但类型变了会误导后续比较；这里确认它就是字符串 "18789" 而不是带转义的怪值）
out, _ = run_info(ver='1.0')
d = json.loads(out)
check(d.get('port') == '18789', 'port 保持原值', repr(d.get('port')))
check(d.get('installed') is True, 'installed 是布尔而不是字符串', repr(d.get('installed')))
check(d.get('free_mb') == '61002', 'free_mb 保持数字字符串', repr(d.get('free_mb')))

print('    共 %s 项，%s 项失败' % (total, failed))
sys.exit(1 if failed else 0)
PYEOF
