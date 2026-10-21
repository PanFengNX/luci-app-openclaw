#!/bin/sh
# config-preserve.sh — 升级不得覆盖用户的 /etc/config/openclaw
#
# 真机事故：升级到 1.8.8 之后，「定时备份」的启用开关、加密开关等设置被清回
# 默认值。根因不是 UCI 迁移写错，而是**安装包里直接带着 /etc/config/openclaw**：
# 包管理器把它当成普通文件解压覆盖，用户改过的值整份丢掉。
#
# 所以这里断言两件事：
#   1. 源码树里不再有 root/etc/config/openclaw（否则会被 collect_files 打进包）；
#   2. 安装脚本只在文件**不存在**时才从模板生成，已有文件一个字都不许改。
#
# 第 2 条用真实执行验证：把 postinst 里那段逻辑抠出来，在两个临时目录里各跑
# 一次 —— 有文件时校验内容没变，没文件时校验生成成功。
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
import shutil
import subprocess
import sys
import tempfile

proj = pathlib.Path(sys.argv[1])
total = 0
failed = 0


def check(ok, desc):
    global total, failed
    total += 1
    print('    %s  %s' % ('ok  ' if ok else 'FAIL', desc))
    if not ok:
        failed += 1


# ── 1. 源码树里不能再有 root/etc/config/openclaw ──────────────────────
shipped = proj / 'root/etc/config/openclaw'
check(not shipped.exists(), 'root/etc/config/openclaw 不再随包发布')
check((proj / 'root/usr/share/openclaw/config.default').is_file(),
      '默认配置模板存在于 /usr/share/openclaw/config.default')

# ── 2. postinst 的"缺失才生成"逻辑 ────────────────────────────────────
src = (proj / 'scripts/build_apk.py').read_text(encoding='utf-8')
m = re.search(r'SCRIPTS = """(.*?)"""', src, re.S)
check(bool(m), '能从 build_apk.py 里取出 postinst')

work = pathlib.Path(tempfile.mkdtemp())


def P(p):
    s = pathlib.Path(p).as_posix()
    mm = re.match(r'^([A-Za-z]):/', s)
    return '/' + mm.group(1).lower() + s[2:] if mm else s


try:
    if m:
        body = m.group(1)
        # 只取"生成配置文件"那一段，去掉 chmod / luci cache 这些与测试无关的动作
        seg = re.search(r'# /etc/config/openclaw 不再随包发布.*?\nfi\n', body, re.S)
        check(bool(seg), 'postinst 里有"缺失才生成配置"的段落')
        if seg:
            snippet = seg.group(0).replace('/etc/config/openclaw', '__ETC__').replace(
                '/usr/share/openclaw/config.default', '__TPL__')

            tpl = work / 'config.default'
            tpl.write_text("config main 'main'\n\toption cloud_enabled '0'\n", encoding='utf-8')

            # 场景 A：已存在用户配置（含用户改过的值）→ 必须原样保留
            etc_a = work / 'a' / 'openclaw'
            etc_a.parent.mkdir(parents=True)
            user = "config main 'main'\n\toption cloud_enabled '1'\n\toption cloud_hour '3'\n"
            etc_a.write_text(user, encoding='utf-8', newline='')
            script = work / 'a.sh'
            script.write_text('#!/bin/sh\n' + snippet.replace('__ETC__', P(etc_a)).replace(
                '__TPL__', P(tpl)) + 'exit 0\n', encoding='utf-8', newline='\n')
            subprocess.run(['sh', P(script)], capture_output=True, text=True)
            after = etc_a.read_text(encoding='utf-8')
            check(after == user, '已有配置在"安装"后逐字节不变（用户设置不会丢）')

            # 场景 B：配置不存在 → 从模板生成
            etc_b = work / 'b' / 'openclaw'
            etc_b.parent.mkdir(parents=True)
            script = work / 'b.sh'
            script.write_text('#!/bin/sh\n' + snippet.replace('__ETC__', P(etc_b)).replace(
                '__TPL__', P(tpl)) + 'exit 0\n', encoding='utf-8', newline='\n')
            subprocess.run(['sh', P(script)], capture_output=True, text=True)
            check(etc_b.is_file(), '配置缺失时会从模板生成')
            if etc_b.is_file():
                check("cloud_enabled '0'" in etc_b.read_text(encoding='utf-8'),
                      '生成的配置内容来自模板')

            # 场景 C：模板也不在（极端情况）→ 不能报错，也不能造出空文件
            etc_c = work / 'c' / 'openclaw'
            etc_c.parent.mkdir(parents=True)
            script = work / 'c.sh'
            script.write_text('#!/bin/sh\n' + snippet.replace('__ETC__', P(etc_c)).replace(
                '__TPL__', P(work / 'nope.default')) + 'exit 0\n', encoding='utf-8', newline='\n')
            r = subprocess.run(['sh', P(script)], capture_output=True, text=True)
            check(r.returncode == 0 and not etc_c.exists(),
                  '模板缺失时安静跳过，不生成空配置')
finally:
    shutil.rmtree(work, ignore_errors=True)

print('    共 %s 项，%s 项失败' % (total, failed))
sys.exit(1 if failed else 0)
PYEOF
