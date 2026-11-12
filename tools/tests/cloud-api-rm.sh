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


NAMES = ('cloud_valid_remote_name', 'cloud_json_scalar', 'cloud_ls_tsv',
         'cloud_rm_list', 'cloud_rm_stat', 'cloud_rm_verify',
         'cloud_rm_attempt', 'cloud_api_conf', 'cloud_api_token',
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
check('token 校验字符集', "*[!A-Za-z0-9._~+/=-]*" in func('cloud_api_token'))
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
case "$sub" in
  help|--help) printf '%s\n' "$STUB_HELP" ;;
  ls)
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
        remote='openclaw-backups', config=None):
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
            'export STUB_HELP=' + repr('usage: bdpan <command>'),
            'export STUB_STATE=' + repr(posix(state_f)),
            'export STUB_RM_OUT=' + repr('unknown command'),
            'export STUB_RM_RC=' + repr('1'),
            'export STUB_TARGET=' + repr(TARGET),
            'export STUB_API=' + repr(api_mode),
            'export STUB_API_EFFECT=' + repr(str(api_effect)),
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
        argv = (d / 'argv.txt').read_text() if (d / 'argv.txt').exists() else ''
        conf = (d / 'conf.txt').read_text() if (d / 'conf.txt').exists() else ''
        data = (d / 'data.txt').read_text() if (d / 'data.txt').exists() else ''
        runtime = dict(argv=argv, conf=conf, data=data, dir=d,
                       conf_keep=(d / 'conf.keep').exists())
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

# 9. 凭据异常（含空格）-> 拒绝且不调用接口
run('凭据含非法字符 -> 拒绝', token='bad token with space',
    expect_rc=1, expect_err='凭据格式异常',
    extra_check=lambda r: (r['argv'] == '', '不应调用 curl'))


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
    if left:
        why.append('临时文件未清理：' + ','.join(left))
    return (not why), '; '.join(why)


run('token 不进 argv、只落 0600 配置、请求路径正确、用完即删',
    expect_rc=0, extra_check=sec_check)

print('共 %d 项，失败 %d 项' % (total, len(fails)))
sys.exit(1 if fails else 0)
PYEOF
