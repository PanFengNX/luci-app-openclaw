#!/bin/sh
# view-messages.sh — 页面提示语的两条规则
#
# 这两个都是"功能其实是好的，但提示把它说成坏了"的问题，用户在截图里
# 直接看到的就是这个：
#
#   1. status.htm 的版本升级块。镜像回退（source=mirror）说明"官方源当前
#      不可达、我们换了国内镜像"，列表是**取到了**的，两个版本照样能判断
#      "已是最新"。但早先它被塞进 versionErrors()，于是整块变成红字 + 重试
#      按钮，看起来像检查更新坏了。
#
#   2. backup.htm 的云端列表。失败时只显示"读取云端列表失败"，把服务端
#      返回的 error 丢掉了 —— 用户无从判断是没装组件、没登录，还是远端
#      目录还没建。诊断信息必须带出来。
#
# 断言（静态，读源码）：
#   1. versionErrors() 里不得出现 mirror / 镜像 字样
#   2. 存在独立的 versionNotes() 与 #ver-note 容器
#   3. renderVersionStatus() 同时渲染错误区与提示区
#   4. backup.htm 的云端列表失败分支引用 r.error
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
total = 0
failed = 0


def check(ok, desc, detail=''):
    global total, failed
    total += 1
    print('    %s  %s%s' % ('ok  ' if ok else 'FAIL', desc, ('  ' + detail) if detail else ''))
    if not ok:
        failed += 1


def body(text, name):
    """取 JS 函数体：从 function name( 开始按大括号配对（已剥字符串）。"""
    m = re.search(r'(?m)^function\s+%s\s*\(' % re.escape(name), text)
    if not m:
        return None
    i = text.index('{', m.end())
    depth = 0
    j = i
    while j < len(text):
        c = text[j]
        if c == '{':
            depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0:
                return text[m.start():j + 1]
        j += 1
    return text[m.start():]


status = (proj / 'luasrc/view/openclaw/status.htm').read_text(encoding='utf-8')
backup = (proj / 'luasrc/view/openclaw/backup.htm').read_text(encoding='utf-8')

# ---- 1) 错误函数里不能提镜像 ----
ve = body(status, 'versionErrors')
check(ve is not None, '取到 versionErrors()')
if ve:
    code = re.sub(r'(?m)//.*$', '', ve)          # 去掉行注释再判断
    check('mirror' not in code.lower(), 'versionErrors() 不处理 mirror 回退')
    # 不能只查"镜像"二字：超时那条错误本身写着"网络 / 镜像不可达"，
    # 那是合法的失败描述。要查的是"把 source=mirror 当失败"这个逻辑。
    check("source" not in code, 'versionErrors() 不读 source 字段')

# ---- 2) 独立的提示函数与容器 ----
vn = body(status, 'versionNotes')
check(vn is not None, '存在 versionNotes()')
if vn:
    check('mirror' in vn, 'versionNotes() 处理 mirror 回退')
    check("'mirror'" in vn or '"mirror"' in vn, 'versionNotes() 判断 source === mirror')
check('id="ver-note"' in status, 'HTML 里有 #ver-note 提示容器')
check('id="ver-note-lines"' in status, '#ver-note 有内容容器')

# ---- 3) 渲染函数两区都管 ----
rv = body(status, 'renderVersionStatus')
check(rv is not None, '取到 renderVersionStatus()')
if rv:
    check('versionErrors' in rv, 'renderVersionStatus() 渲染错误区')
    check('versionNotes' in rv, 'renderVersionStatus() 渲染提示区')
    check('ver-note' in rv, 'renderVersionStatus() 操作 #ver-note')

# ---- 4) 云端列表失败要带出 error ----
m = re.search(r'(?m)^function\s+clLoadList\s*\(', backup)
check(m is not None, '取到 clLoadList()')
if m:
    seg = backup[m.start():m.start() + 1400]
    check('r.error' in seg, '云端列表失败时引用服务端 r.error')
    check("'读取云端列表失败'" in seg or '"读取云端列表失败"' in seg,
          '仍保留"读取云端列表失败"作为前缀')

# ---------------------------------------------------------------- 共享样式
# 9 个视图的共享 <style> 必须逐字节一致（本页专属样式要另开块）。
# 这条不变量让"改一处样式九页生效"成立，也防止有人往共享块里塞单页规则。
import hashlib

sigs = {}
for v in sorted((proj / 'luasrc/view/openclaw').glob('*.htm')):
    mm = re.search(r'(?s)<style>(.*?)</style>', v.read_text(encoding='utf-8'))
    if mm:
        sigs[v.name] = hashlib.sha1(mm.group(1).encode()).hexdigest()[:12]
check(len(set(sigs.values())) == 1, '十个视图的共享样式逐字节一致',
      '唯一签名 %d 个' % len(set(sigs.values())))

# 借鉴来的三个组件必须在共享块里（否则某些页面用不了）
shared = (proj / 'luasrc/view/openclaw/setup.htm').read_text(encoding='utf-8')
for cls in ('.oc-switch', '.is-copied', '.oc-skeleton'):
    check(cls in shared, '共享样式含 %s' % cls)

# 减少动画偏好要尊重（前庭功能障碍用户）
check('prefers-reduced-motion' in shared, '共享样式尊重 prefers-reduced-motion')

# 设置页的两个二值项用滑块而不是 select
setupv = (proj / 'luasrc/view/openclaw/setup.htm').read_text(encoding='utf-8')
check('oc-switch' in setupv, '设置页用滑块表达二值项')
check('$(' + "'cfg-enabled').checked" in setupv, '开机自启按 checked 提交')

# ---- qwen3.8-max 复审后修掉的具体问题（回归保护）----
# 这些不是"审美建议"，而是能在浏览器里被证伪的布局/特异度缺陷。
shared2 = (proj / 'luasrc/view/openclaw/setup.htm').read_text(encoding='utf-8')
check(r'.oc-row .oc-copy' in shared2,
      '.oc-copy 在 .oc-row 内保留强调色（否则被 .oc-row button 覆盖）')
check('pointer:coarse' in shared2, '触摸设备放大命中区域')
check('.oc-card>.oc-head:last-child' in shared2, '头部作为卡片末尾时不留分隔线')
check('.oc-head>.oc-tag' in shared2, '卡片头部标签不被压缩')
check('.oc-card>.oc-empty' in shared2, '空状态内边距不与卡片叠加')
check('@supports not (color: color-mix' in shared2,
      '不支持 color-mix 时有深色兜底色（否则深色主题正文只有 2.18:1）')

print('    共 %s 项，%s 项失败' % (total, failed))
sys.exit(1 if failed else 0)
PYEOF
