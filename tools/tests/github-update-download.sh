#!/bin/sh
# github-update-download.sh — 插件自更新「下载源」回归
#
# 现场问题：设备检查更新正常（api.github.com 可达），但包体在
# github.com/releases/download，报「域名解析失败 / TLS 握手失败」，于是永远
# 装不上。修复后按 直连 -> API 资产接口 -> 镜像 依次尝试。
#
# 这里用桩 api_get 验证「顺序、每个源的 URL/Accept、失败原因汇总、重试边界」，
# 不去真连网络：可复现、不受网关状态影响。
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
PROJ="$(cd "$HERE/../.." && pwd)"
PY=""
for cand in python3 python "${HOME:-}/.workbuddy/binaries/python/versions/3.13.12/python.exe"; do
	if command -v "$cand" >/dev/null 2>&1 || [ -x "$cand" ]; then PY="$cand"; break; fi
done
[ -n "$PY" ] || { echo "    跳过：找不到 python"; exit 0; }
"$PY" - "$PROJ" <<'PYEOF'
import os
import pathlib
import re
import subprocess
import sys
import tempfile

proj = pathlib.Path(sys.argv[1])
NL = chr(10)
gh = (proj / 'root/usr/libexec/openclaw/github-update.sh').read_text(encoding='utf-8')
lib = (proj / 'root/usr/libexec/openclaw/lib.sh').read_text(encoding='utf-8')
work = pathlib.Path(tempfile.mkdtemp(prefix='oc-dl-'))

total = 0
failed = 0


def check(ok, desc, detail=''):
    global total, failed
    total += 1
    print('    %s  %s%s' % ('ok  ' if ok else 'FAIL', desc, ('  ' + detail) if detail else ''))
    if not ok:
        failed += 1


def func(src, name):
    lines = src.splitlines()
    starts = [(i, m.group(1)) for i, line in enumerate(lines)
              for m in [re.match(r'^([a-z_][a-z0-9_]*)\(\)\s*\{', line)] if m]
    for pos, (line_no, found) in enumerate(starts):
        if found == name:
            end = starts[pos + 1][0] if pos + 1 < len(starts) else len(lines)
            return NL.join(lines[line_no:end])
    raise AssertionError('取不到函数 ' + name)


def P(path):
    s = pathlib.Path(path).as_posix()
    return '/c' + s[2:] if len(s) > 1 and s[1] == ':' else s


REPO = 'PanFengNX/luci-app-openclaw'
DIRECT = 'https://github.com/%s/releases/download/luci-app-openclaw-1.8.88-r1.apk' % REPO
API_ASSET = 'https://api.github.com/repos/%s/releases/assets/12345' % REPO
MIRRORS = ['https://m1.test/', 'https://m2.test/', 'https://m3.test/']

judge_lines = [
    '#!/bin/sh',
    'GH_REPO=' + REPO,
    'GH_DL_PREFIX="https://github.com/%s/releases/download/"' % REPO,
    "ACCEPT_JSON='application/vnd.github+json'",
    "ACCEPT_BIN='application/octet-stream'",
    'PKG_TIMEOUT=1',
    "GH_MIRRORS_DEFAULT='%s'" % ' '.join(MIRRORS),
    'msg() { printf "MSG %s\\n" "$*"; }',
    'oc_err() { :; }',
    'uci_get() { printf %s "${UCI_MIRROR-}"; }',
    func(lib, 'oc_safe_url'),
    func(gh, '_mirror_ok'),
    func(gh, 'update_mirror_get'),
    func(gh, '_dl_url_ok'),
    func(gh, 'ver_norm'),
    func(gh, 'version_ok'),
    # api_get 桩：把每次尝试的 Accept 与实际 URL 记进 $TRACE；只有命中
    # $OK_PAT 的 URL 才"下载成功"。
    'api_get() {',
    '  printf "%s|%s\\n" "${4:-$ACCEPT_JSON}" "$1" >>"$TRACE"',
    '  if [ -n "${OK_PAT-}" ]; then',
    '    case "$1" in',
    '      $OK_PAT) printf x >"$2"; API_GET_RC=0; API_GET_ERR=""; return 0 ;;',
    '    esac',
    '  fi',
    '  API_GET_RC="${FAIL_RC:-22}"',
    '  API_GET_ERR="${FAIL_TXT:-HTTP 错误}"',
    '  return 1',
    '}',
    func(gh, '_dl_one'),
    func(gh, 'dl_try'),
    func(gh, 'do_install'),
    'case "${MODE:-}" in',
    'mirror-list) update_mirror_get ;;',
    'url-ok)',
    '  while IFS= read -r u; do',
    '    if _dl_url_ok "$u"; then printf "ACCEPT %s\\n" "$u"; else printf "REJECT %s\\n" "$u"; fi',
    '  done <<EOF2',
    '$URLS',
    'EOF2',
    '  ;;',
    'mirror-ok)',
    '  while IFS= read -r u; do',
    '    if _mirror_ok "$u"; then printf "ACCEPT %s\\n" "$u"; else printf "REJECT %s\\n" "$u"; fi',
    '  done <<EOF2',
    '$URLS',
    'EOF2',
    '  ;;',
    'dl)',
    '  if dl_try "$DEST" "$FURL" "${AID-}"; then printf "OK %s\\n" "$DL_SRC"; else printf "FAIL %s\\n" "$DL_ERR"; fi',
    '  ;;',
    'stale)',
    '  CANDIDATE_FILE="$CAND"',
    '  CONFIRM_ID=abcdef0123456789',
    '  do_install',
    '  exit $?',
    '  ;;',
    '*) printf "BAD MODE\\n"; exit 9 ;;',
    'esac',
]

judge = work / 'judge.sh'
judge.write_bytes((NL.join(judge_lines) + NL).encode('utf-8'))
judge.chmod(0o755)

seq = [0]


def run(mode, extra=None, urls=None):
    seq[0] += 1
    trace = work / ('trace-%d' % seq[0])
    trace.write_bytes(b'')
    env = {
        'PATH': '/usr/bin:/bin',
        'MODE': mode,
        'TRACE': P(trace),
    }
    if extra:
        for k, v in extra.items():
            if v is not None:
                env[k] = str(v)
    if urls is not None:
        env['URLS'] = NL.join(urls)
    r = subprocess.run(['sh', P(judge)], capture_output=True, text=True, env=env, timeout=90)
    trace_txt = trace.read_text(encoding='utf-8') if trace.exists() else ''
    return r, [x for x in trace_txt.splitlines() if x]


def plain(r):
    """去掉桩 msg 的 MSG 行，只留算子输出。"""
    return NL.join([x for x in (r.stdout or '').splitlines() if not x.startswith('MSG ')])


def msgs(r):
    return [x[4:] for x in (r.stdout or '').splitlines() if x.startswith('MSG ')]


# ---------------------------------------------------------------- 镜像配置
r, _ = run('mirror-list')
check(plain(r).splitlines() == MIRRORS, '未配置时按内置镜像顺序展开', plain(r))

r, _ = run('mirror-list', {'UCI_MIRROR': 'off'})
check(plain(r) == '' and not msgs(r), 'main.update_mirror=off 时完全不用镜像', plain(r))

r, _ = run('mirror-list', {'UCI_MIRROR': 'https://only.test'})
check(plain(r).splitlines() == ['https://only.test/'], '自定义镜像缺少末尾 / 时自动补齐', plain(r))

r, _ = run('mirror-list', {'UCI_MIRROR': 'https://only.test/?a=1'})
check(plain(r) == '' and any('不合法' in m for m in msgs(r)),
      '镜像地址带查询串被拒绝并记日志', ' | '.join(msgs(r)))

# ---------------------------------------------------------------- 前缀校验
mirror_ok_cases = [
    ('https://a.test/', True),
    ('https://a.test/sub/', True),
    ('http://a.test/', False),
    ('https://a.test/ x', False),
    ('https://a.test/?x', False),
    ('https://a.test/#x', False),
    ("https://a.test/'", False),
    ('https://a.test/$x', False),
    ('https://a.test/`x`', False),
    ('ftp://a.test/', False),
]
r, _ = run('mirror-ok', urls=[c[0] for c in mirror_ok_cases])
got = {}
for ln in plain(r).splitlines():
    v, _, u = ln.partition(' ')
    got[u] = v
bad = [(u, exp) for u, exp in mirror_ok_cases if got.get(u) != ('ACCEPT' if exp else 'REJECT')]
check(not bad, '镜像前缀只接受干净的 https 前缀', ' '.join('%s期望%s实际%s' % (u, exp, got.get(u)) for u, exp in bad))

# ---------------------------------------------------------------- 下载地址白名单
url_cases = [
    (DIRECT, True),
    (API_ASSET, True),
    (MIRRORS[0] + DIRECT, True),
    ('https://evil.test/' + DIRECT, False),
    ('https://api.github.com/repos/other/repo/releases/latest', False),
    ('http://github.com/%s/releases/download/x.apk' % REPO, False),
    ('https://github.com/other/repo/releases/download/x.apk', False),
]
r, _ = run('url-ok', urls=[c[0] for c in url_cases])
got = {}
for ln in plain(r).splitlines():
    v, _, u = ln.partition(' ')
    got[u] = v
bad = [(u, exp) for u, exp in url_cases if got.get(u) != ('ACCEPT' if exp else 'REJECT')]
check(not bad, '只放行固定仓库地址或"已校验前缀 + 固定仓库地址"',
      ' '.join('%s期望%s实际%s' % (u, exp, got.get(u)) for u, exp in bad))

# ---------------------------------------------------------------- 下载顺序
dest = work / 'pkg.download'

r, tr = run('dl', {'DEST': P(dest), 'FURL': DIRECT, 'AID': None, 'OK_PAT': DIRECT})
check(plain(r).startswith('OK ') and 'GitHub 直连' in plain(r) and len(tr) == 1 and tr[0] == 'application/vnd.github+json|' + DIRECT,
      '直连可用时只尝试一次', plain(r) + ' trace=' + repr(tr))

r, tr = run('dl', {'DEST': P(dest), 'FURL': DIRECT, 'AID': '12345', 'OK_PAT': '*/releases/assets/*'})
check(plain(r).startswith('OK ') and 'API 资产接口' in plain(r), '直连失败后走 API 资产接口', plain(r))
check(len(tr) == 2 and tr[1] == 'application/octet-stream|' + API_ASSET,
      'API 资产接口必须带 octet-stream（否则回的是 JSON 元数据）', repr(tr))

r, tr = run('dl', {'DEST': P(dest), 'FURL': DIRECT, 'AID': None, 'UCI_MIRROR': 'off'})
check(plain(r).startswith('FAIL ') and 'GitHub 直连' in plain(r) and len(tr) == 1,
      '镜像关闭时只有直连一个来源，且确定性失败不重试', plain(r) + ' trace=' + repr(tr))

r, tr = run('dl', {'DEST': P(dest), 'FURL': DIRECT, 'AID': '12345'})
out = plain(r)
check(out.startswith('FAIL ') and 'API 资产接口' in out and 'm1.test' in out and 'm3.test' in out,
      '全部来源失败时逐个带回原因（含镜像）', out)
check(len(tr) == 5, '直连 1 + 资产接口 1 + 镜像 3 = 5 次尝试', repr(len(tr)))

r, tr = run('dl', {'DEST': P(dest), 'FURL': DIRECT, 'AID': None,
                   'UCI_MIRROR': 'https://only.test', 'OK_PAT': 'https://only.test/*'})
check(plain(r).startswith('OK ') and 'only.test/' in plain(r) and len(tr) == 2,
      '自定义镜像作为最后来源可用（前缀已规范化）', plain(r) + ' trace=' + repr(tr))

r, tr = run('dl', {'DEST': P(dest), 'FURL': DIRECT, 'AID': None,
                   'UCI_MIRROR': 'off', 'FAIL_RC': '6', 'FAIL_TXT': '域名解析失败'})
check(len(tr) == 2 and all(x == 'application/vnd.github+json|' + DIRECT for x in tr),
      'DNS 失败（可能瞬断）重试一次，仍失败才放弃', repr(tr))

r, tr = run('dl', {'DEST': P(dest), 'FURL': DIRECT, 'AID': None,
                   'UCI_MIRROR': 'off', 'FAIL_RC': '35'})
check(len(tr) == 2, 'TLS 握手失败也重试一次', repr(tr))

# ---------------------------------------------------------------- 快照格式
cand5 = work / 'cand5'
cand5.write_bytes(('1.8.88' + '\t' + DIRECT + '\tsha256:aa\tluci-app-openclaw-1.8.88-r1.apk\tabcdef'
                   + NL).encode('utf-8'))
r, _ = run('stale', {'CAND': P(cand5), 'DEST': P(dest)})
check(r.returncode != 0 and any('格式已过期' in m for m in msgs(r)),
      '5 列旧快照被明确判过期（提示重新检查，而不是"候选已变化"）', ' | '.join(msgs(r)))

cand6 = work / 'cand6'
cand6.write_bytes(('1.8.88' + '\t' + DIRECT + '\tsha256:aa\tluci-app-openclaw-1.8.88-r1.apk\t12345\tabcdef0123456789'
                   + NL).encode('utf-8'))
r, _ = run('stale', {'CAND': P(cand6), 'DEST': P(dest)})
check(not any('格式已过期' in m for m in msgs(r)),
      '6 列快照通过格式关卡（不会被误判过期）', ' | '.join(msgs(r)))

# ---------------------------------------------------------------- 列顺序静态断言
check("printf '%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n' \"$RELEASE_VERSION\" \"$ASSET_URL\" \"$ASSET_DIGEST\" \"$ASSET_NAME\" \"$ASSET_ID\" \"$CANDIDATE_ID\" >\"$CANDIDATE_TMP\""
      in gh, '快照写 6 列且候选标识在最后一列')
check('IFS=\'\t\' read -r ver url digest name aid got_id' in gh, 'do_install 按 6 列读取快照')

# ---------------------------------------------------------------- api_get 的真实接线
# 上面的 url-ok 只验证了判据函数本身。这里把**真的 api_get** 跑一遍：curl 换成
# 桩，断言非法地址在发起请求之前就被拒（桩未被调用、也不落盘）。
curlbin = work / 'bin'
curlbin.mkdir()
curl_stub = curlbin / 'curl'
curl_stub.write_bytes((NL.join([
    '#!/bin/sh',
    'dest=""',
    'prev=""',
    'for a in "$@"; do',
    '  if [ "$prev" = "-o" ]; then dest="$a"; fi',
    '  prev="$a"',
    'done',
    'printf "%s\\n" "$*" >>"$CURLMARK"',
    '[ -n "$dest" ] && printf PAYLOAD >"$dest"',
    'echo "OC_HTTP_CODE:200"',
    'exit 0',
]) + NL).encode('utf-8'))
curl_stub.chmod(0o755)

j2 = work / 'judge2.sh'
j2.write_bytes((NL.join([
    '#!/bin/sh',
    'GH_REPO=' + REPO,
    'GH_DL_PREFIX="https://github.com/%s/releases/download/"' % REPO,
    "ACCEPT_JSON='application/vnd.github+json'",
    "ACCEPT_BIN='application/octet-stream'",
    'MAX_BYTES=8388608',
    'msg() { printf "MSG %s\\n" "$*"; }',
    'oc_err() { :; }',
    'uci_get() { case "$1" in main.update_mirror) printf %s "${UCI_MIRROR-}" ;; *) printf "" ;; esac; }',
    func(lib, 'oc_safe_url'),
    func(gh, '_curl_rc_text'),
    func(gh, '_mirror_ok'),
    func(gh, 'update_mirror_get'),
    func(gh, '_dl_url_ok'),
    func(gh, 'api_get'),
    'api_get "$1" "$2" 5 "$3"',
    'printf "RC %s\\n" "$?"',
    '[ -f "$2" ] && printf "FILE yes\\n" || printf "FILE no\\n"',
]) + NL).encode('utf-8'))
j2.chmod(0o755)

check('_dl_url_ok "$url" || return 1' in func(gh, 'api_get'),
      'api_get 在拼 curl 命令之前先过下载地址白名单')


def run2(url):
    seq[0] += 1
    mark = work / ('curlmark-%d' % seq[0])
    mark.write_bytes(b'')
    dest2 = work / ('dest-%d' % seq[0])
    env = {'PATH': P(curlbin) + ':/usr/bin:/bin', 'CURLMARK': P(mark)}
    r = subprocess.run(['sh', P(j2), url, P(dest2)], capture_output=True, text=True,
                       env=env, timeout=60)
    hits = mark.read_text(encoding='utf-8').splitlines() if mark.exists() else []
    return r, [x for x in hits if x], dest2.exists()


r, hits, made = run2('https://evil.test/x.apk')
check('RC 1' in plain(r) and not hits and not made,
      '非法地址：curl 根本没被调用，也不落盘', plain(r) + ' hits=' + repr(hits))
r, hits, made = run2(DIRECT)
check('RC 0' in plain(r) and len(hits) == 1 and made,
      '合法直连地址照常下载（白名单不是一刀切）', plain(r) + ' hits=' + repr(len(hits)))
check('"$(printf \'\\t\')$cid\\$"' in gh, 'install 对候选标识的 grep 仍锚定行尾')

print('    共 %s 项，%s 项失败' % (total, failed))
sys.exit(1 if failed else 0)
PYEOF
