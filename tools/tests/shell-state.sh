#!/bin/sh
# shell-state.sh — 子 shell 丢变量、awk 裸 sub 两陷阱
#
# 两个都是"语法合法、静态检查查不出、只有运行时才出错"的坑，且都在实际
# 使用中暴露过：
#
#   1. cloud_probe_latest 被 `latest="$(cloud_probe_latest)"` 调用。
#      命令替换在子 shell 里执行，函数设置的 OC_PROBE_OK / OC_PROBE_REACHABLE
#      全部随子 shell 消失，调用方读到的是初始值 0 —— 于是"探测成功"被判成
#      "网络不通"，检查更新永远显示"无法连接官方下载源"。
#
#   2. awk 里裸写 `sub(/.../, "", $0)` 单独成行时会被当成**模式**，而模式的
#      默认动作是 print —— 匹配到尾部标点的行会被原样打印，绕过后面所有过滤。
#      实测就是它让 provider:/models: 漏进模型下拉框。
#
# 断言：
#   1. 任何"写全局变量供调用方读"的函数，不得用 $(...) 调用
#   2. cloud_probe_latest 通过全局变量返回，且调用方直接调用
#   3. awk 程序里不存在裸 sub/gsub 语句（必须包在 { } 里）
#   4. live_models 对典型 CLI 噪声输出返回空
#   5. live_models 对真实模型列表原样返回
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
total = 0
failed = 0


def check(ok, desc, detail=''):
    global total, failed
    total += 1
    print('    %s  %s%s' % ('ok  ' if ok else 'FAIL', desc, ('  ' + detail) if detail else ''))
    if not ok:
        failed += 1


def read(rel):
    return (proj / rel).read_text(encoding='utf-8')


def extract(text, name):
    """括号配对取函数体；非贪婪正则会截在第一个 }。"""
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


cloud = read('root/usr/libexec/openclaw/cloud.sh')
models = read('root/usr/libexec/openclaw/models.sh')

# ---- 1) 探测函数不得用命令替换调用 ----
# 只查代码，注释里解释这个坑的句子（也含同样的字样）要排除
cloud_code = NL.join(re.sub(r'#.*$', '', ln) for ln in cloud.splitlines())
check('cloud_probe_latest)"' not in cloud_code and
      'cloud_probe_latest)' not in cloud_code.replace('$(cloud_probe_latest', '$(X'),
      '没有用 $(...) 调用 cloud_probe_latest')
check(cloud.count('cloud_probe_latest\n') >= 2 or
      re.search(r'(?m)^\s*cloud_probe_latest\s*$', cloud) is not None,
      '调用方直接调用（结果走全局变量）')
body = extract(cloud, 'cloud_probe_latest') or ''
check('OC_PROBE_LATEST=' in body, '函数把结果写进 OC_PROBE_LATEST')
check('printf' not in body.split('OC_PROBE_LATEST=')[-1][:200] or
      'printf' not in body,
      '函数不再往 stdout 打版本号（避免与变量返回混用）')

# ---- 2) awk 里不得有裸 sub/gsub 语句 ----
# 抓 awk 程序块：单引号包裹的多行段，逐行看是否以 sub(/gsub( 开头且不在 { 内
# 需要跟踪 awk 程序内的大括号深度：`sub(/../, "", $0)` 只有在**深度 0**
# 且单独成行时才是"裸语句"（会被当成模式触发默认 print）。包在 { } 或
# BEGIN { } 里是完全正确的写法，项目里大量存在。
bare = []
for f in sorted((proj / 'root/usr/libexec/openclaw').glob('*.sh')):
    depth = 0
    in_awk = False
    for n, ln in enumerate(f.read_text(encoding='utf-8').splitlines(), 1):
        s = ln.strip()
        if not in_awk:
            if re.search(r"\bawk\b.*'$", s) or re.search(r"\bawk\b.*'\\$", s):
                in_awk = True
                depth = 0
            continue
        if s.startswith("'"):
            in_awk = False
            continue
        code = re.sub(r'#.*$', '', s)          # awk 里的注释
        if depth == 0 and re.match(r'^(sub|gsub)\s*\(', code):
            bare.append('%s:%d' % (f.name, n))
        # 统计括号前必须剥掉字符串字面量：awk 代码里常有 c == "{" 这种比较，
        # 字符串里的花括号会把深度算歪（实测就误报了 3 处）。
        code_ns = re.sub(r'"(?:[^"\\]|\\.)*"', '""', code)
        depth += code_ns.count('{') - code_ns.count('}')
check(not bare, 'awk 里没有裸 sub/gsub 语句（必须包在 { } 里）',
      ('  ' + ', '.join(bare)) if bare else '')

# ---- 3) live_models 行为 ----
fn = extract(models, 'live_models')
check(fn is not None, '取到 live_models')
if fn:
    work = pathlib.Path(tempfile.mkdtemp())

    def P(p):
        s = pathlib.Path(p).as_posix()
        return '/c' + s[2:] if len(s) > 1 and s[1] == ':' else s

    def run(cli_lines):
        data = work / 'cli.txt'
        data.write_bytes(NL.join(cli_lines).encode('utf-8'))
        script = work / 'run.sh'
        script.write_text(NL.join([
            '#!/bin/sh',
            'oc_oc_bin() { echo /bin/true; }',
            'oc_run_q() { cat "%s"; }' % P(data),
            fn,
            'live_models deepseek',
        ]) + NL, encoding='utf-8', newline=NL)
        r = subprocess.run(['sh', P(script)], capture_output=True, text=True)
        return [x for x in r.stdout.split() if x]

    NOISE = [
        ('无模型提示', ['No models found.']),
        ('小写计数', ['0 models found']),
        ('nothing found', ['nothing found']),
        ('Node 报错头', ['Node.js v24.19.0', 'Cannot find module `x`']),
        ('表头', ['provider: deepseek', 'models:']),
    ]
    for label, lines in NOISE:
        got = run(lines)
        bad = [g for g in got if g.lower() in
               ('found', 'models', 'provider', 'find', 'module', 'node') or
               re.match(r'^v[0-9]+(\.[0-9]+)+$', g)]
        check(not bad, '噪声输出被过滤干净（%s）' % label, str(got) if bad else '')

    good = ['deepseek-v4-flash', 'deepseek-v4-pro', 'deepseek-chat', 'deepseek-reasoner']
    check(run(good) == sorted(good), '真实模型清单原样保留',
          str(run(good)))
    check(run(['deepseek/deepseek-chat', 'deepseek/deepseek-v4-flash']) ==
          ['deepseek/deepseek-chat', 'deepseek/deepseek-v4-flash'],
          'provider/model 形式保留')
    check(run(['deepseek-v4.1', 'gpt-4.1-mini']) == ['deepseek-v4.1', 'gpt-4.1-mini'],
          '带点/版本号的模型名不被误杀')
    check(run([]) == [], '空输出返回空')

print('    共 %s 项，%s 项失败' % (total, failed))
sys.exit(1 if failed else 0)
PYEOF
