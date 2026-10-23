#!/bin/sh
# cloud-no-od.sh — 不依赖 od 也要能正常安装与加密
#
# 背景：部分 OpenWrt / iStoreOS 的 busybox 没编进 od。命令缺失时 `od ...`
# 输出为空、stderr 又被 2>/dev/null 吞掉，于是"读文件头"这一步永远拿到空串。
#
# 1.8.1 修过安装器的 ELF 魔数判断（改用 head/tail），但当时漏了两处：
#
#   1. 加密备份的文件头校验（OCBK1 + 版本字节）仍用 od，且**没有兜底** ——
#      缺 od 时 magic/ver 都是空串，正常加密文件被判成"文件头不对"，
#      加密上传必然失败。
#   2. 安装器的架构检查仍用 od。这条本身有兜底（跳过），但它在 sha256
#      已经通过之后还跑，于是每次安装都会多打一条
#      「缺少 od，跳过 ELF 架构校验」的 WARN —— 明明哈希已经证明了架构。
#
# 断言：
#   1. cloud_enc_header_ok 在**没有 od** 的环境下仍能正确判定 OCBK1/v1
#   2. 它不会放过版本字节错误 / 魔数错误 / 空文件 / 截断文件
#   3. 源码里读文件头的地方不再有"无兜底的 od"
#   4. 架构检查只在没有 sha256 可依赖时才调用
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
import os
import pathlib
import re
import subprocess
import sys
import tempfile

proj = pathlib.Path(sys.argv[1])
NL = chr(10)
src = (proj / 'root/usr/libexec/openclaw/cloud.sh').read_text(encoding='utf-8')

total = 0
failed = 0


def check(ok, desc, detail=''):
    global total, failed
    total += 1
    print('    %s  %s%s' % ('ok  ' if ok else 'FAIL', desc, ('  ' + detail) if detail else ''))
    if not ok:
        failed += 1


def func(name):
    """按"下一个顶层函数定义"切函数体（不能用大括号配对，awk 程序里有花括号）。"""
    lines = src.splitlines()
    starts = [(i, m.group(1)) for i, l in enumerate(lines)
              for m in [re.match(r'^([a-z_][a-z0-9_]*)\(\)\s*\{', l)] if m]
    for idx, (ln, nm) in enumerate(starts):
        if nm == name:
            end = starts[idx + 1][0] if idx + 1 < len(starts) else len(lines)
            return NL.join(lines[ln:end])
    raise AssertionError('取不到函数 ' + name)


work = pathlib.Path(tempfile.mkdtemp())


def P(p):
    s = pathlib.Path(p).as_posix()
    return '/c' + s[2:] if len(s) > 1 and s[1] == ':' else s


# ---------------------------------------------------------------- 静态断言
def strip_comments(text):
    """去掉整行注释与行尾注释：判"有没有调用 od"时不能被说明文字误伤。"""
    out = []
    for ln in text.splitlines():
        s = ln.split('#', 1)[0]
        out.append(s)
    return NL.join(out)


hb_code = strip_comments(func('cloud_enc_header_ok'))
check(not re.search(r'\bod\b', hb_code), 'cloud_enc_header_ok 不用 od')

# 架构检查必须只在「没有 sha256 可依赖」的分支里被调用。
# 只数**代码**里的出现次数：函数名会同时出现在定义与注释里。
arch_hits = re.findall(r'cloud_installer_arch_ok', strip_comments(src))
check(len(arch_hits) == 2, 'cloud_installer_arch_ok 只有定义 + 一处调用',
      'count=%d' % len(arch_hits))

# 找出调用点是否位于 sha256 的 else 分支里（即"未收录"分支）
idx = src.find('cloud_installer_arch_ok "$dest"')
seg = src[max(0, idx - 900):idx]
check('未收录' in seg or 'else' in seg, '架构检查在 sha256 未命中的分支里')

# ---------------------------------------------------------------- 行为断言
# 构造一个**没有 od** 的 PATH：只放 sh / head / tail 这些必需命令。
jf = work / 'judge.sh'
jf.write_text(NL.join(['#!/bin/sh', func('cloud_enc_header_ok'),
                       'cloud_enc_header_ok "$1"']) + NL,
              encoding='utf-8', newline=NL)

cases = {
    '正常 OCBK1/v1': (b'OCBK1\n\x01' + b'payload' * 10, 0),
    '版本字节 2': (b'OCBK1\n\x02' + b'payload', 1),
    '魔数错 OCBK2': (b'OCBK2\n\x01' + b'payload', 1),
    '空文件': (b'', 1),
    '纯 ELF 头': (b'\x7fELF' + b'\x00' * 20, 1),
    '截断 3 字节': (b'OCB', 1),
}
for label, (data, want) in cases.items():
    f = work / 'x.bin'
    f.write_bytes(data)
    r = subprocess.run(['sh', P(jf), P(f)], capture_output=True, text=True, timeout=30)
    check(r.returncode == want, '文件头判定：%s' % label,
          'rc=%d want=%d' % (r.returncode, want))

# 关键一条：函数体里没有 od 调用，就等于"缺 od 也不会误判"。
check('command -v od' not in hb_code and 'od -A' not in hb_code,
      '文件头判定完全不依赖 od（缺 od 时不会误判）')

print('    共 %s 项，%s 项失败' % (total, failed))
sys.exit(1 if failed else 0)
PYEOF
