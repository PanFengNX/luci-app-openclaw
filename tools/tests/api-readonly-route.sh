#!/bin/sh
# api-readonly-route.sh — 前端用 GET 调用的端点必须真的登记进 READ_ONLY
#
# 背景（2026-10-29 全盘审计）：控制器的 CSRF 守卫在加载时把每个 api_xxx 换成
# 守卫版，守卫按「路由短名」去查 READ_ONLY 表（READ_ONLY[guard_name]）。
# 于是只要这张表和真实端点名不一致，功能就立刻坏掉：
#
#   * gh_update_status      —— 表项拼错：真实端点叫 github_update_status，
#                              导致安装进度轮询一直报「请使用 POST 提交」；
#   * cloud_backup_poll     —— 从未登记，云端备份进度读不到；
#   * delpass_status        —— 从未登记，备份页「删除密码」永远停在「读取中…」。
#
# 这类故障不会报错-backtrace，只是某个 UI 永远转圈/永远灰色，靠人眼核对签名
# 必然再犯。这个测试把它变成机械检查：
#   1. READ_ONLY 的每个键都必须对应一个真实路由（抓出拼错的僵尸键）；
#   2. 前端用 get() / window.open() 调用的每个端点都必须在 READ_ONLY 里；
#   3. window.open 触发的下载端点同样按 GET 算。
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


ro_block = re.search(r'local READ_ONLY = \{(.*?)\n\}', ctrl, re.S)
if not ro_block:
    check(False, '找到 READ_ONLY 白名单定义')
    print('    共 %s 项，%s 项失败' % (total, failed))
    sys.exit(1)

read_only = set(re.findall(r'([a-z_0-9]+)\s*=\s*true', ro_block.group(1)))
routes = {m.group(1)[4:] for m in re.finditer(r'call\("(api_[a-z_0-9]+)"\)', ctrl)}

# 1) 僵尸键：表里写了但根本没有这个路由 —— 说明名字拼错或被删了忘了摘
ghosts = sorted(read_only - routes)
check(not ghosts, 'READ_ONLY 里没有指向空处的僵尸键',
      ('僵尸键：' + ', '.join(ghosts)) if ghosts else '')

# 2) 前端 GET 调用的端点必须在表里
get_callers = {}
for v in sorted((proj / 'luasrc/view/openclaw').glob('*.htm')):
    txt = v.read_text(encoding='utf-8')
    for m in re.finditer(r'\bget\(\s*API\.([a-z_0-9]+)', txt):
        get_callers.setdefault(m.group(1), set()).add(v.name)
    # window.open(...) 走的是浏览器 GET
    for m in re.finditer(r'window\.open\([^)]*API\.([a-z_0-9]+)', txt):
        get_callers.setdefault(m.group(1), set()).add(v.name + '(window.open)')

missing = {k: sorted(vs) for k, vs in get_callers.items() if k not in read_only}
check(not missing, '前端用 GET 调用的端点都在 READ_ONLY 里',
      '；'.join('%s <- %s' % (k, ','.join(vs)) for k, vs in sorted(missing.items())))

# 3) 顺带确认被豁免的端点确实都在路由里（防止测的就是个不存在的名字）
ghost_eps = sorted(set(get_callers) - routes)
check(not ghost_eps, '前端调用的端点都已注册为路由',
      ('未注册：' + ', '.join(ghost_eps)) if ghost_eps else '')

print('    共 %s 项，%s 项失败' % (total, failed))
sys.exit(1 if failed else 0)
PYEOF
