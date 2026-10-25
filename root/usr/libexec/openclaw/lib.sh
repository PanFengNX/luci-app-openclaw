#!/bin/sh
# openclaw - shared helpers
# POSIX sh (busybox ash) compatible.

OC_NAME="openclaw"
OC_UCI="openclaw"
OC_LOGDIR="/var/log"
OC_LOGFILE="$OC_LOGDIR/openclaw.log"
OC_INSTALLLOG="$OC_LOGDIR/openclaw-install.log"
OC_TASKLOG="$OC_LOGDIR/openclaw-task.log"
OC_BKUPLOG="$OC_LOGDIR/openclaw-backup.log"

# 单个日志文件的上限（256KB）。OpenWrt 的 /var 是 tmpfs：日志无限增长会吃内存，
# 落盘设备上则耗 flash。所有写日志的路径都应在追加之前调用 oc_log_rotate()。
OC_LOG_MAX_BYTES=262144

OC_USER="openclaw"
OC_GROUP="openclaw"

# ---------------------------------------------------------------- rundir
# Everything transient used to live at hard-coded /tmp/openclaw-* names.
# /tmp is mode 1777 on OpenWrt, so any local user could pre-create those
# paths: a symlink at .../install.rc makes us overwrite an arbitrary file as
# root, and a pre-created lock directory denies every management action.
# We now keep one private, mode-0700 directory and validate its ownership on
# every start. The name stays predictable on purpose - diag-run and diag-poll
# are separate processes and must agree on where the output file is.
OC_RUNDIR_BASE="/tmp/.openclaw"

oc_dir_uid() {
	# oc_dir_uid <dir> -> numeric owner uid ("-1" when unknown).
	# `[ -O ]` is a bash-ism and busybox's test is not guaranteed to have it.
	local d="$1" u
	u="$(stat -c %u "$d" 2>/dev/null)"
	[ -n "$u" ] || u="$(ls -ldn "$d" 2>/dev/null | awk '{print $3}')"
	case "$u" in ''|*[!0-9]*) u="-1" ;; esac
	printf '%s' "$u"
}

oc_rundir() {
	# oc_rundir -> prints the private scratch dir (empty + rc 1 when unusable)
	local d="$OC_RUNDIR_BASE" uid
	uid="$(id -u 2>/dev/null || echo 0)"

	# a symlink or a regular file at that name is never legitimate
	if [ -L "$d" ] || { [ -e "$d" ] && [ ! -d "$d" ]; }; then
		rm -f "$d" 2>/dev/null || return 1
	fi

	if [ ! -d "$d" ]; then
		# mkdir -m can fail to apply the mode on some filesystems while still
		# creating the directory - that is not a reason to give up, the chmod
		# below makes another attempt and the contents stay unreadable to
		# others on any normal tmpfs anyway.
		mkdir -m 700 "$d" 2>/dev/null
		[ -d "$d" ] || return 1
	fi

	# 属主不符时的处理：root 收回来；**非 root 不能拒绝**，换到自己的目录。
	#
	# 原来非 root 直接 return 1，于是 uid 998（网关运行用户）下连只读命令
	# （status / info / token / log）全部报「临时目录不属于当前用户」并失败，
	# 锁也拿不到 —— CLI 排障与 cron 自动化全部失效。
	# 而 /tmp/.openclaw 通常是 root（LuCI / procd）先创建的，所以这不是罕见路径，
	# 是**默认路径**。
	if [ "$(oc_dir_uid "$d" 2>/dev/null)" != "$uid" ]; then
		if [ "$uid" = "0" ]; then
			chown "$uid" "$d" 2>/dev/null || true
		else
			# 回落到自己的目录（放在 HOME 下，同用户可写；仍强制 0700）。
			local alt="${HOME:-/tmp}/.openclaw-run-$uid"
			if [ -L "$alt" ] || { [ -e "$alt" ] && [ ! -d "$alt" ]; }; then
				rm -f "$alt" 2>/dev/null || return 1
			fi
			[ -d "$alt" ] || mkdir -m 700 "$alt" 2>/dev/null
			[ -d "$alt" ] || return 1
			# 二次校验：回落目录也必须属于自己，否则等于把私有目录交给别人
			[ "$(oc_dir_uid "$alt" 2>/dev/null)" = "$uid" ] || return 1
			chmod 700 "$alt" 2>/dev/null || true
			printf '%s' "$alt"
			return 0
		fi
	fi
	chmod 700 "$d" 2>/dev/null || true
	printf '%s' "$d"
}

# Resolved once, at load time. Every caller then shares the same directory.
# On failure we still point at the base name rather than at "" - that keeps
# every derived path under /tmp/.openclaw instead of escaping to "/lock",
# and the subsequent mkdir simply fails (fail closed).
OC_RUNDIR="$(oc_rundir)"
[ -n "$OC_RUNDIR" ] || OC_RUNDIR="$OC_RUNDIR_BASE"
OC_LOCK_DIR="$OC_RUNDIR/lock"
OC_DL="$OC_RUNDIR/dl"

# ---------------------------------------------------------------- logging
oc_log_rotate() {
	# oc_log_rotate <file> [max_bytes]
	#
	# 超过上限就把 <file> 改名为 <file>.1（只保留一份历史，旧的 .1 被覆盖）。
	# 用 mv 而不是 rm：rename 是原子的，正在被 tail -f 的读者最多丢一次内容；
	# 也不碰文件权限（mv 保留原 mode/owner）。
	# 任何一步拿不到可信结果都直接返回，绝不影响调用方的写入。
	local f="${1:-}" max="${2:-$OC_LOG_MAX_BYTES}" size
	[ -n "$f" ] || return 0
	[ -f "$f" ] || return 0
	case "$max" in ''|*[!0-9]*) max="$OC_LOG_MAX_BYTES" ;; esac
	size="$(wc -c <"$f" 2>/dev/null | tr -d ' \r\n')"
	case "$size" in ''|*[!0-9]*) return 0 ;; esac
	[ "$size" -gt "$max" ] 2>/dev/null || return 0
	mv -f "$f" "$f.1" 2>/dev/null || return 0
	return 0
}

oc_log() {
	# oc_log <level> <message>
	local lvl="$1"; shift
	local line dir f
	line="$(date '+%Y-%m-%d %H:%M:%S') [$lvl] $*"
	printf '%s\n' "$line"
	# never let a read-only /var/log break the caller
	dir="$OC_LOGDIR"
	f="$OC_LOGFILE"
	# /var/log 在多数固件上是 755 root:root，非 root 身份（网关用户 998）
	# 调用时 `-w` 为假，日志**静默丢弃** —— CLI 与 cron 排障时表现为
	# "日志里什么都没有"，且没有任何提示。回落到安装目录下的 logs/
	# （本包创建、属主正确），保证日志至少有一份落地。
	if [ ! -d "$dir" ] || [ ! -w "$dir" ]; then
		local alt
		alt="$(oc_base_dir 2>/dev/null)/logs"
		if [ -n "$alt" ] && [ -d "$alt" ] && [ -w "$alt" ]; then
			dir="$alt"
			f="$alt/${OC_LOGFILE##*/}"
		fi
	fi
	if [ -d "$dir" ] && [ -w "$dir" ]; then
		oc_log_rotate "$f"
		printf '%s\n' "$line" >>"$f" 2>/dev/null || true
	fi
}

oc_info() { oc_log INFO "$@"; }
# WARN and ERROR go to stderr: several commands (info / diag-poll / install-status)
# print a JSON payload on stdout and a stray log line would corrupt it.
oc_warn() { oc_log WARN "$@" >&2; }
oc_err()  { oc_log ERROR "$@" >&2; }
oc_raw()  { printf '%s\n' "$*"; }

# ---------------------------------------------------------------- portability
oc_timeout() {
	# oc_timeout <seconds> <cmd...>
	# busybox 的 timeout 在部分老版本 / 精简构建里没有（实机见过
	# "timeout: not found"）。缺失时退化为直接执行 —— 不设上限，但必须
	# 在 stderr 留一行告警，否则用户只会看到命令莫名变慢。
	# 注意用 "$@" 转发，绝不把参数拼成字符串（会破坏含空格的路径）。
	local t="$1"; shift
	if command -v timeout >/dev/null 2>&1; then
		timeout "$t" "$@"
		return $?
	fi
	# 没有 timeout applet 时**自己兜底**：放到后台跑，到点先 TERM 再 KILL。
	# 早先这里是"直接执行、不设上限"，代价很实在 —— 实机缺 timeout，
	# `openclaw models list --all` 一旦卡住，模型页的下拉框就永远是空的
	# （前端 20 秒超时，后端却可能跑几分钟）。宁可杀掉，也不能无限等。
	"$@" &
	local pid=$! wd rc
	(
		i=0
		while [ "$i" -lt "$t" ]; do
			sleep 1
			kill -0 "$pid" 2>/dev/null || exit 0
			i=$((i + 1))
		done
		oc_warn "命令超过 ${t} 秒，已终止：$*"
		kill -TERM "$pid" 2>/dev/null
		sleep 1
		kill -KILL "$pid" 2>/dev/null
	) >/dev/null 2>&1 &
	wd=$!
	wait "$pid" 2>/dev/null
	rc=$?
	kill "$wd" 2>/dev/null
	return "$rc"
}

# ---------------------------------------------------------------- uci
uci_get() {
	# uci_get <key> [default]
	local v
	v="$(uci -q get "${OC_UCI}.${1}" 2>/dev/null)"
	[ -n "$v" ] || v="${2:-}"
	printf '%s' "$v"
}

uci_set() {
	# uci_set <key> <value>
	uci -q set "${OC_UCI}.${1}=${2}" 2>/dev/null
}

uci_commit() { uci -q commit "$OC_UCI" 2>/dev/null; }

# base directory (everything lives inside it)
oc_base_dir() {
	local d
	d="$(uci_get main.base_dir '')"
	[ -n "$d" ] || d="/mnt/data/OpenClaw"
	# normalise: strip trailing slashes, but never turn "/" into "" ——
	# an empty result would make every derived path relative (e.g. oc_oc_bin
	# would become "/bin/openclaw") and hide the real value in error messages.
	d="${d%/}"
	[ -n "$d" ] || d="/"
	printf '%s' "$d"
}

# ---------------------------------------------------------------- node paths
# 运行时有两种部署方式（main.node_mode）：
#   private（默认）: 解压到 <安装目录>/node，只有本插件用它，系统里其他程序看不到。
#   global        : 解压到 /usr/lib/nodejs 并在 /usr/bin 建 node/npm/npx 符号链接，
#                   全系统都能直接用（代价是会占用 overlay 空间、且要接管 /usr/bin）。
# 两种模式下 $(oc_node_dir)/bin/node 都指向真实的 node 二进制，路径约定因此自洽。
OC_NODE_GLOBAL_DIR="/usr/lib/nodejs"

oc_node_mode() {
	local m
	m="$(uci_get main.node_mode private)"
	case "$m" in
		global) printf 'global' ;;
		*)      printf 'private' ;;
	esac
}

oc_node_dir() {
	if [ "$(oc_node_mode)" = "global" ]; then
		printf '%s' "$OC_NODE_GLOBAL_DIR"
	else
		printf '%s/node' "$(oc_base_dir)"
	fi
}
oc_oc_dir() {
	# OpenClaw 程序目录。默认是 <安装目录>/openclaw，但可以用 main.openclaw_dir
	# 单独指定 —— 例如程序放内置 flash、数据（会话/工作区）放大容量磁盘。
	#
	# ⚠️ 这是用户可配置的路径，所以任何会 chown / chmod / rm -rf 它的地方
	# 都必须先过 oc_oc_dir_safe()，否则把 openclaw_dir 设成 /etc 就会递归接管系统目录。
	local d
	d="$(uci_get main.openclaw_dir '')"
	[ -n "$d" ] || d="$(oc_base_dir)/openclaw"
	d="${d%/}"
	[ -n "$d" ] || d="/"
	printf '%s' "$d"
}
oc_oc_dir_safe() {
	# 0 when the configured program dir is a safe place to write to / delete from.
	# 复用 base_dir 的形状校验：拒绝相对路径、..、系统前缀，存在时解析符号链接后复查。
	oc_validate_base_dir "$(oc_oc_dir)"
}
oc_state_dir() {
	# OpenClaw 数据根目录：openclaw.json / .env / 会话 / 工作区都在它下面。
	# 默认 <安装目录>/home/.openclaw（历史行为）；可用 main.state_dir 覆盖 ——
	# 例如把数据放到大容量磁盘，或者指向本机已有的 OpenClaw 数据目录
	# （可以直接 uci set 指定，不需要搬动文件）。
	#
	# ⚠️ 与 oc_oc_dir() 同理，这是用户可配置路径：任何会 chown / chmod / 删除它
	# 的地方都必须先过安全校验，不能拿 UCI 值直接递归操作。
	local d
	d="$(uci_get main.state_dir '')"
	[ -n "$d" ] || d="$(oc_base_dir)/home/.openclaw"
	d="${d%/}"
	[ -n "$d" ] || d="/"
	printf '%s' "$d"
}
oc_home_dir()  { printf '%s/home' "$(oc_base_dir)"; }
oc_data_dir()  { oc_state_dir; }
oc_conf()      { printf '%s/openclaw.json' "$(oc_state_dir)"; }

# ---------------------------------------------------------------- CLI state env
# CLI 与网关必须指向同一份配置/环境文件。state_dir 可被 main.state_dir 覆盖，
# 但 OpenClaw CLI 只认自己的默认（$HOME/.openclaw），不会去读 UCI ——
# 所以在这里统一导出，所有 source lib.sh 的脚本（以及 /usr/bin/openclaw 包装器）
# 调用 CLI 时都会自动带上，不用每个调用点各写一遍。
#
# 若 state_dir 被覆盖（数据放大容量盘、手工指向已有安装）而这里不导出，CLI 会
# 继续读写 <安装目录>/home/.openclaw，与网关和 oc_conf() 用的 state_dir 分家：
# 表现为模型页保存成功但网关不生效、改端口重启没变、API Key 写了仍报未配置。
#
# 默认布局下这两个值与改动前完全一致（<base_dir>/home/.openclaw[/openclaw.json]），
# 因此默认行为不变。oc_home_dir() 仍表示进程 HOME，与 state 目录是两回事，不要混用。
#
# ⚠️ 新增调用 CLI 的地方不要再自己拼 HOME 去猜 state 路径，直接依赖这两个变量。
# 注意这是载入时求值的快照：同一进程内修改 UCI 的 main.state_dir 后，已导出的值
# 不会自动更新（改完 main.state_dir 请用新进程，或重新 source 本文件后再调 CLI）。
OC_STATE_DIR="$(oc_state_dir)"
OC_CONF_FILE="$(oc_conf)"
export OPENCLAW_STATE_DIR="$OC_STATE_DIR"
export OPENCLAW_CONFIG_PATH="$OC_CONF_FILE"

oc_node_bin() {
	# global 模式优先用 /usr/bin/node（存在且可执行时），
	# 否则退回运行时目录里的真实二进制。private 模式行为不变。
	if [ "$(oc_node_mode)" = "global" ]; then
		if [ -x /usr/bin/node ]; then
			printf '/usr/bin/node'
		else
			printf '%s/bin/node' "$OC_NODE_GLOBAL_DIR"
		fi
		return 0
	fi
	printf '%s/node/bin/node' "$(oc_base_dir)"
}
oc_oc_bin()    { printf '%s/bin/openclaw' "$(oc_oc_dir)"; }

# ---------------------------------------------------------------- legacy config keys
# 2026.10 起 OpenClaw 删除了 gateway.controlUi 下的三个认证相关键。配置里只要
# 出现任意一个，整份 openclaw.json 就会被判为无效（Unrecognized key），网关直接
# 拒绝启动。iStoreOS 的 luci-app-openclawmgr 每次被调用（启动/停止/安装/打开
# 管理页）都会无条件写回这三个键，所以「用户手动删一次」没有用 —— 本插件复用
# 同一份配置时，必须自己把它们清掉。
#
# 清理结果通过全局变量回传给调用方（busybox ash 没有 local -n，沿用
# OC_PID_REASON 的既有风格）。调用方在调用前不要依赖旧值。
OC_LEGACY_CONTROLUI_APPLICABLE=0	# 1 = 版本门禁通过，确实做了检测
OC_LEGACY_CONTROLUI_FOUND=0		# 检测到的旧键数量
OC_LEGACY_CONTROLUI_REMOVED=0		# 实际删掉的旧键数量

oc_legacy_controlui_keys() {
	# 逐行输出 2026.10 已删除的 controlUi 键名（不带 gateway.controlUi 前缀）。
	# busybox 没有数组，调用方用 for + 命令替换遍历。
	printf '%s\n' \
		allowInsecureAuth \
		dangerouslyDisableDeviceAuth \
		dangerouslyAllowHostHeaderOriginFallback
}

oc_installed_version() {
	# oc_installed_version [oc-dir] -> x.y.z；取不到时无输出并返回 1。
	#
	# 优先读 npm 包自带的 package.json：不启动 CLI，也就不受「配置文件非法」
	# 影响 —— 而配置非法正是本函数要修的故障。若只靠 `openclaw --version`，
	# 一旦 CLI 启动时校验配置，版本门禁就会把清理永久跳过。
	#
	# oc-dir 可显式指定：install.sh 可能用 --base-dir/--openclaw-dir 装到
	# 与 UCI 不同的目录，此时不能依赖 oc_oc_dir()。
	local ocdir pj v
	ocdir="${1:-}"
	[ -n "$ocdir" ] || ocdir="$(oc_oc_dir)"
	pj="$ocdir/lib/node_modules/openclaw/package.json"
	v=""
	if [ -f "$pj" ]; then
		if command -v jsonfilter >/dev/null 2>&1; then
			v="$(jsonfilter -i "$pj" -e '@.version' 2>/dev/null | head -n1)"
		fi
		[ -n "$v" ] || v="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$pj" 2>/dev/null | head -n1)"
	fi
	if [ -z "$v" ] && [ -x "$ocdir/bin/openclaw" ]; then
		v="$(HOME="$(oc_home_dir)" oc_timeout 20 "$ocdir/bin/openclaw" --version 2>/dev/null | head -n1)"
	fi
	# 统一成纯数字版本：去掉 "v" 前缀和任何非数字尾巴
	# （v2026.10.3 / 2026.10.3-beta.1 -> 2026.10.3）
	v="$(printf '%s' "$v" | sed 's/^[^0-9]*//; s/[^0-9.].*$//')"
	case "$v" in
		''|*[!0-9.]*) return 1 ;;
	esac
	case "$v" in
		*[0-9]*) ;;
		*) return 1 ;;
	esac
	printf '%s' "$v"
}

oc_purge_legacy_controlui() {
	# oc_purge_legacy_controlui [config-path] [oc-dir] [node-bin]
	#
	# 删除 2026.10 已不再支持的 gateway.controlUi.* 旧键（旧版 openclawmgr 留下）。
	# 只在已安装版本 >= 2026.10.0 时动手：更早的版本里这些键仍然合法，删掉会
	# 改变旧版行为。取不到版本时什么都不做。
	#
	# oc-dir / node-bin 可显式指定，供 install.sh 在 --base-dir / --openclaw-dir
	# 与 UCI 不一致时使用；省略时走 oc_oc_dir() / oc_node_bin()。
	#
	# 幂等；任何失败都只 oc_warn 并返回 0，绝不中断调用方。
	# **stdout 永远为空** —— 调用方（info / diag / repair --json）可能正在输出 JSON。
	local conf="${1:-}" ocdir="${2:-}" node_bin="${3:-}"
	local ver keys k present n tmp bak ts
	local orig_mode orig_uid orig_gid

	OC_LEGACY_CONTROLUI_APPLICABLE=0
	OC_LEGACY_CONTROLUI_FOUND=0
	OC_LEGACY_CONTROLUI_REMOVED=0

	[ -n "$conf" ] || conf="$(oc_conf)"
	[ -f "$conf" ] || return 0
	command -v jsonfilter >/dev/null 2>&1 || return 0

	ver="$(oc_installed_version "$ocdir")" || return 0
	[ -n "$ver" ] || return 0
	ver_ge "$ver" "2026.10.0" || return 0
	OC_LEGACY_CONTROLUI_APPLICABLE=1

	present=""
	for k in $(oc_legacy_controlui_keys); do
		# 值可能是 false：jsonfilter 输出 "false"（非空），同样算存在。
		# 只有「无输出」才表示键不存在。
		if [ -n "$(jsonfilter -i "$conf" -e "@.gateway.controlUi.$k" 2>/dev/null)" ]; then
			present="$present $k"
		fi
	done
	[ -n "$present" ] || return 0
	n=0
	for k in $present; do
		n=$((n + 1))
	done
	OC_LEGACY_CONTROLUI_FOUND="$n"

	[ -n "$node_bin" ] || node_bin="$(oc_node_bin)"
	if [ ! -x "$node_bin" ]; then
		oc_warn "无法清理 2026.10 废弃配置键：Node.js 不可执行（$node_bin）"
		return 0
	fi

	ts="$(date +%s 2>/dev/null)"
	case "$ts" in ''|*[!0-9]*) ts="$$" ;; esac
	bak="$conf.legacy.bak.$ts"
	if ! cp "$conf" "$bak" 2>/dev/null; then
		oc_warn "无法备份配置文件，已跳过清理 2026.10 废弃配置键：$conf"
		return 0
	fi
	chmod 600 "$bak" 2>/dev/null || true

	# 重写会把文件变成 root:root；先记下原值，覆盖后恢复 —— 网关以 openclaw
	# 用户运行，属主/权限不对就直接读不到配置。
	orig_mode="$(stat -c %a "$conf" 2>/dev/null)"
	orig_uid="$(stat -c %u "$conf" 2>/dev/null)"
	orig_gid="$(stat -c %g "$conf" 2>/dev/null)"

	# 临时文件必须和目标同目录：跨文件系统的 mv 不是原子替换，掉电可能留下
	# 半个配置。jsonfilter 只能查询、不能改写，这里用 Node 做结构化删除；
	# 版本门禁已保证 OpenClaw 装着，而它必须有 Node 才能运行。
	# 参数全部经 argv 传递，不拼进脚本字符串，路径含空格也不会出错。
	tmp="$conf.legacy.tmp.$$"
	rm -f "$tmp" 2>/dev/null || true
	if ! "$node_bin" -e '
const fs = require("fs");
const a = process.argv.slice(1);
const src = a[0], dst = a[1], keys = a.slice(2);
const doc = JSON.parse(fs.readFileSync(src, "utf8"));
const ui = doc && doc.gateway && doc.gateway.controlUi;
if (ui && typeof ui === "object" && !Array.isArray(ui)) {
	for (const k of keys) delete ui[k];
}
fs.writeFileSync(dst, JSON.stringify(doc, null, 2) + "\n", { mode: 0o600 });
' "$conf" "$tmp" $present 2>/dev/null; then
		rm -f "$tmp" 2>/dev/null || true
		oc_warn "清理 2026.10 废弃配置键失败（配置未改动）：$conf"
		return 0
	fi

	# 校验：必须是合法 JSON、非空，且旧键确实消失。任何一项不满足都保留原文件。
	if [ ! -s "$tmp" ] || ! jsonfilter -i "$tmp" -e '$' >/dev/null 2>&1; then
		rm -f "$tmp" 2>/dev/null || true
		oc_warn "清理 2026.10 废弃配置键失败：重写结果不是合法 JSON（配置未改动）：$conf"
		return 0
	fi
	for k in $present; do
		if [ -n "$(jsonfilter -i "$tmp" -e "@.gateway.controlUi.$k" 2>/dev/null)" ]; then
			rm -f "$tmp" 2>/dev/null || true
			oc_warn "清理 2026.10 废弃配置键失败：重写后仍存在 gateway.controlUi.$k（配置未改动）"
			return 0
		fi
	done

	if ! mv -f "$tmp" "$conf" 2>/dev/null; then
		rm -f "$tmp" 2>/dev/null || true
		oc_warn "清理 2026.10 废弃配置键失败：无法覆盖配置文件 $conf"
		return 0
	fi

	case "$orig_mode" in ''|*[!0-7]*) orig_mode="" ;; esac
	[ -n "$orig_mode" ] && chmod "$orig_mode" "$conf" 2>/dev/null
	case "$orig_uid" in ''|*[!0-9]*) orig_uid="" ;; esac
	case "$orig_gid" in ''|*[!0-9]*) orig_gid="" ;; esac
	if [ -n "$orig_uid" ] && [ -n "$orig_gid" ]; then
		chown "$orig_uid:$orig_gid" "$conf" 2>/dev/null \
			|| oc_warn "无法恢复配置文件属主（$orig_uid:$orig_gid）：$conf"
	fi

	for k in $present; do
		OC_LEGACY_CONTROLUI_REMOVED=$((OC_LEGACY_CONTROLUI_REMOVED + 1))
		oc_warn "已移除 2026.10 不再支持的配置键 gateway.controlUi.$k（旧版 openclawmgr 写入，保留会导致网关拒绝启动）"
	done
	oc_warn "配置清理完成：共移除 $OC_LEGACY_CONTROLUI_REMOVED 个 2026.10 不再支持的配置键（备份：$bak）"
	return 0
}

oc_npm_cli() {
	# npm 的 CLI 入口（npm-cli.js）。覆盖 private / global 两种布局：
	#   1. <运行时目录>/lib/node_modules/npm/bin/npm-cli.js   （官方 tar 包布局）
	#   2. 由 /usr/bin/npm 反查（global 模式我们建的链接）
	#   3. 由 node 二进制相对定位（运行时目录被替换成别的布局时）
	#   4. 在运行时目录里 find 兜底
	local c nb d
	c="$(oc_node_dir)/lib/node_modules/npm/bin/npm-cli.js"
	[ -f "$c" ] && { printf '%s' "$c"; return 0; }
	if [ -L /usr/bin/npm ]; then
		c="$(readlink -f /usr/bin/npm 2>/dev/null)" || c=""
		[ -n "$c" ] && [ -f "$c" ] && { printf '%s' "$c"; return 0; }
	fi
	nb="$(oc_node_bin)"
	if [ -n "$nb" ]; then
		d="$(dirname "$nb")"
		for c in "$d/../lib/node_modules/npm/bin/npm-cli.js" "$d/npm-cli.js"; do
			[ -f "$c" ] && { printf '%s' "$c"; return 0; }
		done
	fi
	c="$(find "$(oc_node_dir)" -name npm-cli.js 2>/dev/null | head -n1)"
	[ -n "$c" ] && { printf '%s' "$c"; return 0; }
	return 1
}

# ---------------------------------------------------------------- global node
# 「系统全局安装」= 解压到 $OC_NODE_GLOBAL_DIR，再把 node/npm/npx 链接进 /usr/bin。
# 铁律：只接管本插件自己建的链接，绝不静默覆盖系统已有的 Node.js ——
# 覆盖后发行版包管理器卸载时会连带删掉我们的运行时，反之我们卸载也会删掉别人的文件。

oc_node_global_bins() {
	printf 'node npm npx'
}

oc_node_global_owned() {
	# oc_node_global_owned <path> -> 0 = 可以安全接管
	#   * 路径不存在
	#   * 路径是指向 $OC_NODE_GLOBAL_DIR 的符号链接（本插件建的）
	# 其余情况（普通文件、指向别处的链接、目录）一律 1。
	local l="$1" t
	if [ ! -e "$l" ] && [ ! -L "$l" ]; then
		return 0
	fi
	[ -L "$l" ] || return 1
	t="$(readlink -f "$l" 2>/dev/null)" || t=""
	[ -n "$t" ] || return 1
	case "$t" in
		"$OC_NODE_GLOBAL_DIR"/*) return 0 ;;
	esac
	return 1
}

oc_node_global_conflict() {
	# 打印第一个不允许接管的 /usr/bin/<cmd>；无冲突时无输出并返回 1
	local b
	for b in $(oc_node_global_bins); do
		if ! oc_node_global_owned "/usr/bin/$b"; then
			printf '/usr/bin/%s' "$b"
			return 0
		fi
	done
	return 1
}

oc_node_link() {
	# oc_node_link <target> <link> 幂等；只删「我们自己的」旧链接。
	# 只删符号链接本身（find -maxdepth 0 -type l），绝不跟随它进入目标目录。
	local t="$1" l="$2" cur
	if [ -L "$l" ]; then
		cur="$(readlink "$l" 2>/dev/null)"
		[ "$cur" = "$t" ] && return 0
		find "$l" -maxdepth 0 -type l -delete 2>/dev/null || true
	elif [ -e "$l" ]; then
		# 普通文件/目录：oc_node_global_conflict 已经拦过，这里是第二道防线
		return 1
	fi
	ln -s "$t" "$l" 2>/dev/null || return 1
	return 0
}

# ---------------------------------------------------------------- http
oc_fetch() {
	# oc_fetch <url> <dest> [max-time] [accept]
	# accept 仅在 curl 可用时生效（curl 是唯一能可靠设置请求头的下载工具）；
	# wget / uclient-fetch 本来就不发 Accept，忽略该参数即可，行为与不带时一致。
	local url="$1" dest="$2" mt="${3:-60}" accept="${4:-}"
	local proxy

	# The URL may come from UCI (npm_registry / node_mirror) which the user
	# edits from LuCI. Quoting alone is not enough: a value beginning with "-"
	# is still parsed as an option by curl/wget, and this runs as root.
	oc_safe_url "$url" || { oc_err "拒绝下载非法 URL：$url"; return 126; }

	proxy="$(uci_get main.http_proxy '')"
	if [ -n "$proxy" ]; then
		oc_safe_url "$proxy" || { oc_err "拒绝使用非法代理地址：$proxy"; return 126; }
	fi

	if command -v curl >/dev/null 2>&1; then
		# 用 set -- 拼参数：可选头/代理都不需要 eval（URL 来自 UCI，不能进 shell 代码）。
		set -- -fsSL --connect-timeout 10 --max-time "$mt"
		if [ -n "$accept" ]; then
			set -- "$@" -H "Accept: $accept"
		fi
		if [ -n "$proxy" ]; then
			set -- "$@" -x "$proxy"
		fi
		curl "$@" -o "$dest" "$url"
	elif command -v wget >/dev/null 2>&1; then
		# busybox wget 没有 -x/--proxy 选项，只认 http_proxy / https_proxy 环境变量。
		# 代理为空时**不要**导出这两个变量：空值会把调用方（或 busybox 默认值）
		# 覆盖掉，等于强制直连。
		if [ -n "$proxy" ]; then
			http_proxy="$proxy" https_proxy="$proxy" \
				wget -q -T "$mt" -O "$dest" "$url"
		else
			wget -q -T "$mt" -O "$dest" "$url"
		fi
	elif command -v uclient-fetch >/dev/null 2>&1; then
		# uclient-fetch 同样只认环境变量（没有代理命令行选项）。
		if [ -n "$proxy" ]; then
			http_proxy="$proxy" https_proxy="$proxy" \
				uclient-fetch -q -T "$mt" -O "$dest" "$url"
		else
			uclient-fetch -q -T "$mt" -O "$dest" "$url"
		fi
	else
		return 127
	fi
}

oc_fetch_body() {
	# oc_fetch_body <url> [max-time] -> stdout
	local url="$1" mt="${2:-40}" tmp
	tmp="$(mktemp "$OC_RUNDIR/fetch.XXXXXX" 2>/dev/null || echo "$OC_RUNDIR/fetch.$$")"
	oc_fetch "$url" "$tmp" "$mt" || { rm -f "$tmp"; return 1; }
	cat "$tmp"; rm -f "$tmp"
}

# ---------------------------------------------------------------- semver
# pure shell semver compare, works on busybox ash
_ver_field() {
	# _ver_field <version> <index 1..3>
	# NOTE: awk is used instead of cut because `cut -d. -f2` returns the whole
	# string when the delimiter is missing ("25" -> "25", not "").
	local v="$1" i="$2" f
	v="${v#v}"
	f="$(printf '%s' "$v" | awk -F. -v n="$i" '{ x = $n; if (x == "") x = 0; print x }')"
	# keep leading digits only (24.16.0-beta.3 -> 24 / 16 / 0)
	f="$(printf '%s' "$f" | sed 's/[^0-9].*$//')"
	[ -n "$f" ] || f=0
	printf '%s' "$f"
}

_ver_raw() {
	# _ver_raw <version> <index> - raw field (may be "" or "x")
	printf '%s' "$1" | awk -F. -v n="$2" '{ print $n }'
}

ver_cmp() {
	# ver_cmp <a> <b> -> -1 / 0 / 1   (numeric fields only)
	local a="$1" b="$2" i=1 av bv
	while [ "$i" -le 3 ]; do
		av="$(_ver_field "$a" "$i")"
		bv="$(_ver_field "$b" "$i")"
		if [ "$av" -lt "$bv" ]; then printf -- '-1'; return 0; fi
		if [ "$av" -gt "$bv" ]; then printf '1'; return 0; fi
		i=$((i + 1))
	done
	printf '0'
}

ver_eq() { [ "$(ver_cmp "$1" "$2")" = "0" ]; }
ver_ge() { [ "$(ver_cmp "$1" "$2")" != "-1" ]; }
ver_le() { [ "$(ver_cmp "$1" "$2")" != "1" ]; }
ver_gt() { [ "$(ver_cmp "$1" "$2")" = "1" ]; }
ver_lt() { [ "$(ver_cmp "$1" "$2")" = "-1" ]; }

# ---------------------------------------------------------------- npm engines
# supports: >=, >, <=, <, =, ^, ~, x-ranges (24.x / 24.16.x), *
_cmp_one() {
	# _cmp_one <version> <comparator>
	local v="$1" c="$2" cv
	case "$c" in
		''|'*'|'x'|'X') return 0 ;;
		'>-'|'>='*) cv="${c#>=}"; ;;
		'<='*)      cv="${c#<=}"; ;;
		'>'*)       cv="${c#>}"; ;;
		'<'*)       cv="${c#<}"; ;;
		'='*)       cv="${c#=}"; ;;
		'^'*)       cv="${c#^}"; ;;
		'~'*)       cv="${c#~}"; ;;
		*)          cv="$c"; ;;
	esac
	# x-ranges: 24.x -> only compare given fields
	local i=1 av bv cf
	while [ "$i" -le 3 ]; do
		av="$(_ver_field "$v" "$i")"
		bv="$(_ver_field "$cv" "$i")"
		cf="$(_ver_raw "$cv" "$i")"
		case "$cf" in
			x|X|'') break ;;
		esac
		if [ "$av" -ne "$bv" ]; then
			case "$c" in
				'>='*) [ "$av" -gt "$bv" ] && return 0 || return 1 ;;
				'<='*) [ "$av" -lt "$bv" ] && return 0 || return 1 ;;
				'>'*)  [ "$av" -gt "$bv" ] && return 0 || return 1 ;;
				'<'*)  [ "$av" -lt "$bv" ] && return 0 || return 1 ;;
				'='*|*) return 1 ;;
			esac
		fi
		i=$((i + 1))
	done
	# all compared fields are equal
	case "$c" in
		'>='*|'<='*|'='*|'^'*|'~'*) return 0 ;;
		'>'*|'<'*) return 1 ;;
		*) return 0 ;;
	esac
}

_caret_ok() {
	# ^24.16.0 -> >=24.16.0 <25.0.0 ; ^0.x handled loosely
	local v="$1" cv="${2}" v0 v1 c0 c1
	v0="$(_ver_field "$v" 1)"; v1="$(_ver_field "$v" 2)"
	c0="$(_ver_field "$cv" 1)"; c1="$(_ver_field "$cv" 2)"
	ver_ge "$v" "$cv" || return 1
	if [ "$c0" -gt 0 ]; then
		[ "$v0" -eq "$c0" ] || return 1
	else
		[ "$v0" -eq 0 ] && [ "$v1" -eq "$c1" ] || return 1
	fi
	return 0
}

_tilde_ok() {
	# ~24.16.0 -> >=24.16.0 <24.17.0
	local v="$1" cv="$2" v0 v1 c0 c1
	ver_ge "$v" "$cv" || return 1
	v0="$(_ver_field "$v" 1)"; v1="$(_ver_field "$v" 2)"
	c0="$(_ver_field "$cv" 1)"; c1="$(_ver_field "$cv" 2)"
	[ "$v0" -eq "$c0" ] && [ "$v1" -eq "$c1" ]
}

engines_match() {
	# engines_match <node_version> <engines_spec>
	# spec example: ">=24.16.0 <25 || >=26.1.0"
	local v="$1" spec="$2" range cmp ok
	[ -n "$spec" ] || return 0
	# split on || (trailing newline matters: read would drop the last segment)
	printf '%s\n' "$spec" | tr '|' '\n' | while IFS= read -r range; do
		[ -n "$(printf '%s' "$range" | tr -d ' \t')" ] || continue
		ok=1
		for cmp in $range; do
			case "$cmp" in
				'^'*) _caret_ok "$v" "${cmp#^}" || ok=0 ;;
				'~'*) _tilde_ok "$v" "${cmp#~}" || ok=0 ;;
				*)    _cmp_one "$v" "$cmp" || ok=0 ;;
			esac
		done
		[ "$ok" = "1" ] && printf 'MATCH'
	done | grep -q MATCH
}

engines_min_version() {
	# engines_min_version <spec> -> lowest version satisfying spec (numeric scan)
	# used only for UI hints; returns e.g. 24.16.0
	local spec="$1" v
	v="$(printf '%s' "$spec" | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+' | head -n1)"
	[ -n "$v" ] || v="$(printf '%s' "$spec" | grep -o '[0-9]\+\.[0-9]\+' | head -n1)"
	printf '%s' "${v:-0.0.0}"
}

# ---------------------------------------------------------------- json
oc_json_get() {
	# oc_json_get <file> <path>  (jsonfilter syntax) - fallback grep
	command -v jsonfilter >/dev/null 2>&1 || return 1
	jsonfilter -i "$1" -e "$2" 2>/dev/null | head -n1
}

oc_json_has() {
	[ -f "$1" ] || return 1
	grep -q "$2" "$1" 2>/dev/null
}

oc_json_str() {
	# oc_json_str <value> -> escaped, safe to embed inside a JSON string literal.
	# Every value that ends up in a printf'd JSON document MUST go through this:
	# an unescaped quote breaks the document and lets injected markup travel all
	# the way into the LuCI pages.
	#
	# Control characters are illegal inside a JSON string. They are dropped with
	# tr (portable, present in busybox) instead of an awk character class, whose
	# octal ranges are not reliably supported across awk implementations.
	# \n (012) and \t (011) are kept: \n separates lines, \t gets escaped.
	local v="${1:-}"
	if command -v tr >/dev/null 2>&1; then
		printf '%s' "$v" | tr -d '\000-\010\013-\015\016-\037\177' 2>/dev/null
	else
		printf '%s' "$v"
	fi | awk 'BEGIN { ORS = "" } {
		gsub(/\\/, "\\\\")   # backslash first, or we double the escapes we add
		gsub(/"/,  "\\\"")
		gsub(/\t/, "\\t")
		# newlines survive `tr` on purpose: a multi-line message must still
		# yield ONE valid JSON string, so emit the two-character escape
		if (NR > 1) printf "\\n"
		printf "%s", $0
	}'
}

oc_safe_url() {
	# oc_safe_url <url> [mode] -> 0 when the URL may be handed to curl/wget.
	#
	# 两种模式：
	#   allow-http（缺省）接受 http:// 与 https://。这是历史行为，内网镜像
	#                       大量使用明文 http，一刀切禁掉会让它们全部失效。
	#   strict            只接受 https://，用于下载**可执行文件**（Node.js
	#                      运行时压缩包等）。http 会被拒绝，除非用户显式
	#                      打开 main.allow_http_binaries=1（此时退化为
	#                      allow-http，并告警一次）。
	# 两种模式都拒绝选项注入（以 "-" 开头）与内嵌空白的 URL —— 这些值来自
	# UCI，可被 LuCI 编辑，而这个函数后面接的是以 root 执行的 curl/wget。
	local url="${1:-}" mode="${2:-allow-http}"
	case "$mode" in
		strict) ;;
		*) mode="allow-http" ;;
	esac
	case "$url" in
		*' '*|*'	'*) return 1 ;;
	esac
	case "$url" in
		https://*) ;;
		http://*)
			[ "$mode" = "strict" ] || return 0
			[ "$(uci_get main.allow_http_binaries 0)" = "1" ] || {
				oc_err "拒绝通过明文 http 下载可执行文件：$url（请把镜像改成 https；确需明文请设置 uci set openclaw.main.allow_http_binaries=1）"
				return 1
			}
			# 每次调用都告警会刷屏（下载路径可能被调用两次），只警告一次。
			if [ "${OC_HTTP_BINARIES_WARNED:-0}" != "1" ]; then
				OC_HTTP_BINARIES_WARNED=1
				oc_warn "main.allow_http_binaries=1：已允许通过明文 http 下载可执行文件（校验和不保护传输过程）"
			fi
			;;
		*) return 1 ;;
	esac
	return 0
}

# ---------------------------------------------------------------- misc
oc_arch() {
	case "$(uname -m)" in
		x86_64|amd64)  printf 'x86_64' ;;
		aarch64|arm64) printf 'arm64' ;;
		armv7*|armv6*) printf 'armv7l' ;;
		*) printf '%s' "$(uname -m)" ;;
	esac
}

# Node.js tarball arch token (unofficial-builds naming)
oc_node_arch() {
	case "$(oc_arch)" in
		x86_64)   printf 'x64' ;;
		arm64)    printf 'arm64' ;;
		armv7l)   printf 'armv7l' ;;
		loongarch64|loong64) printf 'loong64' ;;
		riscv64)  printf 'riscv64' ;;
		*) printf '%s' "$(oc_arch)" ;;
	esac
}

# host OS release string (OpenWrt 24.10.x / 25.12.x / ...)
oc_sys_release() {
	if [ -r /etc/os-release ]; then
		sed -n 's/^OPENWRT_RELEASE="\{0,1\}\([^"]*\)"\{0,1\}/\1/p' /etc/os-release 2>/dev/null | head -n1
	fi
}

oc_sys_version() {
	local v
	v="$(oc_sys_release)"
	[ -n "$v" ] || v="$(sed -n 's/^DISTRIB_RELEASE=.\([^"'"'"']*\).*/\1/p' /etc/openwrt_release 2>/dev/null | head -n1)"
	[ -n "$v" ] || v="$(sed -n 's/^DISTRIB_DESCRIPTION=.\([^"'"'"']*\).*/\1/p' /etc/openwrt_release 2>/dev/null | head -n1)"
	printf '%s' "${v:-unknown}"
}

oc_major() {
	# 25.12.4 -> 25 ; 24.10.7 -> 24
	printf '%s' "$(oc_sys_version | cut -d. -f1)"
}

oc_has_apk() { command -v apk >/dev/null 2>&1; }

oc_pkg_install_hint() {
	# print the right command for this system
	if oc_has_apk; then printf 'apk add'; else printf 'opkg install'; fi
}

oc_need() {
	# oc_need <cmd> [hint-package]
	command -v "$1" >/dev/null 2>&1 && return 0
	[ -n "${2:-}" ] && oc_warn "缺少命令 $1，请执行：$(oc_pkg_install_hint) $2"
	return 1
}

oc_ca_ok() {
	[ -f /etc/ssl/certs/ca-certificates.crt ] && return 0
	[ -d /etc/ssl/certs ] && ls /etc/ssl/certs/*.crt >/dev/null 2>&1 && return 0
	return 1
}

oc_is_musl() {
	if command -v ldd >/dev/null 2>&1; then
		ldd /bin/busybox 2>&1 | grep -q musl && return 0
	fi
	ls /lib/libc.musl-* >/dev/null 2>&1 && return 0
	ls /lib/ld-musl-* >/dev/null 2>&1 && return 0
	return 1
}

oc_mtime() {
	# oc_mtime <path> -> 文件 mtime 的 epoch 秒；取不到时输出空串。
	#
	# 不要用 `date -r`：那是 GNU coreutils 的扩展，busybox 的 date 不支持
	# （本机实测 `date -r f +%s` 直接报错）。带 `|| echo 0` 兜底更糟 ——
	# 会静默变成 0，于是 age 恒等于当前时间（十几亿秒），任何 TTL 都不会命中。
	# stat -c %Y 在 GNU 与 busybox 上都可用。
	local f="${1:-}" v
	[ -n "$f" ] && [ -e "$f" ] || return 0
	v="$(stat -c %Y "$f" 2>/dev/null)"
	case "$v" in
		''|*[!0-9]*) v="" ;;
	esac
	[ -n "$v" ] || v="$(date -r "$f" +%s 2>/dev/null)"
	case "$v" in
		''|*[!0-9]*) v="" ;;
	esac
	printf '%s' "$v"
}

oc_free_mb() {
	# free space in MB of a path
	local p="$1"
	df -m "$p" 2>/dev/null | awk 'NR==2{print $4}'
}

oc_mounts() {
	# list candidate mount points with free MB and fs type
	# 数据来源是 /proc/mounts（而不是 df 的整表）：只保留真实可写磁盘上的
	# 挂载点，并逐个过 oc_validate_base_dir —— 下拉里出现的东西，安装时
	# 必须是真的会被接受的（/tmp、/overlay、/var 等系统目录一律剔除）。
	# 输出：挂载点<TAB>可用MB<TAB>文件系统，按可用空间从大到小。
	# 约定：只往 stdout 写结果（cmd_mounts 会直接拼进 JSON），日志走 stderr。
	local dev mnt fst opts rest free seen=""
	# 数据源可覆盖：测试用假 mounts 文件喂进来，线上仍是 /proc/mounts。
	local mf="${OC_PROC_MOUNTS:-/proc/mounts}"
	[ -r "$mf" ] || return 0
	while read -r dev mnt fst opts rest; do
		[ -n "$mnt" ] || continue
		# /proc/mounts 把空格 / 制表符转义成 \040 / \011；这类路径不能
		# 原样交给 df，直接跳过。
		case "$mnt" in *'\'*) continue ;; esac
		# 只收真实可写磁盘；tmpfs / overlay / squashfs / nfs / cifs 等一律不收
		case "$fst" in
			ext2|ext3|ext4|f2fs|xfs|btrfs|exfat|vfat|ntfs|ntfs3|fuseblk|jfs|ufs) ;;
			*) continue ;;
		esac
		# 只读挂载装不了东西
		case ",$opts," in *,ro,*) continue ;; esac
		# 排除系统前缀。/boot 与 /efi 是引导分区：vfat、通常几十到一两百 MB，
		# 装不下 Node 运行时 + OpenClaw 本体，列进下拉只会让人误选。
		case "$mnt" in
			/|/rom|/rom/*|/overlay|/overlay/*|/tmp|/tmp/*|/var|/var/*) continue ;;
			/usr|/usr/*|/etc|/etc/*|/dev|/dev/*|/proc|/proc/*|/sys|/sys/*) continue ;;
			/boot|/boot/*|/efi|/efi/*|/run|/run/*) continue ;;
		esac
		# 同一挂载点可能被多个 bind mount 枚举到
		case "$seen" in *"|$mnt|"*) continue ;; esac
		seen="$seen|$mnt|"
		# 与安装时同一套校验（stderr 丢弃）：不通过的直接剔除
		oc_validate_base_dir "$mnt" 2>/dev/null || continue
		free="$(df -m "$mnt" 2>/dev/null | awk 'NR==2{print $4}')"
		case "$free" in ''|*[!0-9]*) continue ;; esac
		# 装不下的不列：Node 运行时 + OpenClaw 本体约 400 MB，留一倍余量。
		# 一个 119 MB 的分区列在下拉里，用户选中后必然在安装阶段失败。
		[ "$free" -ge 512 ] 2>/dev/null || continue
		printf '%s\t%s\t%s\n' "$mnt" "$free" "$fst"
	done <"$mf" | sort -rn -k2,2
}

# ---------------------------------------------------------------- node runtime probe
# 「安装前先看看本机是不是已经有能用的 Node」的只读探测层。
# 与上一节同一条约定：oc_probe_node_runtimes() 的输出会被直接当成 JSON 响应体，
# 所以这一节里**只能往 stdout 写结果**，日志一律走 oc_warn / oc_err（stderr）。
# 谁在这里加一行 oc_info，谁的 JSON 就坏掉。
#
# 候选是固定列表 + oc_mounts() 给出的挂载点（每个挂载点只看 5 个固定名字），
# 绝不做全盘遍历：几 TB 的盘上 find / 会跑到天荒地老，而这个函数要给 UI 同步调用。
#
# source 取值（调用方据此区分「这份 node 是谁的」）：
#   system         发行版带的 / 用户自己装的（/usr/bin、/usr/local/bin、/opt/...）
#   plugin-global  本插件的全局目录 /usr/lib/nodejs（含指向它的 /usr/bin/node 链接）
#   plugin-private 本插件 private 模式的运行时 <安装目录>/node
#   mount          从挂载点上探测到的

oc_node_engines_spec() {
	# 当前 OpenClaw 的 engines.node 要求；取不到时无输出并返回 1。
	# 离线解析：versions.sh 已把 npm 文档里的 engines 落盘成 oc-versions.tsv，
	# 这里只读缓存 —— 探测必须是纯本地、快、无副作用，绝不发起网络请求。
	local dir ocv e
	dir="${OC_CACHE_DIR:-${OC_RUNDIR:-/tmp/.openclaw}/cache}"
	ocv="$(uci_get main.oc_version latest)"
	[ -n "$ocv" ] || ocv="latest"
	case "$ocv" in
		latest|stable|extended-stable|beta)
			if [ -f "$dir/oc-tags.tsv" ]; then
				ocv="$(awk -F'\t' -v x="$ocv" '$1==x{printf "%s", $2; exit}' "$dir/oc-tags.tsv" 2>/dev/null)"
			fi
			;;
	esac
	[ -n "$ocv" ] || return 1
	[ -f "$dir/oc-versions.tsv" ] || return 1
	e="$(awk -F'\t' -v x="$ocv" '$1==x{printf "%s", $2; exit}' "$dir/oc-versions.tsv" 2>/dev/null)"
	[ -n "$e" ] || return 1
	printf '%s' "$e"
}

oc_node_rt_candidates() {
	# oc_node_rt_candidates [base_dir] -> 每行 "source<TAB>path"
	local bd m free fst rel
	bd="${1:-$(oc_base_dir)}"
	printf 'system\t%s\n' /usr/bin/node
	printf 'system\t%s\n' /usr/local/bin/node
	printf 'system\t%s\n' /opt/bin/node
	printf 'system\t%s\n' /opt/node/bin/node
	printf 'plugin-global\t%s/bin/node\n' "$OC_NODE_GLOBAL_DIR"
	if [ -n "$bd" ]; then
		printf 'plugin-private\t%s/node/bin/node\n' "$bd"
	fi
	# 挂载点范围复用 oc_mounts()（与安装目录候选同一份口径），
	# 每个挂载点只试下面几个固定名字。
	while IFS="$(printf '\t')" read -r m free fst; do
		[ -n "$m" ] || continue
		for rel in bin/node node/bin/node nodejs/bin/node usr/bin/node openclaw/node/bin/node; do
			printf 'mount\t%s/%s\n' "$m" "$rel"
		done
	done <<EOF
$(oc_mounts)
EOF
}

oc_node_rt_num() {
	# oc_node_rt_num <"v24.16.0-xxx"> -> "24.16.0"；解析不出数字版本时返回 1。
	# 只做"去掉非数字尾巴"这一件事，比较交给 ver_cmp/engines_match，不另写一套 semver。
	local nv="${1#v}"
	case "$nv" in
		*[!0-9.]*) nv="$(printf '%s' "$nv" | sed 's/[^0-9.].*$//')" ;;
	esac
	case "$nv" in
		*[0-9]*) ;;
		*) return 1 ;;
	esac
	printf '%s' "$nv"
}

oc_node_rt_perm_ok() {
	# oc_node_rt_perm_ok <real-path> -> 0 = 允许执行它
	# 候选里包含挂载盘上的 node（U 盘 / 外置盘常被挂成普通用户可写），而这个探测会被
	# install.sh 以 root 调用 —— 以 root 执行一个"谁都改得动"的二进制等于把 root 交出去。
	# 所以组/他人可写的候选一律不执行（只报 usable=false）。
	# 取不到 mode 时不做限制（fail open）：fail closed 会让没有 `stat -c` 的极端
	# busybox 上整个探测失效，代价比这点残余风险更大。
	local m g o
	m="$(stat -c %a "$1" 2>/dev/null)"
	case "$m" in ''|*[!0-7]*) return 0 ;; esac
	# 去掉 setuid/setgid/sticky 位，只留 rwx 三位
	while [ "${#m}" -gt 3 ]; do m="${m#?}"; done
	o="${m#??}"            # 第 3 位：other
	g="${m#?}"; g="${g%?}" # 第 2 位：group
	case "$g" in 2|3|6|7) return 1 ;; esac
	case "$o" in 2|3|6|7) return 1 ;; esac
	return 0
}

oc_node_rt_version() {
	# oc_node_rt_version <node-binary> -> "vX.Y.Z"（跑不出来时无输出）
	# timeout 封顶：候选里可能混进坏链接或自解压脚本，绝不能让探测挂住。
	local b="$1" v
	if command -v timeout >/dev/null 2>&1; then
		v="$(timeout 5 "$b" -v 2>/dev/null)"
	else
		v="$("$b" -v 2>/dev/null)"
	fi
	printf '%s' "$v"
}

oc_node_rt_probe() {
	# oc_node_rt_probe [engines_spec] [base_dir]
	#   -> 每行 "source<TAB>path<TAB>version<TAB>usable"
	# 内部共用接口：JSON 版（oc_probe_node_runtimes）和 install.sh 的提示版
	# （oc_node_runtime_other_usable）都走这里，免得在 shell 里解析 JSON。
	local spec="${1:-}" bd="${2:-}" src p v nv usable real seen
	[ -n "$bd" ] || bd="$(oc_base_dir)"
	seen=""
	while IFS="$(printf '\t')" read -r src p; do
		[ -n "$p" ] || continue
		# 同一个文件可能被多条候选命中（显式路径 / 挂载点 / 符号链接），按路径去重
		case "$seen" in *"|$p|"*) continue ;; esac
		seen="$seen|$p|"
		[ -e "$p" ] || continue
		real="$(readlink -f "$p" 2>/dev/null)" || real=""
		[ -n "$real" ] || real="$p"
		case "$seen" in *"|$real|"*) continue ;; esac
		seen="$seen|$real|"
		# 解析后落在本插件全局目录里的（典型：我们建的 /usr/bin/node 链接）归为
		# plugin-global —— 调用方据此判断"这是我自己的运行时，不是别人的"。
		case "$real" in "$OC_NODE_GLOBAL_DIR"/*) src="plugin-global" ;; esac
		v=""
		usable=false
		if [ -x "$p" ] && oc_node_rt_perm_ok "$real"; then
			v="$(oc_node_rt_version "$p")"
		fi
		if [ -n "$v" ]; then
			nv="$(oc_node_rt_num "$v")" || nv=""
			if [ -n "$nv" ]; then
				if [ -n "$spec" ]; then
					engines_match "$nv" "$spec" && usable=true
				else
					# engines 未知（缓存没建起来 / 离线）：只能按"跑得起来"判定，
					# 由调用方决定要不要采信（oc_probe_node_runtimes 会 warn）
					usable=true
				fi
			fi
		fi
		printf '%s\t%s\t%s\t%s\n' "$src" "$p" "$v" "$usable"
	done <<EOF
$(oc_node_rt_candidates "$bd")
EOF
}

oc_probe_node_runtimes() {
	# oc_probe_node_runtimes [engines_spec] [base_dir] -> JSON 数组，每项
	#   {"path":"..","version":"..","source":"..","usable":true|false}
	# 只往 stdout 写 JSON；日志走 stderr（oc_warn / oc_err）。
	local spec="${1:-}" bd="${2:-}" src p v usable first=1
	[ -n "$bd" ] || bd="$(oc_base_dir)"
	if [ -z "$spec" ]; then
		spec="$(oc_node_engines_spec)"
		[ -n "$spec" ] || oc_warn "无法确定 OpenClaw 的 engines.node（版本缓存未生成或设备离线），本次只按「可执行 + 能跑出 -v」判定 node 是否可用"
	fi
	printf '['
	while IFS="$(printf '\t')" read -r src p v usable; do
		[ -n "$p" ] || continue
		[ "$first" = "1" ] || printf ','
		first=0
		# source 只可能是上面四个固定词，path/version 是外部数据，必须转义
		printf '{"path":"%s","version":"%s","source":"%s","usable":%s}' \
			"$(oc_json_str "$p")" "$(oc_json_str "$v")" "$src" "$usable"
	done <<EOF
$(oc_node_rt_probe "$spec" "$bd")
EOF
	printf ']'
}

oc_node_runtime_other_usable() {
	# oc_node_runtime_other_usable [engines_spec] [base_dir]
	#   -> 打印第一个「可用、且不属于本插件全局目录」的运行时 "path<TAB>version"；
	#      没有时返回 1。
	# 给 install.sh 的安装日志提示用（在 shell 里解析 JSON 太脆，所以走内部接口）。
	local spec="${1:-}" bd="${2:-}" src p v usable
	[ -n "$bd" ] || bd="$(oc_base_dir)"
	[ -n "$spec" ] || spec="$(oc_node_engines_spec)"
	while IFS="$(printf '\t')" read -r src p v usable; do
		[ "$usable" = "true" ] || continue
		[ "$src" = "plugin-global" ] && continue
		printf '%s\t%s\n' "$p" "$v"
		return 0
	done <<EOF
$(oc_node_rt_probe "$spec" "$bd")
EOF
	return 1
}

oc_rand_hex() {
	# 32 bytes hex
	if [ -r /dev/urandom ]; then
		dd if=/dev/urandom bs=32 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n'
	else
		awk 'BEGIN{srand();for(i=0;i<32;i++)printf "%02x", int(rand()*256)}'
	fi
}

oc_rmtree() {
	# oc_rmtree <path> -> 删除目录内容与目录本身；不存在时静默成功。
	#
	# 用 find -depth -delete 而不是 rm -rf：
	#   * 不跟随符号链接（-delete 隐含 -depth，且 find 默认不解引用）；
	#   * 递归删除的动作范围能一眼看懂；
	#   * 与 install.sh 清理 node 目录的写法一致。
	# 这是本项目对"删目录"的统一做法，新增代码请用它。
	local d="${1:-}"
	[ -n "$d" ] || return 0
	[ -e "$d" ] || return 0
	# 拒绝危险目标：这些目录删了会毁系统。调用方本不该传进来，
	# 但删目录是不可逆操作，多一道闸不值钱。
	case "$d" in
		/|/tmp|/var|/etc|/usr|/root|/overlay|/rom|/proc|/sys|/dev|/run|/mnt|/bin|/sbin|/lib)
			oc_err "拒绝删除系统路径：$d"
			return 1 ;;
	esac
	find "$d" -depth -delete 2>/dev/null
	return 0
}

oc_kill_tree() {
	# Kill ONLY the actual gateway process (and its direct children).
	# The old form was `pgrep -f openclaw | kill -9`: it matched *anything* with
	# "openclaw" in the command line - including this very script and a user's
	# `tail -f openclaw.log` - and the uninstall would kill itself halfway.
	#
	# 先 TERM 再等，最后才 KILL：直接 SIGKILL 会让 sqlite 的 -wal 留在热状态，
	# 而且进程还没释放 18789 时下一步 start 就撞端口。调用方（uninstall）
	# 在这之后会 rm -rf 程序目录，所以必须确认进程真的没了。
	local p kids i
	# 第一轮：TERM，给 30 秒（与 init.d 的 term_timeout 对齐）
	for p in $(oc_gateway_pids); do
		kids="$(pgrep -P "$p" 2>/dev/null)"
		# shellcheck disable=SC2086
		[ -n "$kids" ] && kill $kids 2>/dev/null
		kill "$p" 2>/dev/null
	done
	i=0
	while [ -n "$(oc_gateway_pids)" ] && [ "$i" -lt 30 ]; do
		sleep 1
		i=$((i + 1))
	done
	# 第二轮：仍在的才 KILL
	for p in $(oc_gateway_pids); do
		kids="$(pgrep -P "$p" 2>/dev/null)"
		# shellcheck disable=SC2086
		[ -n "$kids" ] && kill -9 $kids 2>/dev/null
		kill -9 "$p" 2>/dev/null
	done
	# 再等 5 秒确认；还有残留就返回失败，让调用方别急着 rm -rf
	i=0
	while [ -n "$(oc_gateway_pids)" ] && [ "$i" -lt 5 ]; do
		sleep 1
		i=$((i + 1))
	done
	[ -z "$(oc_gateway_pids)" ]
}

oc_gateway_pids() {
	# pids of the real gateway process.
	#
	# 判据不能只看 argv[0] 是不是 node 二进制。网关启动后 Node 会把
	# process.title 改成 "openclaw-gateway"，Linux 上这会**直接改写 argv[0]**，
	# 于是 /proc/<pid>/cmdline 变成只有一个 token 的 "openclaw-gateway"，
	# 既不含 node 路径也不含 "gateway run"。同理 comm 变成 "openclaw-gatewa"
	# （15 字符截断），所以 `pgrep -x node` 也永远不中。
	#
	# 性能：**不能对每个 pid 都 fork**。原来的写法对每个 pid 跑
	# `tr` + `head` 两次命令替换，几百个进程就是上千次 fork —— 单次调用
	# 在路由器上要几秒，而 install.sh 的「等进程退出」循环每秒调一次，
	# 于是升级过程像卡死。这里先用内建 read 读 comm（零 fork）预筛，
	# 只有 comm 像 node / openclaw-gatewa 的才去读 cmdline。
	local d p comm a0 nb cmd
	nb="$(oc_node_bin 2>/dev/null)"
	for d in /proc/[0-9]*; do
		p="${d#/proc/}"
		[ "$p" = "$$" ] && continue
		comm=""
		[ -r "$d/comm" ] && read -r comm 2>/dev/null <"$d/comm"
		[ -n "$comm" ] || continue

		# 主判据：process.title 改写后 comm 是 openclaw-gatewa（15 字符截断）
		case "$comm" in
			openclaw-gatewa*|openclaw-gateway)
				printf '%s\n' "$p"
				continue ;;
		esac

		# 兼容分支：还没改 title 时 comm 是 node / node-MainThread
		case "$comm" in
			node|node-*) ;;
			*) continue ;;
		esac

		[ -r "$d/cmdline" ] || continue
		cmd="$(tr '\0' '\n' 2>/dev/null <"$d/cmdline")"
		[ -n "$cmd" ] || continue
		a0="$(printf '%s\n' "$cmd" | head -n1)"
		if [ -n "$nb" ] && [ "$a0" = "$nb" ]; then
			case "$(printf '%s' "$cmd" | tr '\n' ' ')" in
				*" gateway "*|*" gateway run"*) printf '%s\n' "$p" ;;
			esac
		fi
	done
}

oc_ensure_user() {
	if ! grep -q "^${OC_USER}:" /etc/passwd 2>/dev/null; then
		if command -v useradd >/dev/null 2>&1; then
			useradd -r -M -s /bin/false -d "$(oc_home_dir)" "$OC_USER" >/dev/null 2>&1
		elif command -v adduser >/dev/null 2>&1; then
			adduser -D -H -S -s /bin/false -h "$(oc_home_dir)" "$OC_USER" >/dev/null 2>&1
		fi
	fi
	grep -q "^${OC_USER}:" /etc/passwd 2>/dev/null
}

oc_fix_perms() {
	local base ocdir
	base="$(oc_base_dir)"
	ocdir="$(oc_oc_dir)"

	if [ -d "$base" ]; then
		if grep -q "^${OC_USER}:" /etc/passwd 2>/dev/null; then
			chown -R "$OC_USER":"$OC_GROUP" "$base" 2>/dev/null || chown -R "$OC_USER" "$base" 2>/dev/null
		fi
		chmod -R u+rwX "$base" 2>/dev/null
	fi

	# 程序目录可以独立于安装目录。那种情况下它不在上面的 chown -R 覆盖范围里，
	# 而网关是以 $OC_USER 运行的 —— 不补这一刀就读不到 node_modules。
	# 注意必须先过安全校验：否则把 openclaw_dir 设成 /etc 就会递归改系统目录属主。
	case "$ocdir" in
		"$base"|"$base"/*) return 0 ;;	# 已在上面处理
	esac
	[ -d "$ocdir" ] || return 0
	if ! oc_oc_dir_safe; then
		oc_warn "跳过程序目录权限修复：$ocdir 未通过安全校验"
		return 0
	fi
	if grep -q "^${OC_USER}:" /etc/passwd 2>/dev/null; then
		chown -R "$OC_USER":"$OC_GROUP" "$ocdir" 2>/dev/null || chown -R "$OC_USER" "$ocdir" 2>/dev/null
	fi
	chmod -R u+rwX "$ocdir" 2>/dev/null
	return 0
}

# ---------------------------------------------------------------- safety
# Everything below was modelled on iStoreOS's luci-app-openclawmgr, which does a
# genuinely good job at not bricking the router. Adopted:
#   * refuse to operate on system / dot-path base directories
#   * a real lock so two LuCI clicks cannot run two installs at once
#   * refuse privileged ports
#   * download with progress + stall detection instead of a silent curl
#   * space check before downloading

oc_canonical_dir() {
	# oc_canonical_dir <abs path> -> physically resolved equivalent (prints),
	# rc 1 when it cannot be resolved. busybox ash has no builtin realpath
	# (and busybox `realpath` may be disabled), so we walk the path with
	# `cd -P` which resolves every symlink component itself.
	local p="$1"
	[ -n "$p" ] || return 1
	case "$p" in /*) ;; *) return 1 ;; esac
	( cd -P "$p" 2>/dev/null && pwd -P ) 2>/dev/null
}

oc_validate_base_dir() {
	# oc_validate_base_dir <dir> -> 0 safe / 1 unsafe
	#
	# Three layers:
	#   1. shape filter - absolute path, no "." / ".." segments, and never on
	#      a system prefix (see oc_validate_base_dir_shape)
	#   2. physical resolution - `/mnt/data/OpenClaw -> /etc` must not slip
	#      past a pure string filter, because oc_fix_perms later runs
	#      `chown -R` and `chmod -R` on the base dir
	#   3. the final component must not itself be a symlink - `chown -R link`
	#      dereferences its argument, so that would hit the target tree
	#
	# A base dir that does not exist yet (fresh install) is still accepted:
	# only the part that physically exists can hide anything, so we never
	# require the full path to resolve.
	local dir="$1" phys
	dir="$(printf '%s' "${dir:-}" | sed 's/[[:space:]]*$//')"
	dir="${dir%/}"
	oc_validate_base_dir_shape "$dir" || return 1

	if [ -L "$dir" ]; then
		return 1
	fi
	if [ -e "$dir" ]; then
		phys="$(readlink -f "$dir" 2>/dev/null)" || phys=""
		[ -n "$phys" ] || phys="$(oc_canonical_dir "$dir" 2>/dev/null)" || phys=""
		# the path exists but cannot be resolved: refuse rather than trust
		[ -n "$phys" ] || return 1
		oc_validate_base_dir_shape "$phys" || return 1
	fi
	return 0
}

oc_validate_base_dir_shape() {
	# pure string checks used by oc_validate_base_dir (and safe to call on
	# an already-resolved path)
	local dir="$1"
	[ -n "$dir" ] || return 1
	case "$dir" in
		/*) ;;
		*) return 1 ;;
	esac
	[ "$dir" != "/" ] || return 1
	case "$dir" in
		/root|/root/*) return 1 ;;
	esac
	case "$dir" in
		*"/../"*|*"/.."|*"/./"*|*"/.") return 1 ;;
	esac
	case "$dir" in
		/bin|/bin/*|/sbin|/sbin/*|/lib|/lib/*|/usr|/usr/*|/etc|/etc/*) return 1 ;;
		/proc|/proc/*|/sys|/sys/*|/dev|/dev/*|/run|/run/*) return 1 ;;
		/tmp|/tmp/*|/var|/var/*|/overlay|/overlay/*|/rom|/rom/*) return 1 ;;
		/boot|/boot/*|/efi|/efi/*) return 1 ;;
	esac
	return 0
}

oc_require_dir() {
	# oc_require_dir <dir> - exits 2 unless <dir> is a safe install target
	local d="${1:-}"
	if [ -z "$d" ]; then
		oc_err "未配置安装目录，请先在 LuCI 选择数据目录并保存"
		exit 2
	fi
	if ! oc_validate_base_dir "$d"; then
		oc_err "拒绝在不安全的安装目录上操作：$d"
		oc_err "请改用专用目录，例如 /mnt/sda1/OpenClaw 或 /mnt/data/OpenClaw"
		exit 2
	fi
	return 0
}

oc_require_base_dir() {
	# exits 2 with a clear message when the configured base dir is unusable
	oc_require_dir "$(oc_base_dir)"
}

oc_safe_port() {
	# oc_safe_port <port> -> 0 ok (>1024, numeric)
	local p="${1:-}"
	case "$p" in
		''|*[!0-9]*) return 1 ;;
	esac
	# busybox `test` overflows on very large integers: "99999999999999999999"
	# would silently pass both bounds. Cap the length first so the numeric
	# comparisons below always see a value they can represent.
	[ ${#p} -le 5 ] || return 1
	[ "$p" -gt 1024 ] 2>/dev/null || return 1
	[ "$p" -le 65535 ] 2>/dev/null || return 1
	return 0
}

# ---------------------------------------------------------------- locking
[ -n "$OC_LOCK_DIR" ] || OC_LOCK_DIR="$OC_RUNDIR/lock"

oc_ppid() {
	[ -r "/proc/$1/stat" ] || return 1
	awk '{print $4}' "/proc/$1/stat" 2>/dev/null
}

# Set by oc_pid_alive() on failure: exited | zombie | reused | no-pid.
# Kept as a global (no `local -n` in ash) so callers can explain *why* a lock
# was treated as stale.
OC_PID_REASON=""

oc_pid_alive() {
	# oc_pid_alive <pid> -> 0 only when <pid> is a live process of this plugin.
	#
	# `kill -0` alone is not good enough to decide whether a lock holder still
	# runs:
	#   * a zombie (dead, not yet reaped) still accepts signal 0;
	#   * after the holder exits its pid can be recycled by an unrelated
	#     process, which also accepts signal 0.
	# Either case left the lock unbreakable ("另一个操作正在运行", forever).
	# So require all three: /proc entry, non-zombie state, and an argv that
	# still names one of our scripts.
	local pid="${1:-}" statline state cmd
	OC_PID_REASON=""
	case "$pid" in ''|*[!0-9]*) OC_PID_REASON="no-pid"; return 1 ;; esac
	[ -d "/proc/$pid" ] || { OC_PID_REASON="exited"; return 1; }

	statline="$(cat "/proc/$pid/stat" 2>/dev/null)"
	[ -n "$statline" ] || { OC_PID_REASON="exited"; return 1; }
	# Field 2 (comm) is wrapped in parens and may itself contain spaces and
	# parens ("(node) worker"). Strip through the *last* ") " and take the
	# first remaining field - awk '{print $3}' would read the wrong token.
	state="${statline##*) }"
	state="${state%% *}"
	[ "$state" = "Z" ] && { OC_PID_REASON="zombie"; return 1; }

	cmd="$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null)"
	# kernel threads have an empty cmdline; either way it is not ours
	[ -n "$cmd" ] || { OC_PID_REASON="reused"; return 1; }
	case "$cmd" in
		*openclaw/cli.sh*|*openclaw/install.sh*|*openclaw/backup.sh*|\
		*openclaw/cloud.sh*|*openclaw/models.sh*|*openclaw/channels.sh*|\
		*openclaw/versions.sh*)
			return 0 ;;
	esac
	OC_PID_REASON="reused"
	return 1
}

oc_pid_reason_text() {
	# oc_pid_reason_text <reason> -> human readable (for logs only)
	case "${1:-}" in
		zombie) printf '持锁进程已成为僵尸进程' ;;
		reused) printf 'pid 已被其它进程复用' ;;
		no-pid) printf '锁内没有有效的 pid 记录' ;;
		*)      printf '持锁进程已退出' ;;
	esac
}

oc_pid_in_ancestry() {
	# true when <pid> is one of our own parents (stale-lock self recovery)
	local target="$1" cur depth
	case "${target:-}" in ''|*[!0-9]*) return 1 ;; esac
	cur="$$"; depth=0
	while [ -n "$cur" ] && [ "$cur" -gt 1 ] 2>/dev/null && [ "$depth" -lt 64 ]; do
		[ "$cur" = "$target" ] && return 0
		cur="$(oc_ppid "$cur" 2>/dev/null || true)"
		depth=$((depth + 1))
	done
	return 1
}

# 锁的持有者关系有四种：
#   OWN    自己创建的 → 退出时删除
#   ADOPT  祖先进程创建的（install.sh 调 cli.sh）→ **绝不删除**，只静默放行
#   none   没有锁 → 创建后成为 OWN
#   other  别的进程正在用 → 拒绝
OC_LOCK_STATE=""

_oc_lock_mark_own() {
	OC_LOCK_STATE="own"
	echo "$$" >"$OC_LOCK_DIR/pid" 2>/dev/null || true
	# 只删自己建的锁。用 OC_LOCK_STATE 判断，而不是"trap 里无条件 rm -rf" ——
	# 后者在 ADOPT 情形下会删掉父进程还在用的锁。
	trap '[ "$OC_LOCK_STATE" = "own" ] && oc_rmtree "$OC_LOCK_DIR"' EXIT
	trap '[ "$OC_LOCK_STATE" = "own" ] && oc_rmtree "$OC_LOCK_DIR"; exit 1' INT TERM HUP
}

oc_lock_acquire() {
	# returns 0 on success, 2 when another operation holds the lock
	if mkdir "$OC_LOCK_DIR" 2>/dev/null; then
		_oc_lock_mark_own
		return 0
	fi

	local pid reason steal
	pid="$(cat "$OC_LOCK_DIR/pid" 2>/dev/null || true)"

	# 祖先进程持锁：install.sh 起 cli.sh 时就是这样。这里**不能**清理再重建 ——
	# 清理会删掉父进程仍在使用的锁，而父进程的 EXIT trap 反过来又会删掉我们的，
	# 结果两个进程都以为自己独占，锁等于不存在。正确做法是继承：放行，但不拥有。
	if [ -n "$pid" ] && oc_pid_in_ancestry "$pid"; then
		OC_LOCK_STATE="adopt"
		trap - EXIT INT TERM HUP 2>/dev/null
		return 0
	fi

	if [ -n "$pid" ] && oc_pid_alive "$pid"; then
		oc_err "另一个操作正在运行（锁 $OC_LOCK_DIR，pid $pid）"
		return 2
	fi

	# 区分三种“死锁”原因，排查时能直接看出是退出、僵尸还是 pid 复用
	if [ -z "$pid" ]; then
		reason="no-pid"
	else
		reason="$OC_PID_REASON"
	fi
	oc_warn "检测到陈旧锁（pid ${pid:-未知}，$(oc_pid_reason_text "$reason")），自动接管：$OC_LOCK_DIR"

	# 抢占必须原子。原来是 `rm -rf` 再 `mkdir`：A 删锁的瞬间 B 恰好 mkdir
	# 成功，接着 A 的 rm 把 B 的**活锁**删掉，然后 A 也 mkdir 成功 —— 两个
	# 进程同时持锁。rename 是原子的：mv 只有一个赢家，输家的 mv 失败。
	steal="$OC_LOCK_DIR.stale.$$"
	oc_rmtree "$steal"
	if ! mv "$OC_LOCK_DIR" "$steal" 2>/dev/null; then
		# 没抢到：要么别人先接管了，要么原来那个锁自己消失了。
		# 两种情况都回到起点重试一次，成功就说明确实空出来了。
		if mkdir "$OC_LOCK_DIR" 2>/dev/null; then
			_oc_lock_mark_own
			return 0
		fi
		oc_err "无法获取操作锁（接管失败）：$OC_LOCK_DIR"
		return 2
	fi
	oc_rmtree "$steal"

	if mkdir "$OC_LOCK_DIR" 2>/dev/null; then
		_oc_lock_mark_own
		return 0
	fi
	oc_err "无法获取操作锁：$OC_LOCK_DIR"
	return 2
}

oc_lock_release() {
	# 只删自己建的锁；ADOPT 状态说明锁属于父进程，放手走人。
	[ "$OC_LOCK_STATE" = "own" ] && oc_rmtree "$OC_LOCK_DIR"
	OC_LOCK_STATE=""
	trap - EXIT INT TERM HUP 2>/dev/null || true
}

oc_locked() { [ -d "$OC_LOCK_DIR" ]; }

oc_lock_busy() {
	# 锁是否被**活着的**进程持有。0 = 忙，1 = 空闲或只有陈旧残留。
	#
	# 与 oc_locked 的区别很重要：oc_locked 只看目录在不在，于是任何一次
	# 被 SIGKILL / OOM / 断电打断的操作都会留下目录，之后所有升级都被
	# "另一个操作正在运行"永久拒绝 —— 除非用户知道要手工 unlock。
	# 升级入口必须问这个函数，而不是 oc_locked。
	local pid
	[ -d "$OC_LOCK_DIR" ] || return 1
	pid="$(cat "$OC_LOCK_DIR/pid" 2>/dev/null || true)"
	case "${pid:-}" in ''|*[!0-9]*) return 1 ;; esac
	oc_pid_alive "$pid" || return 1
	# 祖先进程持锁时对我们而言是"可用"的（会以 ADOPT 方式继承）
	oc_pid_in_ancestry "$pid" && return 1
	return 0
}

# ---------------------------------------------------------------- download
oc_fmt_elapsed() {
	local total="${1:-0}" h m s
	case "$total" in ''|*[!0-9]*) total=0 ;; esac
	h=$((total / 3600)); m=$(((total % 3600) / 60)); s=$((total % 60))
	# zero padded so the progress line keeps a stable width while polling
	if [ "$h" -gt 0 ]; then printf '%dh%02dm%02ds' "$h" "$m" "$s"
	elif [ "$m" -gt 0 ]; then printf '%dm%02ds' "$m" "$s"
	else printf '%ds' "$s"; fi
}

oc_download() {
	# oc_download <url> <dest> [label] [max-time]
	# Downloads in the background and reports progress, so a stalled transfer
	# is visible in the log instead of looking like a hung installer.
	local url="$1" dest="$2" label="${3:-下载}" mt="${4:-600}"
	local err start_ts last_change last_size last_report cpid rc
	local now size quiet elapsed size_mb

	err="$OC_RUNDIR/curl.err"
	rm -f "$err" 2>/dev/null || true
	mkdir -p "$(dirname "$dest")" 2>/dev/null || true

	# same guard as oc_fetch: mirrors are user editable and we run as root
	oc_safe_url "$url" || { oc_err "拒绝下载非法 URL：$url"; return 126; }

	oc_info "$label: $url"

	if ! command -v curl >/dev/null 2>&1; then
		# no curl: fall back and keep it simple
		oc_fetch "$url" "$dest" "$mt" && return 0
		return $?
	fi

	local proxy
	proxy="$(uci_get main.http_proxy '')"
	if [ -n "$proxy" ] && ! oc_safe_url "$proxy"; then
		oc_err "拒绝使用非法代理地址：$proxy"
		return 126
	fi
	if [ -n "$proxy" ]; then
		curl -fSL --retry 2 --retry-delay 1 --connect-timeout 15 --max-time "$mt" \
			-x "$proxy" -o "$dest" "$url" 2>"$err" &
	else
		curl -fSL --retry 2 --retry-delay 1 --connect-timeout 15 --max-time "$mt" \
			-o "$dest" "$url" 2>"$err" &
	fi
	cpid="$!"

	start_ts="$(date +%s 2>/dev/null || echo 0)"
	last_change="$start_ts"; last_size=0; last_report="$start_ts"

	while kill -0 "$cpid" 2>/dev/null; do
		sleep 15
		kill -0 "$cpid" 2>/dev/null || break
		now="$(date +%s 2>/dev/null || echo 0)"
		size="$(wc -c <"$dest" 2>/dev/null || echo 0)"
		case "$size" in ''|*[!0-9]*) size=0 ;; esac
		[ "$size" -ne "$last_size" ] && { last_size="$size"; last_change="$now"; }
		if [ $((now - last_report)) -ge 60 ]; then
			last_report="$now"
			quiet=$((now - last_change)); elapsed="$((now - start_ts))"
			size_mb=$((size / 1048576))
			if [ "$size" -gt 0 ]; then
				if [ "$quiet" -ge 60 ]; then
					oc_warn "$label 进行中（已用 $(oc_fmt_elapsed "$elapsed")；${quiet}s 无新数据；已下载 ${size_mb}MB）"
				else
					oc_info "$label 进行中（已用 $(oc_fmt_elapsed "$elapsed")；已下载 ${size_mb}MB）"
				fi
			else
				oc_info "$label 进行中（已用 $(oc_fmt_elapsed "$elapsed")；暂无数据）"
			fi
		fi
	done

	wait "$cpid"; rc=$?
	if [ "$rc" -ne 0 ]; then
		oc_err "$label 失败 (rc=$rc): $url"
		tail -n 5 "$err" 2>/dev/null | while IFS= read -r ln; do oc_err "$ln"; done
		return "$rc"
	fi
	oc_info "$label 完成（$(( $(wc -c <"$dest" 2>/dev/null || echo 0) / 1024 ))KB）"
	return 0
}

oc_archive_ok() {
	# verify a cached .tar.xz before trusting it
	local a="$1"
	[ -s "$a" ] || return 1
	if command -v xz >/dev/null 2>&1; then
		xz -t "$a" >/dev/null 2>&1 && return 0
		return 1
	fi
	tar -tJf "$a" >/dev/null 2>&1
}

oc_need_space() {
	# oc_need_space <path> <mb>
	local p="$1" need="$2" avail
	avail="$(df -m "$p" 2>/dev/null | awk 'NR==2{print $4}')"
	case "${avail:-}" in ''|*[!0-9]*) return 0 ;; esac   # unknown -> do not block
	if [ "$avail" -lt "$need" ] 2>/dev/null; then
		oc_err "磁盘空间不足：$p 需要 ${need}MB，可用 ${avail}MB"
		return 1
	fi
	return 0
}

# ---------------------------------------------------------------- token
oc_token() {
	# 24 random bytes hex, with fallbacks
	local t
	t="$(dd if=/dev/urandom bs=24 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')"
	[ -n "$t" ] || t="$(openssl rand -hex 24 2>/dev/null)"
	[ -n "$t" ] || t="$(head -c 32 /dev/urandom 2>/dev/null | md5sum 2>/dev/null | awk '{print $1}')"
	[ -n "$t" ] || t="$(awk 'BEGIN{srand();for(i=0;i<24;i++)printf "%02x", int(rand()*256)}')"
	printf '%s' "$t"
}

# ---------------------------------------------------------------- entry
oc_entry() {
	# locate the openclaw CLI entry inside the private npm prefix
	local g entries
	g="$(oc_oc_dir)/lib/node_modules/openclaw"
	entries="$g/openclaw.mjs $g/dist/cli.js $g/dist/index.js $g/openclaw.js"
	for e in $entries; do
		[ -f "$e" ] && { printf '%s' "$e"; return 0; }
	done
	[ -x "$(oc_oc_bin)" ] && { printf '%s' "$(oc_oc_bin)"; return 0; }
	return 1
}

oc_env_file() { printf '%s/.env' "$(oc_data_dir)"; }
