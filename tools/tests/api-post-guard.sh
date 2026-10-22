#!/bin/sh
# api-post-guard.sh — 会读凭据的端点必须强制 POST
#
# 背景（2026-10-22 审计）：api_apply 读了 apikey 却没有 is_post() 检查。
# http.formvalue() 同时接受 POST body 与 URL query，于是
#   GET .../api/apply?provider=x&apikey=sk-...
# 能生效，而 uhttpd 默认把完整 URL 写进访问日志 —— 密钥直接落盘。
# 同文件另外 12 个写操作端点都有这道检查，这是唯一漏掉的一处。
#
# 断言：
#   1. 任何用 formvalue 读 pass/code/apikey/secret/token 的端点，都必须有 is_post()
#   2. is_post() 自身按"取不到方法就拒绝"处理（fail-closed）
#   3. 前端调用这些端点时必须走 post()，不能拼进 URL
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
import sys

proj = pathlib.Path(sys.argv[1])
ctrl = (proj / 'luasrc/controller/openclaw.lua').read_text(encoding='utf-8')

total = 0
failed = 0


def check(ok, desc, detail=''):
    global total, failed
    total += 1
    print('    %s  %s%s' % ('ok  ' if ok else 'FAIL', desc, ('  ' + detail) if detail else ''))
    if not ok:
        failed += 1


# 切出每个 api_xxx 函数体（括号配对，别用非贪婪正则）
def split_funcs(text):
    marks = list(re.finditer(r'(?m)^function (api_\w+)\(\)', text))
    out = []
    for i, m in enumerate(marks):
        end = marks[i + 1].start() if i + 1 < len(marks) else len(text)
        out.append((m.group(1), text[m.start():end]))
    return out


# 单引号、双引号都要算；formvalue(var) 这种变量形式无法静态判断，这里只
# 保证不因引号风格漏检（审计发现原版只匹配双引号，是假阴性来源）。
SECRET_READ = re.compile(r'''formvalue\(\s*["'](pass|code|apikey|secret|token)''')
missing = []
for name, body in split_funcs(ctrl):
    if not SECRET_READ.search(body):
        continue
    if 'is_post()' not in body:
        missing.append(name)

check(not missing,
      '读凭据的端点都强制了 POST',
      ('缺：' + ', '.join(missing)) if missing else '')

# is_post 自身必须 fail-closed：取不到 REQUEST_METHOD 时按"不是 POST"处理
m = re.search(r'(?ms)^local function is_post\(\)\s*.*?\nend', ctrl)
if not m:
    check(False, '找到 is_post() 定义')
else:
    body = m.group(0)
    check('return (m or ""):upper() == "POST"' in body,
          'is_post() 取不到方法时按非 POST 处理（fail-closed）')

# 前端不得把这些端点拼进 URL 查询串
# 视图层面：凭据只允许出现在 post(...) 的 body 对象里，不许拼进 URL。
bad_url = []
for v in sorted((proj / 'luasrc/view/openclaw').glob('*.htm')):
    txt = v.read_text(encoding='utf-8')
    for m in re.finditer(r'[?&](apikey|pass|password|code|secret)=', txt):
        bad_url.append('%s: %s=' % (v.name, m.group(1)))
        break
check(not bad_url, '视图里没有把凭据拼进 URL 查询串',
      (', '.join(bad_url)) if bad_url else '')

# 前端必须用 post() 调用这些端点，而不是拼一个 GET 链接
post_ok = True
for v in sorted((proj / 'luasrc/view/openclaw').glob('*.htm')):
    txt = v.read_text(encoding='utf-8')
    for api in ('API.apply', 'API.cloud_pass_set', 'API.cloud_login_code'):
        if api not in txt:
            continue
        if not re.search(r'post\(\s*' + re.escape(api), txt):
            post_ok = False
            print('        %s 里的 %s 没有走 post()' % (v.name, api))
check(post_ok, '前端用 post() 调用带凭据的端点')

print('    共 %s 项，%s 项失败' % (total, failed))
sys.exit(1 if failed else 0)
PYEOF
