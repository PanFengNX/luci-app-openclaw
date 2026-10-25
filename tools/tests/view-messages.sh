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

# ---- 1.8.25 深度审计后的回归保护 ----
# status.htm：提示只能有一个来源（renderOpen），否则先写的那句会被覆盖。
stv = (proj / 'luasrc/view/openclaw/status.htm').read_text(encoding='utf-8')
body_js = stv.split('<script>')[1]
# renderOpen 里给 msg 赋值的那段，是"服务未启动/端口无效/端口未应答"的唯一出处
check('端口未应答' in body_js, '状态页有「端口未应答」文案')
check(body_js.count('进程在运行，但网关端口暂无应答') == 1,
      '该文案只出现一次（多写一处就会互相覆盖）')

# CSS：不能出现 Selectors Level 4 的 :not(复杂选择器) / :has() / 容器查询
# :not(.a) 这种简单选择器是 Level 3，一直合法，不算。
css_body = re.sub(r'(?s)/\*.*?\*/', '',
                  re.search(r'(?s)<style>(.*?)</style>',
                            (proj / 'luasrc/view/openclaw/setup.htm').read_text(encoding='utf-8')).group(1))
lvl4 = [m.group(0) for m in re.finditer(r':not\([^)]*\)', css_body)
        if re.search(r'[\s>+~]', m.group(0)[5:-1])]
check(not lvl4, '没有 Level 4 的 :not()', str(lvl4[:2]))
check(':has(' not in css_body, '没有 :has()')
check('@container' not in css_body, '没有容器查询')

# 滑块的可点区域不能被 pointer:coarse 的复选框规则撑开
check('.oc-row>input[type=checkbox]' in css_body,
      'pointer:coarse 用子选择器限定复选框（不影响滑块内部 input）')

# install.htm：表单数据里不能混入非字符串的私有字段
ins = (proj / 'luasrc/view/openclaw/install.htm').read_text(encoding='utf-8')
# 只查代码里的赋值/取值，不查注释（注释里会解释"为什么不再这么写"）
ins_code = '\n'.join(l.split('//', 1)[0] for l in ins.splitlines())
check('data.__install' not in ins_code and 'data.__nm' not in ins_code,
      '表单数据里没有 __install/__nm 私有字段')
check('return { save: data,' in ins, 'collectEnvPayload 返回结构体')

# 后端：未安装/未停止时不探测端口
cl2 = (proj / 'root/usr/libexec/openclaw/cli.sh').read_text(encoding='utf-8')
check('installed || { printf' in cl2, '未安装时 reachable 返回 null')
check('running   || { printf' in cl2, '未运行时 reachable 返回 null')

# xz 从"警告"升级为"硬前提"
insh = (proj / 'root/usr/libexec/openclaw/install.sh').read_text(encoding='utf-8')
check('缺少 xz，无法解压' in insh, 'install.sh 缺 xz 时直接失败并给出修复命令')
repsh = (proj / 'root/usr/libexec/openclaw/repair.sh').read_text(encoding='utf-8')
check('xz 已安装' in repsh or '缺少 xz' in repsh, 'repair.sh 检查 xz')

# ---- README 的历史版本引用不能被升版时的盲替换改掉 ----
readme = (proj / 'README.md').read_text(encoding='utf-8')
check('（1.8.16 移除' in readme,
      'README 保留「迁移功能 1.8.16 移除」这一历史事实（曾被盲替换成最新版号）')

# ---- .run 的安装路径也要 reload rpcd（与 postinst 对齐）----
bap = (proj / 'scripts/build_apk.py').read_text(encoding='utf-8')
_ri = bap.index('tar -xzf')
_rj = bap.index('"""', _ri)
check('rpcd reload' in bap[_ri:_rj], '.run 安装器会 reload rpcd')
check(bap.count('rpcd reload') == 2, 'postinst 与 .run 各一处 rpcd reload',
      '实际 %d 处' % bap.count('rpcd reload'))

# ---- 按钮点下去必须有可见反馈（用户报告"点了没反应，不知道生效没"）----
stv2 = (proj / 'luasrc/view/openclaw/status.htm').read_text(encoding='utf-8')
# 服务控制四个按钮不能再是"只发 POST 然后静默 setTimeout"
for bid in ('btn-start', 'btn-stop', 'btn-restart'):
    check(("$('%s').onclick" % bid) in stv2 and 'svcAction(' in stv2,
          '%s 走 svcAction（有忙态与结果提示）' % bid)
check("$('btn-start').onclick   = function(){ svcAction('start'); };" in stv2,
      'btn-start 确实调用 svcAction')
check('svcSay(' in stv2, '有统一的反馈出口 svcSay')
check('svcBusy(' in stv2, '操作期间禁用同组按钮')
check("svcSay('「' + label + '」失败" in stv2, '失败会说明原因而不是静默')

# ---- 启动能看到日志 ----
check('svcLogWatch' in stv2, '状态页有服务日志轮询')
check("API.log + '?lines=200&src=all'" in stv2, '状态页取日志时带 src=all')
check("if (action === 'start' || action === 'restart') svcLogWatch();" in stv2,
      '点启动/重启自动展开日志')

# ---- 日志页能切来源，且失败不再伪装成"无日志" ----
lg = (proj / 'luasrc/view/openclaw/log.htm').read_text(encoding='utf-8')
check('id="log-src"' in lg, '日志页有来源下拉')
check("'?lines=400&src='" in lg, '日志页请求带 src')
check('读取日志失败' in lg, '日志页失败时说清原因（原来显示"(无日志)"）')
check("btn.textContent = '体检中…'" in lg, 'doctor 按钮有忙态')

# ---- 后端 cmd_log 支持三来源 ----
cl3 = (proj / 'root/usr/libexec/openclaw/cli.sh').read_text(encoding='utf-8')
check('all|gateway|file|syslog' in cl3, 'cmd_log 接受 all/gateway/file/syslog')
# gateway 来源必须存在：只读 /var/log/openclaw.log 时日志页几乎永远是空的，
# 真正的启动过程与崩溃堆栈都在网关自己的日志文件里。
check('openclaw-*/openclaw-*.log' in cl3, 'cmd_log 会去找网关自己的日志文件')
check('_log_gateway' in cl3, 'cmd_log 有 gateway 来源')
check('logread' in cl3, 'cmd_log 会读 logread')
check('本机没有 logread' in cl3, '无 logread 时给出明确说明而不是空输出')

# ---- 交互反馈（用户反馈："点了没反应，不知道点没点上"）----
setup2 = (proj / 'luasrc/view/openclaw/setup.htm').read_text(encoding='utf-8')
check('button:active:not(:disabled)' in setup2, '按钮有按下反馈（:active）')
check('[data-busy="1"]' in setup2, '按钮有忙态样式（旋转指示器）')
check('prefers-reduced-motion' in setup2, '动效尊重 prefers-reduced-motion')
check('.oc-modal-mask' in setup2, '有统一的弹窗样式')
check('.oc-progress' in setup2, '有不确定态进度条')

stv3 = (proj / 'luasrc/view/openclaw/status.htm').read_text(encoding='utf-8')
check('id="up-modal"' in stv3, '状态页升级有弹窗')
check('upModalOpen(' in stv3, '升级开始即弹窗')
check("upModalState(d.state === 'done' ? 'done' : 'failed')" in stv3,
      '升级结束切换弹窗状态')
check("if (d.state === 'lost')" in stv3, '升级中断会停止轮询并恢复按钮')
check("b.setAttribute('data-busy', '1')" in stv3, '服务按钮点哪个哪个转圈')

ins3 = (proj / 'luasrc/view/openclaw/install.htm').read_text(encoding='utf-8')
check('需要下载数百 MB' in ins3, '安装前有确认对话框（说明目录/版本/耗时）')
check('id="in-progress"' in ins3, '安装弹窗有进度条')

# ---- 提示必须放在触发它的模块里，不能落在页面底部 ----
stv4 = (proj / 'luasrc/view/openclaw/status.htm').read_text(encoding='utf-8')
check('id="ver-up-hint"' in stv4, '升级模块有自己的提示位')
check('function verUpSay(' in stv4, '升级相关反馈写 ver-up-hint')
# 升级路径不应再用页面底部的 stOpSay（那个位置在"控制台地址"卡片里）
up_block = stv4[stv4.index('function startOcUpdate('):]
up_block = up_block[:up_block.index('function startOcUpdateFromHint')]
check('stOpSay(' not in up_block, '升级失败不再写到页面底部')
check('verUpSay(' in up_block, '升级失败写进升级模块')
# 冲突要能接管已有任务，而不是只丢一句红字
check('function attachRunningTask(' in stv4, '有冲突接管逻辑')
check('looksLikeConflict(' in up_block, '升级失败会区分"是不是冲突"')
check('id="btn-attach-task"' in stv4, '冲突提示旁边有「查看正在进行的任务」')

# ---- 还原步骤顺序：crontab 写在数据恢复之后 ----
bkp3 = (proj / 'root/usr/libexec/openclaw/backup.sh').read_text(encoding='utf-8')
i_data = bkp3.index('# 6a) 数据目录')
i_cron = bkp3.index('# 6b) 定时任务')
check(i_cron > i_data, 'crontab 写回排在数据目录恢复之后（不可回滚的副作用不能先做）')

# ---- 诊断包按 mtime 取最新，不按字典序 ----
cli3 = (proj / 'root/usr/libexec/openclaw/cli.sh').read_text(encoding='utf-8')
gw = cli3[cli3.index('收集网关日志'):]
gw = gw[:gw.index('收集崩溃现场')]
check('sort -rn' in gw and 'head -n 3' in gw,
      '诊断包按 mtime 倒序取最新三份日志（不是字典序前三份）')

# ---- agent 读取日志的通道（不能给 agent 改代码的权限）----
cli5 = (proj / 'root/usr/libexec/openclaw/cli.sh').read_text(encoding='utf-8')
check('cmd_diag_export()' in cli5, '有 diag-export：把快照落到数据目录供 agent 读')
check('cmd_snapshot()' in cli5, '有 snapshot：只读 JSON 快照')
check('diag-export)' in cli5, 'diag-export 已在子命令分发里注册')
# 属主必须改成网关用户，否则 agent 读不到
dx = cli5[cli5.index('cmd_diag_export() {'):]
dx = dx[:dx.index('\n}\n')]
check('chown -R' in dx and 'OC_USER' in dx, 'diag-export 最后把属主给网关用户')
check('README.txt' in dx, 'diag-export 带读取指引')

# api_ilog 不能再硬编码路径，且要能回退到 .1
ctrl5 = (proj / 'luasrc/controller/openclaw.lua').read_text(encoding='utf-8')
il = ctrl5[ctrl5.index('function api_ilog()'):]
il = il[:il.index('\nend\n')]
check('io.open("/var/log/openclaw-install.log"' not in il,
      'api_ilog 不再硬编码日志路径')
check('install-status' in il, 'api_ilog 跟随后端返回的真实路径')
check('.. ".1"' in il or '.1\")' in il or 'path .. ".1"' in il,
      'api_ilog 主日志为空时回退读上一轮的 .1')

# 弹窗状态不能硬编码 running
stv5 = (proj / 'luasrc/view/openclaw/status.htm').read_text(encoding='utf-8')
check('function upModalOpen(title, kind)' in stv5, 'upModalOpen 可传实际状态')
check("openVerLog(true, 'lost')" in stv5, '中断时按 lost 状态打开弹窗')

# 备份排除 diagnostics
bkp5 = (proj / 'root/usr/libexec/openclaw/backup.sh').read_text(encoding='utf-8')
check('${_data_rel}/diagnostics' in bkp5, '备份排除 diagnostics（可重建产物）')

# ---- 安装日志路径必须跨进程一致 ----
# install.sh 在 /var/log 不可写时会回退到 rundir，但那是它自己进程内的变量；
# cli.sh（另一个进程）若仍报 /var/log，面板就会一直显示空日志。
ins6 = (proj / 'root/usr/libexec/openclaw/install.sh').read_text(encoding='utf-8')
cli6 = (proj / 'root/usr/libexec/openclaw/cli.sh').read_text(encoding='utf-8')
check('install.logpath' in ins6, 'install.sh 把实际日志路径写成标记文件')
check('OC_INST_LOGPATH' in cli6, 'cli.sh 定义 logpath 标记路径')
st6 = cli6[cli6.index('cmd_install_status() {'):]
st6 = st6[:st6.index('\n}\n')]
check('OC_INST_LOGPATH' in st6, 'install-status 读标记文件而不是硬编码路径')

print('    共 %s 项，%s 项失败' % (total, failed))
sys.exit(1 if failed else 0)
PYEOF
