#!/bin/sh
# owner-fn-behavior.sh — lib.sh 新函数的行为级冒烟（MSYS 沙箱）
# 探测 / fail-open / 安全闸门三条路径都实际执行一遍。
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(cd "$HERE/../.." && pwd)"   # work/ 根（tools/tests 上两级）
LIB="$WORK/root/usr/libexec/openclaw/lib.sh"
SBX="$WORK/.tmp/owner-fn-test.$$"
rm -rf "$SBX"
mkdir -p "$SBX/oc/bin" || exit 2
echo "x" >"$SBX/oc/bin/openclaw"

fail=0
chk() { n=$((n+1)); if [ "$1" = ok ]; then printf '  ok    %s\n' "$2"; else printf '  FAIL  %s\n' "$2"; fail=$((fail+1)); fi; }
n=0

# 1. 沙箱探测：树属主（MSYS 当前用户）≠ OC_USER("openclaw") → bad 必须为真
(
	# lib.sh 载入会找同目录 credential.sh——直接用 work 副本原位 source
	. "$LIB" 2>/dev/null
	# 覆盖路径函数指向沙箱（真实环境由 uci 决定，这里只测逻辑）
	oc_oc_dir() { printf '%s' "$FAKE"; }
	oc_oc_dir_safe() { return 0; }
	FAKE="$SBX/oc"

	if oc_install_owner_bad; then
		echo "probe-mismatch: yes"
	else
		echo "probe-mismatch: no"
	fi

	# 2. fail-open：MSYS 的 /etc/passwd 无 openclaw 用户 → 修不动但必须 rc=0
	rc=0; oc_fix_install_owner || rc=$?
	echo "failopen-rc=$rc"

	# 3. 安全闸门：oc_oc_dir_safe 失败 → 必须 rc=1（拒绝递归 chown）
	oc_oc_dir_safe() { return 1; }
	rc=0; oc_fix_install_owner || rc=$?
	echo "gate-rc=$rc"

	# 4. 探测不存在目录 → bad 必须为假（无需修复）
	oc_oc_dir_safe() { return 0; }
	FAKE="$SBX/nonexistent"
	if oc_install_owner_bad; then
		echo "probe-missing: bad"
	else
		echo "probe-missing: notbad"
	fi

	# 5. probe 优先级：删掉 bin/openclaw 后应退到 lib/node_modules/openclaw
	FAKE="$SBX/oc"
	rm -f "$SBX/oc/bin/openclaw"
	mkdir -p "$SBX/oc/lib/node_modules/openclaw"
	echo "y" >"$SBX/oc/lib/node_modules/openclaw/package.json"
	if oc_install_owner_bad; then
		echo "probe-fallback: yes"
	else
		echo "probe-fallback: no"
	fi
) >"$SBX/out.txt" 2>"$SBX/err.txt"

while IFS= read -r line; do
	case "$line" in
		'probe-mismatch: yes') chk ok "探测：属主不匹配时返回需修复" ;;
		'probe-mismatch: no') chk fail "探测：属主不匹配时未识别" ;;
		failopen-rc=0) chk ok "fail-open：无服务用户时返回 0（不拦截）" ;;
		failopen-rc=*) chk fail "fail-open 路径返回非 0（$line）" ;;
		gate-rc=1) chk ok "安全闸门：oc_oc_dir_safe 失败时返回 1" ;;
		gate-rc=*) chk fail "安全闸门未拦截（$line）" ;;
		'probe-missing: notbad') chk ok "探测：目录不存在时不算需修复" ;;
		'probe-missing: bad') chk fail "探测：目录不存在被误判为需修复" ;;
		'probe-fallback: yes') chk ok "探测：probe 对象回退到 npm 包根" ;;
		'probe-fallback: no') chk fail "探测：回退失效" ;;
	esac
done <"$SBX/out.txt"

if [ -s "$SBX/err.txt" ]; then
	printf '  (stderr) %s\n' "$(head -3 "$SBX/err.txt")"
fi

printf '  共 %s 项，%s 项失败\n' "$n" "$fail"
rc=1; [ "$fail" -eq 0 ] && rc=0
rm -rf "$SBX"
exit $rc
