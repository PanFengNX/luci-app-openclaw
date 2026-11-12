#!/bin/sh
# cloud-del-capability.sh — 「云端删除不可用就不显示删除按钮」回归
#
# 背景：bdpan 3.8.9 没有删除子命令，又把登录凭据加密保存成 v1:<密文>，插件
# 无法调用网盘删除接口。此时界面不该给出一个必然失败的「删除」按钮 ——
# 1.8.96 起由 overview 的 del 子对象决定按钮是否渲染，并给出替代做法。
#
# 真机踩到的两个坑（本用例逐条覆盖）：
#   1) help 正文里出现 remove 之类的词，被整段匹配当成「有删除命令」；
#   2) cobra 类 CLI 对「未知命令 + --help」会打印根用法并返回 0，只看退出码
#      仍然会把不存在的命令判成存在。
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
import base64
import json
import pathlib
import subprocess
import sys
import tempfile

PROJ = pathlib.Path(sys.argv[1])
SRC = PROJ / 'root/usr/libexec/openclaw/cloud.sh'
HTM = PROJ / 'luasrc/view/openclaw/backup.htm'
src = SRC.read_text(encoding='utf-8') if SRC.exists() else ''
htm = HTM.read_text(encoding='utf-8') if HTM.exists() else ''
fails = []
total = 0


def check(name, cond, extra=''):
    global total
    total += 1
    print(('  ok   ' if cond else '  FAIL ') + name)
    if not cond:
        fails.append(name)
        if extra:
            print('       ' + str(extra)[:240])


def func(name):
    i = src.find('\n' + name + '() {')
    if i < 0:
        return ''
    i += 1
    j = src.find('\n}\n', i)
    return src[i:j + 3] if j > i else ''


NAMES = ('cloud_valid_remote_name', 'cloud_json_scalar', 'cloud_json_deep',
         'cloud_json_keys', 'cloud_api_conf', 'cloud_api_unwrap',
         'cloud_api_unwrap_binary', 'cloud_api_raw_token',
         'cloud_api_token_usable', 'cloud_del_capability')
HAVE_ALL = all(func(n) for n in NAMES)
BODY = '\n'.join(func(n) for n in NAMES)

# ---------------------------------------------------------------- 静态契约
check('新增 cloud_del_capability', func('cloud_del_capability') != '')
check('能力判定不做网络请求（只读配置 + help）',
      'curl' not in func('cloud_del_capability')
      and 'cloud_api_probe' not in func('cloud_del_capability'))
check('overview 暴露 del 子对象',
      '"del":{"can":%s' in src and 'OC_DEL_HINT' in src)
check('前端按能力隐藏云端删除按钮',
      'if (CL.del.can){' in htm and "mk('删除', function(){ bkDeleteCloud" in htm)
check('前端有不可用说明位', 'bk-del-note' in htm and 'bkRenderDelNote' in htm)
check('说明文案只进 textContent', "el.textContent = txt;" in htm
      and 'bk-del-note' in htm)

TOKEN = 'TESTTOK_abcdef123456'
B64JSON = 'v1:' + base64.b64encode(
    json.dumps({'access_token': TOKEN}).encode()).decode()
B64BIN = 'v1:' + base64.b64encode(bytes(range(0, 40))).decode()
PLAIN = TOKEN

CASES = [
    ('子命令 rm 有自己的 Usage 行 -> 可用（cli）',
     'anything', PLAIN, 0, 'cli', '', 'rm'),
    ('help 正文含 remove 但无该命令 -> 不可用（真机回归 1）',
     'usage: bdpan <command>\n  upload   add a file (remove deletes it)', B64BIN,
     1, 'encrypted', '加密保存', ''),
    ('--help 只给根用法 [command] -> 不可用（真机回归 2）',
     'usage: bdpan <command>', B64BIN, 1, 'encrypted', '加密保存', ''),
    ('help 无删除命令 + 明文凭据 -> 可用（token）',
     'usage: bdpan <command>', PLAIN, 0, 'token', '', ''),
    ('help 无删除命令 + base64 JSON 凭据 -> 可用（token）',
     'usage: bdpan <command>', B64JSON, 0, 'token', '', ''),
    ('help 无删除命令 + 加密凭据 -> 不可用（encrypted）',
     'usage: bdpan <command>', B64BIN, 1, 'encrypted', '加密保存', ''),
    ('没有登录配置 -> 不可用（nologin）',
     'usage: bdpan <command>', None, 1, 'nologin', '未登录', ''),
]


def run_case(name, help_text, token, want_rc, want_why, want_hint,
             supports=''):
    if not HAVE_ALL:
        check(name + '（缺函数，判失败）', False)
        return
    with tempfile.TemporaryDirectory() as td:
        d = pathlib.Path(td)
        home = d / 'home'
        (home / '.config/bdpan').mkdir(parents=True, exist_ok=True)
        if token is not None:
            (home / '.config/bdpan/config.json').write_text(
                json.dumps({'access_token': token}), encoding='utf-8')
        bd = d / 'bdpan'
        bd.write_text('#!/bin/sh\nexit 0\n', encoding='utf-8')
        bd.chmod(0o755)
        posix = lambda p: str(p).replace('\\', '/')

        # 桩模拟 cobra 的真实行为（真机上踩到的两个坑）：
        #   * 未知命令 + --help  -> 打印根用法并返回 0；
        #   * help <未知>        -> 报 unknown help topic。
        # 只有 supports 指定的子命令才有自己的 Usage 行。
        stub = (
            # 参数位置要分清：`bdpan help rm` 的 rm 在 $3，`bdpan rm --help` 的
            # rm 在 $2（shift 掉超时值后）。
            'cloud_run() { shift; '
            'case "$*" in '
            '*" help "*) _sub="$3"; case "$_sub" in ' + repr(supports) + ') '
            'printf "Usage: bdpan %s [flags] <path>\\n" "$_sub"; return 0 ;; esac; '
            'printf "Error: unknown help topic %s\\n" "$_sub"; return 1 ;; '
            '*" --help") _sub="$2"; case "$_sub" in ' + repr(supports) + ') '
            'printf "Usage: bdpan %s [flags] <path>\\n" "$_sub"; return 0 ;; esac; '
            'printf "Usage: bdpan [command]\\n"; return 0 ;; '
            'esac; printf %b ' + repr(help_text) + '; }'
        )

        judge = d / 'judge.sh'
        lines = [
            '#!/bin/sh',
            'export OC_CLOUD_HOME=' + repr(posix(home)),
            'export OC_CLOUD_REMOTE=' + repr('openclaw-backups'),
            'OUTF=' + repr(posix(d / 'cap.out')),
            'cloud_bin_ready() { printf %s ' + repr(posix(bd)) + '; }',
            stub,
            BODY,
            # 必须重定向到文件再 cat：用 $(...) 会把函数放进子 shell，
            # OC_DEL_CAN 这些全局变量随子 shell 一起消失（本项目踩过）。
            'cloud_del_capability >"$OUTF" 2>/dev/null',
            '_rc=$?',
            '_out="$(cat "$OUTF" 2>/dev/null)"',
            'printf "RC=%s\\nCAN=%s\\nWHY=%s\\nHINT=%s\\nOUT=%s\\n" '
            '"$_rc" "$OC_DEL_CAN" "$OC_DEL_WHY" "$OC_DEL_HINT" "$_out"',
        ]
        judge.write_text('\n'.join(lines) + '\n', encoding='utf-8')
        p = subprocess.run(['sh', str(judge)], capture_output=True, text=True,
                           timeout=120)
        got = {}
        for line in p.stdout.splitlines():
            if '=' in line:
                k, _, v = line.partition('=')
                got[k] = v
        rc = got.get('RC', '?')
        why = got.get('WHY', '')
        hint = got.get('HINT', '')
        out = got.get('OUT', '')
        ok = (rc == str(want_rc) and why == want_why
              and (want_hint in hint if want_hint else True)
              and out == '')
        check(name, ok, 'RC=%s WHY=%s OUT=%r HINT=%s' % (rc, why, out, hint))


for c in CASES:
    run_case(*c)

print('共 %d 项，失败 %d 项' % (total, len(fails)))
sys.exit(1 if fails else 0)
PYEOF
