#!/bin/sh
# openclaw - OpenClaw Launcher for OpenWrt (iStore compatible CLI)
#
# Native (non-docker) deployment of the official OpenClaw package:
#   procd + private Node.js runtime + npm global install of "openclaw".
#
# Also implements the iStoreOS entry.sh contract (optional - the package
# works standalone; iStore just uses this to show/control it):
#   openclaw.sh status   -> "" (not deployed) | "stopped" | "running"
#   openclaw.sh port     -> gateway port
#   openclaw.sh token    -> gateway auth token
#   openclaw.sh install|start|stop

OC_LIB="/usr/libexec/openclaw/lib.sh"
OC_VER="/usr/libexec/openclaw/versions.sh"
OC_INSTALL="/usr/libexec/openclaw/install.sh"
OC_MODELS="/usr/libexec/openclaw/models.sh"
OC_CHANNELS="/usr/libexec/openclaw/channels.sh"
OC_REPAIR="/usr/libexec/openclaw/repair.sh"
OC_BACKUP="/usr/libexec/openclaw/backup.sh"
. "$OC_LIB"

INITD="/etc/init.d/openclaw"
# inside the private 0700 rundir - see oc_rundir() in lib.sh
DIAG_PREFIX="${OC_RUNDIR:-/tmp/.openclaw}/diag"
OC_INST_RC="${OC_RUNDIR:-/tmp/.openclaw}/install.rc"
OC_INST_DONE="${OC_RUNDIR:-/tmp/.openclaw}/install.done"
# pid of the running install.sh (written by install-bg) and the time install-bg
# was launched. The latter only covers the fork -> exec window: for a few
# milliseconds the pid is alive but its cmdline does not mention install.sh yet,
# and without it a status poll right after install-bg would report "lost".
OC_INST_PID="${OC_RUNDIR:-/tmp/.openclaw}/install.pid"
OC_INST_START="${OC_RUNDIR:-/tmp/.openclaw}/install.start"
OC_INST_START_GRACE=15

installed() {
	[ -x "$(oc_oc_bin)" ] && [ -x "$(oc_node_bin)" ]
}

# ---------------------------------------------------------------- guards
# Modelled on iStoreOS's manager: never touch a system directory, never start on a
# privileged port, and never let two operations run at the same time.
require_safe() {
	oc_require_base_dir
	local p
	p="$(get_port)"
	if ! oc_safe_port "$p"; then
		oc_err "端口 $p 不安全（必须是 1025-65535 之间的数字），已拒绝操作"
		exit 2
	fi
}

need_lock() {
	# mutating commands only
	oc_lock_acquire || exit 2
}

json_escape() {
	# stdin -> body of a JSON string literal (surrounding quotes not included)
	#
	# doctor / repair print progress lines with CR and ANSI escapes. Raw control
	# characters are invalid inside a JSON string and made the LuCI page throw
	# on JSON.parse, so they are stripped here before the awk pass.
	if command -v tr >/dev/null 2>&1; then
		tr -d '\000-\010\013\014\016-\037\177' 2>/dev/null | _json_escape_awk
	else
		_json_escape_awk
	fi
}

_json_escape_awk() {
	awk '{ gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); gsub(/\t/, "\\t"); printf "%s\\n", $0 }'
}

# ---------------------------------------------------------------- async diag
# doctor / repair can take minutes; running them inline makes the LuCI request
# time out and leaves the user with a spinning button. Run detached and poll.
DIAG_TIMEOUT=900   # a diag that runs longer than this is considered lost

diag_paths() {
	DIAG_LOG="${DIAG_PREFIX}-${1}.log"
	DIAG_PID="${DIAG_PREFIX}-${1}.pid"
	DIAG_EXIT="${DIAG_PREFIX}-${1}.exit"
	DIAG_LOCK="${DIAG_PREFIX}-${1}.lock"
	DIAG_TS="${DIAG_PREFIX}-${1}.ts"
}

# returns 0 when a previous run is provably gone (dead pid / over the timeout),
# so its lock can be reclaimed instead of the button spinning forever
diag_stale() {
	[ -d "$DIAG_LOCK" ] || return 1
	local pid ts now
	pid="$(cat "$DIAG_PID" 2>/dev/null || true)"
	if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
		# alive - only give up on it once it blows the hard timeout
		ts="$(cat "$DIAG_TS" 2>/dev/null || true)"
		now="$(date +%s)"
		case "${ts:-}" in ''|*[!0-9]*) return 1 ;; esac
		[ $((now - ts)) -gt "$DIAG_TIMEOUT" ] || return 1
		oc_warn "诊断 ${1:-} 已运行超过 ${DIAG_TIMEOUT}s，判定为丢失并回收"
		return 0
	fi
	oc_warn "诊断 ${1:-} 的进程已退出，回收残留锁：$DIAG_LOCK"
	return 0
}

diag_body() {
	# runs in the background subshell
	set +e
	case "$1" in
		doctor)
			oc_env_doctor ;;
		doctor-fix)
			printf '===== openclaw doctor =====\n'
			oc_env_doctor
			printf '\n===== openclaw doctor --fix =====\n'
			if installed; then
				HOME="$(oc_home_dir)" PATH="$(oc_node_dir)/bin:$(oc_oc_dir)/bin:$PATH" \
					oc_timeout 300 "$(oc_oc_bin)" doctor --fix 2>&1 | tail -n 60
			fi
			printf '\n===== 一键修复 =====\n'
			sh "$OC_REPAIR" ;;
		repair)
			sh "$OC_REPAIR" ;;
	esac
}

cmd_diag_run() {
	local name="${2:-}"
	case "$name" in
		doctor|doctor-fix|repair) ;;
		*) printf '{"ok":false,"error":"unknown diag: %s"}\n' "$name"; return 1 ;;
	esac
	diag_paths "$name"
	if ! mkdir "$DIAG_LOCK" 2>/dev/null; then
		if ! diag_stale "$name"; then
			printf '{"busy":true,"name":"%s"}\n' "$name"
			return 0
		fi
		rm -rf "$DIAG_LOCK" 2>/dev/null || true
		mkdir "$DIAG_LOCK" 2>/dev/null || {
			printf '{"ok":false,"error":"无法启动诊断"}\n'
			return 1
		}
	fi
	rm -f "$DIAG_EXIT" 2>/dev/null || true
	: >"$DIAG_LOG"
	date +%s >"$DIAG_TS"
	(
		diag_body "$name" >"$DIAG_LOG" 2>&1
		echo "$?" >"$DIAG_EXIT"
		rm -rf "$DIAG_LOCK" 2>/dev/null || true
	) &
	# $$ is still the parent's pid inside a subshell, so record the real
	# worker pid from $! - otherwise liveness checks look at the wrong process
	echo "$!" >"$DIAG_PID"
	printf '{"started":true,"name":"%s"}\n' "$name"
}

cmd_diag_poll() {
	local name="${2:-}" out rc
	case "$name" in
		doctor|doctor-fix|repair) ;;
		*) printf '{"ok":false,"error":"unknown diag: %s"}\n' "$name"; return 1 ;;
	esac
	diag_paths "$name"
	[ -f "$DIAG_LOG" ] || { printf '{"done":true,"rc":"0","output":""}\n'; return 0; }
	out="$(tail -n 400 "$DIAG_LOG" | json_escape)"
	if [ -f "$DIAG_EXIT" ]; then
		rc="$(cat "$DIAG_EXIT" 2>/dev/null)"
		printf '{"done":true,"rc":"%s","output":"%s"}\n' "${rc:-0}" "$out"
		return 0
	fi
	# no exit code yet - if the worker is gone the run was killed; report it
	# instead of leaving the UI in "running" forever
	if diag_stale "$name"; then
		rm -rf "$DIAG_LOCK" 2>/dev/null || true
		rc=124
		out="${out}\\n-----\\n诊断进程已中断（被终止或超时 ${DIAG_TIMEOUT}s），以上为已产生的输出。"
		printf '{"done":true,"rc":"%s","output":"%s"}\n' "$rc" "$out"
		return 0
	fi
	printf '{"done":false,"output":"%s"}\n' "$out"
}

running() {
	pgrep -f 'openclaw.*(gateway|run)' >/dev/null 2>&1 && return 0
	[ -f /var/run/openclaw.pid ] && \
		kill -0 "$(cat /var/run/openclaw.pid 2>/dev/null)" 2>/dev/null && return 0
	return 1
}

get_port() {
	local p
	p="$(uci_get main.port '')"
	[ -n "$p" ] || p="18789"
	printf '%s' "$p"
}

get_token() {
	local conf t
	conf="$(oc_conf)"
	[ -f "$conf" ] || return 0
	t="$(oc_json_get "$conf" '$.gateway.auth.token')"
	[ -n "$t" ] || t="$(sed -n 's/.*"token"[^"]*"\([^"]*\)".*/\1/p' "$conf" | head -n1)"
	printf '%s' "$t"
}

cmd_status() {
	if ! installed; then
		printf ''
		return 1
	fi
	if running; then printf 'running\n'; else printf 'stopped\n'; fi
}

cmd_start() {
	installed || { oc_err "OpenClaw 未安装"; return 1; }
	require_safe
	need_lock
	"$INITD" start
}

cmd_stop() {
	"$INITD" stop
}

cmd_restart() {
	installed || { oc_err "OpenClaw 未安装"; return 1; }
	require_safe
	need_lock
	"$INITD" restart
}

cmd_install() {
	shift
	require_safe
	need_lock
	sh "$OC_INSTALL" "$@"
}

cmd_install_bg() {
	# non blocking install for LuCI; progress in $OC_INSTALLLOG
	# NOTE: do not hold the lock here - this process exits immediately, which
	# would release it. install.sh acquires (and holds) the lock itself.
	shift
	require_safe
	if oc_locked; then
		oc_err "另一个操作正在运行，请稍后再试"
		exit 2
	fi
	# install.sh takes the lock only after it has been forked, so oc_locked
	# alone leaves a window where two clicks both get through. The pid-based
	# check closes it (and also covers a foreground `install`).
	if oc_inst_alive; then
		oc_err "已有安装进程在运行，请稍后再试"
		exit 2
	fi
	rm -f "$OC_INSTALLLOG" "$OC_INST_DONE" "$OC_INST_RC" "$OC_INST_PID" 2>/dev/null || true
	mkdir -p "$OC_LOGDIR" "$(dirname "$OC_INST_RC")" 2>/dev/null || true
	date +%s >"$OC_INST_START" 2>/dev/null || true
	(
		# Record install.sh's own pid, not the subshell's: a forked shell keeps
		# the parent's cmdline (openclaw.sh install-bg ...), which does not
		# contain install.sh, so the liveness check would never match it.
		#
		# 用 >> 而不是 >：install.sh 自己也往这个文件追加（ilog），而 `>` 打开的
		# 描述符有独立的文件偏移，两边会互相覆盖 —— 日志里出现重复行和半截行。
		# O_APPEND 让所有写者都落在文件末尾。日志在启动前已被 rm -f，
		# install.sh 开头还会再截断一次，所以不需要这里的 `>` 来清空。
		sh "$OC_INSTALL" "$@" >>"$OC_INSTALLLOG" 2>&1 &
		inst_pid=$!
		printf '%s' "$inst_pid" >"$OC_INST_PID" 2>/dev/null || true
		wait "$inst_pid"
		inst_rc=$?
		printf '%s' "$inst_rc" >"$OC_INST_RC"
		touch "$OC_INST_DONE"
	) &
	# OC_INSTALLLOG may contain quotes after the user picked a custom path
	printf '{"started":true,"log":"%s"}\n' "$(oc_json_str "$OC_INSTALLLOG")"
}

# ---------------------------------------------------------------- install status
# Liveness is decided from /proc/<pid>/cmdline (argv, NUL separated) only -
# never `pgrep -f install.sh`, which also matches an editor, a `tail -f` or a
# grep and cannot tell a recycled pid from the real install. Same convention
# as oc_gateway_pids() in lib.sh.
oc_inst_cmdline_ok() {
	# True when <pid> is alive AND its argv is `<shell> <install.sh> ...`.
	# Both halves matter:
	#   * the pid alone is not enough - pids get recycled, and the next process
	#     to inherit the number would look like a running install forever;
	#   * a plain substring match on the whole cmdline would also hit an editor
	#     (`vi install.sh`), a grep, or a `sh -c '... install.sh ...'` wrapper.
	# So one argv token must equal $OC_INSTALL exactly, and argv[0] must be a
	# shell. Newlines cannot occur in either (fixed path, shell name).
	local p="$1"
	case "$p" in ''|*[!0-9]*) return 1 ;; esac
	[ -d "/proc/$p" ] || return 1
	tr '\0' '\n' <"/proc/$p/cmdline" 2>/dev/null | awk -v want="$OC_INSTALL" '
		NR == 1 { a0 = $0; sub(/.*\//, "", a0) }
		$0 == want { hit = 1 }
		END { exit (hit && a0 ~ /^(sh|ash|bash|dash|busybox)$/) ? 0 : 1 }
	'
}

oc_inst_pid_alive() {
	local pid
	pid="$(cat "$OC_INST_PID" 2>/dev/null)"
	oc_inst_cmdline_ok "$pid"
}

oc_inst_scan_pid() {
	# Fallback for pid files left by an older version (or lost on reboot):
	# find the install.sh process by argv instead of trusting a pid.
	local d pid
	for d in /proc/[0-9]*; do
		[ -d "$d" ] || continue
		pid="${d#/proc/}"
		if oc_inst_cmdline_ok "$pid"; then
			printf '%s' "$pid"
			return 0
		fi
	done
	return 1
}

oc_inst_alive() {
	oc_inst_pid_alive && return 0
	oc_inst_scan_pid >/dev/null 2>&1
}

oc_inst_starting() {
	# install-bg forks first and install.sh gets its own cmdline a moment
	# later; treat the first OC_INST_START_GRACE seconds as "starting" so a
	# poll in that window is not reported as lost.
	local ts now
	[ -f "$OC_INST_START" ] || return 1
	ts="$(cat "$OC_INST_START" 2>/dev/null)"
	case "$ts" in ''|*[!0-9]*) return 1 ;; esac
	now="$(date +%s)"
	[ $((now - ts)) -le "$OC_INST_START_GRACE" ]
}

cmd_install_status() {
	local rc state msg done_at
	if [ -f "$OC_INST_DONE" ]; then
		rc="$(cat "$OC_INST_RC" 2>/dev/null)"
		case "$rc" in ''|*[!0-9]*) rc="" ;; esac
		[ "$rc" = "0" ] && state=done || state=failed
		# mtime of the marker, for the UI; an old marker does NOT change the
		# state (a 24h+ result is still a result).
		done_at="$(stat -c %Y "$OC_INST_DONE" 2>/dev/null)"
		case "$done_at" in
			''|*[!0-9]*) done_at="$(date -r "$OC_INST_DONE" +%s 2>/dev/null)" ;;
		esac
		case "$done_at" in ''|*[!0-9]*) done_at="" ;; esac
	else
		rc=""
		if oc_inst_alive || oc_inst_starting; then
			state=running
		else
			# No completion marker and no process: the install was killed
			# (OOM, manual kill, shell exit). Saying "running" forever is
			# what made the UI look hung.
			state=lost
			msg="后台安装进程已退出，但没有留下完成标记，可能被系统杀死或磁盘写满；请重试安装。"
		fi
	fi
	printf '{"state":"%s","rc":"%s","log":"%s","msg":"%s","done_at":"%s"}\n' \
		"$state" "${rc:-}" "$(oc_json_str "$OC_INSTALLLOG")" "$(oc_json_str "$msg")" "$done_at"
}

cmd_update() {
	# update openclaw (and node if required)
	shift
	require_safe
	need_lock
	sh "$OC_INSTALL" --force "$@"
}

cmd_uninstall() {
	require_safe
	need_lock
	local base ocdir
	base="$(oc_base_dir)"
	ocdir="$(oc_oc_dir)"

	# 程序目录是用户可配置的，删之前必须单独确认：
	#   * 形状不安全（/etc、含 ..、符号链接）→ 直接拒绝
	#   * 等于安装目录、或是安装目录的上级 → 会把 home 数据一起删掉，也拒绝
	if ! oc_oc_dir_safe; then
		oc_err "拒绝卸载：配置的 OpenClaw 程序目录不安全（$ocdir）"
		exit 2
	fi
	if [ "$ocdir" = "$base" ]; then
		oc_err "拒绝卸载：程序目录与安装目录相同（$ocdir），会连带删除数据"
		exit 2
	fi
	case "$base" in
		"$ocdir"/*)
			oc_err "拒绝卸载：程序目录是安装目录的上级（$ocdir 包含 $base），会连带删除数据"
			exit 2 ;;
	esac

	"$INITD" stop >/dev/null 2>&1
	"$INITD" disable >/dev/null 2>&1
	oc_kill_tree
	oc_info "删除 $ocdir 与 $base/node（保留 $base/home 配置数据）"
	rm -rf "$ocdir" "$base/node" "$base/npm-cache" "$base/cache"
	uci_set main.installed 0
	uci_commit
	printf '{"ok":true}\n'
}

cmd_info() {
	local st port token ver nver base free home ocdir
	installed && st="$(running && echo running || echo stopped)" || st="not_installed"
	port="$(get_port)"
	token="$(get_token)"
	base="$(oc_base_dir)"
	ocdir="$(oc_oc_dir)"
	free="$(oc_free_mb "$base")"
	home="$(oc_home_dir)"
	if installed; then
		ver="$(HOME="$home" PATH="$(oc_node_dir)/bin:$(oc_oc_dir)/bin:$PATH" "$(oc_oc_bin)" --version 2>/dev/null | head -n1)"
		nver="$( "$(oc_node_bin)" -v 2>/dev/null)"
	fi
	printf '{"status":"%s","installed":%s,"port":"%s","token":"%s","openclaw":"%s","node":"%s","node_mode":"%s","base_dir":"%s","openclaw_dir":"%s","oc_dir_custom":%s,"home":"%s","free_mb":"%s","arch":"%s","musl":%s,"bind":"%s","node_mirror":"%s","url":"http://%s:%s/"}\n' \
		"$st" \
		"$(installed && echo true || echo false)" \
		"$port" "$token" "${ver:-}" "${nver:-}" \
		"$(oc_node_mode)" \
		"$(oc_json_str "$base")" "$(oc_json_str "$ocdir")" \
		"$([ -n "$(uci_get main.openclaw_dir '')" ] && echo true || echo false)" \
		"$home" "${free:-0}" \
		"$(oc_arch)" "$(oc_is_musl && echo 1 || echo 0)" \
		"$(uci_get main.bind lan)" \
		"$(oc_json_str "$(uci_get main.node_mirror '')")" \
		"$(uci -q get network.lan.ipaddr 2>/dev/null || echo 127.0.0.1)" "$port"
}

cmd_versions() {
	local ocv njson tag
	ocv="$(sh "$OC_VER" oc-versions refresh)"
	njson="$(sh "$OC_VER" node-versions refresh)"
	printf '{"openclaw":%s,"node":%s,"sources":%s}\n' \
		"${ocv:-[]}" "${njson:-[]}" "$(sh "$OC_VER" urls)"
}

cmd_log() {
	local n="${2:-200}"
	[ -f "$OC_LOGFILE" ] && tail -n "$n" "$OC_LOGFILE"
}

cmd_tasklog() {
	local n="${2:-200}"
	[ -f "$OC_TASKLOG" ] && tail -n "$n" "$OC_TASKLOG"
}

cmd_unlock() {
	# unlock : 只读判断 + 必要时清锁，**不取锁**（取锁就永远解不开了）。
	# stdout 只允许一行 JSON；说明信息一律走 stderr。
	local pid cmd reason pidjson
	if ! oc_locked; then
		printf '{"ok":true,"locked":false}\n'
		return 0
	fi

	pid="$(cat "$OC_LOCK_DIR/pid" 2>/dev/null || true)"
	if [ -n "$pid" ] && oc_pid_alive "$pid"; then
		cmd="$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null)"
		cmd="${cmd% }"
		printf '{"ok":false,"locked":true,"pid":%s,"cmd":"%s","error":"仍有操作在运行，请等待其完成"}\n' \
			"$pid" "$(oc_json_str "$cmd")"
		return 2
	fi

	# 到这里锁已被判定为陈旧：pid 已退出 / 僵尸 / 被复用 / 锁内没有 pid。
	# 用既有的 oc_lock_release() 清锁（它只删本插件 0700 rundir 下的锁目录，
	# 不触碰任何用户数据）；不新写删除语句，避免引入新的递归删除模式。
	if [ -z "$pid" ]; then
		reason="no-pid"
	else
		reason="$OC_PID_REASON"
	fi
	case "$pid" in
		''|*[!0-9]*) pidjson="null" ;;
		*)           pidjson="$pid" ;;
	esac
	oc_lock_release
	oc_warn "已清理陈旧锁：$OC_LOCK_DIR（pid ${pid:-未知}，$(oc_pid_reason_text "$reason")）"
	printf '{"ok":true,"locked":false,"cleared":true,"pid":%s,"reason":"stale"}\n' "$pidjson"
	return 0
}

cmd_repair() {	# one click repair
	shift
	local args=""
	for a in "$@"; do case "$a" in --json|--no-restart) args="$args $a";; esac; done
	require_safe
	need_lock
	sh "$OC_REPAIR" $args
}

oc_env_doctor() {
	# run openclaw doctor if available
	if installed; then
		HOME="$(oc_home_dir)" PATH="$(oc_node_dir)/bin:$(oc_oc_dir)/bin:$PATH" \
			oc_timeout 120 "$(oc_oc_bin)" doctor 2>&1 | tail -n 60
	else
		printf 'OpenClaw 未安装\n'
	fi
}

cmd_doctor() {
	# doctor [--fix] : run openclaw doctor, optionally auto repair afterwards
	shift
	local fix=0 a
	for a in "$@"; do [ "$a" = "--fix" ] && fix=1; done
	require_safe
	if [ "$fix" = "1" ]; then
		need_lock
		printf '===== openclaw doctor =====\n'
		oc_env_doctor
		printf '\n===== openclaw doctor --fix =====\n'
		if installed; then
			HOME="$(oc_home_dir)" PATH="$(oc_node_dir)/bin:$(oc_oc_dir)/bin:$PATH" \
				oc_timeout 300 "$(oc_oc_bin)" doctor --fix 2>&1 | tail -n 60
		fi
		printf '\n===== 一键修复 =====\n'
		sh "$OC_REPAIR"
	else
		oc_env_doctor
	fi
}

cmd_run() {
	# run an openclaw command (argv comes from the LuCI terminal box)
	shift
	if ! installed; then printf 'OpenClaw 未安装\n'; return 1; fi

	# Second gate. The controller already whitelists the sub-command and
	# single-quotes every token, so nothing here can reach a shell - but if a
	# future caller forgets to quote, these characters are what turn an
	# argument into a command. Rejecting them costs us nothing: no openclaw
	# argument needs a $, backtick or pipe.
	local a
	for a in "$@"; do
		# single quoted literals, not a bracket expression: backslash escapes
		# inside [...] are not portable across ash / bash / dash
		case "$a" in
			*'$'*|*'`'*|*';'*|*'|'*|*'&'*|*'<'*|*'>'*|*'('*|*')'*|*'{'*|*'}'*|*'!'*|*'\'* )
				printf '拒绝执行：参数包含不允许的字符（$ ` ; | & < > ( ) { } ! \\）\n'
				return 126 ;;
		esac
	done

	HOME="$(oc_home_dir)" PATH="$(oc_node_dir)/bin:$(oc_oc_dir)/bin:$PATH" \
		oc_timeout 120 "$(oc_oc_bin)" "$@" 2>&1 | tail -n 200
}

cmd_mounts() {
	printf '['
	local first=1 m free fst
	while IFS="$(printf '\t')" read -r m free fst; do
		[ -n "$m" ] || continue
		[ "$first" = "1" ] || printf ','
		first=0
		printf '{"path":"%s","free_mb":"%s","dev":"%s"}' "$m" "$free" "$fst"
	done <<EOF
$(oc_mounts)
EOF
	printf ']'
}

cmd_discover() {
	# 只读：列出本机已有的 OpenClaw 安装 / 数据目录（JSON 数组）。
	# 探测逻辑在 lib.sh 的 oc_discover_existing()，这里只负责把结果原样吐到
	# stdout —— 该函数的日志一律走 stderr（oc_warn / oc_err），所以这里绝不能
	# 用 oc_info，否则会往 JSON 前面插一行日志，LuCI 的 JSON.parse 直接报错。
	# 不取锁、不过 require_safe：纯只读，且 discover 本身不做任何写入。
	oc_discover_existing
	printf '\n'
}

cmd_node_existing() {
	# 只读：列出本机已有的 node 运行时（JSON 数组，每项 path/version/source/usable）。
	# 探测逻辑在 lib.sh 的 oc_probe_node_runtimes()，这里只把结果原样吐到 stdout ——
	# 与 cmd_discover 同一条约定：该函数的日志一律走 stderr（oc_warn / oc_err），
	# 所以这里绝不能用 oc_info，否则会往 JSON 前面插一行日志，LuCI 的 JSON.parse 直接报错。
	# 不取锁、不过 require_safe：纯只读，且它不写任何文件、不改 UCI。
	oc_probe_node_runtimes
	printf '\n'
}

# ---------------------------------------------------------------- devices
# 局域网 / Tailnet 访问 Control UI 时 OpenClaw 要求一次性配对批准
# （127.0.0.1 自动批准）。这两条命令把「SSH 手敲 openclaw devices ...」
# 降到 LuCI 里的一个按钮。
#
# 约定与 discover / node-existing 相同：stdout 只有 JSON，日志一律走 stderr
# （oc_warn / oc_err / oc_timeout 的告警都写 stderr），前端直接 JSON.parse。
# 批准是逐条动作：这里刻意不提供 approve-all，避免一次误批陌生设备。

oc_devices_clean() {
	# stdin -> 去掉 CR 与 ANSI SGR 的纯文本（表格解析前先归一化）
	tr -d '\r' 2>/dev/null | tr -d '\033' 2>/dev/null | sed 's/\[[0-9;]*m//g' 2>/dev/null
}

oc_devices_parse() {
	# stdin: `openclaw devices list` 的纯文本
	# stdout: 每行 "id<TAB>label<TAB>role<TAB>requestedAt"
	#
	# 兼容三种常见形态：
	#   * ASCII / Unicode 表格（| ... | 或 │ ... │）
	#   * 两列以上用连续空白分隔的表格
	#   * 段落标记：只看 pending 段，遇到 paired / approved 段停止
	# 解析不出来时什么都不输出，由调用方降级为 raw（不报错、不崩溃）。
	awk '
	function trim(s) { gsub(/^[ \t]+/, "", s); gsub(/[ \t]+$/, "", s); return s }
	function valid(id) {
		if (id == "" || length(id) < 3 || length(id) > 128) return 0
		if (id !~ /^[A-Za-z0-9._-]+$/ || substr(id, 1, 1) == "-") return 0
		if (tolower(id) ~ /^(id|request|requestid|device|label|role|status|pending|none)$/) return 0
		return 1
	}
	function emit(id, label, role, req) {
		id = trim(id); label = trim(label); role = trim(role); req = trim(req)
		if (!valid(id)) return
		gsub(/\t/, " ", label); gsub(/\t/, " ", role); gsub(/\t/, " ", req)
		printf "%s\t%s\t%s\t%s\n", id, label, role, req
	}
	function row(m,   i, h, hasid, hasdev, hasrole, hastime, allsep) {
		if (m < 3) return
		allsep = 1
		for (i = 1; i <= m; i++) if (f[i] !~ /^[-=_+ ]+$/) { allsep = 0; break }
		if (allsep) return
		hasid = 0; hasdev = 0; hasrole = 0; hastime = 0
		for (i = 1; i <= m; i++) {
			h = tolower(f[i]); gsub(/[ _-]+/, "", h)
			if (h == "requestid" || h == "id" || h == "request" || h == "deviceid") hasid = 1
			if (h == "device" || h == "label" || h == "name" || h == "devicename") hasdev = 1
			if (h == "role" || h == "scope") hasrole = 1
			if (h == "requested" || h == "requestedat" || h == "time" || h == "created" || h == "createdat" || h == "when") hastime = 1
		}
		if (!havehdr && hasid && (hasdev || hasrole || hastime)) {
			# 表头出现后按列名重新映射；没有出现的列留空（不能沿用默认列号，
			# 否则 "Device ID | Role | Requested" 会把 Role 同时当成 label）
			idc = 0; labc = 0; rolec = 0; reqc = 0
			for (i = 1; i <= m; i++) {
				h = tolower(f[i]); gsub(/[ _-]+/, "", h)
				if (h == "requestid" || h == "id" || h == "request" || h == "deviceid") idc = i
				else if (h == "device" || h == "label" || h == "name" || h == "devicename") labc = i
				else if (h == "role" || h == "scope") rolec = i
				else if (h == "requested" || h == "requestedat" || h == "time" || h == "created" || h == "createdat" || h == "when") reqc = i
			}
			havehdr = 1
			return
		}
		emit(f[idc], f[labc], f[rolec], f[reqc])
	}
	BEGIN { inpending = 1; havehdr = 0; idc = 1; labc = 2; rolec = 3; reqc = 4 }
	{
		line = $0
		low = tolower(line)
		if (line ~ /^[ \t]*$/) next
		# 段落标记：只在"不是表格行"的文本上判断，避免设备名里带 pending
		# 的数据行被整行丢弃。pending 段保留，paired / approved 段跳过。
		if (line !~ /[|│]/ && line !~ /[ \t][ \t]+/) {
			if (low ~ /(^|[^a-z])(pending|awaiting)/ || low ~ /(待批准|待配对|等待批准)/) { inpending = 1; next }
			if (low ~ /(^|[^a-z])(paired|approved|trusted)/ || low ~ /(已配对|已批准|已知设备)/) { inpending = 0; next }
		}
		if (!inpending) next

		if (line ~ /[|│]/) {
			gsub(/│/, "|", line)
			n = split(line, cells, "|")
			m = 0
			for (i = 1; i <= n; i++) {
				c = trim(cells[i])
				if (c != "") { m++; f[m] = c }
			}
			row(m)
			next
		}

		# 连续两个以上空白才当作列分隔：普通句子（"No pending requests"）不会被误判
		if (line ~ /[ \t][ \t]+/) {
			n = split(line, parts, /[ \t][ \t]+/)
			m = 0
			for (i = 1; i <= n; i++) {
				c = trim(parts[i])
				if (c != "") { m++; f[m] = c }
			}
			row(m)
		}
	}'
}

oc_devices_parse_kv() {
	# 兜底解析 "Request ID: ... / Device: ... / Role: ... / Requested: ..." 形态。
	# 只在表格解析没有任何结果时调用；同样解析失败就输出空。
	awk '
	function trim(s) { gsub(/^[ \t]+/, "", s); gsub(/[ \t]+$/, "", s); return s }
	function valid(id) {
		if (id == "" || length(id) < 3 || length(id) > 128) return 0
		if (id !~ /^[A-Za-z0-9._-]+$/ || substr(id, 1, 1) == "-") return 0
		if (tolower(id) ~ /^(id|request|requestid|device|label|role|status|pending|none)$/) return 0
		return 1
	}
	function flush() {
		if (id != "" && valid(id)) {
			gsub(/\t/, " ", label); gsub(/\t/, " ", role); gsub(/\t/, " ", req)
			printf "%s\t%s\t%s\t%s\n", id, label, role, req
		}
		id = ""; label = ""; role = ""; req = ""
	}
	BEGIN { id = ""; label = ""; role = ""; req = "" }
	{
		line = $0
		low = tolower(line)
		if (line ~ /^[ \t]*$/) next
		if (low ~ /^[ \t]*(pending|awaiting)/ || low ~ /(待批准|待配对|等待批准)/) next
		if (low ~ /^[ \t]*(paired|approved|trusted)/ || low ~ /already paired|paired devices|approved devices|trusted devices/ || low ~ /(已配对|已批准|已知设备)/) { flush(); exit }
		if (match(line, /^[ \t]*[-*]?[ \t]*"?[A-Za-z][A-Za-z0-9 _-]*"?[ \t]*[:=][ \t]*/)) {
			key = substr(line, 1, RLENGTH)
			val = substr(line, RLENGTH + 1)
			gsub(/^[ \t]*[-*]?[ \t]*"?/, "", key)
			gsub(/"?[ \t]*[:=][ \t]*$/, "", key)
			k = tolower(key); gsub(/[ _-]+/, "", k)
			# 兼容每行一个 JSON 对象："id": "req_abc",
			sub(/,[ \t]*$/, "", val)
			val = trim(val)
			if (val ~ /^".*"$/) { sub(/^"/, "", val); sub(/"$/, "", val) }
			if (k == "requestid" || k == "id" || k == "request" || k == "deviceid") { flush(); id = val }
			else if (k == "device" || k == "label" || k == "name" || k == "devicename") label = val
			else if (k == "role" || k == "scope") role = val
			else if (k == "requested" || k == "requestedat" || k == "time" || k == "created" || k == "createdat" || k == "when") req = val
		}
	}
	END { flush() }'
}

cmd_devices_pending() {
	if ! installed; then
		printf '{"ok":false,"error":"运行环境尚未安装"}\n'
		return 1
	fi

	local raw rc clean rows tailtxt rawjson
	raw="$(HOME="$(oc_home_dir)" PATH="$(oc_node_dir)/bin:$(oc_oc_dir)/bin:$PATH" \
		oc_timeout 20 "$(oc_oc_bin)" devices list 2>&1)"
	rc=$?

	# 命令本身失败（子命令不存在 / 网关未启动 / 未登录）：把输出尾部交给前端。
	if [ "$rc" -ne 0 ]; then
		tailtxt="$(printf '%s\n' "$raw" | tail -n 20)"
		[ -n "$tailtxt" ] || tailtxt="执行 openclaw devices list 失败（无输出）"
		printf '{"ok":false,"error":"%s"}\n' "$(printf '%s\n' "$tailtxt" | json_escape)"
		return 1
	fi

	clean="$(printf '%s\n' "$raw" | oc_devices_clean)"
	rows="$(printf '%s\n' "$clean" | oc_devices_parse)"
	[ -n "$rows" ] || rows="$(printf '%s\n' "$clean" | oc_devices_parse_kv)"

	printf '{"ok":true,"pending":['
	local first=1 rid rlabel rrole rreq
	while IFS="$(printf '\t')" read -r rid rlabel rrole rreq; do
		[ -n "$rid" ] || continue
		if [ "$first" -eq 1 ]; then first=0; else printf ','; fi
		printf '{"id":"%s","label":"%s","role":"%s","requestedAt":"%s"}' \
			"$(oc_json_str "$rid")" "$(oc_json_str "$rlabel")" \
			"$(oc_json_str "$rrole")" "$(oc_json_str "$rreq")"
	done <<EOF
$rows
EOF
	printf ']'

	# 解析不出条目但命令确实有输出：把原文（前 40 行）交给前端展示。
	# 这样 OpenClaw 改了输出格式时用户仍能看到内容并手动处理，而不是面对一个
	# 永远空着的列表。明确的 "no pending" 文案不算解析失败，不附 raw。
	if [ -z "$rows" ] && [ -n "$(printf '%s' "$clean" | tr -d '[:space:]')" ]; then
		case "$(printf '%s' "$clean" | tr 'A-Z' 'a-z')" in
			*"no pending"*|*"0 pending"*|*"没有"*|*"暂无"*|*"无待"*) ;;
			*)
				rawjson="$(printf '%s\n' "$clean" | head -n 40 | json_escape)"
				[ -z "$rawjson" ] || printf ',"raw":"%s"' "$rawjson"
				;;
		esac
	fi
	printf '}\n'
	return 0
}

cmd_devices_approve() {
	# devices-approve <requestId>
	#
	# requestId 会进入命令行，白名单是硬要求：只允许 [A-Za-z0-9._-]，
	# 长度 <= 128。另外拒绝前导 "-" —— 它虽然符合白名单，但会被
	# `openclaw devices approve` 当成选项（例如 --help），而不是设备 id。
	local id="${2:-}"
	if [ -z "$id" ]; then
		printf '{"ok":false,"error":"缺少 requestId"}\n'
		return 1
	fi
	if [ "${#id}" -gt 128 ]; then
		printf '{"ok":false,"error":"requestId 过长（上限 128）"}\n'
		return 1
	fi
	case "$id" in
		*[!A-Za-z0-9._-]*)
			printf '{"ok":false,"error":"requestId 非法（只允许字母数字与 . _ -）"}\n'
			return 1 ;;
		-*)
			printf '{"ok":false,"error":"requestId 非法（不能以 - 开头）"}\n'
			return 1 ;;
	esac

	if ! installed; then
		printf '{"ok":false,"error":"运行环境尚未安装"}\n'
		return 1
	fi

	local out rc tailtxt
	out="$(HOME="$(oc_home_dir)" PATH="$(oc_node_dir)/bin:$(oc_oc_dir)/bin:$PATH" \
		oc_timeout 30 "$(oc_oc_bin)" devices approve "$id" 2>&1)"
	rc=$?

	if [ "$rc" -eq 0 ]; then
		printf '{"ok":true,"approved":"%s"}\n' "$(oc_json_str "$id")"
		return 0
	fi

	tailtxt="$(printf '%s\n' "$out" | tail -n 20)"
	[ -n "$tailtxt" ] || tailtxt="批准失败（命令无输出）"
	printf '{"ok":false,"error":"%s"}\n' "$(printf '%s\n' "$tailtxt" | json_escape)"
	return 1
}

# ---------------------------------------------------------------- migrate
# migrate <dir> : 把本机已有的 OpenClaw 安装「迁移」到本插件的默认目录。
#
# 迁移会把文件真正复制过来 —— 之后本插件只使用自己的目录，源目录保持原样，
# 用户确认无误后可以自行删除。
#
# 原子性：先把内容 cp -a 到「与目标同一分区」的暂存目录，校验关键文件通过后
# 才用 mv 换入（同分区 rename，不会留下复制到一半的目标）。换入前若目标已有
# 数据，先走 backup.sh 的安全快照；任何一步失败都只清理暂存目录，已存在的
# 目标数据保持原样。
#
# 关于 cp 与 mv：源目录 → 暂存目录始终用 cp -a。同分区时 mv 虽然只是 rename、
# 更快，但它会消费源目录 —— 与「源目录保持原样、失败可回退」的契约冲突，
# 且校验失败时源数据只剩暂存目录里那一份。跨分区时 mv 会退化成复制+删除源，
# 中途失败更危险。真正需要同分区 rename 的是「暂存 → 目标」换入，那里用 mv，
# 并在下面用 mig_fs_dev 校验同一文件系统（跨分区直接拒绝，不硬做）。
#
# 目标布局：<安装目录>/{home/.openclaw,openclaw,node}。
#
# 数据/程序目录有两种来源：
#   A) main.state_dir / main.openclaw_dir 指向 <安装目录> 之内（含未设置时的
#      默认值）：按相对路径搬到新目录的对应位置，UCI 保持不变。
#   B) 指向 <安装目录> 之外（典型场景：数据 / 程序目录被指到已有的 iStoreOS 安装）：
#      重定位到上述默认位置 —— state_dir → <base>/home/.openclaw，
#      openclaw_dir → <base>/openclaw；原子换入成功后删除对应 UCI 项并
#      commit，让配置回到「由 base_dir 推导」的状态。这样外部安装可以直接
#      migrate 进来，不需要用户先手工清空 UCI。
#
# stdout 只允许 JSON（前端直接 JSON.parse）：日志一律走 stderr，不用 oc_info。

MIG_STAGE=""
MIG_OLD=""
MIG_DST=""
MIG_MOVED=0
MIG_LOCKED=0
# 成功 JSON 里的 relocated / relocations（只记录真正被重定位并清掉 UCI 的项）
MIG_RELOCATED=""
MIG_RELOCATIONS=""

oc_mig_exit() {
	mig_cleanup
	mig_unlock
}

mig_log() {
	# 与 backup.sh 的 blog() 同一约定：进度走 stderr，stdout 只留给 JSON
	printf '%s [INFO] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
}

mig_cleanup() {
	# 兜底：删掉暂存目录；旧目录已移开而新目录尚未就位时，把它放回原位。
	# 递归删除一律用 find -depth -delete：不跟随符号链接，也不会删到目录之外。
	if [ -n "${MIG_STAGE:-}" ] && [ -d "$MIG_STAGE" ]; then
		find "$MIG_STAGE" -depth -delete 2>/dev/null || true
		MIG_STAGE=""
	fi
	if [ -n "${MIG_OLD:-}" ] && [ -d "$MIG_OLD" ]; then
		if [ "${MIG_MOVED:-0}" = "1" ] && [ -n "${MIG_DST:-}" ] && [ ! -e "$MIG_DST" ]; then
			mv "$MIG_OLD" "$MIG_DST" 2>/dev/null || true
			MIG_MOVED=0
		else
			oc_warn "迁移中断：原目录保留在 $MIG_OLD（确认后可自行删除）"
		fi
	fi
	return 0
}

mig_unlock() {
	# oc_lock_release 是无条件删除锁目录的：没持锁时调用会释放别人的锁，
	# 让 install/repair 与本操作并发。所以必须用 MIG_LOCKED 守住。
	[ "${MIG_LOCKED:-0}" = "1" ] || return 0
	MIG_LOCKED=0
	oc_lock_release
}

mig_fail() {
	# mig_fail <message> [rc] : 清理现场 + 输出错误 JSON + 退出（stdout 只有这一行）
	local msg="$1" rc="${2:-1}"
	oc_err "migrate: $msg"
	mig_cleanup
	mig_unlock
	printf '{"ok":false,"error":"%s"}\n' "$(oc_json_str "$msg")"
	exit "$rc"
}

mig_fs_dev() {
	# mig_fs_dev <path> -> 所在文件系统的设备名（路径不存在时回溯到最近的存在祖先）
	local p="$1"
	[ -n "$p" ] || return 1
	while [ ! -e "$p" ] && [ "$p" != "/" ]; do
		p="$(dirname "$p")"
	done
	df -P "$p" 2>/dev/null | awk 'NR==2{print $1}'
}

mig_rand() {
	# 暂存/旧目录名的随机后缀（oc_rand_hex 不可用时退回 $$，仍然是唯一的名字）
	local r
	r="$(oc_rand_hex 2>/dev/null | cut -c1-12)"
	[ -n "$r" ] || r="$$"
	printf '%s' "$r"
}

mig_reloc_add() {
	# mig_reloc_add <key> <from> <to>
	# 追加到成功 JSON 的 relocated（键名数组）与 relocations（明细对象数组）。
	# 只有「文件已经搬到新位置、UCI 也已清掉」的项才调用这里，避免前端展示
	# 一个其实没发生的重定位。
	local k="$1" f="$2" t="$3" obj
	obj="{\"key\":\"$k\",\"from\":\"$(oc_json_str "$f")\",\"to\":\"$(oc_json_str "$t")\"}"
	if [ -z "${MIG_RELOCATED:-}" ]; then
		MIG_RELOCATED="\"$k\""
		MIG_RELOCATIONS="$obj"
	else
		MIG_RELOCATED="$MIG_RELOCATED,\"$k\""
		MIG_RELOCATIONS="$MIG_RELOCATIONS,$obj"
	fi
}

cmd_migrate() {
	# migrate <dir> : 见本节开头的说明。成功输出
	# {"ok":true,"from":..,"to":..,"kind":..}，失败输出 {"ok":false,"error":..}
	local dir="${2:-}" kind src_root base state ocdir nodedir
	local rel_state rel_oc rel_node
	local state_external=0 oc_external=0
	local src_data src_prog src_node
	local dst swap_parent stage old full=1 need have_data before snap dev_stage dev_dst
	local snap_src="" snap_src_phys="" uci_changed=0

	# 每次调用都重置，避免（未来若被同进程复用）把上一次的重定位带进 JSON
	MIG_RELOCATED=""
	MIG_RELOCATIONS=""

	# ---- 1) 参数与前置校验（此时未持锁、未写任何文件）----
	if [ -z "$dir" ]; then
		oc_err "migrate: 缺少目录参数"
		printf '{"ok":false,"error":"缺少目录参数"}\n'
		return 2
	fi
	# 归一化：去掉尾随斜杠（"/" 单独保留，交给下面的探测去拒绝）
	dir="${dir%/}"
	[ -n "$dir" ] || dir="/"

	if [ ! -d "$dir" ]; then
		oc_err "migrate: 目录不存在：$dir"
		printf '{"ok":false,"error":"%s"}\n' "$(oc_json_str "目录不存在：$dir")"
		return 2
	fi

	kind="$(oc_probe_openclaw_dir "$dir")"
	if [ -z "$kind" ]; then
		oc_err "migrate: 不是有效的 OpenClaw 安装：$dir"
		printf '{"ok":false,"error":"%s"}\n' "$(oc_json_str "不是有效的 OpenClaw 安装：$dir")"
		return 2
	fi

	# 源目录可能是符号链接，而 cp -a 隐含 -d（不跟随链接）：直接复制会把
	# "链接本身"搬过去，目标里得到一个指向源目录的链接 —— 看起来迁移成功，
	# 实际两边仍共享同一份文件，且链接可能指到目标目录之外。先物理解析。
	src_root="$(oc_canonical_dir "$dir" 2>/dev/null)"
	[ -n "$src_root" ] || src_root="$dir"

	base="$(oc_base_dir)"
	state="$(oc_state_dir)"
	ocdir="$(oc_oc_dir)"
	nodedir="$(oc_node_dir)"

	# ---- 2) 目标可用性 ----
	oc_validate_base_dir "$base" || mig_fail "拒绝迁移：本插件安装目录不安全（$base）" 2
	oc_validate_base_dir "$state" || mig_fail "拒绝迁移：数据目录不安全（$state）" 2
	oc_validate_base_dir "$ocdir" || mig_fail "拒绝迁移：程序目录不安全（$ocdir）" 2

	if [ "$src_root" = "$base" ]; then
		mig_fail "源目录就是本插件的安装目录，无需迁移：$dir" 2
	fi
	case "$base" in
		"$src_root"/*) mig_fail "拒绝迁移：目标目录位于源目录之内（$base）" 2 ;;
	esac
	case "$src_root" in
		"$base"/*) mig_fail "拒绝迁移：源目录位于目标目录之内（$dir）" 2 ;;
	esac

	# 数据/程序目录的来源分两种：
	#   A) 在 base_dir 之内（含未设置时的默认值）：沿用相对路径，搬到新目录
	#      的对应位置，UCI 保持不变；
	#   B) 在 base_dir 之外（典型：state_dir 被指到已有安装）：重定位
	#      到默认位置，原子换入成功后再清掉对应 UCI 项（见第 9b 步）。
	# 目标位置仍然必须落在 base_dir 之下：暂存目录建在 base 的同级，只有这样
	# 才能用一次 mv 原子换入 —— 这一点不因来源在外部而改变。
	if [ "$state" = "$base" ]; then
		mig_fail "拒绝迁移：数据目录不能等于安装目录（$base），请先修正 main.state_dir" 2
	fi
	rel_state="${state#"$base"/}"
	if [ -z "$rel_state" ] || [ "$rel_state" = "$state" ]; then
		state_external=1
		rel_state="home/.openclaw"
	fi
	rel_oc="${ocdir#"$base"/}"
	if [ -z "$rel_oc" ] || [ "$rel_oc" = "$ocdir" ]; then
		oc_external=1
		rel_oc="openclaw"
	fi
	rel_node=""
	if [ "$(oc_node_mode)" = "private" ]; then
		rel_node="${nodedir#"$base"/}"
		[ "$rel_node" = "$nodedir" ] && rel_node=""
	fi

	# ---- 3) 源侧的三块内容 ----
	src_data="$(oc_probe_data_dir "$src_root" "$kind")"
	if [ -z "$src_data" ] || [ ! -d "$src_data" ]; then
		mig_fail "拒绝迁移：源数据目录不存在（$kind 布局）：$dir" 2
	fi
	src_prog=""
	src_node=""
	case "$kind" in
		ours)
			if [ -f "$src_root/openclaw/bin/openclaw" ]; then
				src_prog="$src_root/openclaw"
			elif [ -f "$src_root/bin/openclaw" ]; then
				# 程序目录就是源目录本身（main.openclaw_dir 被设成安装目录的布局）
				src_prog="$src_root"
			fi
			[ -d "$src_root/node" ] && src_node="$src_root/node"
			;;
		istore)
			[ -d "$src_root/data/openclaw" ] && src_prog="$src_root/data/openclaw"
			[ -d "$src_root/data/node" ] && src_node="$src_root/data/node"
			;;
		data) ;;
	esac

	# ---- 4) 取锁（与 install / repair / restore 互斥）----
	if ! oc_lock_acquire; then
		oc_err "migrate: 另一个操作正在运行"
		printf '{"ok":false,"error":"另一个操作正在运行，请稍后再试"}\n'
		return 2
	fi
	MIG_LOCKED=1
	# oc_lock_acquire 自己装了 EXIT/INT/TERM/HUP 的解锁 trap，这里必须把它
	# 合并进我们的清理函数，否则会把解锁那段顶掉（中断后锁残留）。
	trap 'oc_mig_exit' EXIT
	trap 'oc_mig_exit; exit 1' INT TERM HUP

	# ---- 5) 目标位置与空间检查 ----
	if [ -n "$src_prog" ]; then
		# 源目录是一份完整安装（程序 + 数据 [+ 私有运行时]）→ 整体替换安装目录
		full=1
		dst="$base"
	else
		# 源目录只有数据 → 只替换数据目录，目标已有的程序/运行时保持不动
		full=0
		dst="$base/$rel_state"
	fi
	MIG_DST="$dst"
	swap_parent="$(dirname "$base")"
	mkdir -p "$swap_parent" 2>/dev/null || mig_fail "无法创建目标父目录：$swap_parent"

	# 暂存目录必须与目标同分区，mv 才是 rename（原子）；base 本身是挂载点根时
	# 二者会落在不同文件系统上，此时 mv 退化为跨设备复制，拒绝而不是硬做。
	dev_stage="$(mig_fs_dev "$swap_parent")"
	dev_dst="$(mig_fs_dev "$dst")"
	if [ -n "$dev_stage" ] && [ -n "$dev_dst" ] && [ "$dev_stage" != "$dev_dst" ]; then
		mig_fail "拒绝迁移：目标 $dst 与暂存目录 $swap_parent 不在同一文件系统，无法原子换入（请把安装目录设为挂载点下的子目录）"
	fi

	need="$(oc_dir_size_mb "$src_root")"
	case "$need" in ''|*[!0-9]*) need=0 ;; esac
	if [ "$need" -gt 0 ] && ! oc_need_space "$swap_parent" "$((need + 32))"; then
		mig_fail "目标分区空间不足：复制约需 ${need}MB（暂存于 $swap_parent）"
	fi

	# ---- 6) 复制到暂存目录 ----
	# 优先 mktemp -d：名字不可预测且是 0700，避免共享挂载点上有人预先把
	# .oc-migrate.* 造成符号链接，让 root 的 cp 写到别处。
	stage=""
	if command -v mktemp >/dev/null 2>&1; then
		stage="$(mktemp -d "$swap_parent/.oc-migrate.XXXXXX" 2>/dev/null)" || stage=""
	fi
	if [ -z "$stage" ]; then
		stage="$swap_parent/.oc-migrate.$(mig_rand)"
		if [ -L "$stage" ] || [ -e "$stage" ]; then
			mig_fail "暂存路径已被占用，请稍后重试：$stage"
		fi
		mkdir "$stage" 2>/dev/null || mig_fail "无法创建暂存目录：$stage"
	fi
	MIG_STAGE="$stage"

	if [ "$full" = "1" ]; then
		mkdir -p "$stage/$(dirname "$rel_state")" "$stage/$(dirname "$rel_oc")" 2>/dev/null
		cp -a "$src_data" "$stage/$rel_state" 2>/dev/null \
			|| mig_fail "复制数据目录失败：$src_data"
		if [ "$src_prog" = "$src_root" ]; then
			# 程序目录 == 源目录本身：只取程序本体，否则会把数据目录一起套进去
			mkdir -p "$stage/$rel_oc" 2>/dev/null
			for sub in bin lib package.json; do
				if [ -e "$src_root/$sub" ]; then
					cp -a "$src_root/$sub" "$stage/$rel_oc/$sub" 2>/dev/null \
						|| mig_fail "复制程序本体失败：$src_root/$sub"
				fi
			done
		else
			cp -a "$src_prog" "$stage/$rel_oc" 2>/dev/null \
				|| mig_fail "复制程序目录失败：$src_prog"
		fi
		if [ -n "$src_node" ] && [ -n "$rel_node" ]; then
			mkdir -p "$stage/$(dirname "$rel_node")" 2>/dev/null
			cp -a "$src_node" "$stage/$rel_node" 2>/dev/null \
				|| mig_fail "复制 Node 运行时失败：$src_node"
		fi
		# 源根下的 workspace 一并带走（可能是用户数据）；logs/cache/npm-cache
		# 是可再生的，不迁。
		if [ -d "$src_root/workspace" ]; then
			cp -a "$src_root/workspace" "$stage/workspace" 2>/dev/null \
				|| oc_warn "workspace 复制失败，已跳过"
		fi
	else
		# 只迁数据：暂存目录本身就是"新的数据目录"
		cp -a "$src_data/." "$stage/" 2>/dev/null \
			|| mig_fail "复制数据目录失败：$src_data"
	fi

	# ---- 7) 校验暂存结果：关键文件必须存在，否则不换入 ----
	if [ "$full" = "1" ]; then
		[ -f "$stage/$rel_state/openclaw.json" ] \
			|| mig_fail "复制校验失败：缺少 $rel_state/openclaw.json"
		[ -x "$stage/$rel_oc/bin/openclaw" ] \
			|| mig_fail "复制校验失败：缺少可执行的 $rel_oc/bin/openclaw"
	else
		[ -f "$stage/openclaw.json" ] \
			|| mig_fail "复制校验失败：缺少 openclaw.json"
	fi

	# ---- 8) 目标已有数据 → 先做安全快照（复用 backup.sh，不另写一套）----
	# 快照的必须是「即将被替换的物理目标」，不能直接用 backup.sh 默认的
	# oc_data_dir()：来源在外部时（B），UCI 的 state_dir 指向源安装，而这里
	# 要替换的是 <base>/home/.openclaw，两者不是同一个目录。若沿用默认值，
	# 目标里的旧数据会被换走并删除，却从未进入快照。
	have_data=0
	if [ "$full" = "1" ]; then
		snap_src="$base/$rel_state"
	else
		snap_src="$dst"
	fi
	[ -f "$snap_src/openclaw.json" ] && have_data=1
	if [ "$have_data" = "1" ]; then
		# 目标可能是符号链接：cp -a 会复制链接本身，归档里就多出一条链接
		# 条目（restore 的 oc_archive_inspect 会整体拒绝）。先物理解析。
		snap_src_phys="$(oc_canonical_dir "$snap_src" 2>/dev/null)"
		[ -n "$snap_src_phys" ] || snap_src_phys="$snap_src"
		before="$(sh "$OC_BACKUP" create --name "pre-migrate" --data-dir "$snap_src_phys" 2>/dev/null)"
		snap=""
		case "$before" in
			*'"ok":true'*)
				snap="$(printf '%s' "$before" | sed -n 's/.*"file":"\([^"]*\)".*/\1/p')"
				;;
		esac
		if [ -n "$snap" ]; then
			mig_log "已创建迁移前快照：$snap"
		else
			oc_warn "未能创建迁移前快照，继续（源目录 $dir 仍完整保留）"
		fi
	fi

	# ---- 9) 原子换入 ----
	old="$swap_parent/.oc-migrate-old.$(mig_rand)"
	if [ -L "$old" ] || [ -e "$old" ]; then
		mig_fail "旧目录暂存路径已被占用：$old"
	fi
	MIG_OLD="$old"
	if [ -e "$dst" ]; then
		mv "$dst" "$old" 2>/dev/null \
			|| mig_fail "无法移开现有目录：$dst（目标未改动）"
		MIG_MOVED=1
	fi
	mkdir -p "$(dirname "$dst")" 2>/dev/null
	mv "$stage" "$dst" 2>/dev/null || mig_fail "换入目标位置失败：$dst"
	MIG_STAGE=""
	MIG_MOVED=0

	# 安全快照写在 <安装目录>/backups 里，整树替换时必须先把它带回新目录，
	# 再清理旧目录 —— 顺序反了快照就随旧目录一起没了。
	if [ "$full" = "1" ] && [ -d "$old/backups" ]; then
		mkdir -p "$base/backups" 2>/dev/null
		cp -a "$old/backups/." "$base/backups/" 2>/dev/null \
			|| oc_warn "旧备份未能带入新安装目录（仍保留在 $old）"
	fi
	if [ -d "$old" ]; then
		if find "$old" -depth -delete 2>/dev/null; then
			MIG_OLD=""
		else
			oc_warn "旧目录清理失败，请手动删除：$old"
		fi
	else
		MIG_OLD=""
	fi

	# ---- 9b) 重定位后的 UCI 清理 ----
	# 文件已经原子换入新位置，现在让配置也回到「由 base_dir 推导」的状态。
	# 必须放在 oc_fix_perms 之前：它用 oc_state_dir()/oc_oc_dir() 推导路径，
	# 晚清会让它继续按外部旧路径操作。oc_state_dir()/oc_oc_dir() 每次都读
	# UCI，所以 delete + commit 之后后续调用立即返回新位置。
	if [ "$state_external" = "1" ]; then
		case "$state" in
			"$src_root"|"$src_root"/*) ;;
			*) oc_warn "注意：外部数据目录 $state 不属于本次迁移源 $src_root，其内容未被复制；原目录保持原样" ;;
		esac
		uci -q delete "${OC_UCI}.main.state_dir" 2>/dev/null
		uci_changed=1
		mig_reloc_add "state_dir" "$state" "$base/$rel_state"
		mig_log "已重定位数据目录：$state → $base/$rel_state（清除 main.state_dir）"
	fi
	if [ "$oc_external" = "1" ]; then
		if [ "$full" = "1" ]; then
			case "$ocdir" in
				"$src_root"|"$src_root"/*) ;;
				*) oc_warn "注意：外部程序目录 $ocdir 不是本次迁移源的程序目录，其内容未被复制；原目录保持原样" ;;
			esac
			uci -q delete "${OC_UCI}.main.openclaw_dir" 2>/dev/null
			uci_changed=1
			mig_reloc_add "openclaw_dir" "$ocdir" "$base/$rel_oc"
			mig_log "已重定位程序目录：$ocdir → $base/$rel_oc（清除 main.openclaw_dir）"
		else
			# 源只有数据、没有程序本体：本次没有可搬的程序，清空 UCI 会让
			# oc_oc_dir() 指向并不存在的 <base>/openclaw，服务随即起不来。
			oc_warn "程序目录 $ocdir 不是默认的 $base/openclaw；本次只迁移数据、未复制程序本体，保留 main.openclaw_dir 不变"
		fi
	fi
	if [ "$uci_changed" = "1" ]; then
		if uci_commit; then
			mig_log "已提交 UCI：后续 oc_state_dir()/oc_oc_dir() 立即使用新位置"
		else
			oc_warn "uci commit 失败，配置可能在重启后回退；请手动执行：uci commit $OC_UCI"
		fi
	fi

	# ---- 10) 权限与提示 ----
	oc_fix_perms >/dev/null 2>&1 || oc_warn "权限修复未完全成功，请检查 $base"

	if [ "$full" = "0" ]; then
		oc_warn "源目录只有数据、没有程序本体：迁移后仍需在本插件内安装一次 OpenClaw"
	elif [ "$(oc_node_mode)" = "private" ]; then
		[ -n "$src_node" ] || oc_warn "源目录没有私有 Node 运行时（node/），迁移后可能需要在插件内重新安装运行时"
	else
		oc_warn "当前为 global 模式，未迁移 Node 运行时（使用系统运行时）"
	fi

	# to 报安装目录：那才是"本插件的默认目录"（数据/程序都在它下面）。
	# relocated 是键名数组（无重定位时为 []），relocations 是给前端展示
	# 「已从 X 搬到 Y」的明细（key/from/to）。
	printf '{"ok":true,"from":"%s","to":"%s","kind":"%s","relocated":[%s],"relocations":[%s]}\n' \
		"$(oc_json_str "$dir")" "$(oc_json_str "$base")" "$kind" \
		"${MIG_RELOCATED:-}" "${MIG_RELOCATIONS:-}"
	return 0
}

cmd_save() {
	# save basic settings from uci-like key=value pairs
	shift
	while [ $# -gt 0 ]; do
		case "$1" in
			--base-dir)
				# refuse a dangerous target instead of silently accepting it.
				# 提示必须说清"哪些不允许 + 该选什么"：用户撞到这条时往往不知道
				# /overlay 是系统分区，只说"不安全"会让人反复重试同一个路径。
				if ! oc_validate_base_dir "${2:-}"; then
					oc_err "拒绝保存不安全的安装目录：${2:-}"
					oc_err "不能选 /、/root、/usr、/etc、/tmp、/var、/proc、/sys、/dev、/run 等系统路径，"
					oc_err "也不能选系统分区 /overlay（根文件系统的 overlay，容量与系统共用）或只读的 /rom。"
					oc_err "含 . 或 .. 段的路径、相对路径，以及指向上述目录的符号链接同样会被拒绝。"
					oc_err "请改选数据盘挂载点下的目录，例如 /mnt/<磁盘>/OpenClaw（面板的安装目录下拉可直接选）。"
					exit 2
				fi
				uci_set main.base_dir "$2"; shift 2 ;;
			--openclaw-dir)
				# 程序目录可单独指定；空值表示"恢复默认（<安装目录>/openclaw）"
				local b="${2%/}" cur
				# 与后面的冲突判定用同一个安装目录：--base-dir 可能已在本轮保存过
				cur="$(oc_base_dir)"
				if [ -n "${2:-}" ]; then
					if ! oc_validate_base_dir "$2"; then
						oc_err "拒绝保存不安全的程序目录：${2}"
						oc_err "不能选 /、/root、/usr、/etc、/tmp、/var 等系统路径，也不能选系统分区 /overlay、/rom。"
						oc_err "推荐留空 —— 程序会自动装到 ${cur}/openclaw；"
						oc_err "要单独指定时请选数据盘下的独立目录，例如 /mnt/<磁盘>/OpenClaw-program。"
						exit 2
					fi
					# 程序目录不能是安装目录本身或它的上级，否则卸载时
					# `rm -rf "$ocdir"` 会把数据（home）一起删掉
					if [ "$b" = "$cur" ]; then
						oc_err "程序目录不能等于安装目录（$cur）：卸载时会连同数据（会话 / 工作区）一起删除。"
						oc_err "推荐留空 —— 留空时程序自动装到 ${cur}/openclaw，与数据分开。"
						exit 2
					fi
					case "$cur" in
						"$b"/*)
							oc_err "程序目录不能是安装目录的上级（$b 包含 $cur）：卸载时会连同安装目录（含数据）一起删除。"
							oc_err "推荐留空 —— 留空时程序自动装到 ${cur}/openclaw。"
							exit 2 ;;
					esac
				fi
				uci_set main.openclaw_dir "$2"; shift 2 ;;
			--port)
				if ! oc_safe_port "${2:-}"; then
					oc_err "拒绝保存不安全端口：${2:-}（必须是 1025-65535）"
					exit 2
				fi
				uci_set main.port "$2"; shift 2 ;;
			--bind)
				# openclaw accepts a named scope (lan / loopback / all / auto)
				# or an address; anything else is not worth passing to it
				case "${2:-}" in
					*[!A-Za-z0-9_.:-]* )
						oc_err "拒绝保存非法 bind：${2:-}"; exit 2 ;;
				esac
				uci_set main.bind "$2"; shift 2 ;;
			--oc-version) uci_set main.oc_version "$2"; shift 2 ;;
			--node-version) uci_set main.node_version "$2"; shift 2 ;;
			--node-mode)
				# 运行时部署方式：private（默认）| global
				case "${2:-}" in
					private|global) uci_set main.node_mode "$2" ;;
					*) oc_err "拒绝保存非法 node 模式：${2:-}（只能 private/global）"; exit 2 ;;
				esac
				shift 2 ;;
			--enabled)
				case "${2:-}" in 0|1) uci_set main.enabled "$2" ;;
					*) oc_err "拒绝保存非法 enabled：${2:-}（只能 0/1）"; exit 2 ;;
				esac
				shift 2 ;;
			# mirrors and proxies are handed to curl/npm as root; a value
			# starting with "-" would be parsed as an option, not a URL.
			# --npm-registry / --http-proxy are the names LuCI actually posts
			# (it derives them from the setting keys), so both spellings work.
			--registry|--npm-registry)
				if [ -n "${2:-}" ] && ! oc_safe_url "$2"; then
					oc_err "拒绝保存非法 registry：${2}（必须是 http(s) 地址）"; exit 2
				fi
				uci_set main.npm_registry "$2"; shift 2 ;;
			--node-mirror)
				if [ -n "${2:-}" ] && ! oc_safe_url "$2"; then
					oc_err "拒绝保存非法 node 镜像源：${2}（必须是 http(s) 地址）"; exit 2
				fi
				uci_set main.node_mirror "$2"; shift 2 ;;
			--proxy|--http-proxy)
				if [ -n "${2:-}" ] && ! oc_safe_url "$2"; then
					oc_err "拒绝保存非法代理：${2}（必须是 http(s) 地址）"; exit 2
				fi
				uci_set main.http_proxy "$2"; shift 2 ;;
			*) shift ;;
		esac
	done
	uci_commit
	if installed; then
		if [ -x "$(oc_oc_bin)" ]; then
			HOME="$(oc_home_dir)" PATH="$(oc_node_dir)/bin:$(oc_oc_dir)/bin:$PATH" \
				"$(oc_oc_bin)" config set gateway.port "$(get_port)" >/dev/null 2>&1
			HOME="$(oc_home_dir)" PATH="$(oc_node_dir)/bin:$(oc_oc_dir)/bin:$PATH" \
				"$(oc_oc_bin)" config set gateway.bind "$(uci_get main.bind lan)" >/dev/null 2>&1
		fi
		cmd_restart >/dev/null 2>&1
	fi
	printf '{"ok":true}\n'
}

# ---------------------------------------------------------------- backup
# 备份/恢复的实现在 backup.sh 里；这里只负责守卫与分发。
# 变更类操作（create/restore/delete）都要过 require_safe + need_lock，
# 只读操作（list/verify/path）不需要。
cmd_backup() {
	# 创建备份：输出 {"ok":true,"file":..,"size":..}
	shift
	require_safe
	need_lock
	sh "$OC_BACKUP" create "$@"
}

cmd_backups() {
	# 列出备份：输出 JSON 数组
	sh "$OC_BACKUP" list
}

cmd_backup_verify() {
	# 只校验归档安全性，不还原
	shift
	sh "$OC_BACKUP" verify "$@"
}

cmd_backup_delete() {
	shift
	require_safe
	need_lock
	sh "$OC_BACKUP" delete "$@"
}

cmd_backup_log() {
	# 备份审计日志（只读）：输出 JSON 数组，按时间正序（最早的在前）。
	# 用法 backup-log [N]：N 默认 50、上限 500，0 与非数字一律按 50。
	# 日志由 backup.sh 的 oc_bklog() 写入，每行格式：
	#   YYYY-MM-DD HH:MM:SS <ACTION> <RESULT> <detail>
	# 只读，不取锁；文件不存在或为空时输出 []。
	local n="${2:-}" line t rest action result detail first=1

	case "$n" in ''|*[!0-9]*) n=50 ;; esac
	# busybox 的 test 对超长整数会溢出（参见 lib.sh 的 oc_safe_port），
	# 先按长度截断再做数值比较。
	[ ${#n} -le 5 ] || n=500
	[ "$n" -gt 500 ] 2>/dev/null && n=500
	[ "$n" -gt 0 ] 2>/dev/null || n=50

	if [ ! -f "$OC_BKUPLOG" ] || [ ! -s "$OC_BKUPLOG" ]; then
		printf '[]\n'
		return 0
	fi

	printf '['
	# 先 tail 取最后 N 条，再按原顺序解析 —— 输出即为时间正序，前端可直接顺序渲染。
	tail -n "$n" "$OC_BKUPLOG" 2>/dev/null | while IFS= read -r line; do
		# 时间戳必须符合固定宽度，否则视为格式不符，静默跳过
		case "$line" in
			[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\ [0-9][0-9]:[0-9][0-9]:[0-9][0-9]\ *) ;;
			*) continue ;;
		esac
		# time 固定 19 字符：用参数展开截取。不能用 cut -d' ' 拼 ——
		# date 与 action 之间只有一个空格，按空格切会少一个字段。
		t="${line%"${line#???????????????????}"}"
		rest="${line#???????????????????}"	# 第 20 字符起，必须是空格
		case "$rest" in
			' '*) rest="${rest# }" ;;
			*) continue ;;
		esac
		# 第一个词是 action
		case "$rest" in
			*' '*) action="${rest%% *}"; rest="${rest#* }" ;;
			*) continue ;;
		esac
		# 第二个词是 result，其余全部是 detail（保留其内部空格）
		case "$rest" in
			*' '*) result="${rest%% *}"; detail="${rest#* }" ;;
			*)     result="$rest"; detail="" ;;
		esac
		[ -n "$action" ] && [ -n "$result" ] || continue
		[ "$first" = "1" ] || printf ','
		first=0
		printf '{"time":"%s","action":"%s","result":"%s","detail":"%s"}' \
			"$(oc_json_str "$t")" "$(oc_json_str "$action")" \
			"$(oc_json_str "$result")" "$(oc_json_str "$detail")"
	done
	printf ']\n'
}

cmd_restore() {
	# 还原：会先做一次安全快照，再停网关、替换数据、重启
	shift
	require_safe
	need_lock
	sh "$OC_BACKUP" restore "$@"
}

# ---------------------------------------------------------------- export
# 诊断导出：把排查问题需要的日志 / 系统信息 / 配置打成一个 tar.gz。
#
# 只读操作，不取锁。stdout 只允许一行 JSON（cmd_export 末尾），
# 所有进度与告警一律走 stderr —— lib.sh 的 oc_info() 是写 stdout 的，
# 在这条路径上用一次就会把 JSON 契约破坏掉。
#
# 脱敏是本功能的核心。除了对 openclaw.json / .env / uci show 做结构化脱敏，
# 还会把提取到的真实密钥值对日志、doctor 输出再做一次全文替换：日志里回显的
# token、doctor 打印的配置摘要、进程列表里的 argv 都属于同一批秘密。
export_note() { printf '%s [INFO] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }

export_fail() {
	printf '{"ok":false,"error":"%s"}\n' "$(oc_json_str "${1:-unknown error}")"
	return 1
}

export_timeout() {
	# export_timeout <seconds> <cmd...>
	# 实现已提升到 lib.sh 的 oc_timeout()（带 command -v timeout 检查）；
	# 这里保留函数名，避免改动 cmd_export 里既有的调用点。
	oc_timeout "$@"
}

export_stage_cleanup() {
	# 只删自己建的暂存目录：先删文件再自底向上 rmdir（不新增递归强制删除）
	if [ -n "${EXPORT_STAGE:-}" ] && [ -d "$EXPORT_STAGE" ]; then
		find "$EXPORT_STAGE" -type f -exec rm -f {} \; 2>/dev/null
		find "$EXPORT_STAGE" -depth -type d -exec rmdir {} \; 2>/dev/null
	fi
	EXPORT_STAGE=""
	[ -n "${EXPORT_SECRETS:-}" ] && rm -f "$EXPORT_SECRETS" "$EXPORT_SECRETS.uniq" 2>/dev/null
	[ -n "${EXPORT_TMPERR:-}" ] && rm -f "$EXPORT_TMPERR" 2>/dev/null
	EXPORT_SECRETS=""
	EXPORT_TMPERR=""
	return 0
}

export_redact_env() {
	# export_redact_env <src> <dst> <secrets>
	#
	# 逐行只输出 NAME=***：
	#   * 注释行 / 空行直接丢弃 —— 注释里同样可能贴过密钥
	#   * 只按第一个 = 切分，值里再出现 = 不影响变量名
	#   * export NAME=... / CRLF / 带引号的值都能处理
	#   * 变量名不合法的行一律丢弃，绝不原样输出
	# 同时把"名字看起来是密钥"的真实值记到密钥表，供后续全文脱敏使用。
	local src="$1" dst="$2" sec="$3"
	if [ ! -f "$src" ]; then
		: >"$dst"
		return 0
	fi
	awk -v sec="$sec" -v sq="'" '
		function add(name, v) {
			gsub(/^[ \t]+/, "", v); gsub(/[ \t]+$/, "", v)
			if (length(v) < 6) return
			# 只收集密钥类变量：把 BASE_URL 之类也当密钥全文替换会毁掉诊断信息
			if (toupper(name) ~ /(KEY|TOKEN|SECRET|PASSWORD|PASSWD|AUTH|CREDENTIAL)/)
				print v >> sec
		}
		{
			line = $0
			sub(/\r$/, "", line)
			if (line ~ /^[ \t]*$/) next
			if (line ~ /^[ \t]*#/) next
			rest = line
			sub(/^[ \t]+/, "", rest)
			prefix = ""
			if (rest ~ /^export[ \t]+/) {
				prefix = "export "
				sub(/^export[ \t]+/, "", rest)
			}
			eq = index(rest, "=")
			if (eq <= 1) next
			name = substr(rest, 1, eq - 1)
			gsub(/[ \t]+$/, "", name)
			if (name !~ /^[A-Za-z_][A-Za-z0-9_]*$/) next
			v = substr(rest, eq + 1)
			c1 = substr(v, 1, 1); c2 = substr(v, length(v), 1)
			if (length(v) >= 2 && ((c1 == "\"" && c2 == "\"") || (c1 == sq && c2 == sq)))
				v = substr(v, 2, length(v) - 2)
			add(name, v)
			print prefix name "=***"
		}
	' "$src" >"$dst"
}

export_redact_json() {
	# export_redact_json <src> <dst> <secrets>
	#
	# 逐行重写 "key": "value" 形式的键值对。键名归一化（小写、去掉 _ -）后
	# 命中敏感词才替换，所以 "mode": "token" 不会被误伤，而 apiKey / api_key /
	# authToken / refresh_token / clientSecret 都能覆盖。
	# jsonfilter 只能查询不能改写，sed 在 BRE 下做不了大小写不敏感的键名匹配；
	# 这里用 busybox 自带的 awk，没有引入新依赖。
	local src="$1" dst="$2" sec="$3"
	if [ ! -f "$src" ]; then
		return 1
	fi
	awk -v sec="$sec" '
		function sensitive(k,   x) {
			x = tolower(k)
			gsub(/[_-]/, "", x)
			if (x == "key" || x == "apikey" || x == "token" || x == "secret" ||
			    x == "password" || x == "passwd" || x == "authorization" ||
			    x == "credential" || x == "credentials" || x == "privatekey" ||
			    x == "accesskey" || x == "secretkey" || x == "bearer" ||
			    x ~ /token$/ || x ~ /secret$/ || x ~ /apikey$/ ||
			    x ~ /password$/ || x ~ /credential$/)
				return 1
			return 0
		}
		function add(v) {
			if (length(v) >= 6) print v >> sec
		}
		{
			line = $0
			out = ""
			while (match(line, /"[^"]*"[ \t]*:[ \t]*"[^"]*"/)) {
				pair = substr(line, RSTART, RLENGTH)
				out = out substr(line, 1, RSTART - 1)
				line = substr(line, RSTART + RLENGTH)
				c = index(pair, ":")
				key = substr(pair, 1, c - 1)
				val = substr(pair, c + 1)
				kk = key; gsub(/^[ \t]*"/, "", kk); gsub(/"[ \t]*$/, "", kk)
				vv = val; gsub(/^[ \t]*"/, "", vv); gsub(/"[ \t]*$/, "", vv)
				if (sensitive(kk)) {
					add(vv)
					out = out key ": \"***\""
				} else {
					out = out pair
				}
			}
			print out line
		}
	' "$src" >"$dst"
}

export_redact_uci() {
	# export_redact_uci <dst> <secrets>   (uci show 的输出从 stdin 读)
	# 只替换 option 名命中敏感词的值；其余行原样保留。
	local dst="$1" sec="$2"
	awk -v sec="$sec" -v sq="'" '
		function sensitive(k,   x) {
			x = tolower(k)
			gsub(/[_-]/, "", x)
			if (x == "key" || x == "apikey" || x == "token" || x == "secret" ||
			    x == "password" || x == "passwd" || x == "authorization" ||
			    x == "credential" || x == "credentials" || x == "privatekey" ||
			    x == "accesskey" || x == "secretkey" || x == "bearer" ||
			    x ~ /token$/ || x ~ /secret$/ || x ~ /apikey$/ ||
			    x ~ /password$/ || x ~ /credential$/)
				return 1
			return 0
		}
		function add(v) {
			if (length(v) >= 6) print v >> sec
		}
		{
			line = $0
			eq = index(line, "=")
			if (eq > 0) {
				left = substr(line, 1, eq - 1)
				val = substr(line, eq + 1)
				k = left
				sub(/^.*\./, "", k)
				v = val
				if (length(v) >= 2 && substr(v, 1, 1) == sq && substr(v, length(v), 1) == sq)
					v = substr(v, 2, length(v) - 2)
				if (sensitive(k)) {
					add(v)
					print left "=" sq "***" sq
					next
				}
			}
			print line
		}
	' >"$dst"
}

export_scrub_file() {
	# export_scrub_file <file> <secrets>
	# 用真实密钥值做全文替换（长值优先），再兜底常见密钥形态与 URL 凭据。
	local f="$1" sec="$2" tmp
	[ -f "$f" ] || return 0
	tmp="$f.scrub.$$"
	awk -v secfile="$sec" '
		BEGIN {
			n = 0
			if (secfile != "") {
				while ((getline v < secfile) > 0) {
					if (length(v) >= 6) { n++; s[n] = v }
				}
				close(secfile)
			}
			for (i = 1; i <= n; i++)
				for (j = i + 1; j <= n; j++)
					if (length(s[j]) > length(s[i])) { t = s[i]; s[i] = s[j]; s[j] = t }
		}
		{
			line = $0
			for (i = 1; i <= n; i++) {
				v = s[i]
				p = index(line, v)
				while (p > 0) {
					line = substr(line, 1, p - 1) "***" substr(line, p + length(v))
					p = index(line, v)
				}
			}
			while (match(line, /sk-[A-Za-z0-9_-]+/)) {
				if (RLENGTH < 12) break
				line = substr(line, 1, RSTART - 1) "sk-***" substr(line, RSTART + RLENGTH)
			}
			while (match(line, /[Bb]earer[ \t]+[A-Za-z0-9._~+\/-]+/)) {
				if (RLENGTH < 20) break
				line = substr(line, 1, RSTART - 1) "Bearer ***" substr(line, RSTART + RLENGTH)
			}
			gsub(/\/\/[^\/@ \t]+:[^\/@ \t]+@/, "//***@", line)
			print line
		}
	' "$f" >"$tmp" 2>/dev/null && mv "$tmp" "$f"
	return 0
}

export_verify_stage() {
	# export_verify_stage <stage> <secrets>
	# 打包前自证：拿真实密钥值反向扫描暂存区，任何一个还能匹配到就中止。
	# 另外单独校验 .env 输出只剩 NAME=***。
	local stage="$1" sec="$2" v n=0 leak=0
	if [ -f "$stage/config/env.txt" ]; then
		if ! awk 'length($0) > 0 && $0 !~ /^(export[ \t]+)?[A-Za-z_][A-Za-z0-9_]*=\*\*\*$/ { bad = 1 } END { exit bad ? 1 : 0 }' "$stage/config/env.txt"; then
			export_note "脱敏自检失败：config/env.txt 中存在未脱敏的行"
			return 1
		fi
	fi
	[ -f "$sec" ] || return 0
	sort -u "$sec" >"$sec.uniq" 2>/dev/null || cp "$sec" "$sec.uniq" 2>/dev/null || return 1
	while IFS= read -r v; do
		[ -n "$v" ] || continue
		[ "${#v}" -ge 6 ] || continue
		n=$((n + 1))
		if grep -rFq -e "$v" "$stage" 2>/dev/null; then
			leak=$((leak + 1))
			export_note "脱敏自检：打包内容中仍能匹配到第 $n 个密钥值"
		fi
	done <"$sec.uniq"
	rm -f "$sec.uniq" 2>/dev/null
	if [ "$leak" -ne 0 ]; then
		return 1
	fi
	export_note "脱敏自检通过：$n 个已知密钥值均未出现在打包内容中"
	return 0
}

cmd_export() {
	# export [输出路径]
	local out ts stage outdir sec terr size mode
	local base state ocdir home envf envf2 f

	shift
	if [ "$#" -gt 1 ]; then
		export_fail "用法：openclaw.sh export [输出路径]"
		return 1
	fi
	out="${1:-}"
	case "$out" in
		-*) export_fail "未知参数：$out"; return 1 ;;
	esac
	if [ -z "$out" ]; then
		ts="$(date +%Y%m%d-%H%M%S)"
		out="/tmp/luci-app-openclaw-diag-${ts}.tar.gz"
	fi
	case "$out" in
		/*) ;;
		*) out="$(pwd)/$out" ;;
	esac
	case "$out" in
		*/) export_fail "输出路径不能是目录：$out"; return 1 ;;
	esac
	# 不跟随符号链接、不覆盖已有文件：tar 以 root 打开目标，预置的链接
	# 会把归档写到任意位置。
	if [ -e "$out" ] || [ -L "$out" ]; then
		export_fail "输出文件已存在：$out"
		return 1
	fi
	outdir="$(dirname "$out")"
	if [ ! -d "$outdir" ]; then
		export_fail "输出目录不存在：$outdir"
		return 1
	fi
	if [ ! -w "$outdir" ]; then
		export_fail "输出目录不可写：$outdir"
		return 1
	fi
	command -v tar >/dev/null 2>&1 || { export_fail "缺少 tar，无法打包"; return 1; }

	umask 077

	base="$(oc_base_dir)"
	state="$(oc_state_dir)"
	ocdir="$(oc_oc_dir)"
	home="$(oc_home_dir)"

	# 暂存目录放在输出文件同目录：避免把大日志先复制进 /tmp（tmpfs）吃内存，
	# 也保证 tar 的目标与暂存处于同一个文件系统。
	stage="$outdir/.openclaw-diag.$$"
	EXPORT_STAGE="$stage"
	trap 'export_stage_cleanup' EXIT
	trap 'export_stage_cleanup; exit 130' INT TERM HUP
	if ! mkdir -m 700 "$stage" 2>/dev/null; then
		EXPORT_STAGE=""
		export_fail "无法创建暂存目录：$stage"
		return 1
	fi
	if ! mkdir -p "$stage/logs" "$stage/system" "$stage/config" 2>/dev/null; then
		export_stage_cleanup
		export_fail "无法创建暂存子目录"
		return 1
	fi

	# 密钥表：只在本进程内使用，放在私有 rundir（700），不参与打包。
	sec="$OC_RUNDIR/diag-secrets.$$"
	EXPORT_SECRETS="$sec"
	if ! : >"$sec" 2>/dev/null; then
		sec="$stage/.secrets"
		EXPORT_SECRETS="$sec"
		: >"$sec" 2>/dev/null || true
	fi
	chmod 600 "$sec" 2>/dev/null

	export_note "收集元信息与配置"
	{
		printf 'created=%s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')"
		printf 'plugin=luci-app-openclaw\n'
		printf 'hostname=%s\n' "$(uname -n 2>/dev/null)"
		printf 'system=%s\n' "$(oc_sys_version 2>/dev/null)"
		printf 'arch=%s\n' "$(oc_arch 2>/dev/null)"
		printf 'base_dir=%s\n' "$base"
		printf 'openclaw_dir=%s\n' "$ocdir"
		printf 'state_dir=%s\n' "$state"
		printf 'log_file=%s\n' "$OC_LOGFILE"
		printf 'task_log=%s\n' "$OC_TASKLOG"
		printf 'install_log=%s\n' "$OC_INSTALLLOG"
	} >"$stage/meta.txt"

	# uci：完整输出，按 option 名脱敏
	if command -v uci >/dev/null 2>&1; then
		uci show openclaw 2>/dev/null | export_redact_uci "$stage/config/uci-show.txt" "$sec"
	else
		printf '# uci 不可用\n' >"$stage/config/uci-show.txt"
	fi

	# openclaw.json
	if [ -f "$(oc_conf)" ]; then
		if ! export_redact_json "$(oc_conf)" "$stage/config/openclaw.json" "$sec"; then
			printf '# 读取 %s 失败\n' "$(oc_conf)" >"$stage/config/openclaw.json"
		fi
	else
		printf '# 不存在：%s\n' "$(oc_conf)" >"$stage/config/openclaw.json"
	fi

	# .env：models.sh 写的是 $HOME/.openclaw/.env（HOME=oc_home_dir），
	# lib.sh 的 oc_env_file 用的是 $(oc_data_dir)/.env。state_dir 被覆盖时
	# 两者不是同一个文件，所以两个位置都收，绝不漏掉真正的那份。
	envf="$(oc_data_dir)/.env"
	export_redact_env "$envf" "$stage/config/env.txt" "$sec"
	envf2="$home/.openclaw/.env"
	if [ "$envf2" != "$envf" ] && [ -f "$envf2" ]; then
		export_redact_env "$envf2" "$stage/config/env-home.txt" "$sec"
	fi

	export_note "收集日志"
	if [ -f "$OC_LOGFILE" ]; then
		cat "$OC_LOGFILE" >"$stage/logs/openclaw.log" 2>/dev/null || : >"$stage/logs/openclaw.log"
	else
		printf '# 不存在：%s\n' "$OC_LOGFILE" >"$stage/logs/openclaw.log"
	fi
	if [ -f "$OC_TASKLOG" ]; then
		cat "$OC_TASKLOG" >"$stage/logs/openclaw-task.log" 2>/dev/null || : >"$stage/logs/openclaw-task.log"
	else
		printf '# 不存在：%s\n' "$OC_TASKLOG" >"$stage/logs/openclaw-task.log"
	fi
	if [ -f "$OC_INSTALLLOG" ]; then
		cat "$OC_INSTALLLOG" >"$stage/logs/openclaw-install.log" 2>/dev/null || : >"$stage/logs/openclaw-install.log"
	fi

	export_note "收集系统信息"
	uname -a >"$stage/system/uname.txt" 2>&1 || true
	df -h >"$stage/system/df.txt" 2>&1 || true
	if command -v free >/dev/null 2>&1; then
		free >"$stage/system/free.txt" 2>&1 || true
	else
		printf '(free 不可用)\n' >"$stage/system/free.txt"
	fi
	if [ -r /proc/mounts ]; then
		# 用 index() 做字面匹配：base_dir 里出现正则元字符时不会失效。
		# 长度为 1 或 "/" 的路径不参与，否则会把所有挂载都打进来。
		awk -v a="$base" -v b="$state" -v c="$ocdir" -v d="$home" '
			{
				hit = 0
				if (length(a) > 1 && index($0, a)) hit = 1
				if (!hit && length(b) > 1 && index($0, b)) hit = 1
				if (!hit && length(c) > 1 && index($0, c)) hit = 1
				if (!hit && length(d) > 1 && index($0, d)) hit = 1
				if (!hit && index(tolower($0), "openclaw")) hit = 1
				if (hit) print
			}' /proc/mounts >"$stage/system/mounts.txt" 2>/dev/null || true
	else
		printf '(/proc/mounts 不可用)\n' >"$stage/system/mounts.txt"
	fi
	{
		printf 'openclaw --version:\n'
		if installed; then
			( HOME="$home" PATH="$(oc_node_dir)/bin:$(oc_oc_dir)/bin:$PATH" \
				export_timeout 30 "$(oc_oc_bin)" --version 2>&1 | head -n 5 )
		else
			printf '(未安装)\n'
		fi
		printf '\nnode -v:\n'
		if [ -x "$(oc_node_bin)" ]; then
			export_timeout 15 "$(oc_node_bin)" -v 2>&1
		elif command -v node >/dev/null 2>&1; then
			export_timeout 15 node -v 2>&1
		else
			printf '(未找到 node)\n'
		fi
	} >"$stage/system/versions.txt" 2>&1
	{
		if ps w >/dev/null 2>&1; then ps w 2>/dev/null; else ps 2>/dev/null; fi
	} | awk 'NR == 1 || index(tolower($0), "openclaw")' >"$stage/system/processes.txt" 2>/dev/null || true

	export_note "运行 doctor（timeout 120s，失败不影响打包）"
	{
		if installed; then
			( HOME="$home" PATH="$(oc_node_dir)/bin:$(oc_oc_dir)/bin:$PATH" \
				export_timeout 120 "$(oc_oc_bin)" doctor 2>&1 )
		else
			printf '(openclaw 未安装，跳过 doctor)\n'
		fi
	} >"$stage/doctor.txt" 2>&1 || true

	# 值级二次脱敏：日志/doctor/uci/进程列表里回显的密钥一并清掉
	export_note "脱敏与自检"
	for f in "$stage/logs/openclaw.log" "$stage/logs/openclaw-task.log" \
		"$stage/logs/openclaw-install.log" "$stage/config/openclaw.json" \
		"$stage/config/uci-show.txt" "$stage/doctor.txt" "$stage/meta.txt" \
		"$stage/system/uname.txt" "$stage/system/df.txt" "$stage/system/free.txt" \
		"$stage/system/mounts.txt" "$stage/system/versions.txt" \
		"$stage/system/processes.txt"; do
		export_scrub_file "$f" "$sec"
	done

	if ! export_verify_stage "$stage" "$sec"; then
		export_stage_cleanup
		export_fail "脱敏自检失败：检测到明文密钥，已中止导出"
		return 1
	fi
	# 密钥表绝不能进归档（正常情况下它在 rundir，这里兜底）
	rm -f "$stage/.secrets" 2>/dev/null

	EXPORT_TMPERR="$OC_RUNDIR/diag-tar.$$.err"
	if ! tar -czf "$out" -C "$stage" . 2>"$EXPORT_TMPERR"; then
		terr="$(head -n 1 "$EXPORT_TMPERR" 2>/dev/null)"
		export_stage_cleanup
		rm -f "$out" 2>/dev/null
		export_fail "打包失败：${terr:-tar 返回非 0}"
		return 1
	fi

	chmod 600 "$out" 2>/dev/null
	mode="$(stat -c %a "$out" 2>/dev/null)"
	case "$mode" in
		600|400) ;;
		'')  export_note "警告：无法确认归档权限，请手动执行 chmod 600 $out" ;;
		*)   export_note "警告：归档权限为 $mode（期望 600），请手动执行 chmod 600 $out" ;;
	esac
	size="$(wc -c <"$out" 2>/dev/null | tr -d ' ')"
	case "$size" in ''|*[!0-9]*) size=0 ;; esac

	export_stage_cleanup
	printf '{"ok":true,"path":"%s","size":%s}\n' "$(oc_json_str "$out")" "$size"
	return 0
}

case "${1:-}" in
	status)        cmd_status ;;
	start)         cmd_start ;;
	stop)          cmd_stop ;;
	restart)       cmd_restart ;;
	install)       cmd_install "$@" ;;
	install-bg)    cmd_install_bg "$@" ;;
	install-status) cmd_install_status ;;
	update)        cmd_update "$@" ;;
	uninstall)     cmd_uninstall ;;
	info)          cmd_info ;;
	versions)      cmd_versions ;;
	check)         shift; sh "$OC_VER" check "$@" ;;
	log)           cmd_log "$@" ;;
	tasklog)       cmd_tasklog "$@" ;;
	unlock)        cmd_unlock ;;
	doctor)        cmd_doctor "$@" ;;
	fix)           cmd_repair "$@" ;;
	repair)        cmd_repair "$@" ;;
	diag-run)      cmd_diag_run "$@" ;;
	diag-poll)     cmd_diag_poll "$@" ;;
	backup)        cmd_backup "$@" ;;
	backups)       cmd_backups ;;
	backup-verify) cmd_backup_verify "$@" ;;
	backup-delete) cmd_backup_delete "$@" ;;
	backup-log)    cmd_backup_log "$@" ;;
	backup-path)   sh "$OC_BACKUP" path ;;
	restore)       cmd_restore "$@" ;;
	export)        cmd_export "$@" ;;
	run)           cmd_run "$@" ;;
	mounts)        cmd_mounts ;;
	discover)      cmd_discover ;;
	node-existing) cmd_node_existing ;;
	devices-pending) cmd_devices_pending ;;
	devices-approve) cmd_devices_approve "$@" ;;
	migrate)       cmd_migrate "$@" ;;
	save)          cmd_save "$@" ;;
	port)          get_port; printf '\n' ;;
	token)         get_token; printf '\n' ;;
	models)        shift; sh "$OC_MODELS" "$@" ;;
	channels)      shift; sh "$OC_CHANNELS" "$@" ;;
	*)
		cat <<EOF
openclaw - OpenClaw Launcher (OpenWrt)

Usage: openclaw.sh <command> [options]

  install [--oc-version <v|latest|extended-stable|beta>]
          [--node-version <vX.Y.Z|auto|system>] [--base-dir <dir>]
          [--openclaw-dir <dir>] [--node-mode <private|global>] [--no-start]
          --openclaw-dir relocates the program itself (default <base-dir>/openclaw)
          --node-mode global installs Node.js into /usr/lib/nodejs and links it
          into /usr/bin (system-wide, default); private keeps it under <base-dir>
  install-bg ...            same, detached; poll with install-status
  install-status            {"state":"running|done|failed|lost","rc":..,"log":..,"msg":..,"done_at":..}
  update  [install options] reinstall / upgrade OpenClaw
  uninstall                 remove runtimes, keep config data
  start | stop | restart
  status                    "" | stopped | running
  port | token
  info                      full JSON status
  versions                  online version lists (OpenClaw + Node.js)
  check <oc-ver> <node-ver> verify node satisfies openclaw engines.node
  save --port 18789 --bind lan --base-dir /mnt/data/OpenClaw
       [--openclaw-dir /mnt/nvme0n1-3/OpenClaw]   (empty resets to <base>/openclaw)
  models presets|models <p>|discover <p>|apply <p> <key> [model] [base]|current
  channels weixin install|weixin login|list
  run <openclaw args...>    e.g. run plugins list
  doctor [--fix]            run openclaw doctor; --fix also repairs
  repair [--json] [--no-restart]  one click repair
  diag-run <doctor|doctor-fix|repair>   start a diagnostic in the background
  diag-poll <name>          {"done":bool,"rc":..,"output":".."}  (for LuCI)
  backup [--name <n>] [--no-workspace]   create a backup of config + data
  backups                   JSON array of existing backups
  backup-verify <file>      validate an archive WITHOUT restoring it
  backup-delete <file>      delete one backup
  backup-log [n]            JSON array of backup audit records (oldest first,
                            default 50, max 500)
  backup-path               print the backup directory
  restore <file> [--no-safety]   validate, snapshot, then restore
  log [n] | tasklog [n]
  unlock                    clear a stale operation lock (refuses while the
                            lock holder is still running; JSON on stdout)
  export [path]             diagnostic bundle: full logs + system info + redacted
                            openclaw.json / .env / uci (default
                            /tmp/luci-app-openclaw-diag-<ts>.tar.gz, mode 600)
  mounts                    candidate install targets with free space
  discover                  JSON array of existing OpenClaw installs / data dirs
  node-existing             JSON array of node runtimes already on this device
                            (path / version / source / usable; read-only, installs nothing)
  devices-pending           {"ok":true,"pending":[{id,label,role,requestedAt}]}
                            pending Control UI pairing requests (raw fallback when
                            the CLI output format is not recognised)
  devices-approve <id>      approve ONE pending device (no approve-all by design)
  migrate <dir>             copy an existing install into this plugin's default
                            dirs (cp -a + atomic mv; the source is left as-is).
                            If main.state_dir / main.openclaw_dir point outside
                            base_dir, they are relocated to <base>/home/.openclaw
                            / <base>/openclaw and the UCI keys are cleared

Safety: install/start/restart/update/uninstall/repair refuse to run when the
configured base_dir is a system path (/usr /etc /tmp /var /overlay /rom ...) or
when the gateway port is <= 1024. Mutating commands take a lock in the private
rundir ($OC_LOCK_DIR) so two clicks can never overlap.
EOF
		;;
esac
