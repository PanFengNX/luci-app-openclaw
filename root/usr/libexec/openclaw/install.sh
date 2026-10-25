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
	exit 1
}

# run_with_timeout <seconds> <cmd...>
# 系统有 timeout（GNU 或 busybox 均可）时用它兜底；没有时退化为直接执行，
# 由调用方负责用 ilog 说明「本次不设超时上限」。
run_with_timeout() {
	local secs="$1"; shift
	if command -v timeout >/dev/null 2>&1; then
		timeout "$secs" "$@"
	else
		"$@"
	fi
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

# ---------------------------------------------------------------- openclaw
install_openclaw() {
	ilog "== 安装 OpenClaw $OCV（官方 npm 包） =="
	local reg npmcache npmcli npm_log rc start_ts end_ts elapsed added timed_out
	local npm_ver npm_major npm_minor allow_scripts
	local _gw_pids _i
	reg="$(npm_registry)"
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
	export npm_config_tmp="$OC_DL"
	export npm_config_prefix="$OC_DIR"

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
	set -- install -g --prefix "$OC_DIR" --registry "$reg" \
		--no-audit --no-fund --loglevel=http --prefer-offline
	[ -n "$allow_scripts" ] && set -- "$@" "$allow_scripts"
	set -- "$@" "openclaw@$OCV"
	run_with_heartbeat "npm install" -- \
		run_with_timeout "$NPM_INSTALL_TIMEOUT" "$NODE_BIN" "$npmcli" "$@" \
		>>"$npm_log" 2>&1
	rc=$?

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
		ilog "npm install 完成（$(date '+%Y-%m-%d %H:%M:%S')，耗时 ${elapsed}s）"
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
	ilog "OpenClaw 就绪: $("$OC_DIR/bin/openclaw" --version 2>/dev/null || echo unknown)"
}

# ---------------------------------------------------------------- bootstrap
bootstrap_config() {
	ilog "== 初始化配置 =="
	oc_ensure_user || ilog "WARN: 未创建系统用户 $OC_USER，将以 root 运行"
	mkdir -p "$HOME_DIR/.openclaw" "$BASE_DIR/workspace" "$BASE_DIR/logs"
	oc_fix_perms

	local port bind conf token
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
		"$OC" onboard --non-interactive --mode local --skip-health --accept-risk \
			--skip-channels >/dev/null 2>&1 || ilog "WARN: onboard 未完全成功，将写入最小配置"
	fi
	if [ ! -f "$conf" ]; then
		token="$(oc_rand_hex)"
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

	"$OC" config set gateway.port "$port" >/dev/null 2>&1
	"$OC" config set gateway.bind "$bind" >/dev/null 2>&1
	if ! grep -q '"token"' "$conf" 2>/dev/null; then
		token="$(oc_rand_hex)"
		"$OC" config set gateway.auth.mode token >/dev/null 2>&1
		"$OC" config set gateway.auth.token "$token" >/dev/null 2>&1
	fi

	# 复用的本机配置可能带着旧版 openclawmgr 写入的、2026.10 已删除的
	# gateway.controlUi.* 键；只要残留一个，整份配置就判为无效、网关拒绝启动。
	# 显式传 $conf / $OC_DIR / $NODE_BIN：本次安装可能用 --base-dir 或
	# --openclaw-dir 装到与 UCI 不同的目录，不能让函数去猜。
	oc_purge_legacy_controlui "$conf" "$OC_DIR" "$NODE_BIN"
	if [ "${OC_LEGACY_CONTROLUI_REMOVED:-0}" -gt 0 ] 2>/dev/null; then
		ilog "已移除 ${OC_LEGACY_CONTROLUI_REMOVED} 个 2026.10 不再支持的配置键（gateway.controlUi.*，旧版 openclawmgr 写入）"
	fi
	oc_fix_perms
	ilog "配置文件: $conf"
}

install_default_providers() {
	# DeepSeek ships as an official plugin; zai (Z.AI/GLM) is bundled upstream.
	local OC="$OC_DIR/bin/openclaw"
	local pre
	pre="$(uci_get main.preinstall_providers deepseek)"
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
			if "$OC" plugins install @openclaw/deepseek-provider >>"$OC_INSTALLLOG" 2>&1; then
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
				_deep="$(HOME="$HOME_DIR" PATH="$NODE_DIR/bin:$OC_DIR/bin:$PATH" \
					oc_timeout 60 "$OC_DIR/bin/openclaw" gateway status --deep 2>&1)"
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
	local oc out rc
	oc="$OC_DIR/bin/openclaw"
	[ -x "$oc" ] || { ilog "跳过 doctor：未找到 $oc"; return 0; }

	ilog "运行 openclaw doctor --fix（让 OpenClaw 修正自身配置，官方升级流程要求）"
	out="$(HOME="$HOME_DIR" PATH="$NODE_DIR/bin:$OC_DIR/bin:$PATH" \
		oc_timeout 180 "$oc" doctor --fix 2>&1)"
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
	return 0
}

# ---------------------------------------------------------------- main
main() {
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
