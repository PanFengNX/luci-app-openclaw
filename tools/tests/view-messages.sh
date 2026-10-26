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
# 云端列表已并入「本地 + 云端」合并视图：拉取在 bkLoadCloud，呈现空态与
# 错误在 bkRenderList。原断言指向的 clLoadList 已被删除（合并后不再需要
# 第二份列表），所以这里跟着挪，检查的还是同一件事：失败必须说出原因。
m = re.search(r'(?m)^function\s+bkLoadCloud\s*\(', backup)
check(m is not None, '取到 bkLoadCloud()')
if m:
    seg = backup[m.start():m.start() + 1400]
    check('r.error' in seg, '云端列表失败时引用服务端 r.error')
    check("'读取云端列表失败'" in seg or '"读取云端列表失败"' in seg,
          '仍保留"读取云端列表失败"作为前缀')
check('BK.cloudErr' in backup, '云端错误存进 BK.cloudErr')
_rl = backup[backup.index('function bkRenderList('):]
_rl = _rl[:_rl.index(chr(10) + '}' + chr(10))]
check('BK.cloudErr' in _rl, 'bkRenderList 会把云端错误显示出来')

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

# ---- 升级流程必须对齐 OpenClaw 官方文档 ----
ins7 = (proj / 'root/usr/libexec/openclaw/install.sh').read_text(encoding='utf-8')
lib7 = (proj / 'root/usr/libexec/openclaw/lib.sh').read_text(encoding='utf-8')
cli7 = (proj / 'root/usr/libexec/openclaw/cli.sh').read_text(encoding='utf-8')

# npm 12 默认阻止未批准的 lifecycle scripts，而 OpenClaw 的 preinstall/postinstall
# 正是这类脚本；不显式批准会"装完但跑不起来"。
check('--allow-scripts=openclaw' in ins7, 'npm 12+ 会传 --allow-scripts=openclaw')
check('npm_major' in ins7, '按 npm 版本决定是否传该选项（老版本不支持）')
check('SHARP_IGNORE_GLOBAL_LIBVIPS=1' in ins7, 'sharp 原生构建走官方默认规避')
# 官方升级流程：doctor --fix + gateway status --deep
check('run_doctor_after_upgrade()' in ins7, '升级后跑 openclaw doctor --fix（官方要求）')
check("doctor --fix" in ins7, 'doctor 用 --fix（能修配置而不只是检查）')
check('gateway status --deep' in ins7, '启动后做深度验证')

# 锁判定：陈旧锁不能永久挡住升级
check('oc_lock_busy()' in lib7, '有 oc_lock_busy（问活进程而不是目录存在）')
bg = cli7[cli7.index('cmd_install_bg() {'):]
bg = bg[:bg.index('\n}\n')]
check('oc_lock_busy' in bg, 'install-bg 用 oc_lock_busy')
check('if oc_locked;' not in bg, 'install-bg 不再用裸 oc_locked 挡升级')
check('_inst_log_note' in bg, '拒绝路径会写日志（能查到被拒原因）')
check('install.logpath' in ins7 and 'OC_INST_LOGPATH' in cli7, '日志路径跨进程一致')

# ---- 日志区必须都能"带走"（复制 / 导出）----
for _f, _ids in (('log.htm', ['btn-out-copy', 'btn-out-export']),
                 ('channels.htm', ['btn-out-copy', 'btn-out-export']),
                 ('terminal.htm', ['btn-out-copy', 'btn-out-export']),
                 ('backup.htm', ['btn-clout-copy', 'btn-clout-export']),
                 ('status.htm', ['btn-diag-copy', 'btn-diag-export', 'btn-up-export']),
                 ('install.htm', ['btn-log-copy', 'btn-log-export'])):
    _t = (proj / 'luasrc/view/openclaw' / _f).read_text(encoding='utf-8')
    for _b in _ids:
        check(('id="%s"' % _b) in _t, '%s 有 %s' % (_f, _b))
# 共享 helper：复制在 http 页面上必须有 execCommand 退路
setup3 = (proj / 'luasrc/view/openclaw/setup.htm').read_text(encoding='utf-8')
check('function ocCopyText(' in setup3, '有统一的复制函数')
check('function ocDownloadText(' in setup3, '有统一的导出函数')
check('execCommand' in setup3, '复制有 execCommand 退路（http 页面上 clipboard API 不可用）')
check('function ocBindLogTools(' in setup3, '有统一的绑定 helper')

# ---- 升级：npm 参数与官方文档一致 ----
ins8 = (proj / 'root/usr/libexec/openclaw/install.sh').read_text(encoding='utf-8')
check('--prefer-online' in ins8, 'npm 用 --prefer-online（--prefer-offline 会用旧缓存导致 notarget）')
check('--prefer-offline' not in ins8, '不再用 --prefer-offline')
_ins8_code = '\n'.join(l.split('#', 1)[0] for l in ins8.splitlines())
check('npm_config_tmp' not in _ins8_code, '不再设 npm 已废弃的 npm_config_tmp')
check('oc_source_url_saved' in ins8, '安装复用取版本列表时成功的源')
check('已是 $_cur_ver，跳过 npm install' in ins8 or '跳过 npm install' in ins8,
      '已是要装的版本就跳过 npm install')

# ---- chown：文件系统不支持属主时不该报成故障 ----
lib8 = (proj / 'root/usr/libexec/openclaw/lib.sh').read_text(encoding='utf-8')
init8 = (proj / 'root/etc/init.d/openclaw').read_text(encoding='utf-8')
check('oc_fs_supports_fowner()' in lib8, '有文件系统属主能力判断')
check('/proc/mounts' in lib8[lib8.index('oc_fs_supports_fowner()'):][:2000],
      '判断以 /proc/mounts 为准（stat -f 在部分环境返回 UNKNOWN）')
check('oc_fs_supports_fowner' in init8, 'init.d 用它决定是否 chown')
check('不支持设置属主' in init8, '不支持时给说明性提示而不是故障告警')

# ---- OpenClaw CLI 必须以网关用户运行 ----
# 它以 uid 校验临时目录 <cache>/openclaw-<uid> 的属主；root 跑会创建
# openclaw-0，再被 chown 成 998，随后一切需要状态的操作都被拒绝。
lib9 = (proj / 'root/usr/libexec/openclaw/lib.sh').read_text(encoding='utf-8')
ins9 = (proj / 'root/usr/libexec/openclaw/install.sh').read_text(encoding='utf-8')
check('oc_as_user()' in lib9, '有 oc_as_user（以网关用户执行）')
check('su -s /bin/sh' in lib9, 'oc_as_user 用 su 切用户')
doc9 = ins9[ins9.index('run_doctor_after_upgrade() {'):]
doc9 = doc9[:doc9.index('\n}\n')]
check('oc_as_user' in doc9, 'doctor 以网关用户运行（否则状态库归属冲突）')
check('config validate' in doc9, 'doctor 后验配置并把具体键写进日志')
deep9 = ins9[ins9.index('gateway status --deep'):]
check('oc_as_user' in deep9[:400], 'gateway status 以网关用户运行')
_pi = ins9.index('plugins install @openclaw/deepseek-provider')
check('oc_as_user' in ins9[max(0, _pi - 300):_pi], '插件安装以网关用户运行')
check('openclaw-*' in ins9, '升级前清理遗留的 openclaw-<uid> 临时目录')

# ---- chown 失败要能查到原因（不能只有"失败了"）----
init10 = (proj / 'root/etc/init.d/openclaw').read_text(encoding='utf-8')
_wc = init10[init10.index('_warn_chown() {'):]
_wc = _wc[:_wc.index('\n}\n')]
check('"${2:-}"' in _wc or '${2:-}' in _wc, '_warn_chown 接受调用方传入的真实报错')
_fo = init10[init10.index('_fix_owner() {'):]
_fo = _fo[:_fo.index('\n}\n')]
check('2>"$errf"' in _fo, '_fix_owner 把 chown 的 stderr 接进文件')
check('head -n 1' in _fo, '只取第一条报错（不刷屏）')
_fo_code = '\n'.join(l.split('#', 1)[0] for l in _fo.splitlines())
check('OC_RUNDIR' not in _fo_code, '_fix_owner 代码不依赖 OC_RUNDIR（init.d 里未定义，会写到根目录）')
check('不支持设置属主' in _wc, 'exfat/ntfs 上仍降为说明性提示')

# ---- 备份范围文案必须与实际归档一致 ----
bkh = (proj / 'luasrc/view/openclaw/backup.htm').read_text(encoding='utf-8')
check('另外还会记录：插件清单、定时任务' in bkh, '备份确认框说明包含插件清单与定时任务')
check('插件本体装在程序目录，不在备份内' in bkh, '备份确认框说明插件不在备份内（需重装）')
bks = (proj / 'root/usr/libexec/openclaw/backup.sh').read_text(encoding='utf-8')
check('$stage/plugins.txt' in bks, '归档确实写入 plugins.txt')
check('$stage/crontab.txt' in bks, '归档确实写入 crontab.txt')

# ---- 手动云备份：后台任务 + 进度（本地/云端两行状态）----
cs = (proj / 'root/usr/libexec/openclaw/cloud.sh').read_text(encoding='utf-8')
check('cmd_backup_bg()' in cs, '手动备份有后台入口 backup-bg')
check('cmd_backup_poll()' in cs, '有进度查询 backup-poll')
check('backup_bg_worker()' in cs, '有后台 worker')
check('backup-bg)' in cs and 'backup-poll)' in cs, '两个子命令已注册分发')
# 定时任务那条路径必须保持静默（不改动）
check('cmd_backup_run()' in cs, '定时任务入口仍在（静默路径不变）')
# 阶段前缀：前端据此分开显示"本地备份""云端上传"
check('[local]' in cs and '[cloud]' in cs, '日志带 [local]/[cloud] 阶段前缀')
# 状态文件必须与组件安装分开，否则互相覆盖 pid/rc
check('CLOUD_BK_LOG' in cs and 'CLOUD_INSTALL_LOG' in cs,
      '备份与组件安装各自独立一套状态文件')
check('CLOUD_BK_LOG="$OC_RUNDIR/cloud-bk.log"' in cs, '备份日志路径独立')

bh = (proj / 'luasrc/view/openclaw/backup.htm').read_text(encoding='utf-8')
check('function clPollBackup(' in bh, '前端轮询备份进度')
check('clPhaseFromLog(' in bh, '前端解析阶段前缀成两行状态')
check('id="cl-phase-local"' in bh, '有"本地备份"状态位')
check('id="cl-phase-cloud"' in bh, '有"云端上传"状态位')
check('function clOutSet(' in bh, '有替换式输出（轮询是完整日志，追加会重复）')
check('clOutSet(log' in bh, '轮询用替换而不是追加')
check('cloud_backup_bg' in bh and 'cloud_backup_poll' in bh, '前端已接两个新端点')

ctrl = (proj / 'luasrc/controller/openclaw.lua').read_text(encoding='utf-8')
check('api_cloud_backup_bg' in ctrl and 'api_cloud_backup_poll' in ctrl,
      '后端两个端点都已注册')

# ---- 临时根身份错位（Hermes 实机验证的方案）----
lib11 = (proj / 'root/usr/libexec/openclaw/lib.sh').read_text(encoding='utf-8')
init11 = (proj / 'root/etc/init.d/openclaw').read_text(encoding='utf-8')
wr11 = (proj / 'root/usr/bin/openclaw').read_text(encoding='utf-8')
ins11 = (proj / 'root/usr/libexec/openclaw/install.sh').read_text(encoding='utf-8')
rep11 = (proj / 'root/usr/libexec/openclaw/repair.sh').read_text(encoding='utf-8')

# 机制核心：/tmp/openclaw 必须钉成 root:root 0700
check('oc_pin_system_tmp_root()' in lib11, 'lib.sh 有 oc_pin_system_tmp_root')
check('chown root:root /tmp/openclaw' in lib11, '把它 chown 成 root')
check('chmod 700 /tmp/openclaw' in lib11, '权限位一起钉（判据含 mode & 0o022）')
check('_pin_system_tmp_root' in init11, 'init.d 启动路径里也钉（/tmp 是 tmpfs，重启即失）')
pin_i = init11.index('_pin_system_tmp_root()')
check(pin_i < init11.index('procd_open_instance'), '钉属主的定义在 procd 起网关之前')

# 清理：glob 必须收窄，否则误删 openclaw-update-report-*
# glob 不够：openclaw-[0-9]* 也会命中 openclaw-<date>.log（以数字开头）。
# 必须用「basename 是 openclaw-<纯数字>」的独立判据。
check('oc_is_tmp_root()' in lib11, 'lib 有 oc_is_tmp_root 严格判据')
check('_is_tmp_root()' in init11, 'init 有 _is_tmp_root 严格判据')
check('oc_is_tmp_root "$d"' in lib11, 'lib 清理用严格判据')
check('_is_tmp_root "$d"' in init11, 'init 清理用严格判据')
check('oc_is_tmp_root "$_d"' in ins11, 'install 清理用严格判据')
# 用 glob 收集 + oc_is_tmp_root 严格判定，两者必须成对出现。
# 只检查"没有裸 glob"已经过时：真正的保护是判据，不是 glob 收窄。
_ins_lines = ins11.splitlines()
_glob_i = [i for i, l in enumerate(_ins_lines)
           if 'openclaw-*' in l and not l.lstrip().startswith('#')]
_paired = all(any('oc_is_tmp_root' in _ins_lines[j]
                   for j in range(i + 1, min(i + 6, len(_ins_lines))))
              for i in _glob_i)
check(_paired, 'install 的每个 openclaw-* glob 都紧跟严格判据', 'globs=%d' % len(_glob_i))

# I2/I3：状态操作以服务用户跑；root 不设 TMPDIR
check('unset TMPDIR' in wr11, 'wrapper 在 root 上下文 unset TMPDIR（故障起点）')
check('cd ' in wr11 and 'exec' in wr11, 'wrapper 的 su 命令串内有 cd（EACCES 成因）')
check('oc_as_user' in ins11, 'install 的 doctor 走 oc_as_user')
check('oc_probe_user_access()' in lib11, 'lib 有以服务用户身份的写探针')
check('oc_probe_user_access' in ins11, '安装期即以服务用户身份自检')

# I4：启动路径不再递归 chown
_st = init11[init11.index('start_service() {'):]
_st = _st[:_st.index(chr(10) + '}' + chr(10))]
_st_code = chr(10).join(l.split('#', 1)[0] for l in _st.splitlines())
check('chown -R' not in _st_code, 'start_service 代码里没有 chown -R（I4：无事后修正）')
check('_probe_user_write' in _st, 'start_service 改用用户视角探针')
check('_var_problem' in _st, '断言失败 fail closed 并给修复命令')

# 修复命令必须真的存在
check('owner-fix' in rep11, 'repair.sh 提供 owner-fix（断言提示的那条命令）')
check('_fix_owner_tree' in rep11, 'owner-fix 会修属主树')

# DIAG 域
check('$base/dumps' in init11, 'core 落 DIAG 域 dumps/')

# ---- 备份 busy 误报（截图：已有备份任务在运行，但其实没有）----
cs12 = (proj / 'root/usr/libexec/openclaw/cloud.sh').read_text(encoding='utf-8')
bh12 = (proj / 'luasrc/view/openclaw/backup.htm').read_text(encoding='utf-8')

# 宽松判据会把 backup-poll（本身也是 cloud.sh）当成在跑的任务 → 永久 busy
check('bk_pid_alive()' in cs12, '有 bk_pid_alive 精确判据')
_bk = cs12[cs12.index('bk_pid_alive() {'):]
_bk = _bk[:_bk.index(chr(10) + '}' + chr(10))]
check('backup-bg' in _bk, '判据要求 cmdline 含 backup-bg（不只 cloud.sh）')
check('oc_pid_alive "$pid"' in _bk, '仍先过通用存活检查（挡僵尸/已退出）')
# 两处 busy 判定都必须用它
check('bk_pid_alive "$_p"' in cs12, 'backup-bg 的 busy 判定用精确判据')
check('bk_pid_alive "$pid"' in cs12, 'backup-poll 的 running 判定用精确判据')

# 前端：busy 要接入进度，而不是报错；启动失败不能把阶段标成"失败"
check('d.busy' in bh12, '前端识别 busy 并接入进度')
check('正在接入它的进度' in bh12, 'busy 时提示接入而不是报错')
check('function clPhaseFail(' not in bh12, '不再有 clPhaseFail（会误标阶段失败）')
check('function clResumeBackup(' in bh12, '页面加载时接续正在跑的任务')
check('clResumeBackup();' in bh12, '加载时调用接续')

# ---- 命令行白名单 + 需要 TTY 的命令 ----
# 用户反馈 `gateway auth-token --show` 用不了。查证后是两层原因，都不在白名单本身：
#   1) 照官方文档敲全名时 argv[1] 是 "openclaw"，被当成未知子命令拒掉；
#   2) 该命令拒绝非交互式输出（官方行为），而捕获必然是管道。
ctrl15 = (proj / 'luasrc/controller/openclaw.lua').read_text(encoding='utf-8')
cli15  = (proj / 'root/usr/libexec/openclaw/cli.sh').read_text(encoding='utf-8')
lib15  = (proj / 'root/usr/libexec/openclaw/lib.sh').read_text(encoding='utf-8')
term15 = (proj / 'luasrc/view/openclaw/terminal.htm').read_text(encoding='utf-8')

# 前缀剥离必须两层都有：Lua 层不做，请求根本到不了 cli.sh
check('argv[1] == "openclaw"' in ctrl15, '控制器剥掉 openclaw 前缀')
check('openclaw|/usr/bin/openclaw) shift' in cli15, 'cli.sh 也剥掉 openclaw 前缀')

# pty：只有 script(1) 能造 TTY；缺失时必须明说，不能静默空白
check('oc_pty_run()' in lib15, 'lib 有 oc_pty_run（伪终端执行）')
_pty = lib15[lib15.index('oc_pty_run() {'):]
_pty = _pty[:_pty.index(chr(10) + '}' + chr(10))]
check('command -v script' in _pty, '没有 script 时返回 127（不假装成功）')
check('return 127' in _pty, '缺 script 的返回值可判定')
check("sed \"s/'/'\\\\\\\\''/g" in _pty or "s/'/" in _pty, '参数逐个单引号转义后才拼串')
check('oc_timeout "$t" script' in _pty, 'pty 执行同样受超时约束')

check('run_needs_tty()' in cli15, 'cli.sh 有 run_needs_tty')
check('"gateway auth-token"*) return 0' in cli15, 'gateway auth-token 走 pty')
check('oc_pty_run 120' in cli15, 'cmd_run 对这类命令改用 oc_pty_run')
check('请在 SSH 里直接执行' in cli15, '缺 script 时给出可操作提示')

# 白名单：新增的必须是"不能变成 shell 命令"的；危险的一个都不能进
for _c in ('security', 'secrets', 'tasks', 'nodes', 'pairing', 'qr', 'hooks',
           'webhooks', 'dns', 'docs', 'directory', 'wiki', 'sandbox',
           'approvals', 'agent', 'acp', 'capability', 'infer', 'completion',
           'backup', 'system', 'dashboard'):
    check(('	%s = true' % _c) in ctrl15 or (' %s = true' % _c) in ctrl15,
          '白名单含 %s' % _c)
for _c in ('reset', 'uninstall', 'migrate', 'tui', 'browser', 'exec-policy'):
    check(('\n\t%s = true' % _c) not in ctrl15, '白名单**不含** %s（故意排除）' % _c)

# 页面说明必须与白名单一致：写了却不放行 = 骗人
check('gateway auth-token --show' in term15, '页面示例含 auth-token --show')
check('security' in term15 and 'pairing' in term15, '页面列出新增的子命令')
check('script(1)' in term15, '页面说明 pty 机制')

# ---- 删除密码：只存哈希、口令不进 argv、服务端强制 ----
NL = chr(10)
libd  = (proj / "root/usr/libexec/openclaw/lib.sh").read_text(encoding="utf-8")
clid  = (proj / "root/usr/libexec/openclaw/cli.sh").read_text(encoding="utf-8")
ctrld = (proj / "luasrc/controller/openclaw.lua").read_text(encoding="utf-8")
bhd   = (proj / "luasrc/view/openclaw/backup.htm").read_text(encoding="utf-8")

for _f in ("oc_delpass_dir", "oc_delpass_file", "oc_delpass_present",
           "oc_delpass_hash_alg", "oc_delpass_set", "oc_delpass_verify",
           "oc_delpass_clear"):
    check(_f + "()" in libd, "lib 有 " + _f)

# 删除密码只判「是否同意删除」，永远不需要还原 → 只能存哈希。
# 与加密口令（必须能还原，只能明文存）是两套，混用会导致「改了删除密码老备份解不开」。
_dp = libd[libd.index("oc_delpass_set() {"):]
_dp = _dp[:_dp.index(NL + "}" + NL)]
check("oc_delpass_hash_alg" in _dp, "set 走哈希而不是存明文")
check("umask 077" in _dp, "写文件时 umask 077（默认私有）")
check("chmod 600" in _dp, "文件权限 600")
check("mv -f" in _dp, "先写临时文件再 mv（中断不留半截密码）")
_hv = libd[libd.index("oc_delpass_verify() {"):]
_hv = _hv[:_hv.index(NL + "}" + NL)]
check("${#got}" in _hv, "verify 先比长度再比内容")

# 口令绝不能进 argv：/proc/<pid>/cmdline 全局可读。
_ha = libd[libd.index("oc_delpass_hash_alg() {"):]
_ha = _ha[:_ha.index(NL + "}" + NL)]
check("printf" in _ha and "| sha256sum" in _ha, "口令经 stdin 进哈希（不进 argv）")
check(not any(("sha256sum " + chr(34)) in l for l in _ha.splitlines()),
      "没有把口令当参数传给 sha256sum")

# 存储算法要记下来：某天系统补上 sha256sum，之前用 md5 存的密码还得能验。
check("alg:hex:salt" in libd or "alg" in _dp, "记录算法与盐")

# CLI
check("delpass_validate()" in clid, "cli 有 delpass_validate")
for _c in ("cmd_delpass_status", "cmd_delpass_set", "cmd_delpass_verify", "cmd_delpass_clear"):
    check(_c + "()" in clid, "cli 有 " + _c)
check("delpass-status)" in clid and "delpass-set)" in clid, "子命令已注册分发")
_vs = clid[clid.index("cmd_delpass_verify() {"):]
_vs = _vs[:_vs.index(NL + "}" + NL)]
check("sleep 1" in _vs, "验证失败固定延迟（压住脚本化爆破）")
_cs = clid[clid.index("cmd_delpass_clear() {"):]
_cs = _cs[:_cs.index(NL + "}" + NL)]
check("oc_delpass_verify" in _cs, "清除也要验旧密码（否则谁都能把保护关掉）")

# 控制器：这是真正的强制点
check("local delpass_gate" in ctrld, "有 delpass_gate 前向声明")
_decl = ctrld.index("local delpass_gate")
_del  = ctrld.index("function api_backup_delete()")
check(_decl < _del, "前向声明在 api_backup_delete 之前（Lua 5.1 词法作用域）")
check("cli_exec_stdin" in ctrld, "有给 cli.sh 用的 stdin 通道")
_ce = ctrld[ctrld.index("local function cli_exec_stdin("):]
_ce = _ce[:_ce.index(NL + "end" + NL)]
check("write_private" in _ce, "口令经私有临时文件进 stdin")
check("< " in _ce, "重定向进 stdin（不进 argv）")
check(ctrld.count("delpass_gate(http.formvalue") >= 2,
      "本地删除与云端删除都过同一道闸门")
for _a in ("api_delpass_status", "api_delpass_set", "api_delpass_clear"):
    check("function " + _a in ctrld, "有 " + _a)
_aps = ctrld[ctrld.index("function api_delpass_set()"):]
_aps = _aps[:_aps.index(NL + "end" + NL)]
check("delpass_gate(old)" in _aps, "改密码必须先验旧密码")

# 前端：删除走弹窗，且服务端拒绝时提示「还没设密码」而不是「密码错」
check("function ocAskPass(" in bhd, "有密码弹窗 ocAskPass")
check("function bkAskDelete(" in bhd, "删除前走 bkAskDelete")
check("need_pass" in bhd, "识别 need_pass（未设密码 vs 密码错）")
check("function dpStatus(" in bhd, "有删除密码状态查询")
check("function dpSetDialog(" in bhd, "设置密码走弹窗")
check("function dpClearDialog(" in bhd, "清除密码走弹窗")

# ---- 本地 + 云端合并成一个列表 ----
check("id=" + chr(34) + "bk-list" + chr(34) in bhd, "只有一个列表容器 bk-list")
check("id=" + chr(34) + "cl-list" + chr(34) not in bhd, "旧的云端列表容器已移除")
check("function bkRenderList(" in bhd, "有合并渲染 bkRenderList")
check("function bkLoadLocal(" in bhd and "function bkLoadCloud(" in bhd,
      "本地与云端各自拉取")
check("src: " + chr(39) + "cloud" + chr(39) in bhd, "行带来源标记")
check("bkUpload(e.ref)" in bhd, "本地行可直接上传（先本地备份再上传）")

# ---- 秒表：按区块区分，否则云备份时本地卡片也跳秒 ----
check("function bkTickStart(which)" in bhd, "秒表按区块启动")
check("bkTickStart(" + chr(39) + "cl" + chr(39) + ")" in bhd, "云备份开自己的秒表")
check("bkTickStart(" + chr(39) + "bk" + chr(39) + ")" in bhd, "本地备份开自己的秒表")
check("id=" + chr(34) + "bk-elapsed" + chr(34) in bhd, "本地秒表元素")
check("id=" + chr(34) + "cl-elapsed" + chr(34) in bhd, "云端秒表元素")
check("querySelectorAll(" + chr(39) + ".oc-elapsed" + chr(39) + ")" not in bhd,
      "不再一刀切更新所有秒表")

# ---- 加密口令改成弹窗 ----
check("ocAskPass({" in bhd[bhd.index("function clPassSave("):][:800],
      "设置加密口令走弹窗")
check("cl-pass-new" not in bhd, "页面上不再有常驻口令输入框")
check("cl-pass-new2" not in bhd, "页面上不再有常驻确认口令框")
check("needConfirm: true" in bhd, "弹窗内做两次输入一致性校验")

# ---- 备份页加载性能：一次请求拿全部状态 ----
# 原先页面加载并发打 4 个端点，每个独立启动一次 cloud.sh（lib 2060 行 +
# 本体 3900 行）。路由器上光解析就要可观的时间，四个请求还要抢 uhttpd 的
# worker —— 用户看到「一直读取中」。
cs13  = (proj / "root/usr/libexec/openclaw/cloud.sh").read_text(encoding="utf-8")
bh13  = (proj / "luasrc/view/openclaw/backup.htm").read_text(encoding="utf-8")
ctl13 = (proj / "luasrc/controller/openclaw.lua").read_text(encoding="utf-8")

check("cmd_overview()" in cs13, "cloud.sh 有合并命令 overview")
check("overview)" in cs13, "overview 已注册分发")
check("function api_cloud_overview" in ctl13, "控制器有 cloud_overview 端点")
check("cloud_overview = true" in ctl13, "overview 在只读白名单里")
check("cloud_overview:" in bh13, "前端 API 表有 cloud_overview")
check("function loadOverview(" in bh13, "前端有一次加载全部状态的入口")
check("loadOverview(false);" in bh13, "页面加载调它一次")

# 启动块不能再有那四个独立请求
_boot = bh13[bh13.index("// 初始渲染 + 只读查询"):]
_boot = _boot[:_boot.index("</script>")]
for _f in ("clStatus();", "clEncryptStatus();", "clSchStatus();", "dpStatus();"):
    check(_f not in _boot, "启动块不再单独调用 " + _f)

# 拆成「应用」+「拉取」两层才能被 overview 分发
for _f in ("clApplyStatus", "clApplyEncrypt", "clApplySchedule", "dpApply"):
    check("function " + _f + "(" in bh13, "有 " + _f + "（只应用不拉取）")
check("clApplyStatus(r)" in bh13, "loadOverview 分发组件状态")
check("clApplyEncrypt(" in bh13, "loadOverview 分发加密状态")
check("clApplySchedule(" in bh13, "loadOverview 分发定时状态")
check("dpApply(" in bh13, "loadOverview 分发删除密码状态")

# dpStatus 此前定义了但从未被调用 —— 删除密码状态永远停在「读取中」
check("dpApply(" in bh13[bh13.index("function loadOverview("):][:2000],
      "删除密码状态确实被加载（此前 dpStatus 从未被调用，是 1.8.43 的疏漏）")

# 刷新按钮要绕缓存（用户点刷新就是不信缓存）
check("loadOverview(true)" in bh13, "刷新按钮带 fresh=1")
check("cloud_status(fresh)" not in bh13, "旧的 cloud_status 端点不再被页面调用")

# ---- 状态缓存：whoami 是联网调用，不能每次刷新都跑 ----
check("clock_status_cache_read()" in cs13, "有状态缓存读")
check("clock_status_cache_write()" in cs13, "有状态缓存写")
check("clock_status_cache_drop()" in cs13, "有缓存失效")
check("OC_CLOUD_STATUS_TTL" in cs13, "TTL 可配")
_rd = cs13[cs13.index("clock_status_cache_read() {"):]
_rd = _rd[:_rd.index(NL + "}" + NL)]
check("oc_mtime" in _rd, "新鲜度用 oc_mtime 判断")
# 注释里写了「不要用 date -r」，所以只看代码行
_rd_code = NL.join(l.split("#", 1)[0] for l in _rd.splitlines())
check("date -r" not in _rd_code, "代码里不用 date -r（busybox 没有 -r，会静默恒过期）")
_wr = cs13[cs13.index("clock_status_cache_write() {"):]
_wr = _wr[:_wr.index(NL + "}" + NL)]
check("mv -f" in _wr, "缓存原子写（不留半截 JSON）")
check(cs13.count("clock_status_cache_drop") >= 5,
      "装/更新/登录/登出都会让缓存失效", "处数=%d" % cs13.count("clock_status_cache_drop"))

# cmd_status 默认走缓存，但要能强制刷新
check("--fresh" in cs13, "status 支持 --fresh 绕过缓存")

# 关键：status 失败时 overview 必须整包失败。否则会拼出
# {"ok":true,{"ok":false,... —— 非法 JSON，而「组件未安装」正是最常见场景。
_ov = cs13[cs13.index("cmd_overview() {"):]
_ov = _ov[:_ov.index(NL + "}" + NL)]
check(chr(39) + chr(34) + "ok" + chr(34) + ":false" + chr(39) in _ov,
      "overview 识别 status 的失败结果")
_fail_i = _ov.index(chr(39) + chr(34) + "ok" + chr(34) + ":false" + chr(39))
_strip_i = _ov.index("sed -e")
check(_fail_i < _strip_i, "失败判定在拼接之前（顺序错了就是非法 JSON）")

print('    共 %s 项，%s 项失败' % (total, failed))
sys.exit(1 if failed else 0)
PYEOF
