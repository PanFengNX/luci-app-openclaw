#!/bin/sh
# cloud-api-rm.sh — 云端删除的「开放平台接口」通道回归
#
# 背景：bdpan 3.8.9 的 help 里根本没有删除子命令（只有 whoami/ls/upload/
# download/transfer/share/version/init/update），所以 CLI 通道永远删不掉。
# 1.8.90 起在 CLI 三个候选都失败后落到网盘开放平台 filemanager 接口。
#
# 本用例用桩 curl 覆盖：成功 / 假成功（errno 0 但文件还在）/ 登录态失效 /
# 文件不存在 / 非 JSON 响应 / 网络失败 / 未登录 / 凭据异常；并静态检查
# token 不进 argv、只落 0600 配置文件、用完即删。
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

PROJ = pathlib.Path(sys.argv[1])
SRC = PROJ / 'root/usr/libexec/openclaw/cloud.sh'
src = SRC.read_text(encoding='utf-8') if SRC.exists() else ''
fails = []
total = 0


def check(name, cond, extra=''):
    global total
    total += 1
    print(('  ok   ' if cond else '  FAIL ') + name)
    if not cond:
        fails.append(name)
        if extra:
            print('       ' + extra[:200])


def func(name):
    i = src.find('\n' + name + '() {')
    if i < 0:
        return ''
    i += 1
    j = src.find('\n}\n', i)
    return src[i:j + 3] if j > i else ''


NAMES = ('cloud_valid_remote_name', 'cloud_json_scalar', 'cloud_json_deep',
         'cloud_json_keys', 'cloud_ls_tsv',
         'cloud_rm_list', 'cloud_rm_stat', 'cloud_rm_verify',
         'cloud_rm_attempt', 'cloud_api_conf', 'cloud_api_token',
         'cloud_api_cand_ok', 'cloud_api_probe', 'cloud_api_unwrap',
         'cloud_api_unwrap_binary',
         'cloud_api_delete', 'cloud_rm_remote')

# ---------------------------------------------------------------- 静态契约
check('新增 cloud_api_delete', func('cloud_api_delete') != '')
check('新增 cloud_api_token', func('cloud_api_token') != '')
api = func('cloud_api_delete')
check('走开放平台 filemanager 接口', 'method=filemanager' in api and 'opera=delete' in api)
check('请求带 User-Agent: pan.baidu.com', 'pan.baidu.com' in api)
check('凭据只经 -K 配置文件传递，不进 argv',
      '-K "$conf"' in api and 'access_token=$tok' in api
      and '--data-urlencode' in api and 'access_token=$tok"' not in api.split('--data-urlencode')[-1])
check('配置文件先 umask 077 再 chmod 600', 'umask 077' in api and 'chmod 600' in api)
check('用完立刻删除配置文件', 'rm -f "$conf"' in api)
check('token 校验字符集', "*[!A-Za-z0-9._~+/=-]*" in func('cloud_api_cand_ok'))
check('接口成功也要复验（不复用退出码当结论）',
      'cloud_rm_verify "$bin" "$name" "$before"' in func('cloud_rm_remote'))
check('CLI 失败后落到 API 通道', 'cloud_api_delete "$name"' in func('cloud_rm_remote'))
check('基线里没有目标时提前返回', '远端列表里没有' in func('cloud_rm_remote'))
check('不再谎报「当前 CLI 不支持删除」而不尝试删除',
      '当前 CLI 不支持删除' not in src)

HAVE_ALL = all(func(n) for n in NAMES)
BODY = '\n'.join(func(n) for n in NAMES)

BD = r'''#!/bin/sh
sub="$1"; shift
printf '%s\n' "$sub" >>"$STUB_CALLS"
case "$sub" in
  help|--help) printf '%s\n' "$STUB_HELP" ;;
  ls)
    # 复现真机现象：同一次操作里的第 N 次 ls 偶发非 0 退出。
    cnt=$(cat "$STUB_LS_COUNT" 2>/dev/null || echo 0)
    cnt=$((cnt + 1))
    printf '%s\n' "$cnt" >"$STUB_LS_COUNT"
    case ",${STUB_LS_FAIL_ON:-}," in
      *",$cnt,"*) printf 'Error: transient list failure #%s\n' "$cnt" >&2
        exit "${STUB_LS_EXIT:-1}" ;;
    esac
    n=0
    printf '['
    while IFS= read -r f || [ -n "$f" ]; do
      [ -n "$f" ] || continue
      n=$((n+1))
      [ "$n" -gt 1 ] && printf ','
      printf '{"server_filename":"%s","size":123}' "$f"
    done < "$STUB_STATE"
    printf ']'
    ;;
  rm|delete|remove)
    if [ "${STUB_RM_RC:-1}" = "0" ]; then
      awk -v t="$STUB_TARGET" '$0 != t' "$STUB_STATE" >"$STUB_STATE.n"
      [ -f "$STUB_STATE.n" ] && mv "$STUB_STATE.n" "$STUB_STATE"
    fi
    printf '%s\n' "$STUB_RM_OUT"
    exit "$STUB_RM_RC"
    ;;
esac
exit 0
'''

CURL = r'''#!/bin/sh
printf '%s\n' "$*" >"$STUB_ARGV"
conf=""; out=""; data=""
while [ $# -gt 0 ]; do
  case "$1" in
    -K) conf="$2"; shift 2 ;;
    -o) out="$2"; shift 2 ;;
    -w) shift 2 ;;
    --data-urlencode) data="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$conf" ] && cat "$conf" >"$STUB_CONF_DUMP" && cp "$conf" "$STUB_CONF_KEEP"
printf '%s' "$data" >"$STUB_DATA_DUMP"
# 1.8.94 起取凭据时会先用只读的 method=list 探测候选；这一步不能走删除桩，
# 否则会把状态文件里的目标提前删掉，后面的断言就全乱了。
if grep -q 'method=list' "$conf" 2>/dev/null; then
  # 探测不是删除：把 argv 记录清空，断言「有没有走到删除接口」才有意义。
  : >"$STUB_ARGV"
  printf '%s\n' probe >>"$STUB_CALLS"
  tok=$(sed -n 's/.*access_token=\([^"&]*\).*/\1/p' "$conf" | head -n 1)
  printf '%s\n' "$tok" >>"$STUB_PROBED"
  if [ -n "${STUB_GOOD_TOKEN:-}" ] && [ "$tok" != "$STUB_GOOD_TOKEN" ]; then
    printf '{"errno":-6,"errmsg":"invalid access token"}' >"$out"
    printf 'OC_HTTP:200'; exit 0
  fi
  printf '{"errno":0,"list":[]}' >"$out"
  printf 'OC_HTTP:200'; exit 0
fi
mode="${STUB_API:-ok}"
case "$mode" in
  ok)
    if [ "${STUB_API_EFFECT:-1}" = "1" ]; then
      awk -v t="$STUB_TARGET" '$0 != t' "$STUB_STATE" >"$STUB_STATE.n"
      mv "$STUB_STATE.n" "$STUB_STATE"
    fi
    printf '{"errno":0,"info":[{"errno":0}]}' >"$out"; printf 'OC_HTTP:200'; exit 0 ;;
  auth)
    printf '{"errno":-6,"errmsg":"invalid access token"}' >"$out"
    printf 'OC_HTTP:200'; exit 0 ;;
  gone)
    awk -v t="$STUB_TARGET" '$0 != t' "$STUB_STATE" >"$STUB_STATE.n"
    mv "$STUB_STATE.n" "$STUB_STATE"
    printf '{"errno":-7,"errmsg":"file not exist"}' >"$out"
    printf 'OC_HTTP:200'; exit 0 ;;
  html)
    printf '<html><body>502 Bad Gateway</body></html>' >"$out"
    printf 'OC_HTTP:502'; exit 0 ;;
  nohttp)
    if [ "${STUB_API_EFFECT:-1}" = "1" ]; then
      awk -v t="$STUB_TARGET" '$0 != t' "$STUB_STATE" >"$STUB_STATE.n"
      mv "$STUB_STATE.n" "$STUB_STATE"
    fi
    printf '{"errno":0}' >"$out"; exit 0 ;;
  json502)
    printf '{"errno":0,"info":[{"errno":0}]}' >"$out"
    printf 'OC_HTTP:502'; exit 0 ;;
  netfail)
    printf 'curl: (7) Failed to connect to pan.baidu.com' >&2
    printf 'OC_HTTP:000'; exit 7 ;;
esac
printf 'OC_HTTP:000'
exit 0
'''

TOKEN = 'TESTTOK_abcdef123456'
TARGET = 'openclaw-backup-20261111-000000.tar.gz.enc'
OTHER = 'openclaw-backup-20261110-000000.tar.gz.enc'


def run(name, api_mode='ok', api_effect=1, state=None, token=TOKEN,
        fmt_ok=True, expect_rc=None, expect_err=None, extra_check=None,
        remote='openclaw-backups', config=None, ls_fail_on='', help_text=None,
        expect_not_err=None, ls_exit=1, calls_expect=None, rm_rc=1,
        good_token=None):
    if not HAVE_ALL:
        check(name + '（缺函数，判失败）', False)
        return
    state = state if state is not None else (TARGET + '\n' + OTHER + '\n')
    with tempfile.TemporaryDirectory() as td:
        d = pathlib.Path(td)
        bd = d / 'bdpan'
        cu = d / 'curl'
        state_f = d / 'state.txt'
        bd.write_bytes(BD.encode())
        cu.write_bytes(CURL.encode())
        bd.chmod(0o755)
        cu.chmod(0o755)
        state_f.write_bytes(state.encode())
        home = d / 'home'
        (home / '.config/bdpan').mkdir(parents=True, exist_ok=True)
        if config is not None:
            (home / '.config/bdpan/config.json').write_bytes(config.encode())
        elif token is not None:
            (home / '.config/bdpan/config.json').write_bytes(
                ('{"access_token":"%s","refresh_token":"r"}' % token).encode())
        posix = lambda p: str(p).replace('\\', '/')
        # PATH 里的条目必须是 MSYS 形式（/c/...），Windows 形式 C:/... 在
        # sh 里不会被当成 PATH 目录，桩 curl 就会被真实 curl 顶掉。
        def mspath(p):
            t = posix(p)
            if len(t) > 2 and t[1] == ':' and t[0].isalpha():
                t = '/' + t[0].lower() + t[2:]
            return t

        judge = d / 'judge.sh'
        lines = [
            '#!/bin/sh',
            'export OC_RUNDIR=' + repr(posix(d)),
            'export OC_CLOUD_HOME=' + repr(posix(home)),
            'OC_CLOUD_REMOTE=' + repr(remote),
            'PATH="' + mspath(d) + ':$PATH"',
            'export PATH',
            'export STUB_HELP=' + repr(help_text or 'usage: bdpan <command>'),
            'export STUB_CALLS=' + repr(posix(d / 'calls.txt')),
            'export STUB_LS_COUNT=' + repr(posix(d / 'ls-count.txt')),
            'export STUB_LS_FAIL_ON=' + repr(ls_fail_on),
            'export STUB_LS_EXIT=' + repr(str(ls_exit)),
            'export STUB_RM_RC=' + repr(str(rm_rc)),
            'export STUB_STATE=' + repr(posix(state_f)),
            'export STUB_RM_OUT=' + repr('unknown command'),
            'export STUB_TARGET=' + repr(TARGET),
            'export STUB_API=' + repr(api_mode),
            'export STUB_API_EFFECT=' + repr(str(api_effect)),
            'export STUB_GOOD_TOKEN=' + repr(good_token or ''),
            'export STUB_PROBED=' + repr(posix(d / 'probed.txt')),
            'export STUB_ARGV=' + repr(posix(d / 'argv.txt')),
            'export STUB_CONF_DUMP=' + repr(posix(d / 'conf.txt')),
            'export STUB_CONF_KEEP=' + repr(posix(d / 'conf.keep')),
            'export STUB_DATA_DUMP=' + repr(posix(d / 'data.txt')),
            'cloud_run() { t="$1"; shift; "$@"; }',
            'cloud_bin_ready() { printf %s ' + repr(posix(bd)) + '; }',
            'cloud_redact() { cat; }',
            'oc_cut_utf8() { head -c "${1:-800}"; }',
            'oc_timeout() { shift; "$@"; }',
            BODY,
            'cloud_rm_remote ' + repr(TARGET),
            'rc=$?',
            'printf "RC=%s\\nERR=%s\\n" "$rc" "$OC_RM_ERR"',
        ]
        judge.write_bytes(('\n'.join(lines) + '\n').encode())
        judge.chmod(0o755)
        p = subprocess.run(['sh', str(judge)], capture_output=True, text=True,
                           timeout=180)
        out = p.stdout
        rc = None
        for line in out.splitlines():
            if line.startswith('RC='):
                try:
                    rc = int(line[3:])
                except ValueError:
                    pass
        err = out.split('ERR=', 1)[1] if 'ERR=' in out else ''
        good = True
        if expect_rc is not None:
            good = good and rc == expect_rc
        if expect_err is not None:
            good = good and expect_err in err
        if expect_not_err is not None and expect_not_err in err:
            good = False
            err = err + ' | 不该出现：' + expect_not_err
        argv = (d / 'argv.txt').read_text() if (d / 'argv.txt').exists() else ''
        conf = (d / 'conf.txt').read_text() if (d / 'conf.txt').exists() else ''
        data = (d / 'data.txt').read_text() if (d / 'data.txt').exists() else ''
        calls_f = d / 'calls.txt'
        calls = calls_f.read_text().split() if calls_f.exists() else []
        runtime = dict(argv=argv, conf=conf, data=data, dir=d, calls=calls,
                       conf_keep=(d / 'conf.keep').exists())
        if calls_expect is not None and calls != calls_expect:
            good = False
            err = err + ' | calls=%s 期望 %s' % (' '.join(calls), ' '.join(calls_expect))
        if extra_check:
            ok2, why = extra_check(runtime)
            good = good and ok2
            if not ok2:
                err = err + ' | ' + why
        check(name, good, 'RC=%s ERR=%s' % (rc, err.strip()))


# 1. 主路径：CLI 不会删 -> API 删除 + 复验通过
run('CLI 无删除能力 -> API 通道删除成功', expect_rc=0)

# 2. 接口说成功但文件还在 -> 不得报成功
run('接口返回 0 但远端仍在 -> 报假成功', api_effect=0,
    expect_rc=1, expect_err='返回成功，但远端仍有该文件')

# 3. 登录态失效 -> 明确提示重新登录
run('接口返回 -6 -> 提示登录态失效', api_mode='auth',
    expect_rc=1, expect_err='登录态已失效')

# 5. 非 JSON 响应 -> 不谎报成功
run('接口返回 HTML 502 -> 报无法识别', api_mode='html',
    expect_rc=1, expect_err='HTTP 502')

# 6b. HTTP 非 2xx 但 body 是合法 JSON errno:0 -> 绝不能按成功处理
run('HTTP 502 + body errno 0 -> 不按成功处理', api_mode='json502',
    expect_rc=1, expect_err='HTTP 502')

# 6c. 远端目录名为空/非法 -> 拒绝拼接，且不调用接口
run('云端目录名为空 -> 拒绝', remote='',
    expect_rc=1, expect_err='目录名不合法',
    extra_check=lambda r: (r['argv'] == '', '不应调用 curl'))

# 6d. 取不到 HTTP 状态码（-w 落点异常）但文件确实删掉了 -> 以复验为准判成功
run('取不到 HTTP 状态码但文件已消失 -> 成功', api_mode='nohttp',
    api_effect=1, expect_rc=0)

# 6e. 远端目录名为 .. -> 必须拒绝（白名单不能放行上级目录）
run('云端目录名为 .. -> 拒绝', remote='..',
    expect_rc=1, expect_err='目录名不合法',
    extra_check=lambda r: (r['argv'] == '', '不应调用 curl'))

# 7. 未登录（没有 config.json）-> 提示登录，且不执行删除
run('没有登录配置 -> 提示先登录', token=None,
    expect_rc=1, expect_err='登录配置',
    extra_check=lambda r: (r['argv'] == '', '不应调用 curl'))

# 7b. 登录配置文件是空的 -> 明确提示，别报成「未登录」
run('登录配置为空文件 -> 明确提示', config='',
    expect_rc=1, expect_err='配置是空的')

# 8. 目标不在基线里 -> 提前返回，不做无用请求
run('基线里没有目标 -> 直接报错', state=OTHER + '\n',
    expect_rc=1, expect_err='远端列表里没有',
    extra_check=lambda r: (r['argv'] == '', '不应调用接口'))

# 8b. 凭据放在子对象里（真机就是这样）-> 必须也能取到并走通接口
run('凭据在子对象 tokens 里 -> 仍能删除',
    config='{"tokens":{"access_token":"' + TOKEN + '","refresh_token":"r"}}',
    expect_rc=0)

# 8c. 配置里根本没有凭据字段 -> 明确说「取不到 access_token」并列出字段名
run('配置里没有凭据字段 -> 报字段名清单',
    config='{"app_id":"x","uid":123}',
    expect_rc=1, expect_err='现有字段：app_id,uid',
    extra_check=lambda r: (r['argv'] == '', '不应调用接口'))

# 8d. 值被多包了一层引号 -> 剥一层后应可用（不误判成「格式异常」）
run('凭据被多包一层引号 -> 仍能删除',
    config='{"access_token":"\\"' + TOKEN + '\\""}',
    expect_rc=0)

# 8e. 值带 enc: 前缀 -> 把冒号后那一段拆出来探测，可用就继续删
run('凭据带 enc: 前缀 -> 拆出后半段后成功',
    config='{"access_token":"enc:' + TOKEN + '"}',
    good_token=TOKEN, expect_rc=0)

# 8e2. 拆出来的候选网盘都不认 -> 明确说「试了几个都被拒绝」
run('候选都被网盘拒绝 -> 报凭据不可用',
    config='{"access_token":"enc:deadbeefdeadbeef"}',
    good_token=TOKEN, expect_rc=1,
    expect_err='网盘登录凭据不可用',
    extra_check=lambda r: (r['argv'] == '', '不应走到删除接口'))

# 8f. 值太短（例如取到 null 之类）-> 报长度与字段名
run('凭据过短 -> 报长度与字段名',
    config='{"access_token":"null"}',
    expect_rc=1, expect_err='取自字段 access_token，长度 4',
    extra_check=lambda r: (r['argv'] == '', '不应调用接口'))

# 8g. 值是 v1:<base64(JSON)> -> 解开后拿到真 token 并成功删除
run('凭据是 v1:base64(JSON) 包装 -> 解开后成功',
    config='{"access_token":"v1:eyJhY2Nlc3NfdG9rZW4iOiAiVEVTVFRPS19hYmNkZWYxMjM0NTYifQ=="}',
    good_token=TOKEN, expect_rc=0)

# 8h. 值是 v1:<base64(密文)> -> 说清「加密保存」，并给出可执行的替代做法
run('凭据是加密包 -> 提示去网盘 App 删',
    config='{"access_token":"v1:AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8gISIjJCUmJw=="}',
    expect_rc=1, expect_err='加密保存',
    good_token=TOKEN,
    extra_check=lambda r: (r['argv'] == '', '不应走到删除接口'))

# 9. 凭据异常（含空格）-> 拒绝且不调用接口
run('凭据含非法字符 -> 拒绝', token='bad token with space',
    expect_rc=1, expect_err='凭据格式异常',
    extra_check=lambda r: (r['argv'] == '', '不应调用 curl'))


# ---------------------------------------------------------------- 1.8.91 新契约
# help 里没有任何删除命令时，不该再跑 rm/delete/remove 三个注定失败的候选：
# 真机上它们只会刷出「unknown command」，还叠加三次列表读取。
run('help 无删除命令 -> 不调用 CLI 候选，直接走接口',
    expect_rc=0,
    extra_check=lambda r: (not [c for c in r['calls']
                                if c in ('rm', 'delete', 'remove')],
                           '不应调用 CLI 删除候选：' + ' '.join(r['calls'])))

# CLI 自报有 delete 时仍应按候选尝试（别的 bdpan 版本可能真有）
run('help 有 delete -> 仍先试 CLI 候选',
    help_text='usage: bdpan <command>\n  delete   remove a file',
    expect_rc=0,
    extra_check=lambda r: ('delete' in r['calls'],
                           '应尝试 CLI 的 delete：' + ' '.join(r['calls'])))

# 真机故障复现：删除后那一次 ls 失败一次 -> **仅靠重试**就要判成功。
# 断言不调用接口，否则「接口兜底」也能凑出 rc=0，这条就测不到重试本身。
run('复验那一次 ls 瞬时失败 -> 仅靠重试判成功（CLI 已删）',
    help_text='usage: bdpan <command>\n  delete   remove a file',
    rm_rc=0, ls_fail_on='2', expect_rc=0,
    extra_check=lambda r: (r['argv'] == '',
                           '不该走到接口通道；calls=' + ' '.join(r['calls'])))

# ls 被 timeout 杀掉（124）-> 不重试：重试只会让页面多等一个超时周期
run('ls 超时 -> 不重试、直接报超时',
    ls_fail_on='1,2', ls_exit=124, expect_rc=1, expect_err='超时',
    calls_expect=['ls'],
    extra_check=lambda r: (r['argv'] == '', '不应调用接口'))

# 基线 ls 两次都失败 -> 不执行删除，也不调用接口
run('基线 ls 连续失败 -> 未执行删除',
    ls_fail_on='1,2', expect_rc=1, expect_err='无法读取远端列表确认结果',
    extra_check=lambda r: (r['argv'] == '', '不应调用接口'))

# 接口成功但复验两次都读不到列表 -> 文案说清「接口已成功、无法确认」，
# 且不能掺进 CLI 的 unknown command（真机就是这么误报的）
run('接口成功但复验读不到列表 -> 文案不掺 CLI 噪声',
    ls_fail_on='2,3', expect_rc=1,
    expect_err='网盘删除接口返回成功，但列表读不到',
    expect_not_err='unknown command',
    extra_check=lambda r: (r['argv'] != '', '接口通道应被调用'))

# arc=2（CLI 之后读不到列表）也必须继续走接口，否则这台设备永远删不掉
run('CLI 复验读不到列表 -> 仍走接口通道并成功',
    help_text='usage: bdpan <command>\n  delete   remove a file',
    ls_fail_on='2,3', expect_rc=0,
    extra_check=lambda r: ('delete' in r['calls'] and r['argv'] != '',
                           '应既试 CLI 又走接口：' + ' '.join(r['calls'])))

# ---------------------------------------------------------------- 安全断言
def sec_check(r):
    why = []
    if not r['argv']:
        why.append('没有记录到 curl 调用')
    if TOKEN in r['argv']:
        why.append('token 出现在 argv')
    if 'access_token=' + TOKEN not in r['conf']:
        why.append('配置文件里没有 access_token')
    if 'method=filemanager' not in r['conf'] or 'opera=delete' not in r['conf']:
        why.append('配置文件缺少 filemanager/opera=delete')
    if 'pan.baidu.com' not in r['conf']:
        why.append('请求目标不是 pan.baidu.com')
    want = '/apps/bdpan/openclaw-backups/' + TARGET
    if want not in r['data']:
        why.append('filelist 路径不对：' + r['data'][:80])
    left = [x.name for x in r['dir'].glob('.xpan-rm.*')]
    left += [x.name for x in r['dir'].glob('.xpan-probe.*')]
    if left:
        why.append('临时文件未清理：' + ','.join(left))
    return (not why), '; '.join(why)


run('token 不进 argv、只落 0600 配置、请求路径正确、用完即删',
    expect_rc=0, extra_check=sec_check)

print('共 %d 项，失败 %d 项' % (total, len(fails)))
sys.exit(1 if fails else 0)
PYEOF
