#!/bin/sh
# naming.sh — 本包不依赖 iStoreOS，路径命名也不该沿用它的约定
#
# 用户看到安装日志里"闪过 istore"（chmod 那段里的 /usr/libexec/istorec/openclaw.sh），
# 以为安装要从 iStore 拉东西。事实上本包从不访问 iStore，那个目录名纯粹是历史
# 遗留（iStoreOS 自带管理器的约定）。这里断言：
#
#   1. 源码树里没有任何 istorec 路径引用（入口脚本已移到 openclaw/cli.sh）；
#   2. 控制器指向新路径，且那个文件真的在；
#   3. 升级时会清掉旧的 /usr/libexec/istorec/openclaw.sh —— 但只删这一个确切
#      文件，且用 rmdir（只删空目录），不会误伤装了 iStore 的设备上的其它脚本；
#   4. 打包脚本 / uci-defaults / 修复脚本里的可执行位处理都跟着新路径走。
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


def check(ok, desc):
    global total, failed
    total += 1
    print('    %s  %s' % ('ok  ' if ok else 'FAIL', desc))
    if not ok:
        failed += 1


SKIP_DIRS = {'.git', '.review', '.tmp', 'dist', '__pycache__'}
SUFFIXES = {'.sh', '.lua', '.py', '.htm', '.md'}
NAMES = {'Makefile'}
# 这个测试文件自己当然会提到旧路径
SELF = 'tools/tests/naming.sh'
# CHANGELOG 是历史记录：它必须写明"以前叫什么"，否则用户看不懂这次改动
DOC_ONLY = {'root/usr/share/openclaw/CHANGELOG.md'}

hits = []
for p in proj.rglob('*'):
    if not p.is_file():
        continue
    if any(d in p.parts for d in SKIP_DIRS):
        continue
    if p.suffix not in SUFFIXES and p.name not in NAMES:
        continue
    rel = p.relative_to(proj).as_posix()
    if rel == SELF or rel in DOC_ONLY:
        continue
    try:
        text = p.read_text(encoding='utf-8')
    except Exception:
        continue
    for i, line in enumerate(text.splitlines(), 1):
        if 'istorec' not in line:
            continue
        # 允许在说明性注释里提到旧路径（讲清"以前叫什么"），其余一律算残留。
        # uci-defaults 里那段清理旧文件的逻辑也允许 —— 它删的是旧路径本身。
        if re.search(r'以前叫|旧版本|旧路径|清除|清理|rm -f /usr/libexec/istorec', line):
            continue
        # README 的对照表左列写的是 iStoreOS 自带包的路径（openclawmgr），
        # 那是别人的文件名，不是我们的引用。
        if 'openclawmgr.sh' in line:
            continue
        hits.append('%s:%d: %s' % (p.relative_to(proj).as_posix(), i, line.strip()))

check(not hits, '源码树里没有 istorec 路径引用')
for h in hits[:8]:
    print('        ' + h[:150])

# 新位置存在，且控制器指向它
cli = proj / 'root/usr/libexec/openclaw/cli.sh'
check(cli.is_file(), '入口脚本在 /usr/libexec/openclaw/cli.sh')
ctrl = (proj / 'luasrc/controller/openclaw.lua').read_text(encoding='utf-8')
check('local SH     = "/usr/libexec/openclaw/cli.sh"' in ctrl,
      '控制器指向新路径')

# 旧目录不再随包发布
check(not (proj / 'root/usr/libexec/istorec').exists(),
      'root/usr/libexec/istorec 目录已删除')

# 升级清理旧文件：只删确切路径 + rmdir（空目录才删）
uci = (proj / 'root/etc/uci-defaults/99-openclaw').read_text(encoding='utf-8')
check('rm -f /usr/libexec/istorec/openclaw.sh' in uci,
      '升级时会删除旧的 istorec/openclaw.sh')
check('rmdir /usr/libexec/istorec' in uci,
      '旧目录用 rmdir 清理（只删空目录，不误伤别人的脚本）')
check('rm -rf /usr/libexec/istorec' not in uci,
      '没有用 rm -rf 扫旧目录')

# 打包与修复脚本跟着新路径
build = (proj / 'scripts/build_apk.py').read_text(encoding='utf-8')
check('chmod +x /usr/libexec/openclaw/cli.sh' in build,
      'postinst 里 chmod 的是新路径')
mk = (proj / 'Makefile').read_text(encoding='utf-8')
check('/usr/libexec/openclaw/cli.sh' in mk, 'Makefile 的 postinst 用新路径')

repair = (proj / 'root/usr/libexec/openclaw/repair.sh').read_text(encoding='utf-8')
check('istorec' not in repair, 'repair.sh 不再引用旧路径')

# 进程归属判断要认新名字（否则运行中的安装会被误判成"不是我们的进程"）
lib = (proj / 'root/usr/libexec/openclaw/lib.sh').read_text(encoding='utf-8')
check('*openclaw/cli.sh*' in lib,
      '进程归属判断认得 openclaw/cli.sh')

print('    共 %s 项，%s 项失败' % (total, failed))
sys.exit(1 if failed else 0)
PYEOF
