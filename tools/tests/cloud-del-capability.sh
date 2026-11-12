#!/bin/sh
# cloud-del-capability.sh — 「云端删除不可用就不显示删除按钮」回归
#
# 背景：bdpan 3.8.9 既没有删除子命令，又把登录凭据加密保存成 v1:<密文>，
# 插件无法调用网盘删除接口。此时界面不该给出一个必然失败的「删除」按钮 ——
# 1.8.96 起由 overview 的 del 子对象决定按钮是否渲染，并给出替代做法。
#
# 本用例把 cloud_del_capability 从 cloud.sh 抽出来，桩掉 bdpan 与登录配置，
# 逐场景断言「能力结论 + 原因码 + 提示文案」，并静态检查前端真的按它隐藏按钮。
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
check('能力判定不向 stdout 写东西',
      'printf' not in func('cloud_del_capability').replace(
          "printf '%s\\n' \"$help\"", ''))
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
    ('help 里有 rm -> 可用（成因 cli）',
     'Commands://n  ls       list\n  rm       delete a file\n  upload   add', PLAIN,
     0, 'cli', ''),
    ('help 无删除命令 + 明文凭据 -> 可用（token）',
     'usage: bdpan <command>', PLAIN, 0, 'token', ''),
    ('help 无删除命令 + base64 JSON 凭据 -> 可用（token）',
     'usage: bdpan <command>', B64JSON, 0, 'token', ''),
    ('help 无删除命令 + 加密凭据 -> 不可用（encrypted）',
     'usage: bdpan <command>', B64BIN, 1, 'encrypted', '加密保存'),
    ('help 正文含 remove 但无该命令 -> 不可用（真机回归）',
     'usage: bdpan <command>\n  upload   add a file (remove deletes it)', B64BIN,
     1, 'encrypted', '加密保存'),
    ('help 无删除命令 + 没有登录配置 -> 不可用（nologin）',
     'usage: bdpan <command>', None, 1, 'nologin', '未登录'),
]


def run_case(name, help_text, token, want_rc, want_why, want_hint):
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
        judge = d / 'judge.sh'
        lines = [
            '#!/bin/sh',
            'export OC_CLOUD_HOME=' + repr(posix(home)),
            'export OC_CLOUD_REMOTE=' + repr('openclaw-backups'),
            'cloud_bin_ready() { printf %s ' + repr(posix(bd)) + '; }',
            # 桩要像真 CLI：help 打印正文；<sub> --help 对不存在的命令报
            # unknown command 并非 0 —— 真机就是这个行为。
            'cloud_run() { shift; case "$*" in '
            '*" --help") case "$2" in rm|delete|remove) '
            'printf "Error: unknown command %s\\n" "$2"; return 1 ;; esac ;; esac; '
            # %b：help 文本里的 \n 要被解释成换行，否则整段变成一行，
            # 「行首命令名」的判据就永远匹配不上。
            'printf %b ' + repr(help_text) + '; }',
            BODY,
            'cloud_del_capability >/dev/null 2>&1',
            'printf "RC=%s\\nCAN=%s\\nWHY=%s\\nHINT=%s\\n" "$?" "$OC_DEL_CAN" "$OC_DEL_WHY" "$OC_DEL_HINT"',
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
        ok = (rc == str(want_rc) and why == want_why
              and (want_hint in hint if want_hint else True))
        check(name, ok, 'RC=%s WHY=%s HINT=%s' % (rc, why, hint))


for c in CASES:
    run_case(*c)

print('共 %d 项，失败 %d 项' % (total, len(fails)))
sys.exit(1 if fails else 0)
PYEOF
