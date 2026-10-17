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
					timeout 300 "$(oc_oc_bin)" doctor --fix 2>&1 | tail -n 60
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
	rm -f "$OC_INSTALLLOG" "$OC_INST_DONE"
	mkdir -p "$OC_LOGDIR" "$(dirname "$OC_INST_RC")" 2>/dev/null || true
	( sh "$OC_INSTALL" "$@" >"$OC_INSTALLLOG" 2>&1; \
		printf '%s' "$?" >"$OC_INST_RC"; \
		touch "$OC_INST_DONE" ) &
	# OC_INSTALLLOG may contain quotes after the user picked a custom path
	printf '{"started":true,"log":"%s"}\n' "$(oc_json_str "$OC_INSTALLLOG")"
}

cmd_install_status() {
	local rc state
	if [ -f "$OC_INST_DONE" ]; then
		rc="$(cat "$OC_INST_RC" 2>/dev/null)"
		case "$rc" in ''|*[!0-9]*) rc="" ;; esac
		[ "$rc" = "0" ] && state=done || state=failed
	else
		state=running
	fi
	printf '{"state":"%s","rc":"%s","log":"%s"}\n' "$state" "${rc:-}" "$(oc_json_str "$OC_INSTALLLOG")"
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
	printf '{"status":"%s","installed":%s,"port":"%s","token":"%s","openclaw":"%s","node":"%s","node_mode":"%s","base_dir":"%s","openclaw_dir":"%s","oc_dir_custom":%s,"home":"%s","free_mb":"%s","arch":"%s","musl":%s,"bind":"%s","url":"http://%s:%s/"}\n' \
		"$st" \
		"$(installed && echo true || echo false)" \
		"$port" "$token" "${ver:-}" "${nver:-}" \
		"$(oc_node_mode)" \
		"$(oc_json_str "$base")" "$(oc_json_str "$ocdir")" \
		"$([ -n "$(uci_get main.openclaw_dir '')" ] && echo true || echo false)" \
		"$home" "${free:-0}" \
		"$(oc_arch)" "$(oc_is_musl && echo 1 || echo 0)" \
		"$(uci_get main.bind lan)" \
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
			timeout 120 "$(oc_oc_bin)" doctor 2>&1 | tail -n 60
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
				timeout 300 "$(oc_oc_bin)" doctor --fix 2>&1 | tail -n 60
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
		timeout 120 "$(oc_oc_bin)" "$@" 2>&1 | tail -n 200
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

cmd_link() {
	# link <dir> : 把本机已有的 OpenClaw 安装「关联」到本插件。
	#
	# 只改 UCI（main.base_dir / main.state_dir 指向它，并清掉指向旧 base_dir 的
	# 残留 main.state_dir / main.openclaw_dir）—— 不复制文件、不建目录、不 chown、
	# 不取锁，所以这里不调 require_safe：它校验的是「当前」的 base_dir 与端口，
	# 而 link 的目的恰恰是把它们指到别处。
	#
	# stdout 只允许出现 JSON（前端直接 JSON.parse）：日志一律走 oc_err（stderr），
	# 与 cmd_discover 同一条约定 —— 谁在这里加一行 oc_info，谁的 JSON 就坏掉。
	#
	# 已知缺口（已修复）：kind=ours 时 base_dir 会被指到 <dir>，但 UCI 里若残留
	# main.state_dir / main.openclaw_dir，它们优先于 base_dir 推导出的默认值，
	# 关联可能「报成功但不生效」（数据其实还在旧目录）。这里只清「残留」，不清
	# 「用户显式设置」——判定见下方：非空且位于旧 base_dir 之下 ⇒ 残留（是从旧
	# base_dir 推导出来的）；非空但不在旧 base_dir 之下 ⇒ 用户显式指到别处，保留。
	local dir="${2:-}" kind target="" base_dir="" state_dir=""
	local old_base="" cur="" cleared="" state_cleared=0 f

	[ -n "$dir" ] || {
		oc_err "link: 缺少目录参数"
		printf '{"ok":false,"error":"缺少目录参数"}\n'
		return 2
	}
	# 归一化：去掉尾随斜杠（"/" 单独保留，交给下面的探测/校验去拒绝）
	dir="${dir%/}"
	[ -n "$dir" ] || dir="/"

	if [ ! -d "$dir" ]; then
		oc_err "link: 目录不存在：$dir"
		printf '{"ok":false,"error":"%s"}\n' "$(oc_json_str "目录不存在：$dir")"
		return 2
	fi

	kind="$(oc_probe_openclaw_dir "$dir")"
	# 旧 base_dir 必须在下面写 main.base_dir 之前取到：残留判定要拿它做基准，
	# 否则会把「新」base_dir 当成旧值，残留项就判不出来了。
	old_base="$(oc_base_dir)"
	case "$kind" in
		ours)
			# 本插件布局：base_dir 会被 oc_fix_perms 递归 chown/chmod，
			# 数据默认在 <dir>/home/.openclaw
			target="$dir"
			base_dir="$dir"
			;;
		istore)
			# iStoreOS luci-app-openclawmgr 布局：数据在 <dir>/data/.openclaw
			target="$dir/data/.openclaw"
			state_dir="$target"
			;;
		data)
			# 只有数据：<dir>/.openclaw
			target="$dir/.openclaw"
			state_dir="$target"
			;;
		*)
			oc_err "link: 不是有效的 OpenClaw 安装：$dir"
			printf '{"ok":false,"error":"%s"}\n' "$(oc_json_str "不是有效的 OpenClaw 安装：$dir")"
			return 2
			;;
	esac

	# 要写入的路径都要过同一套校验：base_dir 会被递归 chown/chmod，
	# state_dir 会被备份/还原整体移动或删除 —— 系统路径一律拒绝，且不写入。
	if ! oc_validate_base_dir "$target"; then
		oc_err "link: 拒绝关联不安全的路径：$target（需为绝对路径，且不能是 / /etc /tmp /var 等系统路径）"
		printf '{"ok":false,"error":"%s"}\n' "$(oc_json_str "拒绝关联不安全的路径：$target")"
		return 2
	fi

	# 只清「残留」：kind=ours 会把 base_dir 指到别处，旧 base_dir 派生出的
	# main.state_dir / main.openclaw_dir 随之失效并覆盖新默认值，必须清掉，
	# 否则 link 报成功但数据仍在旧目录。用户显式指到别处（不在旧 base_dir
	# 之下，例如大容量盘）的值保留不动 —— 清掉它会把数据改回一份旧副本。
	if [ "$kind" = "ours" ] && [ -n "$old_base" ] && [ "$old_base" != "/" ]; then
		for f in main.state_dir main.openclaw_dir; do
			cur="$(uci_get "$f" '')"
			[ -n "$cur" ] || continue
			cur="${cur%/}"
			[ -n "$cur" ] || continue
			case "$cur" in
				"$old_base"/*)
					uci -q delete "${OC_UCI}.${f}" 2>/dev/null
					oc_warn "link: 清除残留的 $f=$cur（位于旧安装目录 $old_base 之下）"
					[ "$f" = "main.state_dir" ] && state_cleared=1
					:
					if [ -z "$cleared" ]; then
						cleared="\"$f\""
					else
						cleared="$cleared,\"$f\""
					fi
					;;
			esac
		done
	fi

	case "$kind" in
		ours) uci_set main.base_dir "$dir" ;;
		*)    uci_set main.state_dir "$state_dir" ;;
	esac
	uci_commit

	# state_dir 被清空后不再由 UCI 指定，实际生效值就是 base_dir 派生出的默认
	# 数据目录；把它如实报给前端（不清空时 ours 仍报空串，保持原有语义）。
	if [ "$state_cleared" = "1" ]; then
		state_dir="$(oc_probe_data_dir "$base_dir" ours)"
	fi

	# 未设置的字段给空字符串，保持结构稳定；cleared 是被清空的 UCI 项（无则 []）
	printf '{"ok":true,"kind":"%s","base_dir":"%s","state_dir":"%s","cleared":[%s]}\n' \
		"$kind" "$(oc_json_str "$base_dir")" "$(oc_json_str "$state_dir")" "$cleared"
}

# ---------------------------------------------------------------- migrate
# migrate <dir> : 把本机已有的 OpenClaw 安装「迁移」到本插件的默认目录。
#
# 与 link 的区别：link 只改 UCI 指过去（零拷贝，两边共享同一份文件）；
# migrate 是真的把文件复制过来 —— 之后两边完全独立，源目录保持原样，
# 用户确认无误后可以自行删除。
#
# 原子性：先把内容 cp -a 到「与目标同一分区」的暂存目录，校验关键文件通过后
# 才用 mv 换入（同分区 rename，不会留下复制到一半的目标）。换入前若目标已有
# 数据，先走 backup.sh 的安全快照；任何一步失败都只清理暂存目录，已存在的
# 目标数据保持原样。
#
# 目标布局：<安装目录>/{home/.openclaw,openclaw,node}（可用 main.state_dir /
# main.openclaw_dir 覆盖，但必须仍在 <安装目录> 之下 —— 否则一次 mv 无法原子
# 完成，这里会明确拒绝，而不是留下一半新一半旧的状态）。
#
# stdout 只允许 JSON（前端直接 JSON.parse）：日志一律走 stderr，不用 oc_info。

MIG_STAGE=""
MIG_OLD=""
MIG_DST=""
MIG_MOVED=0
MIG_LOCKED=0

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

cmd_migrate() {
	# migrate <dir> : 见本节开头的说明。成功输出
	# {"ok":true,"from":..,"to":..,"kind":..}，失败输出 {"ok":false,"error":..}
	local dir="${2:-}" kind src_root base state ocdir nodedir
	local rel_state rel_oc rel_node
	local src_data src_prog src_node
	local dst swap_parent stage old full=1 need have_data before snap dev_stage dev_dst

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

	# 目标必须落在 base_dir 之下：暂存目录建在 base 的同级，只有这样才能用
	# 一次 mv 原子换入。自定义到 base 之外的数据/程序目录无法一次搬完，
	# 明确拒绝而不是做一次可能半途失败的多次移动。
	rel_state="${state#"$base"/}"
	if [ -z "$rel_state" ] || [ "$rel_state" = "$state" ]; then
		mig_fail "拒绝迁移：数据目录 $state 不在安装目录 $base 之下，请先清空 main.state_dir" 2
	fi
	rel_oc="${ocdir#"$base"/}"
	if [ -z "$rel_oc" ] || [ "$rel_oc" = "$ocdir" ]; then
		mig_fail "拒绝迁移：程序目录 $ocdir 不在安装目录 $base 之下，请先清空 main.openclaw_dir" 2
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
	have_data=0
	if [ "$full" = "1" ]; then
		[ -f "$base/$rel_state/openclaw.json" ] && have_data=1
	else
		[ -f "$dst/openclaw.json" ] && have_data=1
	fi
	if [ "$have_data" = "1" ]; then
		before="$(sh "$OC_BACKUP" create --name "pre-migrate" 2>/dev/null)"
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

	# ---- 10) 权限与提示 ----
	oc_fix_perms >/dev/null 2>&1 || oc_warn "权限修复未完全成功，请检查 $base"

	if [ "$full" = "0" ]; then
		oc_warn "源目录只有数据、没有程序本体：迁移后仍需在本插件内安装一次 OpenClaw"
	elif [ "$(oc_node_mode)" = "private" ]; then
		[ -n "$src_node" ] || oc_warn "源目录没有私有 Node 运行时（node/），迁移后可能需要在插件内重新安装运行时"
	else
		oc_warn "当前为 global 模式，未迁移 Node 运行时（使用系统运行时）"
	fi

	# to 报安装目录：那才是"本插件的默认目录"（数据/程序都在它下面）
	printf '{"ok":true,"from":"%s","to":"%s","kind":"%s"}\n' \
		"$(oc_json_str "$dir")" "$(oc_json_str "$base")" "$kind"
	return 0
}

cmd_save() {
	# save basic settings from uci-like key=value pairs
	shift
	while [ $# -gt 0 ]; do
		case "$1" in
			--base-dir)
				# refuse a dangerous target instead of silently accepting it
				if ! oc_validate_base_dir "${2:-}"; then
					oc_err "拒绝保存不安全的安装目录：${2:-}"
					exit 2
				fi
				uci_set main.base_dir "$2"; shift 2 ;;
			--openclaw-dir)
				# 程序目录可单独指定；空值表示"恢复默认（<安装目录>/openclaw）"
				if [ -n "${2:-}" ]; then
					if ! oc_validate_base_dir "$2"; then
						oc_err "拒绝保存不安全的程序目录：${2}（不能是 /、/etc、/tmp、/var 等系统路径）"
						exit 2
					fi
					# 程序目录不能是安装目录本身或它的上级，否则卸载时
					# `rm -rf "$ocdir"` 会把数据（home）一起删掉
					local b="${2%/}" cur
					cur="$(oc_base_dir)"
					if [ "$b" = "$cur" ]; then
						oc_err "程序目录不能等于安装目录（$cur）"; exit 2
					fi
					case "$cur" in
						"$b"/*)
							oc_err "程序目录不能是安装目录的上级（$b 包含 $cur）"; exit 2 ;;
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

cmd_restore() {
	# 还原：会先做一次安全快照，再停网关、替换数据、重启
	shift
	require_safe
	need_lock
	sh "$OC_BACKUP" restore "$@"
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
	doctor)        cmd_doctor "$@" ;;
	fix)           cmd_repair "$@" ;;
	repair)        cmd_repair "$@" ;;
	diag-run)      cmd_diag_run "$@" ;;
	diag-poll)     cmd_diag_poll "$@" ;;
	backup)        cmd_backup "$@" ;;
	backups)       cmd_backups ;;
	backup-verify) cmd_backup_verify "$@" ;;
	backup-delete) cmd_backup_delete "$@" ;;
	backup-path)   sh "$OC_BACKUP" path ;;
	restore)       cmd_restore "$@" ;;
	run)           cmd_run "$@" ;;
	mounts)        cmd_mounts ;;
	discover)      cmd_discover ;;
	node-existing) cmd_node_existing ;;
	link)          cmd_link "$@" ;;
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
  install-status            {"state":"running|done|failed"}
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
  backup-path               print the backup directory
  restore <file> [--no-safety]   validate, snapshot, then restore
  log [n] | tasklog [n]
  mounts                    candidate install targets with free space
  discover                  JSON array of existing OpenClaw installs / data dirs
  node-existing             JSON array of node runtimes already on this device
                            (path / version / source / usable; read-only, installs nothing)
  link <dir>                point the config at an existing install (UCI only,
                            nothing is copied: base_dir / state_dir per layout)
  migrate <dir>             copy an existing install into this plugin's default
                            dirs (cp -a + atomic mv; the source is left as-is)

Safety: install/start/restart/update/uninstall/repair refuse to run when the
configured base_dir is a system path (/usr /etc /tmp /var /overlay /rom ...) or
when the gateway port is <= 1024. Mutating commands take a lock in the private
rundir ($OC_LOCK_DIR) so two clicks can never overlap.
EOF
		;;
esac
