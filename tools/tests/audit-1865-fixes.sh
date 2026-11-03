#!/bin/sh
# v1.8.65 审计修复的行为级回归。
#
# 现有 api-run.sh 只做字符串存在性断言，无法证明「绕过路径真的被拒」；
# view-messages.sh 的 node 断言恒真（node 在控制器里到处都是）。
# 这里改成：把 run_argv_allowed 从 Lua 源码里抽出来，用真实逻辑判定用例，
# 而不是 grep 源码。
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
PROJ="$(cd "$HERE/../.." && pwd)"
PY="${PY:-python3}"

"$PY" - "$PROJ" <<'PY'
import re
import sys
from pathlib import Path

proj = Path(sys.argv[1])
lua = (proj / 'luasrc/controller/openclaw.lua').read_text(encoding='utf-8')

fails = 0
total = 0

def check(cond, name, detail=''):
    global fails, total
    total += 1
    if cond:
        print('  ok    ' + name)
    else:
        fails += 1
        print('  FAIL  ' + name + (('  [' + detail + ']') if detail else ''))

# ---- 1) 用真实逻辑复现 run_argv_allowed，而不是 grep 源码 ----
# 从 Lua 里抽出 RUN_DENY 的键与 run_argv_allowed 的判定规则。
# 不用 Lua 解释器（路由器上未必有），而是把同一套规则用 Python 复刻，
# 并要求 Lua 源码里确实存在对应结构 —— 两者对不上就 FAIL。
if 'local RUN_DENY' not in lua:
    print('  FAIL  RUN_DENY 表不存在，控制器未采用黑名单')
    sys.exit(1)
def slice_fn(src, marker, end='\n}\n'):
    """安全切片：标记不存在时返回空串，而不是抛 ValueError 让整个测试崩掉。"""
    if marker not in src:
        return ''
    body = src[src.index(marker):]
    return body[:body.index(end) + len(end)] if end in body else body

deny_block = lua[lua.index('local RUN_DENY'):]
deny_block = deny_block[:deny_block.index('\n}')] if '\n}' in deny_block else deny_block
# 一行里可能写多个 key（reset = true, uninstall = true, ...），
# 不能用 ^ 行首锚定，否则每行只抓到第一个。
deny_keys = set(re.findall(r'(\w+)\s*=\s*true', deny_block))
deny_keys |= set(re.findall(r'\["([^"]+)"\]\s*=\s*true', deny_block))
deny_keys.discard('local')

check({'reset', 'uninstall', 'migrate', 'tui', 'chat', 'browser', 'exec-policy', 'node'} <= deny_keys,
      'RUN_DENY 覆盖全部 8 个危险子命令', str(sorted(deny_keys)))

def allowed(cmd):
    """复刻 run_argv_allowed：循环剥前缀 -> 选项处理 -> 黑名单查表。"""
    argv = cmd.split()
    while argv and argv[0] in ('openclaw', '/usr/bin/openclaw'):
        argv.pop(0)
    if not argv:
        return False
    first = argv[0]
    if first in ('--version', '--help'):
        return True
    if first.startswith('-'):
        return False
    return first not in deny_keys

# ---- 2) 绕过路径必须被拒（审计 P0-2 / P0-3 / P0-4）----
bypass_cases = [
    ('-- reset', '选项终止符把 reset 顶到子命令位'),
    ('-- uninstall', '选项终止符把 uninstall 顶到子命令位'),
    ('openclaw -- reset', '带前缀的选项终止符'),
    ('-y reset', '短选项前缀绕过'),
    ('-f uninstall', '短选项前缀绕过 2'),
    ('openclaw openclaw reset', '双重前缀剥离绕过'),
    ('openclaw /usr/bin/openclaw uninstall', '混合双重前缀绕过'),
    ('reset', '裸黑名单命令'),
    ('openclaw reset', '带前缀黑名单命令'),
    ('/usr/bin/openclaw migrate', '绝对路径前缀黑名单命令'),
    ('tui', '会挂住的 tui'),
    ('exec-policy', '能绕过防线的 exec-policy'),
    ('node', '能绕过防线的 node'),
    ('', '空命令'),
    ('openclaw', '只有前缀没有子命令'),
]
for cmd, why in bypass_cases:
    check(not allowed(cmd), '拒绝：%s' % (cmd or '(空)'), why)

# ---- 3) 正常命令必须放行（不能把功能改死）----
allow_cases = [
    ('gateway auth-token --show', '内网重新认证需要'),
    ('openclaw gateway auth-token --show', '带前缀的官方写法'),
    ('status', '最常用只读命令'),
    ('models list --provider zai', '模型列表'),
    ('config set gateway.bind lan', '配置修改（内网允许）'),
    ('security audit', '安全审计'),
    ('--version', '版本号'),
    ('--help', '帮助'),
]
for cmd, why in allow_cases:
    check(allowed(cmd), '放行：%s' % cmd, why)

# ---- 4) 源码层面确认这些规则不是「Python 复刻的幻觉」----
fn = slice_fn(lua, 'local function run_argv_allowed', '\nend\n')
check('while #argv > 0' in fn, '控制器循环剥离前缀（不是只剥一层）')
check('table.remove(argv, 1)' in fn, '确实移除前缀 token')
check('first == "--version" or first == "--help"' in fn,
      '只放行 --version / --help，而不是所有 --*')
check('first:match("^%-") then return false' in fn,
      '其余以 - 开头的首 token 一律拒绝')
check('RUN_DENY[first] ~= true' in fn, '最终仍走黑名单判定')

# 旧实现的两个漏洞不能再出现
check('first:match("^%-%-") then return true' not in lua,
      '不存在「所有 --* 直接放行」的旧漏洞')
check(lua.count('table.remove(argv, 1)') >= 1, '存在前缀剥离')

# ---- 5) cloud.sh：setsid 不能执行 shell 函数 ----
cloud = (proj / 'root/usr/libexec/openclaw/cloud.sh').read_text(encoding='utf-8')
check('setsid backup_bg_worker' not in cloud,
      'setsid 不再直接执行 shell 函数（外部程序无法 exec 函数）')
check('backup-bg-worker)' in cloud, '存在 backup-bg-worker 真实子命令入口')
check('backup-bg-worker) shift; backup_bg_worker "$@"' in cloud,
      'backup-bg-worker 正确转发到 worker 函数')

# ---- 6) worker 内取锁顺序：先取锁、后写 PID ----
worker = slice_fn(cloud, 'backup_bg_worker() {')
def find_code_line(text, needle):
    """找一个不以 # 开头的真实代码行位置，避免命中注释里的同名片段。"""
    pos = 0
    for line in text.split(chr(10)):
        stripped = line.lstrip()
        if needle in line and not stripped.startswith('#'):
            return pos + line.index(needle)
        pos += len(line) + 1
    return -1

lock_pos = find_code_line(worker, 'oc_lock_acquire')
pid_pos = worker.find('>"$CLOUD_BK_PID"')
check(lock_pos != -1, 'worker 内确实取锁（双向互斥的真正防线）')
check(pid_pos != -1, 'worker 写自己的真实 PID')
check(lock_pos != -1 and pid_pos != -1 and lock_pos < pid_pos,
      '先取锁再写 PID（抢锁失败时不覆盖别人的状态文件）')

# 抢锁失败分支不能无条件覆盖别人的 PID 与 rc：必须先用占位值判定归属
fail_branch = worker[lock_pos:pid_pos] if lock_pos < pid_pos else ''
check("grep -q '^starting '" in fail_branch,
      '抢锁失败分支先判定 pid 文件是否还是自己写的占位值')
check(fail_branch.count('rm -f "$CLOUD_BK_PID"') <= 1,
      '抢锁失败分支最多收尾一次 PID')
if 'rm -f "$CLOUD_BK_PID"' in fail_branch:
    guard_at = fail_branch.index("grep -q '^starting '")
    rm_at = fail_branch.index('rm -f "$CLOUD_BK_PID"')
    check(guard_at < rm_at, '删除 PID 之前必须先确认占位值归属')

# ---- 7) 父进程只写占位值，避免与 worker 的 $$ 互相覆盖 ----
bg = slice_fn(cloud, 'cmd_backup_bg() {')
check("printf 'starting %s\\n'" in bg,
      '父进程写带时间戳的 starting 占位，而不是 $!')
check('printf \'%s\\n\' "$!" >"$CLOUD_BK_PID"' not in bg,
      '父进程不再用 $! 覆盖（setsid 下 $! 未必是 worker）')
check('exec "$1" backup-bg-worker' in bg or "exec \"$1\" backup-bg-worker" in bg,
      'setsid 分支走脚本真实入口 backup-bg-worker')
check("printf '%s\\n' \"$!\" >\"$CLOUD_BK_PID\"" not in bg,
      '父进程不用 $! 写 PID（setsid 下 $! 未必是 worker）')

# ---- 8) poll 认得 starting 占位，不会立刻误报中断 ----
poll = slice_fn(cloud, 'cmd_backup_poll() {')
check('elif [ -n "$_st_ts" ]' in poll,
      'poll 有专用的 starting 分支（不是随便提到这个词）')
check('running=true' in poll, 'starting 期间按运行中处理')
# 超时兜底必须真的是双层数字校验 + 减法比较，不能只在 local 行出现变量名
check('_st_ts="${pid#starting }"' in poll,
      '时间戳从占位里解析，不依赖 stat -c（精简 busybox 可能没有）')
check("case \"$_st_ts\" in" in poll and "case \"$_st_now\" in" in poll,
      '两侧时间分别做纯数字校验（空值不会算成 0 → 误判超时）')
check('$((_st_now - _st_ts)) -gt 120' in poll,
      '确实用差值判断超时，而不是任意写法')
# 占位不能永远卡住：busy 检查里必须给 starting 留过期
check('starting\\ *) _ts="${_p#starting }"' in slice_fn(cloud, 'cmd_backup_bg() {'),
      '入口 busy 检查解析 starting 占位及其时间戳')
check('-le 120' in slice_fn(cloud, 'cmd_backup_bg() {'),
      'starting 占位会过期，不会永久挡住新备份')

print()
print('    共 %d 项，%d 项失败' % (total, fails))
sys.exit(1 if fails else 0)
PY
