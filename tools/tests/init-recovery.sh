#!/bin/sh
# init-recovery.sh — 网关"停了不回来"的两条根因与 schema 自检
#
# 用户实测（2026-10-23）：
#   dmesg: openclaw-gatewa segfault ...  ubus: running=false, exit_code=139
#   → 一小时内崩 5 次后 procd 彻底放弃，表现为"停了再也不回来"。
#   另一次是恢复备份后 schema 24 < 25，网关每次 exit 1、端口不开。
#
# 断言：
#   1. respawn 的 retry 是 0（永不放弃），timeout 与 threshold 合理
#   2. term_timeout 已设（procd 默认 5 秒，插件收尾来不及）
#   3. core dump 是**可选**的：默认不设 limits、不改全局 core_pattern
#   4. oc_schema_heal 只在日志同时出现 "schema version" 与 "doctor --fix" 时才动手
#   5. 每次开机最多修一次（标记文件生效）
#   6. 日志里没有那两条特征时，绝不调用 doctor
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
import os
import re
import subprocess
import sys
import tempfile

proj = pathlib.Path(sys.argv[1])
NL = chr(10)
init = (proj / 'root/etc/init.d/openclaw').read_text(encoding='utf-8')
defaults = (proj / 'root/usr/share/openclaw/config.default').read_text(encoding='utf-8')

total = 0
failed = 0


def check(ok, desc, detail=''):
    global total, failed
    total += 1
    print('    %s  %s%s' % ('ok  ' if ok else 'FAIL', desc, ('  ' + detail) if detail else ''))
    if not ok:
        failed += 1


# ---------------------------------------------------------------- 静态断言
m = re.search(r'(?m)^\s*procd_set_param respawn ([0-9]+) ([0-9]+) ([0-9]+)', init)
check(m is not None, '有 respawn 参数')
if m:
    thr, tmo, retry = m.group(1), m.group(2), m.group(3)
    check(retry == '0', 'respawn 的 retry 为 0（永不放弃）', 'retry=%s' % retry)
    check(int(tmo) >= 5, 'respawn timeout 不小于 5 秒', 'timeout=%s' % tmo)
    check(int(thr) >= 600, 'respawn threshold 足够大（退避封顶）', 'threshold=%s' % thr)

check(re.search(r'(?m)^\s*procd_set_param term_timeout ([0-9]+)', init) is not None,
      'term_timeout 已设置')
m2 = re.search(r'(?m)^\s*procd_set_param term_timeout ([0-9]+)', init)
if m2:
    check(int(m2.group(1)) >= 20, 'term_timeout >= 20 秒', 'value=%s' % m2.group(1))

# core dump 必须在开关里，不能无条件设置
check('config_get_bool core_dumps main core_dumps 0' in init,
      'core dump 由 UCI 开关控制（默认 0）')
check("option core_dumps '0'" in defaults, 'config.default 里 core_dumps 默认为 0')
# 无条件出现 = 每次启动都改全局 core_pattern
# 只数**真的写** /proc/sys/kernel/core_pattern 的行：
# 注释与 logger 文案里也会出现这个词，不能一起算。
core_line = [l for l in init.splitlines()
             if '/proc/sys/kernel/core_pattern' in l and not l.strip().startswith('#')]
check(len(core_line) == 1, 'core_pattern 只在开关分支里写一次', 'hits=%d' % len(core_line))
if core_line:
    idx = init.index(core_line[0])
    # 取该 if 语句本身之前的足够窗口：DIAG 域的 mkdir/chown/chmod 也在分支内，
    # 窗口要给够（600 会假失败）。
    before = init[max(0, idx - 1200):idx]
    check('if [ "$core_dumps" = "1" ]' in before, 'core_pattern 写在 core_dumps 分支内')
    # 顺带验证落点是 DIAG 域而不是 VAR 域（core 属主取决于崩溃进程，不该进用户域）
    check('"$base/dumps"' in before, 'core 落在 DIAG 域（dumps/），不落 VAR 域')

# ---- core_dumps 的读写链路：能存、能读、界面能提交 ----
cli = (proj / 'root/usr/libexec/openclaw/cli.sh').read_text(encoding='utf-8')
ctrl = (proj / 'luasrc/controller/openclaw.lua').read_text(encoding='utf-8')
setup = (proj / 'luasrc/view/openclaw/setup.htm').read_text(encoding='utf-8')

# 依赖清单必须覆盖代码真的会调用的命令（这两条曾被漏掉，
# 后果是装完才发现 tar -xJf 没有 xz、https 下载没有 ca-bundle）
build = (proj / 'scripts/build_apk.py').read_text(encoding='utf-8')
check('"xz-utils"' in build, 'DEPEND 含 xz-utils（tar -xJf 需要）')
check('"ca-bundle"' in build, 'DEPEND 含 ca-bundle（https 下载需要）')
check('rpcd reload' in build, 'postinst 会 reload rpcd（否则新 ACL 不生效）')

# 网关可达性探测：进程在 ≠ 端口应答
# running() 必须用 argv 判定，不能用 pgrep -f 模糊匹配。
# 实测 `pgrep -f 'openclaw.*(gateway|run)'` 会把 `cli.sh run date`（终端页）
# 和 `tail -f ...openclaw.log gateway` 都判成"网关在跑"。
_i = cli.index('running() {')
_j = cli.index('\n}\n', _i)
runfn = cli[_i:_j]
runfn_code = '\n'.join(l.split('#')[0] for l in runfn.splitlines())
check('oc_gateway_pids' in runfn_code, 'running() 用 oc_gateway_pids 精确判定')
check('pgrep -f' not in runfn_code, 'running() 里没有 pgrep -f 模糊匹配')

# ---- 1.8.28：实际运行复核后的一批修复 ----
ins2 = (proj / 'root/usr/libexec/openclaw/install.sh').read_text(encoding='utf-8')
bkp2 = (proj / 'root/usr/libexec/openclaw/backup.sh').read_text(encoding='utf-8')
lib2 = (proj / 'root/usr/libexec/openclaw/lib.sh').read_text(encoding='utf-8')
init2 = (proj / 'root/etc/init.d/openclaw').read_text(encoding='utf-8')
mdl2 = (proj / 'root/usr/libexec/openclaw/models.sh').read_text(encoding='utf-8')
ver2 = (proj / 'root/usr/libexec/openclaw/versions.sh').read_text(encoding='utf-8')

# 覆盖安装必须先停服务，收尾用 restart
check('init.d/openclaw stop' in ins2, 'install.sh 覆盖安装前会停服务')
# 收尾必须是 stop → start，不是 restart：procd 的 restart 只给**已注册**实例
# 发信号，不重读 initscript；而升级会换掉 init.d 里的 limits/env/respawn。
check('init.d/openclaw stop' in ins2 and 'init.d/openclaw start' in ins2,
      '安装收尾用 stop → start（让 procd 重读 initscript）')
check('init.d/openclaw restart' not in ins2, '安装收尾不再用 restart')
# 备份暂存不能在 tmpfs
check('stage_root="$base/tmp"' in bkp2, '备份暂存目录在数据盘而不是 /tmp')
check('cp -al "$data"' in bkp2, '备份用硬链接树而不是整份复制')
# 备份排除路径必须精确
_bkp_code = '\n'.join(l.split('#', 1)[0] for l in bkp2.splitlines())
check("--exclude='logs'" not in _bkp_code,
      '排除规则不再用裸名字（会误伤 workspace/logs）')
check('_data_rel' in bkp2, '排除规则改用相对归档根的精确路径')
# 还原：白名单 + 回滚
check('uci -q -c "$stage/etc/config"' in bkp2, '还原只取非路径类 UCI 键')
check('已自动回滚到还原前数据' in bkp2, '还原后起不来会自动回滚')
# 等待窗口
check('while [ "$i" -lt 120 ]' in ins2, '启动等待上限 120 秒（原 15 秒）')
# 缓存 TTL
check('cache_fresh()' in ver2, '有 cache_fresh（TTL 真正生效）')
check('cache_fresh oc-versions.tsv' in ver2, 'oc-versions 走 TTL 判断')
# 密钥不进 argv
check('拒绝从命令行参数读取 API Key' in mdl2, 'models.sh 拒绝位置参数传 key')
check('config set "models.providers.${provider}.apiKey" "$key"' not in mdl2,
      '不再把明文 key 写进配置（会进 argv）')
# 进程终止
check('kill "$p"' in lib2, 'oc_kill_tree 先 TERM')
check('[ -z "$(oc_gateway_pids)" ]' in lib2, 'oc_kill_tree 确认进程真的没了')
# chown 优化
check('stat -c %U "$home"' in init2, 'start 时先比对属主再决定是否递归')

# ---- 外部实测报告（REPORT.md）里的修复 ----
lib3 = (proj / 'root/usr/libexec/openclaw/lib.sh').read_text(encoding='utf-8')
init3 = (proj / 'root/etc/init.d/openclaw').read_text(encoding='utf-8')
ins3 = (proj / 'root/usr/libexec/openclaw/install.sh').read_text(encoding='utf-8')
mdl3 = (proj / 'root/usr/libexec/openclaw/models.sh').read_text(encoding='utf-8')
chl3 = (proj / 'root/usr/libexec/openclaw/channels.sh').read_text(encoding='utf-8')

# BUG-1：网关把 process.title 改成 openclaw-gateway，argv[0] 随之被改写，
# 所以「argv[0] == node 二进制」的判据永远不中（本机实测 cmdline 只有
# 一个 token "openclaw-gateway"，comm 被截断成 "openclaw-gatewa"）。
gp = lib3[lib3.index('oc_gateway_pids() {'):]
gp = gp[:gp.index('\n}\n')]
check('openclaw-gateway' in gp, 'oc_gateway_pids 认 process.title 改写后的 argv[0]')
check('/proc/[0-9]*' in gp, 'oc_gateway_pids 遍历 /proc 而不是依赖 pgrep')
_gp_code = '\n'.join(l.split('#', 1)[0] for l in gp.splitlines())
check('pgrep' not in _gp_code, 'oc_gateway_pids 代码里不再用 pgrep（注释里提到不算）')

# BUG-6：init.d running 走 ubus，某些固件没有 service 对象，恒返回未运行。
stop_gate = ins3[ins3.index('覆盖安装前必须先停服务'):]
stop_gate = stop_gate[:stop_gate.index('npm install -g openclaw@')]
check('oc_gateway_pids' in stop_gate, 'install 停服门用进程表判定（不用 init.d running）')
check('/etc/init.d/openclaw running' not in stop_gate,
      'install 停服门不再依赖不可信的 init.d running')

# BUG-2：非 root 不再拒绝，回落到自己的目录。
check('.openclaw-run-$uid' in lib3, '非 root 时回落到 $HOME/.openclaw-run-<uid>')
check('拒绝继续' not in lib3[:3000], '非 root 不再直接拒绝（否则 CLI 全废）')

# BUG-3：SecretRef 不是明文 token，必须返回空。
gt = cli[cli.index('get_token() {'):]
gt = gt[:gt.index('\n}\n')]
check("'{'*'}'" in gt, 'get_token 识别 SecretRef 并返回空')

# BUG-4：logread 会挂死，必须有超时。
check('oc_timeout 5 logread' in cli, 'logread 有 5 秒超时')

# BUG-7：core="unlimited unlimited" 会让 soft 退化为 0。
check('limits core="unlimited"' in init3, 'core limits 用单值 unlimited')
check('limits core="unlimited unlimited"' not in init3, '不再用双 unlimited（soft 会变 0）')

# BUG-8：pidfile 必须有人写。
check('procd_set_param pidfile' in init3, 'procd 维护 pidfile')

# BUG-9：SecretRef 不能进环境变量，必须通过共享结构化判定器判断，不能靠 init 内的形状猜测。
credlib = (proj / 'root/usr/libexec/openclaw/credential.sh').read_text(encoding='utf-8')
check('credential.sh' in init3 and 'oc_credential_state' in init3,
      'init.d source 共享凭据判定库')
check('token_is_secretref' not in init3, 'init.d 移除旧的 SecretRef 形状猜测')
check("OC_CRED_STATE=REF" in credlib and "OC_CRED_STATE=BADREF" in credlib,
      '共享判定区分有效引用与坏引用')
check('token_env="OPENCLAW_GATEWAY_TOKEN=$token"' in init3,
      '仅在 PLAIN 明文分支准备 gateway token env')

# Hermes P1-2：schema-heal 的 doctor 必须降权到服务用户，不能以 root 写 state。
# 注意这个检查必须放在 func() 定义之后；函数定义在"行为断言"段落里。

check('oc_log_rotate "$OC_TASKLOG"' in chl3, 'channels.sh 写 tasklog 前轮转')
check(mdl3.count('oc_log_rotate "$OC_TASKLOG"') >= 2,
      'models.sh 写 tasklog 前轮转', '实际 %d 处' % mdl3.count('oc_log_rotate "$OC_TASKLOG"'))

# OPT-3：/var/log 对网关用户不可写时要回落。
check('/logs' in lib3 and 'oc_base_dir' in lib3, 'oc_log 在 /var/log 不可写时回落')

check('oc_gateway_reachable()' in cli, '有网关可达性探测函数')
check('"reachable":%s' in cli, 'cmd_info 输出 reachable')
check('_reachable_flag' in cli, 'info 经由 _reachable_flag 决定是否探测')
check('installed || { printf \'null\'' in cli.replace('"null"', "'null'"),
      '未安装时返回 null（不探测端口，省 1-2 秒连接超时）')
check('running   || { printf' in cli or 'running || { printf' in cli,
      '已停止时返回 null（同样不探测）')
check('oc_gateway_reachable "$(get_port)"' in cli,
      '_reachable_flag 里真的调用了探测函数')
check('oc_probe_hosts()' in cli, '按 bind 选择探测主机')
statusview = (proj / 'luasrc/view/openclaw/status.htm').read_text(encoding='utf-8')
check('运行中（端口未应答）' in statusview, '状态页区分「端口未应答」')

check('--core-dumps' in cli, 'cmd_save 接受 --core-dumps')
check(re.search(r'--core-dumps\).*?0\|1', cli, re.S) is not None,
      '--core-dumps 只接受 0/1')
check('"core_dumps":%s' in cli, 'cmd_info 输出 core_dumps')
check('"core_dumps"' in ctrl, '控制器 save 白名单含 core_dumps')
check('id="cfg-coredump"' in setup, '设置·基础页有崩溃转储下拉')
check('core_dumps: $(' in setup, '保存时提交 core_dumps')
check("$('cfg-enabled').checked = String" in setup,
      '开机自启开关会按服务端状态回填（原先不回填，保存一次就把禁用改回启用）')

# ---------------------------------------------------------------- 行为断言
def func(name):
    lines = init.splitlines()
    starts = [(i, mm.group(1)) for i, l in enumerate(lines)
              for mm in [re.match(r'^([a-z_][a-z0-9_]*)\(\)\s*\{', l)] if mm]
    for idx, (ln, nm) in enumerate(starts):
        if nm == name:
            end = starts[idx + 1][0] if idx + 1 < len(starts) else len(lines)
            return NL.join(lines[ln:end])
    raise AssertionError('取不到函数 ' + name)


# Hermes P1-2：schema-heal 的 doctor 必须降权到服务用户，不能以 root 写 state。
_schema = func('oc_schema_heal')
check('su -s /bin/sh "$OC_USER" -c' in _schema,
      'schema-heal 通过 su 降权到服务用户')
check('OPENCLAW_STATE_DIR="$2"' in _schema and 'OPENCLAW_CONFIG_PATH="$2/openclaw.json"' in _schema,
      'doctor 以一致的 state/config 路径运行')
check('cd "$1"' in _schema and 'export HOME="$1"' in _schema,
      'doctor cwd 与 HOME 都在服务用户家目录')


def msys_tmp():
    """MSYS 视角下 /tmp 的真实 Windows 路径。"""
    try:
        r = subprocess.run(['sh', '-c', 'cd /tmp && pwd -W'],
                           capture_output=True, text=True, timeout=30)
        out = r.stdout.strip()
        if out:
            return out
    except Exception:
        pass
    return '/tmp'


work = pathlib.Path(tempfile.mkdtemp())


def P(p):
    s = pathlib.Path(p).as_posix()
    return '/c' + s[2:] if len(s) > 1 and s[1] == ':' else s


# 假 node：只记录自己被调用过（参数里含 doctor 时写标记）
fake_node = work / 'node'
fake_node.write_text(NL.join([
    '#!/bin/sh',
    'printf "%s\\n" "$*" >>"$DOCTOR_CALLS"',
    'exit 0',
    '',
]), encoding='utf-8', newline=NL)
calls = work / 'calls.txt'

runner = work / 'heal.sh'
# 用 PATH 里的可执行假 su，而不是在 runner 中定义函数：
# `command -v su` 在 dash/ash 下对函数的识别并不一致，曾导致测试实际调用
# 系统 su，Windows/MSYS 没有 openclaw 用户，于是 doctor 分支被静默跳过。
su_bin = work / 'bin'
su_bin.mkdir(parents=True, exist_ok=True)
fake_su = su_bin / 'su'
fake_su.write_text(NL.join([
    '#!/bin/sh',
    '_script=""; _user=""; _have_c=0',
    'while [ "$#" -gt 0 ]; do',
    '  case "$1" in',
    '    -s) shift 2 ;;',
    '    -c) _have_c=1; _script="$2"; shift 2 ;;',
    '    -) shift ;;',
    '    *) if [ -z "$_user" ]; then _user="$1"; shift; else break; fi ;;',
    '  esac',
    'done',
    '[ "$_have_c" = "1" ] || exit 1',
    'printf "su-as=%s\\n" "${_user:-?}" >>"$DOCTOR_CALLS"',
    'sh -c "$_script" "$@"',
    '',
]), encoding='utf-8', newline=NL)
os.chmod(fake_su, 0o755)
runner.write_text(NL.join([
    '#!/bin/sh',
    'logger() { :; }',
    # OC_USER 是 init.d 顶部的全局变量，func() 只截取函数体，不会带上它。
    # 漏了这句时 su 收到的是空用户名：
    #   su -s /bin/sh "" -c <script> sh <args...>
    # 假 su 会把空串当成未赋值并继续吃掉后面的 "sh"，于是 $0/$1.. 全部错位，
    # "doctor 以 openclaw 身份执行" 之类的断言就假失败（实测踩过）。
    'OC_USER=openclaw',
    func('oc_schema_heal'),
    'oc_schema_heal "$1" "$2" "$3" "$4" "$5"',
    '',
]), encoding='utf-8', newline=NL)


def heal(log_body=None, marker_exists=False):
    """准备一个假 base，跑一次 oc_schema_heal，返回 doctor 被调用次数。"""
    base = work / 'base'
    tmp = base / 'tmp' / 'openclaw-0'
    tmp.mkdir(parents=True, exist_ok=True)
    if log_body is not None:
        (tmp / 'openclaw-2026-10-23.log').write_text(log_body, encoding='utf-8')
    # 标记文件在 /tmp/.openclaw 下。MSYS 的 /tmp 并不是 Windows 的 C://tmp，
    # 必须先问出它的真实位置，否则这里的删除/创建落在另一个目录上，
    # "每次开机只修一次"那条断言会假失败（实测踩过）。
    mk = pathlib.Path(msys_tmp()) / '.openclaw' / 'schema-healed'
    if mk.exists():
        mk.unlink()
    if marker_exists:
        mk.parent.mkdir(parents=True, exist_ok=True)
        mk.write_text('', encoding='utf-8')
    if calls.exists():
        calls.unlink()
    env = {'PATH': P(su_bin) + ':/usr/bin:/bin', 'DOCTOR_CALLS': P(calls)}
    subprocess.run(['sh', P(runner), P(base), P(work / 'state'), P(work / 'home'),
                    P(fake_node), P(work / 'entry.mjs')],
                   capture_output=True, text=True, env=env, timeout=120)
    if not calls.exists():
        return 0
    return len([l for l in calls.read_text(encoding='utf-8').splitlines() if 'doctor' in l])


SCHEMA_LOG = NL.join([
    '13:33:09 uses schema version 24; the bundled version is 25.',
    '13:33:09 Sessions remain unavailable. run openclaw doctor --fix',
    '',
])

check(heal(log_body=None) == 0, '没有日志 → 不调用 doctor')
check(heal(log_body='all good' + NL) == 0, '日志无特征 → 不调用 doctor')
check(heal(log_body='uses schema version 24' + NL) == 0,
      '只有 schema version、没有 doctor --fix → 不调用 doctor')
check(heal(log_body='run openclaw doctor --fix' + NL) == 0,
      '只有 doctor --fix、没有 schema version → 不调用 doctor')
check(heal(log_body=SCHEMA_LOG) == 1, '两条特征都在 → 调用一次 doctor')
check(heal(log_body=SCHEMA_LOG, marker_exists=True) == 0,
      '本次开机已修过 → 不再调用（防死循环）')

# doctor 必须以服务用户身份执行（不能以 root 写 state）。
_ = heal(log_body=SCHEMA_LOG)
_calls = calls.read_text(encoding='utf-8') if calls.exists() else ''
check('su-as=openclaw' in _calls, 'doctor 经 su 以 openclaw 身份执行')
check('doctor --fix --force' in _calls, 'doctor 参数完整（--fix --force）')

print('    共 %s 项，%s 项失败' % (total, failed))
sys.exit(1 if failed else 0)
PYEOF
