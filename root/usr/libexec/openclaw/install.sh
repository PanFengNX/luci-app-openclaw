#!/bin/sh
# openclaw - installation routines
#
# Installs an upstream, unmodified OpenClaw (npm package "openclaw") plus the
# Node.js runtime that its package.json engines.node demands. Versions are
# resolved online; a Node.js release below the required range is rejected.

OC_LIB="/usr/libexec/openclaw/lib.sh"
OC_VER="/usr/libexec/openclaw/versions.sh"
. "$OC_LIB"
. "$OC_VER"

MIN_FREE_MB=900
REC_FREE_MB=1500
# /usr/lib/nodejs 所在分区（OpenWrt 上通常是 overlay）解压 Node.js 所需的空间。
# 官方 tar.xz 解压后约 80-100MB，留出余量取 120MB。
NODE_GLOBAL_FREE_MB=120

OCV=""
NODE_V=""
NODE_MODE=""
BASE_DIR=""
OC_DIR_ARG=""
FORCE=0
NO_START=0
USE_SYSTEM_NODE=0

usage() {
	cat <<EOF
Usage: install.sh [--oc-version <ver|latest|extended-stable|beta>]
                  [--node-version <v24.16.0|auto|system>]
                  [--node-mode <private|global>]
                  [--base-dir <path>] [--openclaw-dir <path>]
                  [--force] [--no-start]

  --node-mode global   解压到 /usr/lib/nodejs 并链接到 /usr/bin/node|npm|npx（默认）
  --node-mode private  Node.js 解压到 <安装目录>/node（不动系统目录）
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--oc-version) OCV="$2"; shift 2 ;;
		--node-version) NODE_V="$2"; shift 2 ;;
		--node-mode) NODE_MODE="$2"; shift 2 ;;
		--base-dir) BASE_DIR="$2"; shift 2 ;;
		--openclaw-dir) OC_DIR_ARG="$2"; shift 2 ;;
		--force) FORCE=1; shift ;;
		--no-start) NO_START=1; shift ;;
		--system-node) USE_SYSTEM_NODE=1; shift ;;
		-h|--help) usage; exit 0 ;;
		*) shift ;;
	esac
done

[ -n "$BASE_DIR" ] || BASE_DIR="$(oc_base_dir)"

# Refuse dangerous targets and make sure only one install runs at a time.
# (install-bg detaches us, so the lock must be taken here, not by the caller.)
oc_require_dir "$BASE_DIR"
oc_lock_acquire || exit 2

[ -n "$OCV" ] || OCV="$(uci_get main.oc_version latest)"
[ -n "$OCV" ] || OCV="latest"
[ -n "$NODE_V" ] || NODE_V="$(uci_get main.node_version auto)"
[ -n "$NODE_V" ] || NODE_V="auto"

# npm install 的硬超时（秒）。默认 30 分钟：正常安装几分钟内完成，
# 卡住时不能无限期占着安装锁。环境变量优先，其次 UCI，非法值回退默认。
NPM_INSTALL_TIMEOUT_DEFAULT=1800
NPM_INSTALL_TIMEOUT="${NPM_INSTALL_TIMEOUT:-$(uci_get main.npm_install_timeout "$NPM_INSTALL_TIMEOUT_DEFAULT")}"
case "$NPM_INSTALL_TIMEOUT" in
	''|*[!0-9]*) NPM_INSTALL_TIMEOUT="$NPM_INSTALL_TIMEOUT_DEFAULT" ;;
esac
[ "$NPM_INSTALL_TIMEOUT" -gt 0 ] 2>/dev/null || NPM_INSTALL_TIMEOUT="$NPM_INSTALL_TIMEOUT_DEFAULT"

# 运行时的部署方式。命令行优先，其次 UCI，最后默认 private。
[ -n "$NODE_MODE" ] || NODE_MODE="$(uci_get main.node_mode private)"
[ -n "$NODE_MODE" ] || NODE_MODE="private"
case "$NODE_MODE" in
	private|global) ;;
	*) NODE_MODE="private" ;;
esac

# 注意：这里不能直接用 oc_node_dir()。它读的是 UCI 里的 base_dir，
# 而本次安装可能通过 --base-dir 指定了别的目录，两者不一定一致。
if [ "$NODE_MODE" = "global" ]; then
	NODE_DIR="$OC_NODE_GLOBAL_DIR"
else
	NODE_DIR="$BASE_DIR/node"
fi
# Program dir is relocatable: --openclaw-dir > main.openclaw_dir > <base>/openclaw.
# 注意这里不能直接用 oc_oc_dir()：它读的是 UCI 里的 base_dir，而本次安装可能
# 是通过 --base-dir 指定的新目录，两者不一定一致。
OC_DIR="${OC_DIR_ARG:-$(uci_get main.openclaw_dir '')}"
[ -n "$OC_DIR" ] || OC_DIR="$BASE_DIR/openclaw"
OC_DIR="${OC_DIR%/}"
HOME_DIR="$BASE_DIR/home"

# 上一轮的日志先留一份再清空：直接 `: >` 会把它抹掉。
# 这台机器的 syslog 是 128KB 环形缓冲、被 netifd 的 DHCPv6 刷得很勤
# （只存约 30 秒），事后根本翻不到安装现场 —— 这份 .1 是唯一线索。
[ -s "${OC_INSTALLLOG:-}" ] && mv -f "$OC_INSTALLLOG" "$OC_INSTALLLOG.1" 2>/dev/null
: >"$OC_INSTALLLOG" 2>/dev/null || OC_INSTALLLOG="${OC_RUNDIR:-/tmp/.openclaw}/install.log"
: >"$OC_INSTALLLOG" 2>/dev/null || true
# 把**实际使用**的日志路径写到标记文件，让 install-status 与 api_ilog 能拿到。
# 上面那句回退只改本进程的变量：cli.sh 是另一个进程，它报告给面板的仍是
# /var/log/... 那个（可能根本写不进去的）路径，于是"日志在哪"有三个进程
# 各猜各的。这里落一个单一真相来源。
printf '%s' "$OC_INSTALLLOG" >"${OC_RUNDIR:-/tmp/.openclaw}/install.logpath" 2>/dev/null || true
# 只写一次。install-bg 会把本进程的 stdout 也重定向到 $OC_INSTALLLOG，
# 原来的 `| tee -a` 于是成了第二个写者：两个描述符各有一个文件偏移，
# 日志里会出现重复行和被覆盖的半截行。这里只追加到日志文件；
# 前台运行（终端里直接跑 install.sh）时再额外打一份到终端。
ilog() {
	if printf '%s\n' "$*" >>"$OC_INSTALLLOG" 2>/dev/null; then
		[ -t 1 ] && printf '%s\n' "$*"
	else
		printf '%s\n' "$*"
	fi
	# 必须显式返回 0：非交互（install-bg）时上面的 `[ -t 1 ]` 为假，若把它的
	# 状态当成本函数的返回值，main() 的最后一个 ilog 就会让整个安装以 1 退出。
	return 0
}

# ---------------------------------------------------------------- progress
# 阶段编号与心跳。两者都只写日志：不改变控制流，也不影响任何退出码。
#
# 背景：npm 的输出已经单独写到 $OC_INSTALLLOG.npm，主日志在 npm 阶段只剩
# 开始/结束两行；路由器上 npm install 常常跑十几分钟，前端每 2 秒重写日志区
# 却始终看到同一段文字，用户就会以为安装卡死了。所以这里补两样东西：
#   [i/N] 阶段名 …            每个阶段开始/结束各一行，能看出"到第几步、共几步"
#   … 仍在进行（已 Xm Ys）     长步骤每 15 秒一行心跳，证明进程还活着
STAGE_TOTAL=8
STAGE_IDX=0
STAGE_NAME=""
STAGE_START=0
HB_PID=""
HB_WATCH=""
HB_INTERVAL=15

stage_begin() {
	STAGE_IDX=$((STAGE_IDX + 1))
	STAGE_NAME="$1"
	STAGE_START="$(date +%s 2>/dev/null)"
	case "$STAGE_START" in ''|*[!0-9]*) STAGE_START=0 ;; esac
	ilog "[$STAGE_IDX/$STAGE_TOTAL] $STAGE_NAME …"
}

stage_end() {
	# 阶段结束时心跳必须已经停掉：否则日志里会出现「阶段已完成」之后
	# 还在刷「仍在进行」的怪现象。这里兜底收一次，调用方漏停也不会漏。
	hb_stop
	local now elapsed
	now="$(date +%s 2>/dev/null)"
	case "$now" in ''|*[!0-9]*) now=0 ;; esac
	elapsed=0
	if [ "$STAGE_START" -gt 0 ] && [ "$now" -ge "$STAGE_START" ]; then
		elapsed=$((now - STAGE_START))
	fi
	ilog "[$STAGE_IDX/$STAGE_TOTAL] $STAGE_NAME 完成（耗时 $(oc_fmt_elapsed "$elapsed")）"
}

hb_size_mb() {
	# hb_size_mb <file> -> 文件当前大小的 MB 数（一位小数）；取不到时输出空。
	# 只用于心跳展示，失败一律静默（不能因为统计进度把安装搞挂）。
	local f="$1" b
	[ -n "$f" ] && [ -f "$f" ] || return 0
	b="$(wc -c <"$f" 2>/dev/null | awk '{print $1}')"
	case "$b" in ''|*[!0-9]*) return 0 ;; esac
	awk -v b="$b" 'BEGIN { printf "%.1f", b / 1048576 }' 2>/dev/null
}

hb_start() {
	# hb_start <label> [watch-file] —— 为可能超过 15 秒的步骤起一个后台心跳。
	# watch-file 可选：给了就在心跳里附上它的当前大小（下载进度）。
	# 子 shell 里 $$ 仍是父 shell 的 pid，所以父进程一旦退出（包括被 kill -9），
	# 下一轮 kill -0 就会失败并自行结束，不会留下永久循环的孤儿进程。
	hb_stop
	local label="$1" watch="${2:-}" parent start
	parent=$$
	start="$(date +%s 2>/dev/null)"
	case "$start" in ''|*[!0-9]*) start=0 ;; esac
	HB_WATCH="$watch"
	(
		# sleep 放后台再 wait：收到 TERM 时 trap 立刻收掉这个 sleep，
		# 不必依赖 pgrep（busybox 可以不带它），也不会留下孤儿 sleep。
		spid=""
		trap '[ -n "$spid" ] && kill "$spid" 2>/dev/null; exit 0' TERM INT HUP
		while kill -0 "$parent" 2>/dev/null; do
			sleep "$HB_INTERVAL" &
			spid=$!
			wait "$spid" 2>/dev/null
			spid=""
			kill -0 "$parent" 2>/dev/null || break
			now="$(date +%s 2>/dev/null)"
			case "$now" in ''|*[!0-9]*) now="$start" ;; esac
			msg="[$STAGE_IDX/$STAGE_TOTAL] $label 仍在进行（已 $(oc_fmt_elapsed $((now - start)))）"
			size="$(hb_size_mb "$HB_WATCH")"
			if [ -n "$size" ]; then
				msg="$msg 已下载 ${size} MB"
			fi
			ilog "$msg"
		done
	) &
	HB_PID=$!
}

hb_stop() {
	[ -n "$HB_PID" ] || return 0
	# 心跳子 shell 自己的 TERM trap 会收掉正在 wait 的 sleep；这里再按父子
	# 关系兜底杀一次（有 pgrep 时），覆盖 trap 没能执行的老 ash。
	local kids
	if command -v pgrep >/dev/null 2>&1; then
		kids="$(pgrep -P "$HB_PID" 2>/dev/null)"
		# shellcheck disable=SC2086
		[ -n "$kids" ] && kill $kids 2>/dev/null
	fi
	kill "$HB_PID" 2>/dev/null
	wait "$HB_PID" 2>/dev/null
	HB_PID=""
	HB_WATCH=""
	return 0
}

# run_with_heartbeat <label> [--watch <file>] -- <cmd...>
# 在当前阶段执行 <cmd...>，执行期间每 HB_INTERVAL 秒往安装日志写一行心跳；
# 命令一结束立刻停掉心跳（含它的 sleep 子进程），退出码原样返回给调用方。
run_with_heartbeat() {
	local label="$1" watch="" rc
	shift
	case "${1:-}" in
		--watch)
			watch="$2"
			shift 2
			;;
	esac
	[ "${1:-}" = "--" ] && shift
	hb_start "$label" "$watch"
	"$@"
	rc=$?
	hb_stop
	return "$rc"
}

die() {
	hb_stop
	ilog "ERROR: $*"
	# 覆盖安装前安装器会先停网关。若 npm install 没成功就走到这里，不把服务拉回来，
	# 用户看到的就是「升级失败，网关也没了」（2026-11-26 真机：ECONNRESET 之后状态
	# 停在 stopped，只能手工点启动）。
	#
	# 但「原程序还能用」必须有证据，不能只看 package.json 还是旧版本：npm 在替换
	# 阶段失败时它可能没变，旁边的包却已被换过，启动的是半新半旧的树。
	# 要同时满足下面三条才恢复，任何一条不满足都保持停止并说清原因 ——
	# 启动一个不确定完好的网关比停着更糟。
	#   1. 确实停过网关（OC_GW_WAS_RUNNING=1，npm 成功后清零）；
	#   2. 自 npm 开始以来程序目录里没有任何文件/目录被创建、修改、删除
	#      （oc_tree_untouched：说明 npm 连替换阶段都没进入）；
	#   3. 程序版本等于升级前的版本。
	# 版本用全局 OC_PRE_UPGRADE_VER 传进来，不靠动态作用域去读调用方的 local。
	if [ "${OC_GW_WAS_RUNNING:-0}" = "1" ]; then
		OC_GW_WAS_RUNNING=0
		die_old_ver=""
		if [ -x "$OC_DIR/bin/openclaw" ]; then
			die_old_ver="$(oc_pkg_version "$OC_DIR" 2>/dev/null | head -n1)"
			[ -n "$die_old_ver" ] || die_old_ver="$(oc_installed_version "$OC_DIR" 2>/dev/null | head -n1)"
		fi
		if [ -n "${OC_UPGRADE_MARKER:-}" ] && oc_tree_untouched "$OC_DIR" "$OC_UPGRADE_MARKER" \
				&& [ -n "$die_old_ver" ] && [ "$die_old_ver" = "${OC_PRE_UPGRADE_VER:-}" ] \
				&& [ -x "${OC_INITD:-/etc/init.d/openclaw}" ]; then
			ilog "升级未完成：程序目录自升级开始后没有任何改动，仍是原版本 $die_old_ver，重新启动网关"
			"${OC_INITD:-/etc/init.d/openclaw}" start >/dev/null 2>&1
		else
			ilog "WARN: 升级未完成，且无法确认原程序完好（当前版本 ${die_old_ver:-读不到}，升级前 ${OC_PRE_UPGRADE_VER:-未知}，安装目录是否有改动见上），未自动启动网关。请重新执行一次安装（会完整重装）或点「一键修复」"
		fi
	fi
	case "${OC_UPGRADE_MARKER:-}" in ?*) rm -f "$OC_UPGRADE_MARKER" 2>/dev/null ;; esac
	exit 1
}

# run_with_timeout <seconds> <cmd...>
# 系统有 timeout（GNU 或 busybox 均可）时用它兜底；没有时退化为直接执行，
# 由调用方负责用 ilog 说明「本次不设超时上限」。
run_with_timeout() {
	local secs="$1"; shift
	# lib.sh 的 fallback 在没有 timeout applet 时后台运行并按 TERM/KILL/wait
	# 收束，安装流程也必须使用同一条有限路径。
	oc_timeout "$secs" "$@"
}

# append_tail <file> <lines> <label>
# 把某份独立日志的最后 N 行追加进主日志。只在失败路径调用：成功时保持主日志精简。
append_tail() {
	local f="$1" n="$2" label="$3"
	[ -s "$f" ] || return 0
	ilog "---- $label 最后 $n 行（完整日志：$f） ----"
	tail -n "$n" "$f" >>"$OC_INSTALLLOG" 2>/dev/null || true
	ilog "---- $label 结束 ----"
}

# The program dir is user-configurable, so it needs its own safety check:
# we write node_modules into it and later run `chown -R` / `rm -rf` on it.
# Without this, openclaw_dir=/etc would turn a reinstall into a system takeover.
oc_validate_base_dir "$OC_DIR" \
	|| die "不安全的 OpenClaw 程序目录：$OC_DIR（不能是 /、/etc、/tmp、/var 等系统路径，也不能含 .. 或符号链接）"

# ---------------------------------------------------------------- preflight
preflight() {
	ilog "== 环境预检 =="
	ilog "架构: $(oc_arch) ($(uname -m))  libc: $(oc_is_musl && echo musl || echo glibc)"
	ilog "系统: OpenWrt $(oc_sys_version)  包管理器: $(oc_has_apk && echo apk || echo opkg)"
	ilog "安装目录: $BASE_DIR"
	ilog "Node 模式: $NODE_MODE（运行时目录 $NODE_DIR）"

	# S1：global 模式要接管 /usr/bin/node|npm|npx，装之前先确认它们要么不存在、
	# 要么就是本插件自己建的链接。否则一旦覆盖，发行版包管理器卸载时会连带删掉
	# 我们的运行时，反过来本插件卸载也会删掉不属于自己的文件。
	if [ "$NODE_MODE" = "global" ]; then
		local conflict
		conflict="$(oc_node_global_conflict)"
		if [ -n "$conflict" ]; then
			ilog "ERROR: 系统已存在 Node.js：$conflict"
			ilog "全局模式只允许接管本插件安装的 $OC_NODE_GLOBAL_DIR（$conflict 需指向该目录）。"
			ilog "请改用 private 模式（--node-mode private，运行时装在安装目录内，互不影响），"
			ilog "或先手动移除系统 Node.js 后重试。"
			exit 2
		fi
		[ -L "$OC_NODE_GLOBAL_DIR" ] && die "拒绝操作：$OC_NODE_GLOBAL_DIR 是符号链接"
	fi

	mkdir -p "$BASE_DIR" 2>/dev/null || die "无法创建安装目录 $BASE_DIR"
	# write probe
	probe="$BASE_DIR/.oc-write-probe"
	if ! : >"$probe" 2>/dev/null; then
		die "安装目录不可写（只读/未挂载/权限不足）：$BASE_DIR"
	fi
	rm -f "$probe"

	# 升级前先清掉 OpenClaw 自己留下的 SQLite 只读快照。
	#
	# 这些快照是 OpenClaw 每次以只读方式打开数据库时复制出来的**整库副本**
	# （~/.cache/openclaw/openclaw-sqlite-readonly-v2-*），只在进程正常退出时
	# 才删；被 kill / 崩溃 / 磁盘满打断就永久残留。实测一台设备积了 63GB，
	# 磁盘满之后 doctor 建不出新快照 → schema 迁移中断 → 网关起不来
	# （页面显示"运行中（端口未应答）"）。每升一次级就多漏一个，所以表现成
	# "升级后经常出问题"。这里在升级前清一次（保留最新的 1 个、只删 10 分钟
	# 以前的，避免动到正在用的），升级后再清一次收尾。
	_cleaned="$(oc_clean_sqlite_snapshots 1 600)"
	case "$_cleaned" in ''|*[!0-9]*) _cleaned=0 ;; esac
	[ "$_cleaned" -gt 0 ] && ilog "清理 OpenClaw 只读快照：$_cleaned 个（每个都是整库副本，磁盘满的常见原因）"

	local free
	free="$(oc_free_mb "$BASE_DIR")"
	[ -n "$free" ] || free=0
	ilog "可用空间: ${free} MB"
	if [ "$free" -lt "$MIN_FREE_MB" ]; then
		die "可用空间不足（${free} MB < ${MIN_FREE_MB} MB）。请更换挂载盘或清理空间后重试。"
	elif [ "$free" -lt "$REC_FREE_MB" ]; then
		ilog "WARN: 可用空间偏低（建议 ${REC_FREE_MB} MB 以上）"
	fi

	command -v tar >/dev/null 2>&1 || die "缺少 tar"
	# xz 不是可选项：Node.js 官方分发包是 .tar.xz，而 busybox 版 tar 多数
	# 没编进 -J。缺 xz 时下面的解压会失败，报的是"解压失败（tar）"，
	# 与真正的原因（缺命令）完全对不上 —— 用户只能猜。
	# 因此在 preflight 就把它当成硬前提，直接给出可执行的修复命令。
	if ! command -v xz >/dev/null 2>&1 && ! command -v unxz >/dev/null 2>&1; then
		if tar --help 2>/dev/null | grep -q -- '-J'; then
			ilog "tar 自带 xz 支持，无需单独安装 xz"
		else
			die "缺少 xz，无法解压 Node.js 的 .tar.xz。请先执行：$(oc_pkg_install_hint) xz-utils"
		fi
	fi
	command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || \
		command -v uclient-fetch >/dev/null 2>&1 || die "缺少下载工具（curl/wget/uclient-fetch）"
}

# ---------------------------------------------------------------- resolve
resolve_versions() {
	ilog "== 解析版本（在线获取） =="
	sh "$OC_VER" oc-versions refresh >/dev/null 2>&1

	case "$OCV" in
		latest|extended-stable|beta|stable)
			local resolved
			resolved="$(awk -F'\t' -v x="$OCV" '$1==x{printf "%s",$2; exit}' "${OC_CACHE_DIR:-/tmp/.openclaw/cache}/oc-tags.tsv" 2>/dev/null)"
			[ -n "$resolved" ] || die "无法获取 OpenClaw 的 $OCV 版本号（网络问题？）"
			ilog "标签 $OCV -> OpenClaw $resolved"
			OCV="$resolved"
			;;
	esac
	uci_set main.oc_version "$OCV"

	ENGINES="$(sh "$OC_VER" engines "$OCV" 2>/dev/null | sed 's/.*"engines":"//; s/".*//')"
	[ -n "$ENGINES" ] || die "无法获取 OpenClaw $OCV 的 engines.node 要求"
	ilog "OpenClaw $OCV 要求 Node.js: $ENGINES"

	if [ "$NODE_V" = "system" ] || [ "$USE_SYSTEM_NODE" = "1" ]; then
		if command -v node >/dev/null 2>&1; then
			NODE_V="$(node -v 2>/dev/null)"
			USE_SYSTEM_NODE=1
			ilog "使用系统 Node.js: $NODE_V"
		else
			die "未找到系统 Node.js，请改为安装内置运行时"
		fi
	elif [ "$NODE_V" = "auto" ] || [ -z "$NODE_V" ]; then
		sh "$OC_VER" node-versions refresh >/dev/null 2>&1
		NODE_V="$(awk -F'\t' '{print $1}' "${OC_CACHE_DIR:-/tmp/.openclaw/cache}/node-versions.tsv" 2>/dev/null | while read -r nv; do
			n="${nv#v}"
			if engines_match "$n" "$ENGINES"; then printf '%s\n' "$nv"; break; fi
		done)"
		[ -n "$NODE_V" ] || die "没有满足 Node.js $ENGINES 的可用运行时"
		ilog "自动选择 Node.js: $NODE_V"
	fi
	uci_set main.node_version "$NODE_V"
	uci_commit
}

verify_node_version() {
	ilog "== 校验 Node.js 版本 =="
	local nv="${NODE_V#v}"
	if [ "$USE_SYSTEM_NODE" = "1" ]; then
		ilog "系统 Node.js $nv（跳过下载）"
	else
		if ! engines_match "$nv" "$ENGINES"; then
			ilog "ERROR: Node.js $nv 不满足 OpenClaw $OCV 的要求：$ENGINES"
			ilog "请选择不低于要求的版本后重新安装。"
			exit 2
		fi
	fi
	ilog "OK: Node.js $nv 满足 $ENGINES"
}

# ---------------------------------------------------------------- node
node_verify_sum() {
	# node_verify_sum <version-url> <tarball> <file>
	#
	# 比对 SHASUMS256.txt。**fail-closed**：清单拉不到 / 清单里没有该文件 /
	# 系统缺 sha256sum，一律中止安装。这是可执行文件的完整性校验，静默跳过
	# 等于把「镜像被换包」变成「装了个能跑的二进制」。
	#
	# 唯一的显式出路是 UCI main.allow_unverified_node=1（默认 0）：此时保留
	# 旧行为放行，但每一条都要在安装日志里写明跳过了什么，事后可追溯。
	# 校验和不匹配永远中止，不受开关影响。
	local vurl="$1" tarball="$2" file="$3" want got allow
	allow="$(uci_get main.allow_unverified_node 0)"
	case "$allow" in
		1|true|yes|on) allow=1 ;;
		*) allow=0 ;;
	esac

	if ! oc_fetch "$vurl/SHASUMS256.txt" "$OC_DL/SHASUMS256.txt" 60 2>/dev/null; then
		if [ "$allow" = "1" ]; then
			ilog "WARN: 无法获取 Node.js 校验清单（$vurl/SHASUMS256.txt），已按 main.allow_unverified_node=1 跳过校验"
			return 0
		fi
		die "无法获取 Node.js 校验清单（$vurl/SHASUMS256.txt），已中止安装。确认网络/镜像可用后重试；确需跳过校验请设置 uci set openclaw.main.allow_unverified_node=1"
	fi

	want="$(grep "  *$tarball\$" "$OC_DL/SHASUMS256.txt" | awk '{print $1}')"
	if [ -z "$want" ]; then
		if [ "$allow" = "1" ]; then
			ilog "WARN: SHASUMS256.txt 中没有 $tarball 的记录，已按 main.allow_unverified_node=1 跳过校验"
			return 0
		fi
		die "Node.js 校验清单（$vurl/SHASUMS256.txt）中没有 $tarball 的记录，已中止安装。确认镜像与版本匹配后重试；确需跳过校验请设置 uci set openclaw.main.allow_unverified_node=1"
	fi

	if ! command -v sha256sum >/dev/null 2>&1; then
		if [ "$allow" = "1" ]; then
			ilog "WARN: 系统缺少 sha256sum，已按 main.allow_unverified_node=1 跳过校验（$tarball）"
			return 0
		fi
		die "系统缺少 sha256sum 工具，无法校验 Node.js 压缩包（$tarball），已中止安装。请先安装 coreutils-sha256sum（或 busybox 的 sha256sum）后重试；确需跳过校验请设置 uci set openclaw.main.allow_unverified_node=1"
	fi

	got="$(sha256sum "$file" 2>/dev/null | awk '{print $1}')"
	if [ -z "$got" ]; then
		die "无法计算校验和（$file）：sha256sum 执行失败或文件不可读"
	fi
	if [ "$got" != "$want" ]; then
		die "校验和不匹配（$tarball）：期望 $want 实际 $got"
	fi
	ilog "校验和 OK"
	return 0
}

install_node_global() {
	# 「系统全局安装」：解压到 $OC_NODE_GLOBAL_DIR（/usr/lib/nodejs），
	# 再把 node/npm/npx 链接进 /usr/bin，全系统都能直接用。
	# 与 private 模式的差别只有落点；归属校验（S1）已在 preflight 里做过。
	ilog "== 安装 Node.js $NODE_V（系统全局模式） =="
	local base tarball url dest b got
	base="$(node_base_url)"
	tarball="$(node_tarball_name "$NODE_V")"
	url="$base/$NODE_V/$tarball"
	dest="$BASE_DIR/cache/$tarball"
	mkdir -p "$BASE_DIR/cache" "$OC_DL"

	# S2：目标分区（OpenWrt 上 /usr 通常落在 overlay）必须先确认空间。
	# 写满 overlay 的后果不只是安装失败 —— 之后所有配置变更都无法落盘。
	mkdir -p "$OC_NODE_GLOBAL_DIR" 2>/dev/null \
		|| die "无法创建 $OC_NODE_GLOBAL_DIR（只读文件系统？）"
	if ! oc_need_space "$OC_NODE_GLOBAL_DIR" "$NODE_GLOBAL_FREE_MB"; then
		ilog "提示：可改用 private 模式（--node-mode private），"
		ilog "      运行时将装在 $BASE_DIR/node，不占用 overlay 空间。"
		exit 2
	fi

	if [ "$FORCE" != "1" ] && [ -x "$NODE_DIR/bin/node" ] && [ "$(NODE_DIR_bin)" = "v${NODE_V#v}" ]; then
		ilog "Node.js $NODE_V 已存在，跳过下载"
	else
		if oc_archive_ok "$dest"; then
			ilog "复用已缓存的 Node.js 压缩包：$dest"
		else
			[ -e "$dest" ] && { ilog "缓存的压缩包已损坏，重新下载：$dest"; rm -f "$dest"; }
			oc_need_space "$BASE_DIR" 200 || die "空间不足以下载 Node.js（需要约 200MB）"
			# Node.js 压缩包解压后就是会被执行的二进制，所以这里用 strict：
			# 明文 http 一律拒绝（除非显式打开 main.allow_http_binaries）。
			# 拒绝原因由 oc_safe_url 打印（含可操作的修复提示），这里只负责中止。
			oc_safe_url "$url" strict || die "Node.js 下载被拒绝：$url"
			# 心跳里带上 $dest 的当前大小：慢网下能看出是在下还是没动。
			run_with_heartbeat "下载 Node.js $NODE_V" --watch "$dest" -- \
				oc_download "$url" "$dest" "下载 Node.js $NODE_V" 600 \
				|| die "Node.js 下载失败：$url"
		fi
		node_verify_sum "$base/$NODE_V" "$tarball" "$dest"
		# 清空目标目录。这里刻意不用 rm -rf：find -depth -delete 只删目录内容，
		# 且默认不跟随符号链接（preflight 已确认它本身不是链接）。
		mkdir -p "$OC_NODE_GLOBAL_DIR"
		find "$OC_NODE_GLOBAL_DIR" -depth -delete 2>/dev/null || true
		mkdir -p "$OC_NODE_GLOBAL_DIR" 2>/dev/null \
			|| die "无法重建 $OC_NODE_GLOBAL_DIR"
		ilog "解压中（$OC_NODE_GLOBAL_DIR） ..."
		hb_start "解压 Node.js $NODE_V"
		if command -v xz >/dev/null 2>&1; then
			tar -xJf "$dest" -C "$OC_NODE_GLOBAL_DIR" --strip-components=1 || die "解压失败（xz）"
		else
			tar -xf "$dest" -C "$OC_NODE_GLOBAL_DIR" --strip-components=1 || die "解压失败（tar）"
		fi
		hb_stop
		rm -f "$dest"
	fi

	NODE_BIN="$OC_NODE_GLOBAL_DIR/bin/node"
	NPM_BIN="$OC_NODE_GLOBAL_DIR/bin/npm"
	[ -x "$NODE_BIN" ] || die "Node.js 安装后不可执行：$NODE_BIN"
	got="$("$NODE_BIN" -v 2>/dev/null)"
	[ -n "$got" ] || die "Node.js 无法运行（$NODE_BIN），可能是架构或 libc 不匹配"

	# 网关以 openclaw 用户运行，必须能读并执行这份运行时。官方 tar 解压出来是
	# 0755，但 root 的 umask 若是 077 就会变成 0700，网关直接起不来。
	chmod -R a+rX "$OC_NODE_GLOBAL_DIR" 2>/dev/null || true

	# 让全局生效：/usr/bin/{node,npm,npx} -> $OC_NODE_GLOBAL_DIR/bin/*
	for b in $(oc_node_global_bins); do
		oc_node_link "$OC_NODE_GLOBAL_DIR/bin/$b" "/usr/bin/$b" \
			|| die "无法创建符号链接 /usr/bin/$b（权限不足或只读文件系统）"
	done
	ilog "全局符号链接就绪: /usr/bin/node -> $OC_NODE_GLOBAL_DIR/bin/node（npm、npx 同）"
	ilog "Node.js 就绪: $got  npm: $("$NODE_BIN" "$OC_NODE_GLOBAL_DIR/lib/node_modules/npm/bin/npm-cli.js" -v 2>/dev/null)"
	case "$got" in
		"$NODE_V"|"v${NODE_V#v}") ;;
		*) ilog "WARN: 实际版本 $got 与请求版本 $NODE_V 不一致" ;;
	esac
}

install_node() {
	if [ "$USE_SYSTEM_NODE" = "1" ]; then
		NODE_BIN="$(command -v node)"
		NPM_BIN="$(command -v npm)"
		[ -n "$NPM_BIN" ] || NPM_BIN="$(dirname "$NODE_BIN")/npm"
		return 0
	fi
	if [ "$NODE_MODE" = "global" ]; then
		install_node_global
		return 0
	fi
	ilog "== 安装 Node.js $NODE_V =="
	local base tarball url sums dest
	base="$(node_base_url)"
	tarball="$(node_tarball_name "$NODE_V")"
	url="$base/$NODE_V/$tarball"
	# Keep the archive on the target disk, not in /tmp (tmpfs = RAM on OpenWrt).
	# A failed install can then resume without re-downloading ~60MB.
	dest="$BASE_DIR/cache/$tarball"
	mkdir -p "$BASE_DIR/cache" "$OC_DL"

	if [ "$FORCE" != "1" ] && [ -f "$NODE_DIR/bin/node" ] && [ "$(NODE_DIR_bin)" = "v${NODE_V#v}" ]; then
		ilog "Node.js $NODE_V 已存在，跳过下载"
	else
		# reuse a previously downloaded archive if it is still intact
		if oc_archive_ok "$dest"; then
			ilog "复用已缓存的 Node.js 压缩包：$dest"
		else
			[ -e "$dest" ] && { ilog "缓存的压缩包已损坏，重新下载：$dest"; rm -f "$dest"; }
			oc_need_space "$BASE_DIR" 200 || die "空间不足以下载 Node.js（需要约 200MB）"
			# 同 install_node_global：可执行文件只走 https。
			oc_safe_url "$url" strict || die "Node.js 下载被拒绝：$url"
			# 心跳里带上 $dest 的当前大小：慢网下能看出是在下还是没动。
			run_with_heartbeat "下载 Node.js $NODE_V" --watch "$dest" -- \
				oc_download "$url" "$dest" "下载 Node.js $NODE_V" 600 \
				|| die "Node.js 下载失败：$url"
		fi
		node_verify_sum "$base/$NODE_V" "$tarball" "$dest"
		rm -rf "$NODE_DIR"
		mkdir -p "$NODE_DIR"
		ilog "解压中 ..."
		hb_start "解压 Node.js $NODE_V"
		if command -v xz >/dev/null 2>&1; then
			tar -xJf "$dest" -C "$NODE_DIR" --strip-components=1 || die "解压失败（xz）"
		else
			tar -xf "$dest" -C "$NODE_DIR" --strip-components=1 || die "解压失败（tar）"
		fi
		hb_stop
		rm -f "$dest"
	fi
	NODE_BIN="$NODE_DIR/bin/node"
	NPM_BIN="$NODE_DIR/bin/npm"
	[ -x "$NODE_BIN" ] || die "Node.js 安装后不可执行：$NODE_BIN"
	local got
	got="$("$NODE_BIN" -v 2>/dev/null)"
	[ -n "$got" ] || die "Node.js 无法运行（$NODE_BIN），可能是架构或 libc 不匹配"
	ilog "Node.js 就绪: $got  npm: $("$NODE_BIN" "$NODE_DIR/lib/node_modules/npm/bin/npm-cli.js" -v 2>/dev/null)"
	case "$got" in
		"$NODE_V"|"v${NODE_V#v}") ;;
		*) ilog "WARN: 实际版本 $got 与请求版本 $NODE_V 不一致" ;;
	esac
}

NODE_DIR_bin() { "$NODE_DIR/bin/node" -v 2>/dev/null; }

# ---------------------------------------------------------------- upgrade strategy
oc_ver_norm() {
	# oc_ver_norm <任意版本输出> -> 年.月.补丁 三个纯数字段（取不到则无输出）
	# 「OpenClaw 2026.11.10 (6ea542f)」「v2026.11.10」「2026.11.10-beta.1」-> 2026.11.10
	# 只用于**比较跨度**；判断「是不是同一个版本」必须用 oc_pkg_version 的原值，
	# 否则 2026.11.10-beta.1 会被当成 2026.11.10。
	printf '%s' "$1" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' 2>/dev/null | head -n1
}

oc_pkg_version() {
	# oc_pkg_version [oc-dir] -> package.json 里的原始 version（可带 -beta.1 等后缀）
	# 读文件、不启动 CLI：不受「配置文件非法」影响，也没有 --version 那种
	# 「OpenClaw 2026.11.10 (6ea542f)」的整行前缀。
	local pj v
	pj="${1:-$(oc_oc_dir 2>/dev/null)}/lib/node_modules/openclaw/package.json"
	[ -f "$pj" ] || return 1
	v=""
	if command -v jsonfilter >/dev/null 2>&1; then
		v="$(jsonfilter -i "$pj" -e '@.version' 2>/dev/null | head -n1)"
	fi
	[ -n "$v" ] || v="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$pj" 2>/dev/null | head -n1)"
	[ -n "$v" ] || return 1
	printf '%s' "$v"
}

oc_upgrade_class() {
	# oc_upgrade_class <当前版本> <目标版本>
	#   -> same | patch | minor | downgrade | prerelease | unknown
	#
	# OpenClaw 用日历版本（年.月.补丁号[-预发布]）。跨度不同，升级要做的事确实不同：
	#   same       同一个版本：不必重装（强制重装除外）
	#   patch      同月内升级：只换程序，配置格式不变
	#              （beta -> 同号正式版、beta.1 -> beta.2 也算）
	#   minor      跨月升级：配置格式会变 —— 2026.10 删了 gateway.controlUi.*，
	#              2026.11 删了 agents.defaults.heartbeat，残留一个键整份配置
	#              就被判无效。所以升级前必须备份配置，装完跑 doctor --fix 并校验。
	#   downgrade  降级：共享状态库只升不降（官方文档：迁移之后旧版 Gateway
	#              跑不了已迁移的任务），默认拒绝。
	#   prerelease 正式版 -> 预发布版：数字段再大，状态库也可能被预发布版迁移，
	#              按跨月升级对待（备份配置），并明确提示。
	# 任一版本认不出来 -> unknown，调用方按最保守的 minor 处理。
	#
	# 数字段相同不等于同一个版本：2026.11.10-beta.1 与 2026.11.10、
	# 与 2026.11.10-beta.2 都是不同版本，按 semver 的预发布规则比。
	local cur tgt cy cm ty tm r pc pt
	cur="$(oc_ver_norm "${1:-}")"
	tgt="$(oc_ver_norm "${2:-}")"
	if [ -z "$cur" ] || [ -z "$tgt" ]; then printf 'unknown'; return 0; fi
	if ver_eq "$cur" "$tgt"; then
		pc="$(oc_pre_part "${1:-}" "$cur")"
		pt="$(oc_pre_part "${2:-}" "$tgt")"
		if [ -z "$pc" ] && [ -z "$pt" ]; then printf 'same'
		elif [ -z "$pc" ]; then printf 'prerelease'
		elif [ -z "$pt" ]; then printf 'patch'
		else
			# oc_pre_cmp 返回 -1 表示当前的预发布段更早（beta.1 -> beta.2 是升级）
			case "$(oc_pre_cmp "$pc" "$pt")" in
				0) printf 'same' ;;
				1) printf 'downgrade' ;;
				*) printf 'patch' ;;
			esac
		fi
		return 0
	fi
	if ver_lt "$tgt" "$cur"; then printf 'downgrade'; return 0; fi
	cy="${cur%%.*}"; r="${cur#*.}"; cm="${r%%.*}"
	ty="${tgt%%.*}"; r="${tgt#*.}"; tm="${r%%.*}"
	if [ "$cy" = "$ty" ] && [ "$cm" = "$tm" ]; then printf 'patch'
	else printf 'minor'
	fi
}

oc_pre_part() {
	# oc_pre_part <原始版本> <年.月.补丁> -> 预发布段（没有则无输出）
	# 「2026.11.10-beta.1」-> beta.1；「OpenClaw 2026.11.10 (6ea542f)」-> 无
	local rest="${1#*"$2"}"
	[ "$rest" != "$1" ] || return 0
	case "$rest" in
		-*) printf '%s' "${rest#-}" | sed 's/[[:space:]].*$//; s/+.*$//' ;;
	esac
}

oc_pre_cmp() {
	# oc_pre_cmp <预发布段a> <预发布段b> -> -1 / 0 / 1（semver 规则）
	#
	# 逐段比较：纯数字段按数值，数字段小于字母段，字母段按字典序；
	# 前面都相同则段数多的更大（beta < beta.1）。
	# expr 的操作数前面各加一个 x：让「1」「01」这类段不会被 expr 当成
	# 运算符，也保证它做的是字符串比较。
	local a="$1" b="$2" x y
	while [ -n "$a" ] && [ -n "$b" ]; do
		x="${a%%.*}"; y="${b%%.*}"
		if [ "$x" != "$y" ]; then
			case "$x" in
				*[!0-9]*)
					case "$y" in
						*[!0-9]*)
							# 都是字母段：字典序
							if expr "x$x" '<' "x$y" >/dev/null 2>&1; then printf -- '-1'
							else printf '1'; fi
							return 0 ;;
						*) printf '1'; return 0 ;;    # 字母段 > 数字段
					esac ;;
			esac
			case "$y" in *[!0-9]*) printf -- '-1'; return 0 ;; esac
			# 都是数字段：去掉前导零再比（1 与 01 是同一个数）
			while [ "${#x}" -gt 1 ] && [ "${x#0}" != "$x" ]; do x="${x#0}"; done
			while [ "${#y}" -gt 1 ] && [ "${y#0}" != "$y" ]; do y="${y#0}"; done
			if [ "$x" = "$y" ]; then :; elif [ "$x" -lt "$y" ]; then printf -- '-1'; return 0
			else printf '1'; return 0; fi
		fi
		case "$a" in *.*) a="${a#*.}" ;; *) a="" ;; esac
		case "$b" in *.*) b="${b#*.}" ;; *) b="" ;; esac
	done
	if [ -n "$a" ]; then printf '1'; return 0; fi
	if [ -n "$b" ]; then printf -- '-1'; return 0; fi
	printf '0'
}

npm_net_fail() {
	# npm_net_fail <**这一次尝试**的 npm 日志> -> 0 表示失败原因是网络（值得重试/换源）
	#
	# 入参必须是单次尝试自己的日志（npm_install_retry 每次写一个文件）：几份日志
	# 合在一起时，分不清哪条报错属于哪一次。也不看「最后 N 行」—— 网络报错后面
	# 可能还跟着几十行上下文，按行数截会漏。
	#
	# 只认 npm 自己的错误码行和那句 network aborted，不用泛泛的关键字：
	# 「fetch failed」之类在包不存在、磁盘满时的上下文里也会出现，拿它去换源
	# 只会得到一个更难懂的 404。
	# 不属于网络的（E404 / ETARGET / ENOSPC / EACCES / 生命周期脚本失败）不重试：
	# 再跑一次结果一样，只会多等十几分钟。
	[ -s "$1" ] || return 1
	grep -qE '^npm error code (ECONNRESET|ETIMEDOUT|EAI_AGAIN|ECONNREFUSED|ECONNABORTED|EPIPE|ENETUNREACH|EHOSTUNREACH|ENOTFOUND)([[:space:]]|$)' \
		"$1" 2>/dev/null || grep -q '^npm error network aborted' "$1" 2>/dev/null
}

npm_alt_registry() {
	# npm_alt_registry <当前源> -> 另一个源；不在「官方 / npmmirror」范围内则无输出
	# （用户自建的源不替他换，换了可能根本同步不到这个版本）。
	case "$1" in
		*registry.npmjs.org*) printf 'https://registry.npmmirror.com' ;;
		*registry.npmmirror.com*) printf 'https://registry.npmjs.org' ;;
	esac
}


oc_install_ok() {
	# oc_install_ok <oc-dir> <版本> -> 0 表示这个版本**完整装完过**
	#
	# 「已是该版本就跳过」必须同时满足三个条件：有入口、package.json 是这个版本、
	# 并且装完时写过完成标记。只看 package.json 不够：npm 在替换阶段失败时它
	# 可能已经是新版本，而旁边的依赖还没换完 —— 那种半截状态最需要重装，
	# 却会被「版本一样」放过。没有完成标记就一律当作没装完。
	[ -x "$1/bin/openclaw" ] && [ -f "$1/.oc-install-ok" ] \
		&& [ "$(sed -n '1p' "$1/.oc-install-ok" 2>/dev/null)" = "$2" ] \
		&& [ "$(oc_pkg_version "$1" 2>/dev/null | head -n1)" = "$2" ]
}

oc_tree_untouched() {
	# oc_tree_untouched <目录> <标记文件> -> 0 表示标记创建之后，该目录下**没有任何
	# 文件或目录被创建、修改、删除**。
	#
	# 判据是 mtime：目录里增删条目会更新该目录自己的 mtime，所以「没有任何东西比
	# 标记新」等价于「这段时间这个目录没人动过」。npm 替换包的方式是整目录移走、
	# 移入，父目录的 mtime 一定会变，所以只要它进入了替换阶段就一定查得出来。
	# 取不到结论（目录/标记不存在、find 失败）一律返回非 0：宁可不起网关。
	[ -d "$1" ] && [ -e "$2" ] || return 1
	[ -z "$(find "$1" -newer "$2" 2>/dev/null | head -n 1)" ]
}

npm_registry_has() {
	# npm_registry_has <源> -> 0 表示该源上查得到 openclaw@$OCV
	#
	# 换源之前先确认：镜像可能还没同步这个版本，换过去只会把「网络中断」变成
	# 一个更难懂的 404。查不到就不换，留在原源重试。
	[ -n "$1" ] && [ -n "$OCV" ] || return 1
	oc_timeout 60 "$NODE_BIN" "$npmcli" view "openclaw@$OCV" version \
		--registry "$1" --loglevel=error >/dev/null 2>&1
}

npm_install_retry() {
	# 跑 `npm install -g openclaw@<版本>`，网络类失败自动重试（最多 3 次），
	# 第 3 次换源。
	#
	# 2026-11-26 真机：设备直连 registry.npmjs.org 拉 tarball，两次都在 87 秒
	# 左右被重置（ECONNRESET / network aborted）；同一个版本走 npmmirror 一次
	# 成功。安装器原先一失败就 die，而那时网关已经停了。
	#   第 1 次：配置里的源
	#   第 2 次：还是它（多半只是抖一下，npm 缓存里已下载的部分会复用）
	#   第 3 次：换成另一个源 —— 仅限官方 <-> npmmirror 这两个插件本来就自动二选一
	#           的源，且先确认备用源上查得到这个版本。用户自建的源不替他换。
	# 不重试的情况：超时 / 被 SIGKILL（多半是内存不足）/ 被 SIGTERM 中止 ——
	# 这些都不是「网络抖一下」，再跑一次结果一样；非网络错误同理。
	# 总耗时仍受 NPM_INSTALL_TIMEOUT 约束：算不出剩余时间、或剩余不足 2 分钟，
	# 就不再起新的一轮。
	#
	# 入参取调用方 install_openclaw 作用域里的（POSIX 动态作用域）：
	#   reg npm_log allow_scripts OC_DIR OCV NPM_INSTALL_TIMEOUT NODE_BIN npmcli start_ts
	# 结果经全局变量回传：NPM_RC（最后一次退出码）/ NPM_REG_USED（最终用的源）/
	# NPM_ATTEMPTS（共试了几次）。
	local n_attempt=0 n_reg n_now n_left n_alt n_log n_i
	n_reg="$reg"
	NPM_RC=0
	NPM_ATTEMPTS=0
	while :; do
		n_attempt=$((n_attempt + 1))
		NPM_ATTEMPTS="$n_attempt"
		[ "$n_attempt" -le 1 ] || ilog "npm install 第 $n_attempt 次尝试（源：$n_reg）"
		# 每次尝试单独记日志：判断「这一次为什么失败」时，上一次的报错不能混进来。
		# 全部结束后再并回完整日志（失败时取末尾、成功时找 added 行都看它）。
		n_log="$npm_log.attempt$n_attempt"
		: >"$n_log" 2>/dev/null || n_log="$npm_log"
		set -- install -g --prefix "$OC_DIR" --registry "$n_reg" \
			--no-audit --no-fund --loglevel=http --prefer-online \
			--fetch-retries=4 --fetch-retry-mintimeout=2000 --fetch-retry-maxtimeout=60000
		[ -n "$allow_scripts" ] && set -- "$@" "$allow_scripts"
		set -- "$@" "openclaw@$OCV"
		run_with_heartbeat "npm install" -- \
			run_with_timeout "$NPM_INSTALL_TIMEOUT" "$NODE_BIN" "$npmcli" "$@" \
			>>"$n_log" 2>&1
		NPM_RC=$?
		[ "$NPM_RC" -eq 0 ] && break
		[ "$n_attempt" -lt 3 ] || break
		# 124 = 超时包装器返回；137 = 被 SIGKILL；143 = 被 SIGTERM。后两个在
		# 没有 timeout 命令的设备上分别是「被杀」和「被中止」，都不该重试。
		case "$NPM_RC" in 124|137|143) break ;; esac
		npm_net_fail "$n_log" || break
		n_now="$(date +%s 2>/dev/null)"
		# start_ts 取不到时被置成了 0：拿它算出来的「剩余时间」是个巨大的负数，
		# 看起来像「时间用完」，其实只是没开始计时。算不出来就不重试，并说明原因。
		case "$start_ts" in ''|*[!0-9]*|0) n_now="" ;; esac
		case "$n_now" in
			''|*[!0-9]*) ilog "无法计算剩余时间，不再重试 npm install"; break ;;
		esac
		n_left=$((NPM_INSTALL_TIMEOUT - (n_now - start_ts)))
		[ "$n_left" -ge 120 ] || { ilog "剩余时间不足（${n_left}s），不再重试"; break; }
		if [ "$n_attempt" -eq 1 ]; then
			ilog "npm install 第 1 次因网络中断失败，5 秒后用同一个源重试"
		else
			n_alt="$(npm_alt_registry "$n_reg")"
			if [ -n "$n_alt" ] && npm_registry_has "$n_alt"; then
				ilog "同一个源连续 2 次网络中断，换源重试：$n_reg → $n_alt"
				n_reg="$n_alt"
			else
				ilog "同一个源连续 2 次网络中断，再重试一次（无可用的备用源）"
			fi
		fi
		sleep 5
	done
	n_i=1
	while [ "$n_i" -le "$n_attempt" ] && [ -f "$npm_log.attempt$n_i" ]; do
		cat "$npm_log.attempt$n_i" >>"$npm_log"
		rm -f "$npm_log.attempt$n_i"
		n_i=$((n_i + 1))
	done
	NPM_REG_USED="$n_reg"
}

# ---------------------------------------------------------------- openclaw
install_openclaw() {
	ilog "== 安装 OpenClaw $OCV（官方 npm 包） =="
	local reg npmcache npmcli npm_log rc start_ts end_ts elapsed added timed_out
	local npm_ver npm_major npm_minor allow_scripts _cur_ver _want_ver
	local _gw_pids _i
	# _cur_ver 是本函数的 local；die() 由本函数调用，POSIX 的动态作用域让它看得到。
	# die_old_ver 在 die() 里赋值，故意不加 local（加了 die 自己也读不到）。
	local _cls _pre_conf _pre_bak _reg _alt _left _now npm_attempt _old
	# 优先用「取版本列表时实际成功的那个源」。
	# 只记 official/mirror 是不够的：安装阶段要重新推断 URL，推断结果一旦
	# 与取列表时不同，就会出现"列表里有这个版本、npm 说没有"。
	# 有记录就用记录里的；没有（用户手工指定了 main.npm_registry）就用配置值。
	reg="$(oc_source_url_saved 2>/dev/null)"
	[ -n "$reg" ] || reg="$(npm_registry)"
	if [ "$reg" != "$(npm_registry)" ]; then
		ilog "使用取版本列表时成功的源：$reg（配置值 $(npm_registry) 本次未采用）"
	fi
	npmcache="$BASE_DIR/npm-cache"
	npmcli="$NODE_DIR/lib/node_modules/npm/bin/npm-cli.js"
	[ -f "$npmcli" ] || npmcli="$(dirname "$NPM_BIN")/../lib/node_modules/npm/bin/npm-cli.js"
	if [ ! -f "$npmcli" ]; then
		npmcli="$(find "$NODE_DIR" -name npm-cli.js 2>/dev/null | head -n1)"
	fi
	[ -n "$npmcli" ] || die "未找到 npm-cli.js"

	mkdir -p "$OC_DIR" "$npmcache" "$HOME_DIR"
	export PATH="$NODE_DIR/bin:$PATH"
	export HOME="$HOME_DIR"
	export npm_config_cache="$npmcache"
	# 不要设 npm_config_tmp：npm 11+ 已移除该配置项，只会刷
	# `npm warn Unknown env config "tmp"`，对实际行为没有影响。
	# 临时目录用 TMPDIR 表达（npm 与 node 都认）。
	export TMPDIR="$OC_DL"
	export npm_config_prefix="$OC_DIR"

	# ---- 已经是要装的版本就跳过（用户明确要求：已安装的不要重装）------
	# 版本相同再跑一遍 npm install 的唯一效果是：停一次网关、下载几百 MB、
	# 重写 node_modules，最后什么都没变。用户点"升级"时如果已经是最新，
	# 这里应当立刻返回，而不是让他等几分钟。
	# 注意：只用 main.oc_version 不可靠（手工装过、或被改过），
	# 以**程序自己报的版本**为准。
	# 当前版本以 npm 包自带的 package.json 为准。原先读 `openclaw --version`，
	# 而它的输出是「OpenClaw 2026.11.10 (6ea542f)」这样带前缀和提交号的整行，
	# 跟目标版本比**永远不相等** —— 「已是该版本就跳过」从来没生效过，同版本
	# 再点一次升级照样停网关、重下几百 MB（2026-11-26 真机实测）。
	# 原值可能带 -beta.1 之类后缀：要保留，否则 beta 与正式版会被当成同一个。
	_cur_ver=""
	if [ -x "$OC_DIR/bin/openclaw" ]; then
		_cur_ver="$(oc_pkg_version "$OC_DIR" 2>/dev/null | head -n1)"
		[ -n "$_cur_ver" ] || _cur_ver="$(oc_installed_version "$OC_DIR" 2>/dev/null | head -n1)"
		[ -n "$_cur_ver" ] || _cur_ver="$(oc_ver_norm "$(HOME="$HOME_DIR" PATH="$NODE_DIR/bin:$OC_DIR/bin:$PATH" \
			oc_timeout 20 "$OC_DIR/bin/openclaw" --version 2>/dev/null | head -n1)")"
	fi
	_want_ver="$(printf '%s' "$OCV" | sed 's/^[vV]//')"
	# 跳过还要有「装完」的证据（oc_install_ok）：上次装到一半失败时 package.json
	# 可能已经是这个版本，那种半截状态恰恰最需要重装。
	if [ "$FORCE" != "1" ] && oc_install_ok "$OC_DIR" "$_want_ver"; then
		ilog "OpenClaw 已是 $_cur_ver，跳过 npm install（如需强制重装请在设置页勾选强制）"
		return 0
	fi
	[ -n "$_cur_ver" ] && [ "$_cur_ver" != "$_want_ver" ] && \
		ilog "当前 OpenClaw $_cur_ver → 目标 $_want_ver，开始升级"

	# ---- 按升级跨度选策略 ----------------------------------------------
	# 全新安装 / 同版本 / 同月补丁 / 跨月 / 降级，各自要做的事不同。
	if [ -z "$_cur_ver" ]; then
		_cls="fresh"
	else
		_cls="$(oc_upgrade_class "$_cur_ver" "$_want_ver")"
	fi
	case "$_cls" in
		fresh)
			ilog "升级策略：全新安装 $_want_ver" ;;
		same)
			if [ "$FORCE" = "1" ]; then
				ilog "升级策略：同版本重装（$_cur_ver，已勾选强制）"
			else
				# 走到这里说明没有完成标记：多半是更早的插件版本装的。
				ilog "升级策略：同版本 $_cur_ver，但没有上次完整装完的记录，重装一次并记录（之后同版本会直接跳过）"
			fi ;;
		patch)
			ilog "升级策略：同月补丁升级（$_cur_ver → $_want_ver），配置格式不变；失败时原版本不受影响" ;;
		minor|unknown|prerelease)
			[ "$_cls" = "prerelease" ] && \
				ilog "注意：要从正式版换到预发布版（$_cur_ver → $_want_ver），状态库可能被预发布版迁移，换回正式版时需要强制"
			ilog "升级策略：跨月升级（$_cur_ver → $_want_ver），升级前先备份配置，装完由 doctor 迁移并校验"
			_pre_conf="$HOME_DIR/.openclaw/openclaw.json"
			if [ -f "$_pre_conf" ]; then
				# 文件名带上 pid：同一秒内重复触发也不会互相覆盖。
				_pre_bak="$_pre_conf.pre-upgrade-$(printf '%s' "${_cur_ver:-unknown}" | tr -c 'A-Za-z0-9._-' '_').$(date +%Y%m%d%H%M%S 2>/dev/null).$$"
				if cp "$_pre_conf" "$_pre_bak" 2>/dev/null; then
					# 里面有网关 token 与模型凭据：不能按 umask 落成全局可读。
					# 收紧权限失败就删掉这份副本，并且说出来 —— 留下一份全局可读的
					# 凭据副本而不自知，比没有备份更糟。
					if chmod 600 "$_pre_bak" 2>/dev/null; then
						ilog "已备份升级前的配置：$_pre_bak"
					else
						rm -f "$_pre_bak" 2>/dev/null
						ilog "WARN: 配置备份无法收紧为 600，已删除该副本；升级前请手动备份 $_pre_conf"
					fi
				else
					ilog "WARN: 升级前备份配置失败（继续安装；doctor 也会另存 openclaw.json.bak）"
				fi
				# 只留最近 3 份，跨月升级多了也不会无限累积。
				for _old in $(ls -1t "$HOME_DIR/.openclaw/"openclaw.json.pre-upgrade-* 2>/dev/null | tail -n +4); do
					rm -f "$HOME_DIR/.openclaw/$_old" 2>/dev/null
				done
			fi ;;
		downgrade)
			if [ "$FORCE" != "1" ]; then
				die "目标版本 $_want_ver 低于当前已安装的 $_cur_ver，已拒绝降级：OpenClaw 的共享状态库只升不降，降级后旧版网关可能起不来。如确需降级，请先备份 $HOME_DIR/.openclaw，再到设置页勾选「强制重装」"
			fi
			ilog "WARN: 降级 $_cur_ver → $_want_ver（已勾选强制）；状态库若已被新版迁移，旧版可能无法启动" ;;
	esac

	# ---- 覆盖安装前必须先停服务 ----------------------------------------
	# 整份脚本原先没有一处 init.d stop，直接在运行中的网关脚下替换
	# node_modules：旧进程继续持有已被 unlink 的模块句柄，新版本不生效
	# （UI 却显示"已安装"），native .node 被替换/截断还可能导致段错误。
	# procd 的 start 对已运行的实例是空操作，所以收尾也必须用 restart。
	# 判据是**进程表**，不是 `init.d ... running`：
	# 后者走 rc.common → procd_running → `ubus call service list`，而某些
	# iStoreOS 构建上 ubus 根本没有 service 对象（实测 `ubus call service
	# list` 返回 Not found），于是 running 恒为"未运行"—— 连一个不存在的
	# 子命令都返回 0，这个分发完全不可信。用进程表是唯一可靠的判据。
	_gw_pids="$(oc_gateway_pids 2>/dev/null)"
	if [ -n "$_gw_pids" ]; then
		ilog "检测到网关正在运行（pid: $(printf '%s' "$_gw_pids" | tr '\n' ' ')），先停止再覆盖安装"
		[ -x /etc/init.d/openclaw ] && /etc/init.d/openclaw stop >/dev/null 2>&1
		# 记下来：npm 没装成功就退出时，die() 要把原版本重新拉起来。
		OC_GW_WAS_RUNNING=1
		# 等进程真的退出（最多 40 秒）：procd 的 stop 是异步的，
		# 立刻 npm install 仍会与正在退出的进程抢同一批文件。
		_i=0
		while [ -n "$(oc_gateway_pids 2>/dev/null)" ] && [ "$_i" -lt 40 ]; do
			sleep 1
			_i=$((_i + 1))
		done
		if [ -n "$(oc_gateway_pids 2>/dev/null)" ]; then
			ilog "WARN: 进程未在 40s 内退出，强制清理"
			# oc_kill_tree 现在先 TERM 再 KILL，并返回"是否真的清空了"。
			# 没清空就继续 npm install，等于在活进程脚下改 node_modules ——
			# 正是这次要修的问题本身。所以这里必须检查返回值并中止。
			if ! oc_kill_tree; then
				die "仍有网关进程无法终止，已中止安装（在运行中的进程上覆盖 node_modules 会损坏安装）。请手动检查后重试：ps | grep openclaw"
			fi
		fi
	fi

	# ---- 按 npm 版本决定是否传 --allow-scripts（官方文档要求）----------
	# npm 12 默认**阻止**未批准的 package lifecycle scripts，OpenClaw 的
	# preinstall / postinstall 正是这类脚本；不显式批准会被 blocked，
	# 表现为"装完了但运行不正常"。而 npm <=11.15 根本没有这个选项，
	# 带了会让 npm 直接报错。所以只能探测版本后再决定：
	#   npm >= 12        → 必须加 --allow-scripts=openclaw
	#   npm 11.16        → 接受该选项（仅警告），脚本仍会执行 → 加上更稳
	#   npm <= 11.15     → 绝不能加
	npm_ver=""
	if [ -n "$npmcli" ] && [ -f "$npmcli" ]; then
		npm_ver="$("$NODE_BIN" "$npmcli" --version 2>/dev/null | head -n1)"
	fi
	# npm --version 正常输出 "11.6.2"，但个别包装脚本会带 v 前缀；先剥掉。
	npm_ver="${npm_ver#v}"
	npm_major=""
	case "$npm_ver" in
		[0-9]*) npm_major="${npm_ver%%.*}" ;;
	esac
	case "$npm_major" in ''|*[!0-9]*) npm_major=0 ;; esac

	allow_scripts=""
	if [ "$npm_major" -ge 12 ]; then
		allow_scripts="--allow-scripts=openclaw"
	elif [ "$npm_major" -eq 11 ]; then
		npm_minor="${npm_ver#*.}"; npm_minor="${npm_minor%%.*}"
		case "$npm_minor" in ''|*[!0-9]*) npm_minor=0 ;; esac
		[ "$npm_minor" -ge 16 ] && allow_scripts="--allow-scripts=openclaw"
	fi

	# sharp 的原生二进制：官方安装器默认 SHARP_IGNORE_GLOBAL_LIBVIPS=1，
	# 避免它在路由器上尝试对系统 libvips 做原生构建（必然失败或极慢）。
	# 我们跟随官方默认值。
	SHARP_IGNORE_GLOBAL_LIBVIPS=1
	export SHARP_IGNORE_GLOBAL_LIBVIPS

	if [ -n "$allow_scripts" ]; then
		ilog "npm 版本 ${npm_ver:-未知}：使用 $allow_scripts（npm 12 起必须显式批准生命周期脚本）"
	else
		ilog "npm 版本 ${npm_ver:-未知}：不传 --allow-scripts（该版本不支持此选项）"
	fi
	ilog "npm install -g openclaw@$OCV  (registry=$reg)"
	# npm 的输出写到独立文件：$OC_INSTALLLOG 由 ilog 的 tee -a 追加，
	# 两个写入者（外加调用方的 stdout 重定向）同时写一个文件会产生半截行。
	# NOTE: piping through tee would swallow npm's exit status (we would only
	# ever see tee's 0), so the rc below is captured directly.
	npm_log="$OC_INSTALLLOG.npm"
	: >"$npm_log" 2>/dev/null || die "无法创建 npm 日志：$npm_log"

	if command -v timeout >/dev/null 2>&1; then
		ilog "npm install 开始（$(date '+%Y-%m-%d %H:%M:%S')，超时 ${NPM_INSTALL_TIMEOUT}s）"
	else
		ilog "npm install 开始（$(date '+%Y-%m-%d %H:%M:%S')）"
		ilog "WARN: 未找到 timeout 命令，本次 npm install 不设超时上限，卡住时只能手动终止"
	fi
	start_ts="$(date +%s 2>/dev/null)"
	case "$start_ts" in ''|*[!0-9]*) start_ts=0 ;; esac

	# npm 的输出只进独立日志，主日志在整段安装期间不会自己增长；
	# 心跳是"还在干活"的唯一可见证据，命令结束（含被 timeout 杀掉）后立刻收掉。
	# 用 set -- 组装参数：allow_scripts 可能为空，直接拼字符串会留下多余空格，
	# 而这里每一个选项都必须原样传给 npm。
	# 网络类失败自动重试并换源，见 npm_install_retry（结果经 NPM_RC / NPM_REG_USED /
	# NPM_ATTEMPTS 回传）。
	# 「安装树没被碰过」的参照物：npm 失败后 die() 靠它判断原程序是否完好。
	# 放在 npm 缓存目录（不在程序目录里），npm 自己不会去动它。
	OC_UPGRADE_MARKER="$npmcache/.upgrade-marker.$$"
	if : >"$OC_UPGRADE_MARKER" 2>/dev/null; then
		# mtime 是有精度的：ext4 是纳秒，但有些文件系统只有 1 秒甚至 2 秒。
		# 标记与 npm 随后的写入若落在同一个精度单位里，-newer 分不出先后。
		# 等 3 秒把 2 秒精度的情况也盖住（多等这几秒无伤大雅）。
		sleep 3
	else
		OC_UPGRADE_MARKER=""
		ilog "WARN: 无法创建升级标记（$npmcache），升级失败时将不会自动重启网关"
	fi
	OC_PRE_UPGRADE_VER="$_cur_ver"
	# 从这里开始 npm 可能改动程序目录：之前的「装完」标记作废，装完再写。
	rm -f "$OC_DIR/.oc-install-ok" 2>/dev/null
	# npm 期间收到 TERM/HUP/INT 也要走 die()：否则安装脚本直接没了，网关停在
	# 「已停止」且没人把它拉起来。npm 结束（成功）后恢复默认处置。
	trap 'die "安装被信号中止（npm install 未完成）"' TERM HUP INT
	npm_install_retry
	rc="$NPM_RC"
	_reg="$NPM_REG_USED"
	npm_attempt="$NPM_ATTEMPTS"

	end_ts="$(date +%s 2>/dev/null)"
	case "$end_ts" in ''|*[!0-9]*) end_ts=0 ;; esac
	elapsed=0
	if [ "$start_ts" -gt 0 ] && [ "$end_ts" -ge "$start_ts" ]; then
		elapsed=$((end_ts - start_ts))
	fi

	# GNU timeout 超时返回 124；busybox 用 SIGTERM 收尾、返回 143。
	# 143 只有在耗时确实到达上限时才当超时，避免把外部 SIGTERM 误报成超时。
	timed_out=0
	if [ "$rc" -eq 124 ]; then
		timed_out=1
	elif [ "$rc" -eq 143 ] && command -v timeout >/dev/null 2>&1 \
		&& [ "$elapsed" -ge "$((NPM_INSTALL_TIMEOUT - 5))" ]; then
		timed_out=1
	fi

	if [ "$rc" -eq 0 ]; then
		# 新版本已经就位：之后的失败不再走 die() 的「恢复原版本」分支。
		OC_GW_WAS_RUNNING=0
		trap - TERM HUP INT
		case "${OC_UPGRADE_MARKER:-}" in ?*) rm -f "$OC_UPGRADE_MARKER" 2>/dev/null ;; esac
		OC_UPGRADE_MARKER=""
		ilog "npm install 完成（$(date '+%Y-%m-%d %H:%M:%S')，耗时 ${elapsed}s）"
		if [ "$_reg" != "$reg" ]; then
			ilog "注意：本次是换源后装成功的（$_reg，共 $npm_attempt 次）。设置里的 npm 源（$reg）在当前网络下不稳，可到设置页改成 $_reg"
		elif [ "$npm_attempt" -gt 1 ]; then
			ilog "注意：本次重试 $npm_attempt 次才成功，当前网络到 $_reg 不太稳定"
		fi
		# 汇总行单独提出来：确认真的出现了 added N packages，而不是中途静默结束。
		added="$(grep -E '^added [0-9]+ packages?' "$npm_log" 2>/dev/null | tail -n 1)"
		if [ -n "$added" ]; then ilog "npm: $added"; fi
	elif [ "$timed_out" -eq 1 ]; then
		ilog "npm install 超时（${NPM_INSTALL_TIMEOUT} 秒，退出码 $rc，耗时 ${elapsed}s，$(date '+%Y-%m-%d %H:%M:%S')）"
		append_tail "$npm_log" 40 "npm 日志"
		die "npm install 超时（${NPM_INSTALL_TIMEOUT} 秒）。可调大 NPM_INSTALL_TIMEOUT（环境变量或 UCI main.npm_install_timeout），或更换镜像源（npm_registry）后重试。npm 日志：$npm_log"
	elif [ "$rc" -eq 137 ]; then
		ilog "npm install 被 SIGKILL 终止（退出码 137，耗时 ${elapsed}s，$(date '+%Y-%m-%d %H:%M:%S')），可能因内存不足被 OOM killer 杀掉"
		append_tail "$npm_log" 40 "npm 日志"
		die "npm install 被强制终止（退出码 137）。请检查可用内存（free -m）后重试。npm 日志：$npm_log"
	else
		ilog "npm install 失败（退出码 $rc，耗时 ${elapsed}s，$(date '+%Y-%m-%d %H:%M:%S')）"
		append_tail "$npm_log" 40 "npm 日志"
		die "npm install 失败（退出码 $rc，完整日志：$npm_log）"
	fi

	if [ ! -x "$OC_DIR/bin/openclaw" ]; then
		# some layouts place the shim elsewhere: build a proper wrapper script
		# instead of symlinking the .mjs - a bare .mjs has no node shebang and
		# would only work by accident
		target="$(find "$OC_DIR/lib/node_modules/openclaw" -name 'openclaw.mjs' -o -name 'openclaw.js' 2>/dev/null | head -n1)"
		if [ -n "$target" ]; then
			mkdir -p "$OC_DIR/bin"
			cat >"$OC_DIR/bin/openclaw" <<EOF
#!/bin/sh
exec "$NODE_BIN" "$target" "\$@"
EOF
			chmod +x "$OC_DIR/bin/openclaw"
		fi
	fi
	[ -x "$OC_DIR/bin/openclaw" ] || die "OpenClaw 安装失败：未生成可执行文件"
	# 装完了才写完成标记（下一次「同版本跳过」要求它在，见 oc_install_ok）。
	printf '%s\n' "$_want_ver" >"$OC_DIR/.oc-install-ok" 2>/dev/null \
		|| ilog "WARN: 无法写入安装完成标记（$OC_DIR/.oc-install-ok），下次点同版本会重装一次"
	ilog "OpenClaw 就绪: $("$OC_DIR/bin/openclaw" --version 2>/dev/null || echo unknown)"
}

# ---------------------------------------------------------------- bootstrap
oc_cli() {
	# 安装期调用 openclaw CLI 的唯一入口：**一律以网关用户执行**。
	#
	# root 跑会用到 <cache>/openclaw-0，而 oc_fix_perms 已经把整个 base 目录
	# 交给网关用户，于是 root 侧被 OpenClaw 的临时目录校验拒绝（
	# "Unsafe fallback OpenClaw temp dir ... expected uid 0"）。更糟的是
	# bootstrap_config 里的 config set 全都重定向到了 /dev/null，失败是静默的
	# ——网关端口/绑定/token 根本写不进去，页面却显示安装成功。
	oc_as_user env HOME="$HOME_DIR" TMPDIR="$BASE_DIR/tmp" \
		PATH="$NODE_DIR/bin:$OC_DIR/bin:$PATH" "$OC_DIR/bin/openclaw" "$@"
}

bootstrap_config() {
	ilog "== 初始化配置 =="
	oc_ensure_user || ilog "WARN: 未创建系统用户 $OC_USER，将以 root 运行"
	mkdir -p "$HOME_DIR/.openclaw" "$BASE_DIR/workspace" "$BASE_DIR/logs"
	oc_fix_perms

	local port bind conf token _cur
	port="$(uci_get main.port 18789)"
	bind="$(uci_get main.bind lan)"
	# bind lands in openclaw.json verbatim; keep it to a safe character set
	case "$bind" in *[!A-Za-z0-9_.:-]* ) bind="lan" ;; esac
	conf="$HOME_DIR/.openclaw/openclaw.json"

	export HOME="$HOME_DIR"
	export PATH="$NODE_DIR/bin:$OC_DIR/bin:$PATH"
	local OC="$OC_DIR/bin/openclaw"

	if [ ! -f "$conf" ]; then
		ilog "生成初始配置"
		oc_cli onboard --non-interactive --mode local --skip-health --accept-risk \
			--skip-channels >/dev/null 2>&1 || ilog "WARN: onboard 未完全成功，将写入最小配置"
	fi
	if [ ! -f "$conf" ]; then
		token="$(oc_rand_hex)"
		# 宁可中止安装，也不用空 token 或弱随机值初始化配置。
		[ -n "$token" ] || { ilog "ERROR: 无法生成安全网关 token（随机源不可用），已中止配置初始化"; return 1; }
		# 不要在这里添加 allowInsecureAuth / dangerouslyDisableDeviceAuth /
		# dangerouslyAllowHostHeaderOriginFallback：2026.10 起这三个键已被删除，
		# 写入任意一个都会让整份配置判为无效（Unrecognized key），网关拒绝启动。
		cat >"$conf" <<EOF
{
  "gateway": {
    "port": $port,
    "bind": "$bind",
    "auth": { "mode": "token", "token": "$token" },
    "controlUi": { "enabled": true, "allowedOrigins": [] }
  }
}
EOF
	fi

	# 写入失败要说出来：这里是端口/绑定/凭据的落盘点，静默失败会让页面
	# 显示安装成功但网关仍用旧值（或根本没有 token）。
	oc_cli config set gateway.port "$port" >/dev/null 2>&1 \
		|| ilog "WARN: 写入 gateway.port 失败（$port）"
	oc_cli config set gateway.bind "$bind" >/dev/null 2>&1 \
		|| ilog "WARN: 写入 gateway.bind 失败（$bind）"
	# 凭据存在性走 lib.sh 的唯一判定。
	# 旧写法 `grep -q '"token"'` 有两个问题：`"mode": "token"` 也会命中，
	# 且无法区分 SecretRef 与明文 —— 一旦判成"没有"，就会用新明文覆盖掉
	# 用户已配好的 SecretRef，把凭据重新落成 plaintext。
	if command -v oc_credential_state >/dev/null 2>&1; then
		oc_credential_state "$conf"
		if [ "$OC_CRED_STATE" = "MISSING" ]; then
			token="$(oc_rand_hex)"
			[ -n "$token" ] || { ilog "ERROR: 无法生成安全网关 token，已中止配置初始化"; return 1; }
			oc_cli config set gateway.auth.mode token >/dev/null 2>&1
			oc_cli config set gateway.auth.token "$token" >/dev/null 2>&1
			ilog "已生成网关 token（原本缺失）"
		else
			ilog "保留已有网关凭据（$OC_CRED_STATE）"
		fi
	else
		# 兜底：没有 lib 函数时退回最保守的判断 —— 只有确实找不到
		# auth.token 键才补，避免覆盖 SecretRef。
		if ! grep -q '"auth"' "$conf" 2>/dev/null; then
			token="$(oc_rand_hex)"
			# 宁可中止，也不用空 token 或弱随机值补凭据。
			[ -n "$token" ] || { ilog "ERROR: 无法生成安全网关 token（随机源不可用），已中止凭据补齐"; return 1; }
			oc_cli config set gateway.auth.mode token >/dev/null 2>&1
			oc_cli config set gateway.auth.token "$token" >/dev/null 2>&1
		fi
	fi

	# 复用的本机配置可能带着较早版本写入的、2026.10 已删除的
	# gateway.controlUi.* 键；只要残留一个，整份配置就判为无效、网关拒绝启动。
	# 显式传 $conf / $OC_DIR / $NODE_BIN：本次安装可能用 --base-dir 或
	# --openclaw-dir 装到与 UCI 不同的目录，不能让函数去猜。
	oc_purge_legacy_controlui "$conf" "$OC_DIR" "$NODE_BIN"
	if [ "${OC_LEGACY_CONTROLUI_REMOVED:-0}" -gt 0 ] 2>/dev/null; then
		ilog "已移除 ${OC_LEGACY_CONTROLUI_REMOVED} 个 2026.10 不再支持的配置键（gateway.controlUi.*，较早版本写入）"
	fi

	# 关掉 OpenClaw 自带的 npm 自更新（幂等）。
	# 这套布局里它不可能成功：安装树由插件安装、属主是网关用户，网关没有
	# 系统 npm 前缀的写权限。真机日志是
	#   Gateway restart update skipped (npm): update restart sentinel
	#   remained pending after retry window
	# —— 每次重启/升级都留一条错误，用户以为插件坏了。
	# 更新由插件自己走 GitHub Release（页面「更新」），因此这里固定关掉。
	_cur="$(oc_cli config get update.auto.enabled 2>/dev/null | sed -n '1p' | tr -d '\r')"
	case "$_cur" in
		*false*) : ;;
		*)
			if oc_cli config set update.auto.enabled false >/dev/null 2>&1; then
				ilog "已关闭 OpenClaw 自带的 npm 自更新（更新统一由插件负责）"
			else
				ilog "WARN: 无法关闭 OpenClaw 自更新（update.auto.enabled），重启后可能再报更新失败"
			fi
			;;
	esac
	oc_fix_perms
	ilog "配置文件: $conf"
}

install_default_providers() {
	# DeepSeek ships as an official plugin; zai (Z.AI/GLM) is bundled upstream.
	local OC="$OC_DIR/bin/openclaw"
	local pre
	pre="$(uci_get main.preinstall_providers '')"
	if [ -z "$pre" ]; then
		ilog "未配置预装模型插件（main.preinstall_providers 为空），跳过"
		return 0
	fi
	export HOME="$HOME_DIR"
	export PATH="$NODE_DIR/bin:$OC_DIR/bin:$PATH"
	ilog "== 预装模型插件: $pre =="
	case "$pre" in
		*deepseek*)
			# NOTE: never pipe this through `head`. `tee ... | head -n 20`
			# closes the pipe after 20 lines, the writer takes SIGPIPE and the
			# plugin install is cut off mid-way while still reporting success.
			# 同 doctor：以网关用户执行，避免 openclaw-<uid> 临时目录属主冲突。
			if oc_as_user env HOME="$HOME_DIR" TMPDIR="$BASE_DIR/tmp" \
				PATH="$NODE_DIR/bin:$OC_DIR/bin:$PATH" \
				"$OC" plugins install @openclaw/deepseek-provider >>"$OC_INSTALLLOG" 2>&1; then
				ilog "DeepSeek 插件安装完成"
			else
				ilog "WARN: DeepSeek 插件安装失败（可稍后在模型页重试）"
			fi
			;;
	esac
}

# ---------------------------------------------------------------- autostart
# 安装成功后的自动启动。
#
# 关键点：init.d 的 start_service() 第一件事就是读 main.enabled，为 0 时直接
# `return 0`（既不启动也不报错）。安装流程原来从不置 1，所以收尾那句
# `restart` 一直是静默空转 —— 这就是"装完还得再点一次启动"的根因。
# 自动启动时一并把 main.enabled 置 1。
svc_running() {
	# 与 openclaw/cli.sh 的 running() 同一语义，但用 lib.sh 的精确探测：
	# `pgrep -f 'openclaw.*(gateway|run)'` 会误命中编辑器 / tail -f / grep。
	[ -n "$(oc_gateway_pids 2>/dev/null)" ] && return 0
	[ -f /var/run/openclaw.pid ] && \
		kill -0 "$(cat /var/run/openclaw.pid 2>/dev/null)" 2>/dev/null && return 0
	return 1
}

svc_wait_running() {
	# 等网关真的可用，不只是"进程存在"。
	#
	# 原来等 15 秒 —— 而这台机器的实测冷启动是 28s，历史上有过 60-90s。
	# 于是安装日志一稳定写「WARN: 服务启动失败」，用户照提示去点「一键修复」，
	# 实际服务只是还在初始化。这里改成：
	#   1) 先等进程出现（procd 的 start 异步返回，进程可能要几秒才 fork 出来）
	#   2) 再等端口能应答（curl 200 才算"起来了"）
	# 上限 120 秒，期间每秒探一次；超过上限返回失败。
	local i=0 port
	port="$(uci_get main.port 18789)"
	case "$port" in ''|*[!0-9]*) port=18789 ;; esac

	while [ "$i" -lt 120 ]; do
		if svc_running; then
			# 进程有了，再看端口。网关初始化要几十秒，这里不再额外加超时，
			# 由外层 120 秒总上限兜住。
			if command -v curl >/dev/null 2>&1; then
				if curl -s -o /dev/null --connect-timeout 1 --max-time 2 \
					-w '%{http_code}' "http://127.0.0.1:${port}/" 2>/dev/null \
					| grep -qE '^[23]'; then   # 2xx/3xx 都算应答；连不上时 curl 输出 000
					return 0
				fi
			else
				# 没有 curl：无法验端口。退一步 —— 等 5 秒后**再确认进程还活着**。
				# 单纯 sleep 5 后 return 0 只是把"刚 fork 就算起来"推迟了 5 秒：
				# 网关在初始化阶段崩溃时仍会报"已启动"。
				# 这里至少能排除"起来后又退了"这种最常见的失败。
				sleep 5
				if svc_running; then
					return 0
				fi
				# 进程没了 → 不返回，交给外层循环继续等（直到 120 秒上限）。
			fi
		fi
		sleep 1
		i=$((i + 1))
	done
	return 1
}

autostart_service() {
	# 只在安装全部成功时调用（finish 的末尾）。任何失败都只告警：
	# 安装本身已经成功，这里的退出码必须保持 0。
	local auto _n _deep
	if [ "$NO_START" = "1" ]; then
		ilog "已跳过自动启动（--no-start）"
		return 0
	fi
	auto="$(uci_get main.auto_start 1)"
	[ -n "$auto" ] || auto=1
	case "$auto" in
		0)
			ilog "已跳过自动启动（main.auto_start=0）"
			;;
		*)
			ilog "设置开机自启（/etc/init.d/openclaw enable）"
			/etc/init.d/openclaw enable >/dev/null 2>&1 \
				|| ilog "WARN: 开机自启设置失败（不影响安装，可在状态页手动处理）"
			uci_set main.enabled 1
			uci_commit
			# 用 restart 而不是 start：start 对 procd 里已注册的实例是空操作，
			# 而上面刚 stop 过 —— 只有 restart 能保证装完真的起来。
			# 必须 stop → start，不能用 restart。procd 的 restart 只是给
			# **已注册**的实例发信号，不会重读 initscript；而这次升级换掉了
			# init.d 里的 limits / env / respawn。用 restart 的话新脚本
			# 根本没被解析，改了等于没改（实测：init.d 已含 SecretRef 守卫，
			# 但进程 environ 里仍是旧的 token JSON，limits 也还是旧的）。
			ilog "停止后重新启动服务（stop → start，各最多 150s）"
			oc_timeout 150 /etc/init.d/openclaw stop >/dev/null 2>&1
			# 等进程真的退出：procd 的 stop 是异步的，立刻 start 会撞端口
			_n=0
			while [ -n "$(oc_gateway_pids 2>/dev/null)" ] && [ "$_n" -lt 40 ]; do
				sleep 1
				_n=$((_n + 1))
			done
			oc_timeout 150 /etc/init.d/openclaw start >/dev/null 2>&1
			if svc_wait_running; then
				ilog "服务已启动"
				# 官方升级流程的最后一步：`openclaw gateway status --deep`
				# 端口通只说明进程在听，不说明网关自己认为健康（插件加载失败、
				# schema 未迁移完都可能仍然监听）。这一步把结论记进日志。
				_deep="$(oc_as_user env HOME="$HOME_DIR" TMPDIR="$BASE_DIR/tmp" \
					PATH="$NODE_DIR/bin:$OC_DIR/bin:$PATH" \
					"$OC_DIR/bin/openclaw" gateway status --deep 2>&1)"
				if [ -n "$_deep" ]; then
					printf '%s\n' "$_deep" | tail -n 10 | while IFS= read -r _l; do
						[ -n "$_l" ] && ilog "  status| $_l"
					done
				fi
			else
				ilog "WARN: 服务启动失败，请到状态页查看日志或点「一键修复」"
			fi
			;;
	esac
	return 0
}

finish() {
	ilog "== 收尾 =="
	uci_set main.base_dir "$BASE_DIR"
	uci_set main.installed 1
	uci_set main.oc_version "$OCV"
	uci_set main.node_version "$NODE_V"
	uci_set main.node_mode "$NODE_MODE"
	uci_commit
	chmod +x /etc/init.d/openclaw 2>/dev/null
	autostart_service
	# 临时根与残留：装完立刻做一次，之后每次服务启动也会做（/tmp 是 tmpfs）。
	oc_pin_system_tmp_root
	oc_sweep_stale_tmp

	# 收尾再清一次 SQLite 只读快照：本次升级的 doctor / 迁移过程本身也会
	# 产生若干个（每个是整库副本）。不留在磁盘上，下次升级就不会因为空间
	# 不足而失败。这里连"最新 1 个"也不保留 —— 安装结束时没有读者在用它们。
	_cleaned2="$(oc_clean_sqlite_snapshots 0 60)"
	case "$_cleaned2" in ''|*[!0-9]*) _cleaned2=0 ;; esac
	[ "$_cleaned2" -gt 0 ] && ilog "收尾清理只读快照：$_cleaned2 个"

	# 以**服务用户身份**验证核心路径可访问。这是唯一可信的判据 ——
	# root 视角看不出服务用户能否读写。失败即判安装失败：
	# 与其"装完了但网关 EACCES 起不来"，不如装不上并说清原因。
	if command -v oc_probe_user_access >/dev/null 2>&1; then
		if oc_probe_user_access "$(oc_state_dir)"; then
			ilog "权限自检通过：服务用户可写 $(oc_state_dir)"
		else
			die "权限自检失败：服务用户无法写入 $(oc_state_dir)。请执行 /usr/libexec/openclaw/repair.sh owner-fix 后重试"
		fi
	fi

	# 安装树属主自检：OpenClaw 自更新（openclaw update）的 admission 校验
	# 安装树属主必须等于网关用户。失败只 WARN 不 die —— 安装本身已成功，
	# 属主错误只影响自更新功能（2026-11-04 教训：功能路径上的检查必须
	# fail-open，拿不到判据或修不动时放行 + 告警，不拦截交付）。
	if command -v oc_fix_install_owner >/dev/null 2>&1; then
		if oc_fix_install_owner; then
			ilog "安装树属主自检通过：$OC_USER（OpenClaw 可自更新）"
		else
			ilog "WARN: 安装树属主不是 $OC_USER，OpenClaw 自更新会被拒绝；可执行 /usr/libexec/openclaw/repair.sh owner-fix 修复"
		fi
	fi

	ilog "== 部署完成 =="
	ilog "OpenClaw $OCV  |  Node.js $NODE_V  |  目录 $BASE_DIR"
}

# ---------------------------------------------------------------- doctor
run_doctor_after_upgrade() {
	# 升级后让 OpenClaw 修自己的配置（官方安装器的做法）。
	#
	# 官方 install.sh 在"升级已有安装"时会执行 `openclaw doctor --non-interactive`
	# （best effort）。我们不跑这一步的后果很具体：openclaw.json 的 schema 会
	# 随版本演进（旧键被移除、新键有默认值），不修的话升级完网关可能起不来，
	# 或者起来了但功能不对 —— 而日志里只有一句 "config invalid"。
	#
	# 用 --fix（与官方"从极旧版本升级"的桥接步骤一致）：只跑只读体检不会改配置。
	# 失败不判死：doctor 在个别问题上会返回非零，但那不代表安装失败。
	local oc out rc vout vrc hbp _p
	oc="$OC_DIR/bin/openclaw"
	[ -x "$oc" ] || { ilog "跳过 doctor：未找到 $oc"; return 0; }

	ilog "运行 openclaw doctor --fix（让 OpenClaw 修正自身配置，官方升级流程要求）"
	# 以**网关用户**执行，不是 root：OpenClaw 会校验临时目录
	# <cache>/openclaw-<uid> 的属主等于当前进程 uid。root 跑会创建
	# openclaw-0，而 oc_fix_perms 的 chown -R 又把它改成 998，
	# 下次 root 再跑就报 "has owner uid 998, expected uid 0" 并拒绝一切
	# 需要状态的操作。以 998 跑，uid 自始至终一致。
	# TMPDIR 也必须显式给：不指定时 OpenClaw 会回退到共享 /tmp 下的目录，
	# 属主不符会被它自己的安全校验拒绝（实测报 "Unsafe fallback OpenClaw
	# temp dir ... do not chmod a shared temp directory to 0700"）。
	out="$(oc_as_user env HOME="$HOME_DIR" TMPDIR="$BASE_DIR/tmp" \
		PATH="$NODE_DIR/bin:$OC_DIR/bin:$PATH" \
		"$oc" doctor --fix 2>&1)"
	rc=$?
	if [ "$rc" -eq 0 ]; then
		ilog "doctor --fix 完成"
	else
		ilog "WARN: doctor --fix 退出码 $rc（不代表安装失败；个别问题它修不了）"
	fi
	# 只记最后几行：doctor 输出很长，全打进主日志会把关键信息埋掉。
	[ -n "$out" ] && printf '%s\n' "$out" | tail -n 20 | while IFS= read -r _l; do
		[ -n "$_l" ] && ilog "  doctor| $_l"
	done

	# doctor 之后验一次配置。无效时把**具体键**写进日志：
	# 后面插件安装会因此失败，而它只会说 "config is invalid"，
	# 用户无从知道要改什么。典型来源是旧版残留的通道 id（如 qqbot）。
	vout="$(oc_as_user env HOME="$HOME_DIR" PATH="$NODE_DIR/bin:$OC_DIR/bin:$PATH" \
		"$oc" config validate 2>&1)"
	vrc=$?
	# 2026.11 起 agents.defaults.heartbeat 被移除（改成 automation jobs）。
	# 官方迁移路径是 doctor --fix（把心跳转成 job 再删键），上面已经跑过一次；
	# 这里还留着说明本版 doctor 迁不动它。而留着它的后果很重：整份配置被判
	# 无效，网关虽然能起，却**忽略所有渠道 / 模型 / 凭据**（真机 2026-11-18
	# 08:04 就是这个状态，doctor 随后报一堆 Auth profile missing）。
	hbp="$(printf '%s\n' "$vout" | oc_obsolete_heartbeat_paths 2>/dev/null)"
	if [ "$vrc" -ne 0 ] && [ -n "$hbp" ]; then
		ilog "检测到 2026.11 已移除的心跳配置键（旧版 agents.defaults.heartbeat）"
		for _p in $hbp; do
			if oc_cli config unset "$_p" >/dev/null 2>&1; then
				ilog "已移除无效键 $_p（心跳不再由该键控制，请改用页面/CLI 的 Automations）"
			else
				ilog "WARN: 无法移除无效键 $_p，整份配置仍会失效"
			fi
		done
		vout="$(oc_as_user env HOME="$HOME_DIR" PATH="$NODE_DIR/bin:$OC_DIR/bin:$PATH" \
			"$oc" config validate 2>&1)"
		vrc=$?
	fi
	if [ "$vrc" -ne 0 ] && [ -n "$vout" ]; then
		ilog "WARN: 配置校验未通过，以下是具体问题（插件安装可能因此失败）："
		printf '%s\n' "$vout" | grep -E '^\s*-|unknown|invalid|Problem' | head -n 12 | \
			while IFS= read -r _l; do [ -n "$_l" ] && ilog "  config| $_l"; done
		ilog "  处理建议：在「日志」页导出诊断包，或 SSH 执行 openclaw config validate 查看完整原因"
	else
		ilog "配置校验通过"
	fi
	return 0
}

# ---------------------------------------------------------------- main
main() {
	local _cache_dir _d
	stage_begin "检查环境并准备目录"
	preflight
	stage_end

	stage_begin "解析版本"
	resolve_versions
	verify_node_version
	stage_end

	stage_begin "下载并安装 Node.js $NODE_V"
	install_node
	stage_end

	stage_begin "安装 OpenClaw（npm install，可能数分钟）"
	install_openclaw
	stage_end

	# 官方安装器在升级已有安装后必跑 doctor；放在写配置之前，
	# 让它先修好 OpenClaw 自己的 schema，我们再补自己的键。
	stage_begin "让 OpenClaw 修正自身配置（doctor --fix）"
	# 升级前只清理真正的一次性临时根；**绝不清 $HOME_DIR/.openclaw/tmp**。
	# OpenClaw 2026.10 起把 state.<hash>.lock 放在 state_dir/tmp/openclaw-<uid>/，
	# 这不是缓存而是网关 / sqlite-maintenance 共用的状态所有权锁。
	# 误删会让升级后数据库留下死租约，网关和 doctor 都报 offline maintenance。
	for _root in "$BASE_DIR/tmp"; do
		[ -d "$_root" ] || continue
		for _d in "$_root"/openclaw-*; do
			[ -d "$_d" ] || continue
			# 必须是 openclaw-<纯数字>；日期日志等文件不能被误删。
			oc_is_tmp_root "$_d" || continue
			rm -rf "$_d" 2>/dev/null || true
		done
	done
	run_doctor_after_upgrade
	stage_end

	stage_begin "写入配置"
	bootstrap_config
	stage_end

	stage_begin "预装模型插件"
	install_default_providers
	stage_end

	stage_begin "收尾并启动服务"
	finish
	stage_end
}

main "$@"
