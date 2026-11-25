#!/bin/sh
# upgrade-strategy.sh — OpenClaw 本体升级：按跨度选策略 / 网络重试换源 / 失败恢复网关
#
# 背景（2026-11-26 真机）：
#   设备 2026.11.8 → 2026.11.10，`npm install` 直连 registry.npmjs.org 两次都在
#   87 秒左右 ECONNRESET。安装器一失败就 die，而它为了覆盖安装**先停了网关**，
#   于是状态停在 stopped；同一个版本走 npmmirror 一次成功。
#   另外发现「已是该版本就跳过」从来没生效过：它拿 `openclaw --version` 的整行
#   输出（OpenClaw 2026.11.10 (6ea542f)）去跟目标版本比，永远不相等。
#
# 第二轮（异源复核后）收紧的几处，这里都有反例：
#   * 只凭 package.json 版本相同不能重启网关 —— 必须证明安装树零改动；
#   * npm 在替换阶段失败后 package.json 可能已是新版本 —— 「跳过」要完成标记；
#   * beta 与正式版数字段相同但不是同一个版本；
#   * 每次尝试单独记日志，网络判定只认 npm 的错误码行；
#   * 换源前确认备用源上真有这个版本；算不出剩余时间就不重试。
#
# 退出码：0 = 全部通过；1 = 有失败

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
PROJ="${1:-$(cd "$HERE/../.." && pwd)}"
PY=""
for cand in python3 python "${HOME:-}/.workbuddy/binaries/python/versions/3.13.12/python.exe"; do
	if command -v "$cand" >/dev/null 2>&1 || [ -x "$cand" ]; then PY="$cand"; break; fi
done
[ -n "$PY" ] || { echo "    跳过：找不到 python"; exit 0; }

"$PY" - "$PROJ" <<'PYEOF'
import pathlib
import subprocess
import sys
import tempfile
import time

PROJ = pathlib.Path(sys.argv[1])
INS = PROJ / 'root/usr/libexec/openclaw/install.sh'
LIB = PROJ / 'root/usr/libexec/openclaw/lib.sh'
ins = INS.read_text(encoding='utf-8') if INS.exists() else ''
lib = LIB.read_text(encoding='utf-8') if LIB.exists() else ''

fails = []
total = 0


def check(name, cond, extra=''):
    global total
    total += 1
    print(('  ok   ' if cond else '  FAIL ') + name)
    if not cond:
        fails.append(name)
        if extra != '':
            print('       ' + str(extra)[:260])


def func(src, name):
    i = src.find('\n' + name + '() {')
    if i < 0:
        return ''
    i += 1
    j = src.find('\n}\n', i)
    return src[i:j + 3] if j > i else ''


def sh_run(script_text, td, name='j.sh', timeout=90):
    f = td / name
    f.write_text(script_text, encoding='utf-8', newline='\n')
    p = subprocess.run(['sh', str(f)], capture_output=True, text=True, timeout=timeout)
    return p.returncode, p.stdout, p.stderr


def posix(p):
    return str(p).replace('\\', '/')


def q(v):
    return '"' + str(v).replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n') \
        .replace('$', '\\$').replace('`', '\\`') + '"'


# ---------------------------------------------------------------- 静态契约
io = func(ins, 'install_openclaw')
i_npm = io.find('npm_install_retry\n')
i_flag1 = io.find('OC_GW_WAS_RUNNING=1')
i_flag0 = io.find('OC_GW_WAS_RUNNING=0')
check('当前版本改读 package.json（不再用 --version 整行去比）',
      '_cur_ver="$(oc_pkg_version "$OC_DIR" 2>/dev/null | head -n1)"' in io
      and 'tr -d ' not in io)
check('同版本跳过要求「装完」标记 + 入口 + 版本三者同时成立',
      'oc_install_ok "$OC_DIR" "$_want_ver"' in io
      and '[ "$_cur_ver" = "$_want_ver" ]; then' not in io)
check('npm 开始前作废完成标记，npm 成功后才重写',
      0 < io.find('rm -f "$OC_DIR/.oc-install-ok"') < i_npm
      < io.find('>"$OC_DIR/.oc-install-ok"'))
check('安装时按跨度选策略', 'oc_upgrade_class "$_cur_ver" "$_want_ver"' in io and '升级策略：' in io)
check('跨月升级前备份配置：权限 600、只留 3 份',
      'pre-upgrade-' in io and 'chmod 600 "$_pre_bak"' in io and 'tail -n +4' in io)
check('降级默认拒绝、需显式强制', '已拒绝降级' in io and '[ "$FORCE" != "1" ]' in io)
check('停网关时记下「原来在跑」，npm 成功后才清零', 0 < i_flag1 < i_npm < i_flag0)
check('npm 期间收到 TERM/HUP/INT 也走 die()，成功后恢复默认处置',
      "trap 'die \"安装被信号中止" in io and 'trap - TERM HUP INT' in io
      and i_flag1 < io.find("trap 'die") < i_npm < io.find('trap - TERM HUP INT'))
check('npm 经带重试的函数执行，并带 fetch 重试参数',
      '--fetch-retries=4' in ins and '--prefer-online' in ins)
die_fn = func(ins, 'die')
check('die() 恢复网关必须证明「安装树零改动」且版本一致',
      'oc_tree_untouched "$OC_DIR" "$OC_UPGRADE_MARKER"' in die_fn
      and '"$die_old_ver" = "${OC_PRE_UPGRADE_VER:-}"' in die_fn
      and '_cur_ver' not in die_fn and '未自动启动网关' in die_fn)
rf = func(ins, 'npm_install_retry')
check('每次尝试单独记日志；换源前先确认备用源有这个版本',
      'npm_log.attempt' in rf and 'npm_registry_has "$n_alt"' in rf
      and 'npm_net_fail "$n_log"' in rf)

VER = '\n'.join(func(lib, n) for n in ('_ver_field', 'ver_cmp', 'ver_eq', 'ver_lt'))
FNS = VER + '\n' + '\n'.join(func(ins, n) for n in (
    'oc_ver_norm', 'oc_pkg_version', 'oc_pre_part', 'oc_pre_cmp', 'oc_upgrade_class',
    'npm_net_fail', 'npm_alt_registry', 'oc_install_ok', 'oc_tree_untouched'))

# ---------------------------------------------------------------- 行为：跨度分类
CLS = [
    ('2026.11.8', '2026.11.10', 'patch', '同月补丁（真机本次）'),
    ('2026.11.10', '2026.11.10', 'same', '同版本'),
    ('2026.11.10-beta.1', '2026.11.10-beta.2', 'patch', '同号的两个 beta 是两个版本（beta.2 更新）'),
    ('2026.11.10-beta.1', '2026.11.10', 'patch', 'beta -> 同号正式版是升级，不是同版本'),
    ('2026.11.10', '2026.11.10-beta.1', 'prerelease', '正式版 -> beta 不能无声放行'),
    ('2026.10.7', '2026.11.10', 'minor', '跨月（2026.10 → 2026.11，heartbeat 被删那次）'),
    ('2026.1.29', '2026.11.10', 'minor', '跨很多个月'),
    ('2026.11.10', '2026.12.1', 'minor', '跨到下个月'),
    ('2026.11.10', '2026.11.8', 'downgrade', '降级'),
    ('2026.11.10', '2026.10.7', 'downgrade', '跨月降级'),
    ('2026.11.10-beta.2', '2026.11.10-beta.1', 'downgrade', '同号 beta 降级'),
    ('2026.11.10-beta.1', '2026.11.9', 'downgrade', 'beta 比旧正式版新'),
    ('2026.11.10-beta.9', '2026.11.10-beta.10', 'patch', '预发布数字段按数值比（9 < 10）'),
    ('2026.11.10-beta.10', '2026.11.10-beta.9', 'downgrade', '预发布数字段按数值比（10 > 9）'),
    ('2026.11.10-alpha.5', '2026.11.10-beta.1', 'patch', 'alpha < beta'),
    ('2026.11.10-rc.1', '2026.11.10-beta.9', 'downgrade', 'beta < rc'),
    ('2026.11.10-beta', '2026.11.10-beta.1', 'patch', '段数多的更大'),
    ('2026.11.10-beta.1', '2026.11.10-beta', 'downgrade', '段数少的小'),
    ('2026.11.10-1', '2026.11.10-alpha', 'patch', '数字段小于字母段'),
    ('2026.11.10-beta.01', '2026.11.10-beta.1', 'same', '前导零不算区别'),
    ('2026.11.10-beta.1+sha.abc', '2026.11.10-beta.1', 'same', '构建元数据不算区别'),
    ('', '2026.11.10', 'unknown', '当前版本读不到'),
    ('latest', '2026.11.10', 'unknown', '当前版本不是版本号'),
    ('2026.11.8', 'latest', 'unknown', '目标不是版本号'),
    ('2026.11.8', '2026.11.10-beta.1', 'patch', '目标带预发布后缀'),
]
with tempfile.TemporaryDirectory() as td:
    d = pathlib.Path(td)
    lines = ['#!/bin/sh', FNS]
    for i, (cur, tgt, _w, _n) in enumerate(CLS):
        lines.append('printf "%%s|%%s\\n" %s "$(oc_upgrade_class %s %s)"' % (i, q(cur), q(tgt)))
    # 每个用例要起十几次 awk/sed；MSYS 上 fork 很慢，25 个用例远超默认超时。
    rc, out, err = sh_run('\n'.join(lines) + '\n', d, timeout=600)
    got = {}
    for line in out.splitlines():
        k, _, v = line.partition('|')
        got[k] = v
    for i, (cur, tgt, want, name) in enumerate(CLS):
        check('跨度分类：%s（%s → %s）' % (name, cur or '空', tgt), got.get(str(i)) == want,
              '得到 %r，期望 %r；stderr=%s' % (got.get(str(i)), want, err[:120]))

# ---------------------------------------------------------------- 行为：版本规范化 / 读包
NORM = [
    ('OpenClaw 2026.11.10 (6ea542f)', '2026.11.10', '真机 --version 整行输出'),
    ('v2026.11.10', '2026.11.10', 'v 前缀'),
    ('2026.11.10-beta.1', '2026.11.10', '预发布后缀'),
    ('2026.11.10', '2026.11.10', '纯版本号'),
    ('', '', '空'),
    ('latest', '', '不是版本号'),
]
with tempfile.TemporaryDirectory() as td:
    d = pathlib.Path(td)
    lines = ['#!/bin/sh', FNS]
    for i, (raw, _w, _n) in enumerate(NORM):
        lines.append('printf "%%s|%%s\\n" %s "$(oc_ver_norm %s)"' % (i, q(raw)))
    rc, out, err = sh_run('\n'.join(lines) + '\n', d)
    got = dict(l.split('|', 1) for l in out.splitlines() if '|' in l)
    for i, (raw, want, name) in enumerate(NORM):
        check('版本规范化：%s' % name, got.get(str(i)) == want,
              '得到 %r，期望 %r' % (got.get(str(i)), want))

    # oc_pkg_version / oc_install_ok：读 package.json 原值（保留预发布后缀）
    ocdir = d / 'oc'
    (ocdir / 'lib/node_modules/openclaw').mkdir(parents=True)
    (ocdir / 'bin').mkdir()
    pkg = ocdir / 'lib/node_modules/openclaw/package.json'
    binf = ocdir / 'bin/openclaw'
    marker = ocdir / '.oc-install-ok'
    PJD = '{\n  "name": "openclaw",\n  "version": "%s",\n  "engines": { "node": ">=26.1.0" }\n}\n'
    pkg.write_text(PJD % '2026.11.10-beta.1', encoding='utf-8')
    script = '\n'.join(['#!/bin/sh', FNS,
                        'oc_pkg_version %s; echo "|rc=$?"' % q(posix(ocdir)),
                        'oc_pkg_version %s; echo "|rc=$?"' % q(posix(d / 'nope'))]) + '\n'
    rc, out, err = sh_run(script, d, 'pkg.sh')
    o = out.splitlines()
    check('读 package.json 原值（保留 -beta.1 后缀）', o[:1] == ['2026.11.10-beta.1|rc=0'], o)
    check('没有 package.json 时返回非 0 且无输出', o[1:2] == ['|rc=1'], o)

    def install_ok(version, marker_text, with_bin=True):
        pkg.write_text(PJD % version, encoding='utf-8')
        if marker_text is None:
            if marker.exists():
                marker.unlink()
        else:
            marker.write_text(marker_text + '\n', encoding='utf-8')
        if with_bin:
            binf.write_text('#!/bin/sh\n', encoding='utf-8')
            binf.chmod(0o755)
        elif binf.exists():
            binf.unlink()
        script_ = '\n'.join(['#!/bin/sh', FNS,
                             'oc_install_ok %s 2026.11.10; echo "rc=$?"' % q(posix(ocdir))]) + '\n'
        return sh_run(script_, d, 'ok.sh')[1].strip()

    check('装完标记 + 版本 + 入口都在 -> 算装完', install_ok('2026.11.10', '2026.11.10') == 'rc=0')
    check('没有装完标记 -> 不算装完（旧安装 / 装到一半）', install_ok('2026.11.10', None) == 'rc=1')
    check('标记是别的版本 -> 不算装完', install_ok('2026.11.10', '2026.11.8') == 'rc=1')
    check('标记对得上但 package.json 是别的版本 -> 不算装完',
          install_ok('2026.11.8', '2026.11.10') == 'rc=1')
    check('没有可执行入口 -> 不算装完', install_ok('2026.11.10', '2026.11.10', False) == 'rc=1')

# ---------------------------------------------------------------- 行为：安装树是否被动过
TREES = [
    ('clean', None, 0, '没人动过 -> 零改动'),
    ('added', lambda t: (t / 'lib/node_modules/newpkg').mkdir(), 1, '新增包目录（npm 移入新包）-> 被动过'),
    ('modified', lambda t: open(t / 'lib/node_modules/openclaw/package.json', 'a').write(' '), 1,
     '修改已有文件 -> 被动过'),
    ('deleted', lambda t: (t / 'lib/node_modules/openclaw/package.json').unlink(), 1,
     '删除文件（父目录 mtime 变）-> 被动过'),
    ('nested', lambda t: ((t / 'lib/node_modules/a/b/c').mkdir(parents=True),
                          (t / 'lib/node_modules/a/b/c/x.js').write_text('x')), 1,
     '深层新增文件 -> 被动过'),
]
with tempfile.TemporaryDirectory() as td:
    d = pathlib.Path(td)
    for label, mutate, want, name in TREES:
        sub = pathlib.Path(tempfile.mkdtemp(dir=str(d)))
        tree = sub / 'tree'
        (tree / 'lib/node_modules/openclaw').mkdir(parents=True)
        (tree / 'lib/node_modules/openclaw/package.json').write_text('{"version":"2026.11.8"}', encoding='utf-8')
        # 树里所有条目的 mtime 调到很早以前，标记是「现在」创建的
        for p in [tree] + list(tree.rglob('*')):
            subprocess.run(['touch', '-t', '200001010000', str(p)], check=False)
        mk = sub / 'marker'
        mk.write_text('', encoding='utf-8')
        # mtime 只有秒级精度：标记与随后的改动若落在同一秒，-newer 分不出先后。
        # 真机上安装器是「建标记后等 1 秒再跑 npm」；测试里把标记倒拨 3 秒，等价且不拖慢。
        subprocess.run(['touch', '-t', time.strftime('%Y%m%d%H%M%S', time.localtime(time.time() - 3)),
                        str(mk)], check=False)
        if mutate:
            mutate(tree)
        script_ = '\n'.join(['#!/bin/sh', FNS,
                             'oc_tree_untouched %s %s; echo "r=$?"' % (q(posix(tree)), q(posix(mk))),
                             'oc_tree_untouched %s %s; echo "m=$?"' % (q(posix(tree)), q(posix(sub / 'nope')))])
        rc, out, err = sh_run(script_ + '\n', sub, 't.sh')
        o = out.split()
        check('安装树：%s' % name, ('r=%d' % want) in o, '%s 期望 r=%d；stderr=%s' % (o, want, err[:100]))
        if label == 'clean':
            check('标记文件不存在 -> 取不到结论，返回非 0', 'm=1' in o, o)

# ---------------------------------------------------------------- 行为：网络失败判定 / 换源
with tempfile.TemporaryDirectory() as td:
    d = pathlib.Path(td)
    L = [
        ('reset', 'npm http fetch GET 200 https://registry.npmjs.org/a 100ms\n'
                  'npm error code ECONNRESET\nnpm error network aborted\n', 0),
        ('onlyaborted', 'npm error network aborted\n', 0),
        ('e404', 'npm error code E404\nnpm error 404 Not Found - GET https://x/y\n', 1),
        ('fetchfailed', 'npm error fetch failed\nnpm error request to https://x/y failed\n', 1),
        ('ctx', 'npm error code E404\nnpm error network This is a problem related to fetch failed maybe\n', 1),
        ('wordonly', 'npm warn got ECONNRESET once\nnpm error code ELIFECYCLE\n', 1),
        ('early', 'npm error code ECONNRESET\n' + 'npm error context line\n' * 80, 0),
        ('none', '', 1),
    ]
    lines = ['#!/bin/sh', FNS]
    for k, text, _w in L:
        f = d / (k + '.log')
        f.write_text(text, encoding='utf-8')
        lines.append('npm_net_fail %s; echo "%s=$?"' % (q(posix(f)), k))
    lines.append('npm_net_fail %s; echo "missing=$?"' % q(posix(d / 'nofile')))
    lines.append('echo "alt1=$(npm_alt_registry https://registry.npmjs.org)"')
    lines.append('echo "alt2=$(npm_alt_registry https://registry.npmmirror.com)"')
    lines.append('echo "alt3=[$(npm_alt_registry https://npm.example.com)]"')
    rc, out, err = sh_run('\n'.join(lines) + '\n', d, 'net.sh')
    o = out.split()
    for k, _t, want in L:
        check('网络判定 %s -> %s' % (k, '重试' if want == 0 else '不重试'), ('%s=%d' % (k, want)) in o, o)
    check('日志文件不存在 -> 不重试', 'missing=1' in o, o)
    check('换源：官方 -> npmmirror', 'alt1=https://registry.npmmirror.com' in o, o)
    check('换源：npmmirror -> 官方', 'alt2=https://registry.npmjs.org' in o, o)
    check('换源：用户自建源不替他换', 'alt3=[]' in o, o)

# ---------------------------------------------------------------- 行为：重试循环
RETRY_FN = FNS + '\n' + func(ins, 'npm_registry_has') + '\n' + func(ins, 'npm_install_retry')
STUB = r'''
ilog() { printf '%s\n' "$*" >>"$ILOG"; }
sleep() { :; }
# npm_registry_has 的底座是 oc_timeout：用 ALT_HAS 控制备用源上有没有这个版本
oc_timeout() { return "$ALT_HAS"; }
run_with_heartbeat() {
	_n=$((_n + 1))
	_reg=""
	_prev=""
	for _a in "$@"; do
		case "$_prev" in --registry) _reg="$_a" ;; esac
		_prev="$_a"
	done
	printf '%s\n' "$_reg" >>"$REGS"
	_rc="$(printf '%s' "$RC_LIST" | cut -d' ' -f$_n)"
	_err="$(printf '%s' "$ERR_LIST" | cut -d'|' -f$_n)"
	# stdout 被函数重定向到「这一次尝试」的日志
	case "$_err" in ''|'|') ;; *) printf '%b\n' "$_err" ;; esac
	case "$_rc" in ''|*[!0-9]*) _rc=1 ;; esac
	return "$_rc"
}
_n=0
'''
JS = 'https://registry.npmjs.org'
NM = 'https://registry.npmmirror.com'
CX = 'https://npm.example.com'
FILLER = 'npm error code ECONNRESET\n' + 'npm error context line\n' * 80
E = 'npm error code ECONNRESET'
# 名称, RC_LIST, ERR_LIST, reg, start_ts 偏移(None=无效), ALT_HAS,
# 期望 (rc, attempts, reg_used), 期望提示条数, 期望合并后错误码行数
RETRY = [
    ('真机：两次 ECONNRESET，换源后成功', '1 1 0', E + '|' + E + '|', JS, 0, 0, ('0', '3', NM), 1, 2),
    ('第 2 次就成功，不换源', '1 0', 'npm error code ETIMEDOUT|', JS, 0, 0, ('0', '2', JS), 0, 1),
    ('三次都网络失败 -> 如实失败，不无限重试', '1 1 1', E + '|' + E + '|' + E, JS, 0, 0,
     ('1', '3', NM), 1, 3),
    ('E404 不是网络问题 -> 不重试', '1', 'npm error code E404', JS, 0, 0, ('1', '1', JS), 0, 1),
    ('只有 fetch failed、没有网络错误码 -> 不重试（不误判）', '1', 'npm error fetch failed', JS, 0, 0,
     ('1', '1', JS), 0, 0),
    ('超时(124) -> 不重试', '124', '', JS, 0, 0, ('124', '1', JS), 0, 0),
    ('被 OOM 杀掉(137) -> 不重试', '137', '', JS, 0, 0, ('137', '1', JS), 0, 0),
    ('被中止(143) -> 不重试', '143', '', JS, 0, 0, ('143', '1', JS), 0, 0),
    ('用户自建源：连续失败也不替他换源', '1 1 0', E + '|' + E + '|', CX, 0, 0, ('0', '3', CX), 1, 2),
    ('剩余时间不足 -> 不再起新一轮', '1', E, JS, 1790, 0, ('1', '1', JS), 1, 1),
    ('配置的就是镜像：失败后换回官方', '1 1 0', E + '|' + E + '|', NM, 0, 0, ('0', '3', JS), 1, 2),
    ('备用源上没有这个版本 -> 不换源', '1 1 0', E + '|' + E + '|', JS, 0, 1, ('0', '3', JS), 1, 2),
    ('算不出剩余时间(start_ts 无效) -> 不重试并说明', '1', E, JS, None, 0, ('1', '1', JS), 1, 1),
    ('第 2 次是 E404：只按这一次的日志判定，立即停止', '1 1', E + '|npm error code E404', JS, 0, 0,
     ('1', '2', JS), 0, 2),
    ('网络报错在长日志开头（60 行以外）-> 仍然判得出', '1 0', FILLER + '|', JS, 0, 0, ('0', '2', JS), 0, 1),
]
with tempfile.TemporaryDirectory() as td:
    d = pathlib.Path(td)
    for idx, (name, rcs, errs, reg, ago, alt_has, (w_rc, w_att, w_reg), w_note, w_merged) in enumerate(RETRY):
        sub = d / ('r%d' % idx)
        sub.mkdir()
        npm_log = sub / 'npm.log'
        npm_log.write_text('', encoding='utf-8')
        st = 'start_ts=0' if ago is None else 'start_ts=$(( $(date +%%s) - %d ))' % ago
        lines = [
            '#!/bin/sh', RETRY_FN, STUB,
            'ILOG=' + q(posix(sub / 'ilog')),
            'REGS=' + q(posix(sub / 'regs')),
            'npm_log=' + q(posix(npm_log)),
            ': >"$ILOG"; : >"$REGS"',
            'reg=' + q(reg),
            # 桩按「第几次尝试」返回预设的退出码与报错文本
            'RC_LIST=' + q(rcs),
            'ERR_LIST=' + q(errs),
            'ALT_HAS=%d' % alt_has,
            'allow_scripts=""',
            'OC_DIR=/tmp/oc; OCV=2026.11.10; NPM_INSTALL_TIMEOUT=1800; NODE_BIN=node; npmcli=npm',
            st,
            'npm_install_retry',
            # 下面几行不做 % 格式化，所以是单个 %s
            'printf "RES=%s|%s|%s\\n" "$NPM_RC" "$NPM_ATTEMPTS" "$NPM_REG_USED"',
            'printf "REGS=%s\\n" "$(tr "\\n" "," <"$REGS")"',
            'printf "NOTE=%s\\n" "$(grep -c "换源重试\\|无可用的备用源\\|剩余时间不足\\|无法计算剩余时间" "$ILOG")"',
            'printf "MERGED=%s\\n" "$(grep -c "npm error code" "$npm_log")"',
            'printf "LEFT=%s\\n" "$(ls "$npm_log".attempt* 2>/dev/null | wc -l | tr -d " ")"',
        ]
        rc, out, err = sh_run('\n'.join(lines) + '\n', d, 'retry%d.sh' % idx)
        o = dict((l.split('=', 1)[0], l.split('=', 1)[1]) for l in out.splitlines() if '=' in l)
        want = '%s|%s|%s' % (w_rc, w_att, w_reg)
        check('重试循环：%s' % name, o.get('RES') == want,
              '得到 %s，期望 %s；stderr=%s' % (o.get('RES'), want, err[:200]))
        check('  └ 提示与日志：%s' % name,
              o.get('NOTE') == str(w_note) and o.get('MERGED') == str(w_merged) and o.get('LEFT') == '0',
              'NOTE=%s(期望 %s) MERGED=%s(期望 %s) LEFT=%s' % (
                  o.get('NOTE'), w_note, o.get('MERGED'), w_merged, o.get('LEFT')))
        if idx == 0:
            check('真机场景：三次尝试用的源依次是 官方/官方/镜像',
                  o.get('REGS') == '%s,%s,%s,' % (JS, JS, NM), o)
        if idx == 11:
            check('备用源没有该版本：三次都留在原源',
                  o.get('REGS') == '%s,%s,%s,' % (JS, JS, JS), o)

# ---------------------------------------------------------------- 行为：die() 恢复网关
DIE_FN = func(ins, 'die')
U, T_, N, C, P = 'untouched', 'touched', 'no-marker', 'ver-changed', 'pre-unknown'
DIE = [
    ('停过网关 + 安装树零改动 + 版本一致 -> 重新启动', '1', U, '2026.11.8', 'start', '没有任何改动'),
    ('停过网关 + 安装树被 npm 动过 -> 不启动，只告警', '1', T_, '2026.11.8', '', '未自动启动网关'),
    ('停过网关 + 没有升级标记（取不到结论）-> 不启动', '1', N, '2026.11.8', '', '未自动启动网关'),
    ('停过网关 + 程序版本已变 -> 不启动，只告警', '1', C, '2026.11.8', '', '未自动启动网关'),
    ('停过网关 + 不知道升级前是哪个版本 -> 不启动', '1', P, '2026.11.8', '', '未自动启动网关'),
    ('没停过网关（早期失败）-> 不碰服务', '0', U, '2026.11.8', '', ''),
]
with tempfile.TemporaryDirectory() as td:
    d = pathlib.Path(td)
    for idx, (name, flag, mode, pre_ver, want_start, want_log) in enumerate(DIE):
        sub = d / ('d%d' % idx)
        ocdir = sub / 'oc'
        (ocdir / 'lib/node_modules/openclaw').mkdir(parents=True)
        (ocdir / 'bin').mkdir()
        pkg = ocdir / 'lib/node_modules/openclaw/package.json'
        pkg.write_text('{"version": "2026.11.8"}', encoding='utf-8')
        binf = ocdir / 'bin/openclaw'
        binf.write_text('#!/bin/sh\n', encoding='utf-8')
        binf.chmod(0o755)
        for p in [ocdir] + list(ocdir.rglob('*')):
            subprocess.run(['touch', '-t', '200001010000', str(p)], check=False)
        marker = sub / 'marker'
        marker.write_text('', encoding='utf-8')
        if mode == T_:
            # npm 在替换阶段动过：包目录的 mtime 变成「现在」，但 package.json 还是旧版本
            subprocess.run(['touch', str(ocdir / 'lib/node_modules')], check=False)
        if mode == C:
            pkg.write_text('{"version": "2026.11.10"}', encoding='utf-8')
            subprocess.run(['touch', '-t', '200001010000', str(pkg)], check=False)
        initd = sub / 'initd'
        initd.write_text('#!/bin/sh\necho "$1" >>"%s"\n' % posix(sub / 'started'), encoding='utf-8')
        initd.chmod(0o755)
        mk_line = 'OC_UPGRADE_MARKER=""' if mode == N else 'OC_UPGRADE_MARKER=' + q(posix(marker))
        lines = [
            '#!/bin/sh', FNS, DIE_FN,
            'hb_stop() { :; }',
            'oc_installed_version() { :; }',
            'ilog() { printf \'%%s\\n\' "$*" >>"%s"; }' % posix(sub / 'ilog'),
            mk_line,
            'OC_INITD=' + q(posix(initd)),
            'OC_DIR=' + q(posix(ocdir)),
            'OC_GW_WAS_RUNNING=%s' % flag,
            'OC_PRE_UPGRADE_VER=' + ('""' if mode == P else q(pre_ver)),
            'die "boom"',
        ]
        rc, out, err = sh_run('\n'.join(lines) + '\n', d, 'die%d.sh' % idx)
        started = (sub / 'started').read_text(encoding='utf-8').strip() if (sub / 'started').exists() else ''
        ilog = (sub / 'ilog').read_text(encoding='utf-8') if (sub / 'ilog').exists() else ''
        marker_left = marker.exists() and mode != N
        okk = rc == 1 and started == want_start and (want_log in ilog) and 'ERROR: boom' in ilog \
            and not marker_left
        check('die()：%s' % name, okk,
              'rc=%s started=%r log=%r 标记残留=%s stderr=%s' % (rc, started, ilog[:160], marker_left, err[:100]))

print('共 %d 项，失败 %d 项' % (total, len(fails)))
sys.exit(1 if fails else 0)
PYEOF
