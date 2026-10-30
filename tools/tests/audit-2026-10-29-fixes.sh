#!/bin/sh
# audit-2026-10-29-fixes.sh — 2026-10-29 全盘审计中 P0-1 / P0-2 / P1-3 三处修复的回归测试
#
# 三处都是「代码看着对、实际没生效」的死代码型缺陷，静态断言防不住，
# 必须行为级实测：
#
#   P0-1  backup.sh  cmd_restore() 先 rm -rf "$stage"，之后才读
#         $stage/crontab.txt / $stage/plugins.txt → 两个分支恒假，
#         定时任务恢复与插件清单提示从未执行过。
#
#   P0-2  lib.sh     oc_fix_perms() 对 base 做 chown -R 给服务用户，
#         把 secure/delpass（删除密码哈希）与 cloud/pass（云备份口令）
#         也一并交出去。修复是追加 oc_harden_root_paths() 收紧回来；
#         调用点必须落在 `case "$ocdir" in "$base"|"$base"/*) return 0`
#         之前 —— 默认 openclaw_dir 正是 $base/openclaw，放在函数末尾
#         会永远执行不到。
#
#   P1-3  init.d     _state_dir_safe() 有定义无调用点，main.state_dir
#         实际从未校验。修复后必须「系统目录拒绝、正常数据目录放行」，
#         且校验要落在 enabled 判断之后（未启用时不该报启动失败）。
#
# 退出码：0 = 全部通过；1 = 有失败

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
PROJ="$(cd "$HERE/../.." && pwd)"

PY=""
for cand in python3 python "$HOME/.workbuddy/binaries/python/versions/3.13.12/python.exe"; do
	if command -v "$cand" >/dev/null 2>&1 || [ -x "$cand" ]; then PY="$cand"; break; fi
done

FAILED=0
pass() { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; FAILED=1; }

BACKUP="$PROJ/root/usr/libexec/openclaw/backup.sh"
LIBSH="$PROJ/root/usr/libexec/openclaw/lib.sh"
INITD="$PROJ/root/etc/init.d/openclaw"

for f in "$BACKUP" "$LIBSH" "$INITD"; do
	[ -f "$f" ] || { echo "    缺少被测文件：$f"; exit 1; }
done

echo "== P0-1 恢复流程：暂存目录的读取必须早于回收 =="

# 取 cmd_restore() 函数体（到下一个顶层函数为止）
if ! "$PY" - "$BACKUP" <<'PYEOF' 2>/dev/null
import re, sys
src = open(sys.argv[1], encoding='utf-8').read()
start = src.index('cmd_restore() {')
nxt = src.find('\ncmd_delete() {', start)
body = src[start:nxt if nxt > 0 else len(src)]
lines = body.splitlines()

def at(pat):
    return [i + 1 for i, l in enumerate(lines) if re.search(pat, l)]

# 正常路径的回收：oc_rmtree "$stage"（不带 ; die_json 那种失败分支写法）
recycle = at(r'^\s*oc_rmtree "\$stage"\s*$')
crontab = at(r'if \[ -s "\$stage/crontab\.txt" \]')
plugins = at(r'if \[ -s "\$stage/plugins\.txt" \]')

ok = True
if len(recycle) != 1:
    print("    FAIL  正常路径的 oc_rmtree \"$stage\" 应恰好 1 处，实得 %d 处" % len(recycle))
    ok = False
elif not crontab or not plugins:
    print("    FAIL  未找到 crontab.txt / plugins.txt 的读取点")
    ok = False
elif recycle[0] <= max(crontab + plugins):
    print("    FAIL  回收在第 %d 行，早于读取点 %s —— 清单读不到"
          % (recycle[0], crontab + plugins))
    ok = False
else:
    print("    回收行 %d 晚于全部读取点 %s" % (recycle[0], sorted(crontab + plugins)))

# 早期删除（rm -rf "$stage"）只允许出现在失败分支或重新初始化
early = at(r'rm -rf "\$stage"')
for i in early:
    ctx = ""
    for j in range(i, min(i + 3, len(lines))):
        if lines[j].strip():
            ctx = lines[j]
            break
    if 'die_json' not in ctx and 'mkdir' not in ctx:
        print("    FAIL  第 %d 行的删除不在失败/初始化分支：%s" % (i, ctx.strip()[:60]))
        ok = False

sys.exit(0 if ok else 1)
PYEOF
then
	fail "cmd_restore 暂存目录生命周期（P0-1）"
else
	pass "cmd_restore 暂存目录生命周期（P0-1）"
fi

echo "== P0-2 权限收紧：默认布局下必须真的被调用 =="

# 用桩函数跑一遍 oc_fix_perms：默认 openclaw_dir = $base/openclaw，
# 正是会命中 `case "$ocdir" in "$base"/*) return 0` 的场景。
STAGE="$(mktemp -d 2>/dev/null || echo /tmp/oc-perm-test)"
mkdir -p "$STAGE/root/usr/libexec/openclaw" 2>/dev/null
if [ -d "$STAGE/root/usr/libexec/openclaw" ]; then
	cp "$LIBSH" "$STAGE/root/usr/libexec/openclaw/lib.sh" 2>/dev/null
	cat > "$STAGE/t.sh" <<'TEOF'
#!/bin/sh
. "$1/root/usr/libexec/openclaw/lib.sh" >/dev/null 2>&1
TB="$(mktemp -d)"
mkdir -p "$TB/secure" "$TB/cloud" "$TB/backups" "$TB/openclaw"
: > "$TB/secure/delpass"; : > "$TB/cloud/pass"; : > "$TB/backups/a.tar.gz"
LOG="$(mktemp)"
oc_base_dir() { echo "$TB"; }
oc_oc_dir()   { echo "$TB/openclaw"; }
chown() { echo "chown[$*]" >> "$LOG"; return 0; }
chmod() { echo "chmod[$*]" >> "$LOG"; return 0; }
oc_warn() { echo "WARN[$*]" >> "$LOG"; }
OC_USER=openclaw OC_GROUP=openclaw
oc_fix_perms >/dev/null 2>&1
rc=0
need() { grep -q "$1" "$LOG" || { echo "    缺失：$1"; rc=1; }; }
need "chown\[-R root:root .*/secure\]"
need "chmod\[700 .*/secure\]"
need "chown\[root:root .*/cloud/pass\]"
need "chmod\[600 .*/cloud/pass\]"
need "chown\[-R root:root .*/backups\]"
need "chmod\[700 .*/backups\]"
rm -rf "$TB" "$LOG" 2>/dev/null
exit $rc
TEOF
	if sh "$STAGE/t.sh" "$STAGE" 2>/dev/null; then
		pass "oc_fix_perms 默认布局下收紧 secure / cloud/pass / backups（P0-2）"
	else
		fail "oc_fix_perms 默认布局下收紧 secure / cloud/pass / backups（P0-2）"
	fi
	rm -rf "$STAGE" 2>/dev/null
else
	fail "无法创建临时目录用于 P0-2 实测"
fi

echo "== P1-3 state_dir 安全校验：系统目录拒绝、正常目录放行 =="

TMPDIR2="$(mktemp -d 2>/dev/null || echo /tmp/oc-sd-$$)"
mkdir -p "$TMPDIR2" 2>/dev/null
cat > "$TMPDIR2/oc-sd-check.sh" <<'SEOF'
#!/bin/sh
eval "$(sed -n '/^_state_dir_shape_ok() {/,/^}/p' "$1")"
eval "$(sed -n '/^_state_dir_safe() {/,/^}/p' "$1")"
rc=0
rej() { _state_dir_safe "$1" && { echo "    误放行：$1"; rc=1; }; }
acc() { _state_dir_safe "$1" || { echo "    误拒绝：$1"; rc=1; }; }
rej /etc
rej /etc/openclaw
rej /
rej /mnt
rej /usr/lib
rej /tmp
rej "//etc/x"
rej /mnt/data/../etc
rej "relative/path"
acc /mnt/data/OpenClaw/home/.openclaw
acc /mnt/sda1/home/.openclaw
acc /mnt/nvme0n1/openclaw/state
exit $rc
SEOF
if sh "$TMPDIR2/oc-sd-check.sh" "$INITD" 2>/dev/null; then
	pass "_state_dir_safe 判定矩阵（P1-3）"
else
	fail "_state_dir_safe 判定矩阵（P1-3）"
fi
rm -rf "$TMPDIR2" 2>/dev/null

# 校验必须有真实调用点，且落在 enabled 判断之后
if grep -q '_state_dir_safe "\$state_dir"' "$INITD"; then
	pass "init.d 存在 _state_dir_safe 调用点（P1-3）"
else
	fail "init.d 存在 _state_dir_safe 调用点（P1-3）"
fi

ORDER=$(awk '
	/\[ "\$enabled" -eq 1 \]/ { en = NR }
	/_state_dir_safe "\$state_dir"/ { sd = NR }
	END { if (en && sd) print (sd > en) ? "after" : "before"; else print "missing" }
' "$INITD")
if [ "$ORDER" = "after" ]; then
	pass "校验位于 enabled 判断之后（未启用时不误报）（P1-3）"
else
	fail "校验位于 enabled 判断之后，实得：$ORDER（P1-3）"
fi

echo
if [ "$FAILED" -eq 0 ]; then
	echo "  结论：全部通过"
else
	echo "  结论：存在失败项"
fi
exit "$FAILED"
