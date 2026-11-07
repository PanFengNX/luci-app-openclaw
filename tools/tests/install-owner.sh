#!/bin/sh
# install-owner.sh —— 守住「安装树属主必须归网关用户」这条链（真机踩过，
# 代价是 OpenClaw 自带的 openclaw update 从未成功过）
#
# 背景：OpenClaw 自更新（以网关用户运行）的 package-publication-admission
# 阶段校验安装树属主 == 运行进程 uid。root 跑过 npm install / 手工部署后
# 树是 root 的，自更新从此永远被拒。修复链有四个环节，缺一不可：
#   1) lib.sh 提供 oc_install_owner_bad / oc_fix_install_owner（探测 + 修复）
#   2) repair.sh owner-fix 分支真正覆盖安装树（历史上漏掉，声称修属主
#      实际不碰安装树）
#   3) repair.sh 常规体检的 ownership 项探测树内部，不是只看 $BASE 顶层
#   4) install.sh 收尾自检 + Makefile postinst 自愈（包升级不重跑 install.sh，
#      postinst 是旧设备唯一的自动修复点）
#
# 本机（MSYS）无法真实 chown，所以这里是静态结构断言；行为级验证在
# 真机完成（owner-fix 后 stat -c %U bin/openclaw = openclaw）。
#
# 退出码：0 = 全部通过；1 = 有失败

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
PROJ="$(cd "$HERE/../.." && pwd)"
LIB="$PROJ/root/usr/libexec/openclaw/lib.sh"
REPAIR="$PROJ/root/usr/libexec/openclaw/repair.sh"
INSTALL="$PROJ/root/usr/libexec/openclaw/install.sh"
MAKEFILE="$PROJ/Makefile"
fail=0
n=0

chk() {
	n=$((n + 1))
	if [ "$1" = "ok" ]; then
		printf '    ok    %s\n' "$2"
	else
		printf '    FAIL  %s\n' "$2"
		fail=$((fail + 1))
	fi
}

for f in "$LIB" "$REPAIR" "$INSTALL" "$MAKEFILE"; do
	[ -f "$f" ] || { printf '    跳过：找不到 %s\n' "$f"; exit 0; }
done

# ---- 1. lib.sh 定义了探测与修复函数 --------------------------------------
for fn in oc_install_owner_bad oc_fix_install_owner; do
	if grep -q "^${fn}()" "$LIB"; then
		chk ok "lib.sh 定义了 $fn()"
	else
		chk fail "lib.sh 缺少 $fn() 定义"
	fi
done

# ---- 2. oc_fix_install_owner 的安全顺序：oc_oc_dir_safe 在 chown 之前 ----
# sed 取函数体（从函数定义行到下一个顶层 '^}'）
fn_body="$(sed -n '/^oc_fix_install_owner()/,/^}/p' "$LIB")"
if [ -n "$fn_body" ]; then
	safe_line="$(printf '%s\n' "$fn_body" | grep -n 'oc_oc_dir_safe' | head -1 | cut -d: -f1)"
	chown_line="$(printf '%s\n' "$fn_body" | grep -n 'chown -R' | head -1 | cut -d: -f1)"
	if [ -n "$safe_line" ] && [ -n "$chown_line" ] && [ "$safe_line" -lt "$chown_line" ]; then
		chk ok "oc_fix_install_owner 先安全校验再 chown（第 $safe_line < $chown_line 行）"
	else
		chk fail "oc_fix_install_owner 的 oc_oc_dir_safe 必须出现在 chown -R 之前"
	fi
	# fail-open：没有服务用户时必须放行（return 0），不拦截
	if printf '%s\n' "$fn_body" | grep -q 'grep -q "\^${OC_USER}:" /etc/passwd'; then
		chk ok "oc_fix_install_owner 对无服务用户场景 fail-open"
	else
		chk fail "oc_fix_install_owner 缺少服务用户存在性检查（无用户时应 return 0）"
	fi
else
	chk fail "找不到 oc_fix_install_owner 函数体"
fi

# ---- 3. repair.sh owner-fix 分支覆盖安装树 --------------------------------
# owner-fix 提前分支：从 OWNER_FIX 判定到第一个 exit 0 之间
ownerfix_body="$(sed -n '/OWNER_FIX" = "1"/,/^exit 0$/p' "$REPAIR" | head -60)"
# 程序目录的解析与 BASE/DATA 同模式：在提前分支**之前**统一完成
pre_branch="$(sed -n '1,/OWNER_FIX" = "1"/p' "$REPAIR")"
if printf '%s' "$pre_branch" | grep -q 'OC_DIR_FIX=.*oc_oc_dir'; then
	chk ok "owner-fix 之前已解析程序目录（OC_DIR_FIX=\$(oc_oc_dir)，与 BASE/DATA 同模式）"
else
	chk fail "程序目录解析缺失（owner-fix 修不到安装树）"
fi
if printf '%s' "$ownerfix_body" | grep -q '_fix_owner_tree.*OC_DIR'; then
	chk ok "owner-fix 分支对安装树执行 _fix_owner_tree"
else
	chk fail "owner-fix 分支没有对安装树调用 _fix_owner_tree"
fi
# 提前分支之前必须对 OC_DIR 做 fail-closed 校验（与 BASE/DATA 同等待遇）
if printf '%s' "$pre_branch" | grep -q 'oc_validate_base_dir.*"\$OC_DIR_FIX"'; then
	chk ok "owner-fix 之前对程序目录做安全校验（fail-closed）"
else
	chk fail "owner-fix 之前缺少对 \$OC_DIR_FIX 的 oc_validate_base_dir 校验"
fi

# ---- 4. repair.sh 常规体检的 ownership 项探测安装树 ------------------------
if grep -q 'oc_install_owner_bad' "$REPAIR"; then
	chk ok "repair.sh ownership 项探测安装树属主（不只是顶层目录）"
else
	chk fail "repair.sh ownership 项没有探测安装树属主"
fi

# ---- 5. install.sh 收尾自检（fail-open：只 WARN 不 die）--------------------
if grep -q 'oc_fix_install_owner' "$INSTALL"; then
	chk ok "install.sh 收尾调用 oc_fix_install_owner"
else
	chk fail "install.sh 收尾缺少安装树属主自检"
fi
# 收尾自检不允许 die/return 1（安装已成功，属主失败只影响自更新）
finish_body="$(sed -n '/^finish()/,/^}/p' "$INSTALL")"
owner_chk="$(printf '%s\n' "$finish_body" | sed -n '/oc_fix_install_owner/,/fi/p')"
if [ -n "$owner_chk" ] && ! printf '%s\n' "$owner_chk" | grep -qE '\bdie\b|return 1'; then
	chk ok "install.sh 属主自检失败路径只告警不中止（fail-open）"
else
	chk fail "install.sh 属主自检的失败路径不得 die / return 1"
fi

# ---- 6. Makefile postinst 自愈 --------------------------------------------
postinst_body="$(sed -n '/^define Package\/\$(PKG_NAME)\/postinst/,/^endef/p' "$MAKEFILE")"
if printf '%s' "$postinst_body" | grep -q 'owner-fix'; then
	chk ok "Makefile postinst 含 owner-fix 自愈（SDK 构建通道）"
else
	chk fail "Makefile postinst 缺少 owner-fix 自愈（SDK 构建通道）"
fi
if printf '%s' "$postinst_body" | grep -q 'stat -c %U.*bin/openclaw'; then
	chk ok "Makefile postinst 用 stat 探测 bin/openclaw 属主（只在确实不对时才修）"
else
	chk fail "Makefile postinst 缺少 stat -c %U 探测（会无条件跑 owner-fix）"
fi
if printf '%s' "$postinst_body" | grep -q 'uci -q get openclaw.main'; then
	chk ok "Makefile postinst 用 uci 解析安装目录（不写死路径）"
else
	chk fail "Makefile postinst 没有通过 uci 解析安装目录"
fi
# postinst 自愈必须 best-effort：任何失败不得让包安装失败
heal_body="$(printf '%s\n' "$postinst_body" | sed -n '/Self-heal/,/exit 0/p')"
if printf '%s' "$heal_body" | grep -q '|| true'; then
	chk ok "Makefile postinst 自愈 best-effort（|| true 兜底）"
else
	chk fail "Makefile postinst 自愈缺少 || true（可能让包安装失败）"
fi

# ---- 6b. 发行包构建通道的自愈（build_apk.py 的 SCRIPTS 与 .run 模板）------
# 真实教训：postinst 有三条独立通道 —— Makefile define 只进 SDK 构建，
# **发行包（apk v3 / ipk / apk v2 / .run）全部走 build_apk.py 里的模板**。
# 1.8.79 首包就漏了这里：源码修了、包里没有，靠解包验证才抓到。
BUILDER="$PROJ/scripts/build_apk.py"
if [ -f "$BUILDER" ]; then
	builder_scripts="$(sed -n '/^SCRIPTS = """/,/^"""/p' "$BUILDER")"
	if printf '%s' "$builder_scripts" | grep -q 'owner-fix'; then
		chk ok "build_apk.py SCRIPTS 模板含 owner-fix 自愈（apk/ipk 通道）"
	else
		chk fail "build_apk.py SCRIPTS 模板缺少 owner-fix 自愈（发行包 postinst 不会自愈！）"
	fi
	if printf '%s' "$builder_scripts" | grep -q 'stat -c %U.*bin/openclaw'; then
		chk ok "SCRIPTS 模板用 stat 探测（只在确实不对时才修）"
	else
		chk fail "SCRIPTS 模板缺少 stat 探测（会无条件跑 owner-fix）"
	fi
	run_tail="$(sed -n '/script = f"""/,/^"""/p' "$BUILDER")"
	if printf '%s' "$run_tail" | grep -q 'owner-fix'; then
		chk ok ".run 模板含 owner-fix 自愈（免包管理器通道）"
	else
		chk fail ".run 模板缺少 owner-fix 自愈（.run 安装不会自愈！）"
	fi
else
	chk fail "找不到 scripts/build_apk.py（发行包构建器缺失）"
fi

# ---- 7. 不允许在代码里写死 UID（环境适配：判据必须是相对量）--------------
# 只查非注释行：历史注释里有大量「uid 998」的机制说明，那是文档不是判据。
for f in "$LIB" "$REPAIR" "$INSTALL"; do
	bad_line="$(grep -n '998' "$f" 2>/dev/null | grep -v '^[0-9]*:[[:space:]]*#' | head -1)"
	if [ -n "$bad_line" ]; then
		chk fail "$(basename "$f") 代码行出现字面 998（$bad_line）——属主判据必须用 \$OC_USER"
	else
		chk ok "$(basename "$f") 代码行无字面 998"
	fi
done

# ---- 8. 符号链接盲区（2026-11-07 真机：chown -R 对符号链接操作数不递归）----
# 设备的 openclaw 目录可以是指向另一棵 npm 树的符号链接；busybox chown -R
# 遇到符号链接操作数只改链接本身，树纹丝不动且无任何报错。递归 chown 必须
# 先解析真实路径。
if grep -q '^oc_resolve_dir()' "$LIB"; then
	chk ok "lib.sh 提供 oc_resolve_dir()（符号链接解析）"
else
	chk fail "lib.sh 缺少 oc_resolve_dir()（符号链接安装树永远修不好）"
fi
fix_body="$(sed -n '/^oc_fix_install_owner()/,/^}/p' "$LIB")"
if printf '%s' "$fix_body" | grep -q 'oc_resolve_dir'; then
	chk ok "oc_fix_install_owner 先解析真实路径再 chown"
else
	chk fail "oc_fix_install_owner 直接对配置路径 chown（符号链接盲区）"
fi
# 解析出的真实路径必须再过安全校验（符号链接可以指向校验看不见的地方）
if printf '%s' "$fix_body" | grep -q 'oc_validate_base_dir.*\$real\|oc_validate_base_dir "\$real"'; then
	chk ok "解析路径复验安全校验（fail-closed）"
else
	chk fail "解析路径缺少 oc_validate_base_dir 复验（符号链接可绕过安全边界）"
fi
repair_fn="$(sed -n '/_fix_owner_tree()/,/^	}/p' "$REPAIR")"
if printf '%s' "$repair_fn" | grep -q 'oc_resolve_dir'; then
	chk ok "repair.sh owner-fix 解析真实路径再 chown"
else
	chk fail "repair.sh owner-fix 直接对原路径 chown（符号链接盲区）"
fi
# chown 失败不允许整体静默：必须存在失败告警路径
if printf '%s' "$fix_body" | grep -q 'oc_warn.*chown\|chown 失败'; then
	chk ok "chown 失败路径有告警（不再全静默）"
else
	chk fail "chown 失败仍被 2>/dev/null 完全吞掉（无法排障）"
fi
# 复验失败必须带 stat 证据
if printf '%s' "$fix_body" | grep -q 'ls -ld\|stat -c.*%U:%G'; then
	chk ok "复验失败时输出 stat/ls 证据（路径+当前属主）"
else
	chk fail "复验失败时缺少 stat 证据（下轮排查仍无从下手）"
fi
# ---- 9. 树内 launcher 符号链接（2026-11-07 第二层根因）--------------------
# bin/openclaw 可以是指向树外另一棵 npm 树的符号链接：stat/admission 看的是
# 链接终点的属主，而 chown -R 递归不跟随树内链接。必须显式解析并归还。
if printf '%s' "$fix_body" | grep -q '\[ -L "\$probe" \]\|-L "\$probe"'; then
	chk ok "oc_fix_install_owner 对探测对象做符号链接判定（[ -L ]）"
else
	chk fail "oc_fix_install_owner 不判定探测对象是否符号链接（launcher 指树外时修不到）"
fi
if printf '%s' "$fix_body" | grep -q 'readlink -f "\$probe"'; then
	chk ok "探测对象是链接时解析终点（readlink -f）"
else
	chk fail "缺少对探测对象链接终点的解析（树外目标永远轮不到）"
fi
# 链接终点的 chown 也必须过安全校验（不能 chown 任意 readlink 结果）
linktgt_body="$(printf '%s' "$fix_body" | sed -n '/for probe in/,/done/p' | head -40)"
if printf '%s' "$linktgt_body" | grep -q 'oc_validate_base_dir'; then
	chk ok "链接终点 chown 前有 oc_validate_base_dir 校验（fail-closed）"
else
	chk fail "链接终点缺少安全校验（readlink 可被指向系统路径）"
fi
ownerfix_body2="$(sed -n '/OWNER_FIX" = "1"/,/^exit 0/p' "$REPAIR" | head -70)"
if printf '%s' "$ownerfix_body2" | grep -q 'oc_fix_install_owner'; then
	chk ok "owner-fix 对安装树复用 oc_fix_install_owner（与 9b 同路径）"
else
	chk fail "owner-fix 用普通递归 chown 处理安装树（与 9b 行为漂移）"
fi

printf '    共 %s 项，%s 项失败\n' "$n" "$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
