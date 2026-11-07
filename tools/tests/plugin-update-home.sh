#!/bin/sh
# plugin-update-home.sh — 插件自身更新必须在首页（状态页）可用
#
# 背景：插件更新原来只在「安装」页的一张卡片里，用户要升级插件得先想到去
# 那里翻。首页的「版本升级」块本来就有 OpenClaw / Node 两行，插件理应同构。
#
# 断言（静态，读源码）：
#   1. status.htm 有独立的「插件」行：版本药丸 + 提示 + 按钮
#   2. status.htm 的三个更新端点指向 github_update_{status,check,install}
#   3. 进页面会静默检查一次（pluginStatus(true)），不是空的占位行
#   4. 安装必须 POST + confirm=1 + 回传候选 id（否则等于静默升级）
#   5. 候选版本只经 renderVerHint 渲染，不拼 innerHTML
#   6. 更新器 status 输出带 current（首页当前版本不再依赖"先检查一次"）
#
# 退出码：0 = 全部通过；1 = 有失败

set -u

# 用法：plugin-update-home.sh [项目根]（默认取脚本所在仓库；传旧版本目录
# 可反向验证本测试确实会 FAIL，而不是空跑）
HERE="$(cd "$(dirname "$0")" && pwd)"
PROJ="${1:-$(cd "$HERE/../.." && pwd)}"

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
view = (proj / "luasrc/view/openclaw/status.htm").read_text(encoding="utf-8")
upd = (proj / "root/usr/libexec/openclaw/github-update.sh").read_text(encoding="utf-8")

fails = []


def check(name, cond, detail=""):
    if cond:
        print("    ok    %s" % name)
    else:
        print("    FAIL  %s%s" % (name, ("：" + detail) if detail else ""))
        fails.append(name)


# 1. 「插件」行的三件套
for el in ('id="up-plugin-cur"', 'id="plugin-ver-hint"', 'id="btn-plugin-update"'):
    check("首页有 %s" % el, el in view)

# 行必须落在「版本升级」块里（#ver-up 之后、版本列表提示之前），
# 而不是随便挂在页面某处。
start = view.find('id="ver-up"')
plugin_row = view.find('id="up-plugin-cur"')
check("「插件」行在 #ver-up 块内",
      start >= 0 and plugin_row > start)

# 2. 端点指向更新器的真实路由。键名必须与路由短名一致 ——
#    api-readonly-route.sh 按 API.<键名> 去 READ_ONLY / 路由表里查，
#    自造简称（gh_status）会让 GET 守卫那层静默失效。
for route in ("github_update_status", "github_update_check", "github_update_install"):
    pat = re.compile(r"%s:\s*'<%%=\s*luci\.dispatcher\.build_url\([^)]*api[^)]*%s" % (route, route))
    check("API.%s -> %s" % (route, route), bool(pat.search(view)))

# 3. 首屏静默检查 + 有手动复查入口
check("进页面调用 pluginStatus(true)", "pluginStatus(true)" in view)
check("有「检查插件更新」手动入口", 'id="btn-plugin-check"' in view)
# 静默检查要节流：每次刷新都打一次 GitHub 会占住 uhttpd worker。
check("检查结果有 sessionStorage 缓存", "sessionStorage" in view and "PLUGIN_CACHE_MS" in view)
check("缓存按本机版本作废", "c.current === pluginPillCur()" in view)

# 4. 安装是 POST 且带确认与候选指纹
inst = re.search(r"post\(API\.github_update_install,\s*\{\s*confirm:'1',\s*id:\s*p\.id\s*\}", view)
check("install 带 confirm=1 与候选 id", bool(inst))
check("install 走 post()", 'post(API.github_update_install' in view)
check("没有 get(API.github_update_install)", 'get(API.github_update_install' not in view)
check("没有 get(API.github_update_check)", 'get(API.github_update_check' not in view)

# 5. 候选版本渲染不得拼 innerHTML
render_fn = view[view.find("function pluginRender()"):view.find("function pluginLastLogLine")]
check("pluginRender 用 renderVerHint 渲染候选",
      "renderVerHint(hint, ['可升级到 '" in render_fn)
check("pluginRender 不写 innerHTML", "innerHTML" not in render_fn)

# 6. 更新器 status 输出带 current
st = upd[upd.find("cmd_status()"):upd.find("# ---------------------------------------------------------------- rollback")]
check("status 输出 current 字段", r'\"current\":\"$(jstr "$cur")\"' in st)
check("status 调 current_version", "current_version" in st)
check("status 仍输出 rollbacks", r'\"rollbacks\":$nrb' in st)

# 7. 安装页卡片已移除，回滚入口挪到首页
#    1.8.85：首页有了检查/安装之后，「安装」页那张「插件自身更新」卡片
#    与首页完全重复；唯一不重复的是「回滚上一版本」，挪到首页操作区。
inst_view = (proj / "luasrc/view/openclaw/install.htm").read_text(encoding="utf-8")
check("安装页不再有「插件自身更新」卡片", "插件自身更新" not in inst_view)
check("安装页没有残留 gh 卡片元素", "btn-gh-" not in inst_view and "gh-log" not in inst_view)
check("安装页没有残留 github_update 引用", "github_update" not in inst_view)
check("首页有回滚按钮", 'id="btn-plugin-rollback"' in view)
check("回滚按钮默认隐藏", re.search(r'id="btn-plugin-rollback"[^>]*display:none', view) is not None)
check("回滚走 POST + confirm=1",
      bool(re.search(r"post\(API\.github_update_rollback,\s*\{\s*confirm:'1'\s*\}", view)))
rbfn = view[view.find("function pluginRollback()"):] if "function pluginRollback()" in view else ""
check("回滚前有确认弹窗", "confirm(" in rbfn)
check("回滚期间 busy 防重入", "p.busy = true; p.phase = 'rollback'" in rbfn)
check("pluginRender 按 rollbacks 显示回滚按钮",
      "Number(p.rollbacks) > 0" in view and "btn-plugin-rollback" in view)

if fails:
    print("\n    %d 项失败" % len(fails))
    sys.exit(1)
print("\n    全部通过")
PYEOF
