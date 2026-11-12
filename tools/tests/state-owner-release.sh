#!/bin/sh
# 回归：状态目录被「活着的半死网关」占用时能否安全释放。
#
# 覆盖的真机现象：页面卡在「运行中（端口未应答）」，日志只有
#   Another gateway (pid N) already owns this state directory
# 官方契约（docs.openclaw.ai/gateway/gateway-lock）允许先停掉持有者。
# 这里断言的核心是"不杀错"：非本插件进程不杀、健康网关不杀、刚启动的不杀、
# 并且从不删锁文件。
#
# 用法：sh tools/tests/state-owner-release.sh [项目根]
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
PROJ="${1:-$(cd "$HERE/../.." && pwd)}"
LIB="$PROJ/root/usr/libexec/openclaw/lib.sh"
REPAIR="$PROJ/root/usr/libexec/openclaw/repair.sh"
TMP="$(mktemp -d 2>/dev/null || echo "/tmp/oc-owner-test.$$")"
mkdir -p "$TMP/bin"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

pass=0
failn=0
ok() { pass=$((pass + 1)); printf '    ok    %s\n' "$1"; }
no() { failn=$((failn + 1)); printf '    FAIL  %s%s\n' "$1" "${2:+  ($2)}"; }
chk() { if [ "$1" = "$2" ]; then ok "$3"; else no "$3" "got=$1 want=$2"; fi; }

# ---- 桩 curl：由 $TMP/curl_code 决定返回码；$TMP/curl_only 非空时只对 URL
#      含该子串的请求返回该码，其余返回 000（用来证明探测确实试了多个主机）。
cat >"$TMP/bin/curl" <<'EOF'
#!/bin/sh
code="$(cat "$OC_TEST_CURL_CODE" 2>/dev/null)"
only="$(cat "$OC_TEST_CURL_ONLY" 2>/dev/null)"
deny="$(cat "$OC_TEST_CURL_DENY" 2>/dev/null)"
url=""
for a in "$@"; do url="$a"; done
if [ -n "$deny" ]; then
	case "$url" in
		*"$deny"*) printf '000'; exit 0 ;;
	esac
fi
if [ -n "$only" ]; then
	case "$url" in
		*"$only"*) printf '%s' "${code:-000}" ;;
		*) printf '000' ;;
	esac
	exit 0
fi
printf '%s' "${code:-000}"
exit 0
EOF
chmod +x "$TMP/bin/curl"

# ---- 桩 uci：只回答 network.lan.ipaddr（bind=lan 时探测会先试它）-----------
cat >"$TMP/bin/uci" <<'EOF'
#!/bin/sh
case "$*" in
	*"network.lan.ipaddr"*) [ -n "${OC_TEST_LANIP:-}" ] && printf '%s\n' "$OC_TEST_LANIP" ;;
esac
exit 0
EOF
chmod +x "$TMP/bin/uci"

mksidecar() {
	# mksidecar <state-dir> <pid>：sidecar 在 $state/tmp/openclaw-<uid>/
	d="$1/tmp/openclaw-1000"
	mkdir -p "$d"
	printf '{"pid":%s,"host":"dev","role":"gateway"}\n' "$2" >"$d/state.abc123.lock"
}

run_case() {
	# run_case <state-dir> <port> <own-list> <curl-code> [min-age] [bind] [lanip] [only-url-substr]
	(
		PATH="$TMP/bin:$PATH"
		OC_TEST_CURL_CODE="$TMP/curl_code"
		OC_TEST_CURL_ONLY="$TMP/curl_only"
		OC_TEST_LANIP="${7:-}"
		printf '%s' "$4" >"$OC_TEST_CURL_CODE"
		printf '%s' "${8:-}" >"$OC_TEST_CURL_ONLY"
		export PATH OC_TEST_CURL_CODE OC_TEST_CURL_ONLY OC_TEST_LANIP
		. "$LIB" >/dev/null 2>&1
		oc_release_blocked_state_owner "$1" "$2" "${6:-lan}" "$3" "${5:-120}" >/dev/null 2>&1
		printf '%s' "$?"
	)
}

printf '== 状态目录占用释放（gateway-lock） ==\n'

# 1) 没有任何 sidecar
mkdir -p "$TMP/c1"
chk "$(run_case "$TMP/c1" 18789 "" 200)" 0 "没有锁时不干预"

# 2) sidecar 里的 pid 早已不存在
mksidecar "$TMP/c2" 999999
chk "$(run_case "$TMP/c2" 18789 "" 000)" 0 "持有者已死：交给运行时自行回收，不杀不删"

# 2b) 持有者已死，但端口上有别的服务在应答：仍返回 0（没有活着的占用者）
mksidecar "$TMP/c2b" 999999
chk "$(run_case "$TMP/c2b" 18789 "" 200)" 0 "持有者已死时不因端口应答而误判"

# 3) 存活的持有者不是本插件网关（不能杀）
sleep 60 &
foreign=$!
mksidecar "$TMP/c3" "$foreign"
chk "$(run_case "$TMP/c3" 18789 "" 000 0)" 1 "非本插件进程：拒绝自动释放"
if kill -0 "$foreign" 2>/dev/null; then ok "非本插件进程仍然存活（未被误杀）"; else no "非本插件进程被误杀"; fi
kill "$foreign" 2>/dev/null

# 4) 本插件网关但端口在应答 = 健康，不许干预
sleep 60 &
healthy=$!
mksidecar "$TMP/c4" "$healthy"
chk "$(run_case "$TMP/c4" 18789 "$healthy" 200 0)" 2 "健康网关不干预（官方行为也是让它继续持有）"
if kill -0 "$healthy" 2>/dev/null; then ok "健康网关仍然存活"; else no "健康网关被杀掉了"; fi
kill "$healthy" 2>/dev/null

# 4b) bind=lan 时只监听 LAN 地址（回环拒绝）：必须靠 LAN IP 探测判成健康。
#     这是复核指出的 H2：只探 127.0.0.1 会把健康网关误杀。
sleep 60 &
lanonly=$!
mksidecar "$TMP/c4b" "$lanonly"
# min-age 传 0：让"健康就不该干预"这一条独立成立，不被存活时间护栏掩盖。
chk "$(run_case "$TMP/c4b" 18789 "$lanonly" 200 0 lan 192.168.10.2 192.168.10.2)" 2 "只监听 LAN 的健康网关不被误判（bind 感知探测）"
if kill -0 "$lanonly" 2>/dev/null; then ok "只监听 LAN 的网关仍然存活"; else no "只监听 LAN 的网关被杀掉了"; fi
kill "$lanonly" 2>/dev/null

# 4c) 同一个桩下对比：bind=lan 命中 LAN IP，bind=loopback 只探回环 → 失败。
chk "$(
	PATH="$TMP/bin:$PATH"
	OC_TEST_CURL_CODE="$TMP/curl_code"
	OC_TEST_CURL_ONLY="$TMP/curl_only"
	OC_TEST_LANIP=192.168.10.2
	printf '200' >"$OC_TEST_CURL_CODE"
	printf '192.168.10.2' >"$OC_TEST_CURL_ONLY"
	export PATH OC_TEST_CURL_CODE OC_TEST_CURL_ONLY OC_TEST_LANIP
	. "$LIB" >/dev/null 2>&1
	oc_http_answers 18789 lan >/dev/null 2>&1; a=$?
	oc_http_answers 18789 loopback >/dev/null 2>&1; b=$?
	printf '%s/%s' "$a" "$b"
)" "0/1" "探测按 bind 换主机：lan 命中，loopback 不命中"

# 4d) 可达性判据：只要拿到任意 HTTP 状态码就算在监听。
#     真机证据：网关 / 回 401 时旧判据把健康网关报成"端口未应答"。
probe() {
	# probe <code> [only] [deny] -> oc_http_answers 的返回码
	(
		PATH="$TMP/bin:$PATH"
		OC_TEST_CURL_CODE="$TMP/curl_code"
		OC_TEST_CURL_ONLY="$TMP/curl_only"
		OC_TEST_CURL_DENY="$TMP/curl_deny"
		OC_TEST_LANIP=
		printf '%s' "$1" >"$OC_TEST_CURL_CODE"
		printf '%s' "${2:-}" >"$OC_TEST_CURL_ONLY"
		printf '%s' "${3:-}" >"$OC_TEST_CURL_DENY"
		export PATH OC_TEST_CURL_CODE OC_TEST_CURL_ONLY OC_TEST_CURL_DENY OC_TEST_LANIP
		. "$LIB" >/dev/null 2>&1
		oc_http_answers 18789 lan >/dev/null 2>&1
		printf '%s' "$?"
	)
}
chk "$(probe 401)" 0 "401 也算在监听（不再把需鉴权的健康网关判成死的）"
chk "$(probe 503)" 0 "503 也算在监听（端口已绑定，只是服务内部报错）"
chk "$(probe 200 /healthz)" 0 "优先探 /healthz：只有健康端点通也判为在监听"
chk "$(probe 200 "" /healthz)" 0 "/healthz 不通时回退探 /，仍然判为在监听"
chk "$(probe 000)" 1 "连不上（000）才算不应答"

# 5) 本插件网关 + 端口不应答 = 半死，必须停掉（min-age 传 0 才能立即判定）
sleep 60 &
halfdead=$!
mksidecar "$TMP/c5" "$halfdead"
chk "$(run_case "$TMP/c5" 18789 "$halfdead" 000 0)" 0 "半死网关被释放"
if kill -0 "$halfdead" 2>/dev/null; then no "半死网关仍在运行"; else ok "半死网关已停止"; fi
kill "$halfdead" 2>/dev/null

# 5b) 刚启动的网关（存活时间 < min-age）即使端口不应答也不许杀
sleep 60 &
fresh=$!
mksidecar "$TMP/c5b" "$fresh"
chk "$(run_case "$TMP/c5b" 18789 "$fresh" 000 120)" 3 "刚启动的网关不杀（挡住 PID 复用与启动期误杀）"
if kill -0 "$fresh" 2>/dev/null; then ok "新启动的网关仍然存活"; else no "新启动的网关被杀掉了"; fi
kill "$fresh" 2>/dev/null

# 6) sidecar 内容不可解析（没有 pid）→ 不做任何动作
mkdir -p "$TMP/c6/tmp/openclaw-1000"
printf 'not-json\n' >"$TMP/c6/tmp/openclaw-1000/state.abc.lock"
chk "$(run_case "$TMP/c6" 18789 "" 000)" 0 "sidecar 无 pid：忽略，不猜"

# 7) oc_stop_pids 的入参护栏：非数字与 pid 1 一律拒绝
(
	. "$LIB" >/dev/null 2>&1
	oc_stop_pids abc >/dev/null 2>&1
	printf 'bad=%s ' "$?"
	oc_stop_pids 1 >/dev/null 2>&1
	printf 'one=%s' "$?"
) >"$TMP/guard.txt" 2>/dev/null
chk "$(cat "$TMP/guard.txt")" "bad=1 one=1" "oc_stop_pids 拒绝非法 pid 与 pid 1"

# ---- 静态断言：接线、restart、不删锁 --------------------------------------
if grep -q 'oc_release_blocked_state_owner "\$DATA" "\$port"' "$REPAIR"; then
	ok "repair.sh 在端口检查之后调用释放逻辑"
else
	no "repair.sh 未调用 oc_release_blocked_state_owner"
fi
if grep -q 'gateway recover-lock' "$REPAIR"; then
	ok "repair.sh 提示官方排查命令"
else
	no "repair.sh 缺少官方命令提示"
fi
# 停掉占用者之后必须真的把服务拉起来，否则"修好了"仍然是停的。
if sed -n '/^# 15 ---/,$p' "$REPAIR" | grep -q 'INITD" restart'; then
	ok "repair.sh 末尾会重启服务（释放占用后能真正起回来）"
else
	no "repair.sh 释放占用后没有重启服务"
fi
if grep -q '^oc_state_lock_pid() {' "$LIB" && grep -q '^oc_state_owner_pids() {' "$LIB"; then
	ok "sidecar pid 解析与枚举函数都在 lib.sh"
else
	no "lib.sh 缺少 sidecar 解析函数"
fi
# 任何路径都不得删除锁文件：官方明确要求改走 recover-lock，手工删除会留下
# 指向已消失进程的租约，导致此后每次启动与 doctor 都判"维护中"。
if sed -n '/oc_state_owner_pids() {/,/^}/p;/oc_release_blocked_state_owner() {/,/^}/p' "$LIB" | grep -qE '(^|[[:space:]])rm[[:space:]]+-[rf]'; then
	no "释放逻辑里出现了 rm（不得手工删锁文件）"
else
	ok "释放逻辑不删除任何锁文件"
fi

total=$((pass + failn))
printf '\n    共 %s 项，%s 项失败\n' "$total" "$failn"
[ "$failn" -eq 0 ] || exit 1
exit 0
