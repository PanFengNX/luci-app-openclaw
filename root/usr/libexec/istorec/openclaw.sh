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
	printf '{"status":"%s","installed":%s,"port":"%s","token":"%s","openclaw":"%s","node":"%s","base_dir":"%s","openclaw_dir":"%s","oc_dir_custom":%s,"home":"%s","free_mb":"%s","arch":"%s","musl":%s,"bind":"%s","url":"http://%s:%s/"}\n' \
		"$st" \
		"$(installed && echo true || echo false)" \
		"$port" "$token" "${ver:-}" "${nver:-}" \
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
          [--openclaw-dir <dir>] [--no-start]
          --openclaw-dir relocates the program itself (default <base-dir>/openclaw)
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

Safety: install/start/restart/update/uninstall/repair refuse to run when the
configured base_dir is a system path (/usr /etc /tmp /var /overlay /rom ...) or
when the gateway port is <= 1024. Mutating commands take a lock in the private
rundir ($OC_LOCK_DIR) so two clicks can never overlap.
EOF
		;;
esac
