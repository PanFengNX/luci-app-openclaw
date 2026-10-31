#!/bin/sh
# Static contract for cloud_install_version's post-install path hardening order.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
PROJ="$(cd "$HERE/../.." && pwd)"
CLOUD="$PROJ/root/usr/libexec/openclaw/cloud.sh"
CLOUD_TEXT="$(cat "$CLOUD")"

body="$(awk '
/^cloud_install_version\(\)/ { in_fn=1 }
in_fn { print }
in_fn && /^cmd_install_cli\(\)/ { exit }
' "$CLOUD")"

fail=0
case "$body" in
	*'case "$_reason" in'*'symlink|outside-root|insecure-path'*'return 1'* ) : ;;
	*) printf 'FAIL dangerous reason case is missing\n'; fail=1 ;;
esac

count="$(printf '%s\n' "$body" | grep -c 'symlink|outside-root|insecure-path' || true)"
[ "$count" -eq 1 ] || { printf 'FAIL dangerous reason case appears %s times\n' "$count"; fail=1; }

case_line="$(printf '%s\n' "$body" | awk '/symlink\|outside-root\|insecure-path/ { print NR; exit }')"
first_fix="$(printf '%s\n' "$body" | awk '/chown root:root "\$bin"|chmod 755 "\$bin"|chmod go-w "\$bin"/ { print NR; exit }')"
return_line="$(printf '%s\n' "$body" | awk '
/symlink\|outside-root\|insecure-path/ { in_case=1 }
in_case && /return 1/ { print NR; exit }
')"
if [ -z "$case_line" ] || [ -z "$first_fix" ] || [ -z "$return_line" ] || \
	[ "$return_line" -ge "$first_fix" ] || [ "$case_line" -ge "$first_fix" ]; then
	printf 'FAIL dangerous return is not before every repair action\n'
	fail=1
else
	printf '  ok dangerous return precedes chown/chmod repairs\n'
fi

# 修复动作必须无条件收敛到白名单内的 755。
# 写成 `[ -x "$bin" ] || chmod 755` 时，0744/0745 这类 owner 带 x 的 mode
# 修不动，重装也修不好（复核实测指出的功能回归）。
case "$body" in
	*'chmod 755 "$bin"'*) : ;;
	*) printf 'FAIL repair does not normalize the mode to 755\n'; fail=1 ;;
esac
case "$body" in
	*'-x "$bin" ] || chmod 755'*)
		printf 'FAIL mode repair is conditional; 0744 cannot self-heal\n'; fail=1 ;;
	*) : ;;
esac

# ---------------------------------------------------------------- status 一致性
# 现场故障的另一半是「状态页说已安装、列表说没装」。状态必须直接对规范路径
# 取安全结论，不能先经 cloud_bin() 把 symlink 过滤成空，否则同一个组件在
# 两个接口里的说法会再次不一致。
status_body="$(awk '
/^[a-z_][a-z0-9_]*\(\)/ {
	if (in_fn) exit
	if ($0 ~ /^cmd_status\(\)/) in_fn=1
}
in_fn { print }
' "$CLOUD")"

case "$status_body" in
	*'bin="$OC_CLOUD_BIN"'*) : ;;
	*) printf 'FAIL cmd_status does not resolve the canonical component path\n'; fail=1 ;;
esac
case "$status_body" in
	*'cloud_secure_reason "$bin"'*) : ;;
	*) printf 'FAIL cmd_status does not reuse cloud_secure_reason\n'; fail=1 ;;
esac
# 断链的符号链接也要判成 symlink，不能显示成「未安装」。
case "$status_body" in
	*'-L "$bin"'*) : ;;
	*) printf 'FAIL cmd_status drops dangling symlink detection\n'; fail=1 ;;
esac

reason_line="$(printf '%s\n' "$status_body" | awk '/cloud_secure_reason "\$bin"/ { print NR; exit }')"
exec_line="$(printf '%s\n' "$status_body" | awk '/^[[:space:]]*executable=true/ { print NR; exit }')"
if [ -z "$reason_line" ] || [ -z "$exec_line" ] || [ "$reason_line" -ge "$exec_line" ]; then
	printf 'FAIL executable=true is not gated by cloud_secure_reason\n'
	fail=1
else
	printf '  ok status reuses the same component security verdict\n'
fi

# 状态页会以 root 执行 bdpan（version / whoami）。这些执行点必须落在
# 「已通过安全校验」之后，否则属主为服务用户的二进制会被 root 直接跑起来。
gate_line="$(printf '%s\n' "$status_body" | awk '/if \[ "\$executable" = "true" \]/ { print NR; exit }')"
run_line="$(printf '%s\n' "$status_body" | awk '/cloud_run [0-9]+ "\$bin"/ { print NR; exit }')"
if [ -n "$run_line" ]; then
	if [ -z "$gate_line" ] || [ "$run_line" -le "$gate_line" ]; then
		printf 'FAIL bdpan is executed before the component is verified secure\n'
		fail=1
	else
		printf '  ok bdpan execution stays behind the security gate\n'
	fi
fi
case "$status_body" in
	*'-x "$bin" ]'*) printf 'FAIL status still trusts a bare -x check on bdpan\n'; fail=1 ;;
	*) : ;;
esac

# OC_CLOUD_ROOT 为空时，根范围 case 会退化成「任何绝对路径都在根内」，
# 且 `[ "$d" = "" ]` 永假导致 dirname / 原地打转。必须有 fail-closed 与
# 终止兜底，否则 status 这个高频入口会被拖死。
case "$CLOUD_TEXT" in
	*'[ -n "${OC_CLOUD_ROOT:-}" ]'*) : ;;
	*) printf 'FAIL missing fail-closed guard for empty OC_CLOUD_ROOT\n'; fail=1 ;;
esac
case "$CLOUD_TEXT" in
	*'[ "$d" = "/" ] && { printf'*'outside-root'* ) : ;;
	*) printf 'FAIL missing loop terminator when walking above the cloud root\n'; fail=1 ;;
esac

[ "$fail" -eq 0 ]
