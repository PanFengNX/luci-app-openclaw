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

: >"$OC_INSTALLLOG" 2>/dev/null || OC_INSTALLLOG="${OC_RUNDIR:-/tmp/.openclaw}/install.log"
: >"$OC_INSTALLLOG" 2>/dev/null || true
ilog() { printf '%s\n' "$*" | tee -a "$OC_INSTALLLOG"; }

die() {
	ilog "ERROR: $*"
	exit 1
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
	command -v xz >/dev/null 2>&1 || command -v unxz >/dev/null 2>&1 || \
		ilog "WARN: 未找到 xz，将尝试 busybox tar 直接解压"
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
	# 比对 SHASUMS256.txt；取不到清单时只告警不阻断（与旧行为一致）。
	local vurl="$1" tarball="$2" file="$3" want got
	oc_fetch "$vurl/SHASUMS256.txt" "$OC_DL/SHASUMS256.txt" 60 2>/dev/null || return 0
	want="$(grep "  *$tarball\$" "$OC_DL/SHASUMS256.txt" | awk '{print $1}')"
	if [ -n "$want" ]; then
		got="$(sha256sum "$file" 2>/dev/null | awk '{print $1}')"
		if [ -n "$got" ] && [ "$got" != "$want" ]; then
			die "校验和不匹配（$tarball）：期望 $want 实际 $got"
		fi
		ilog "校验和 OK"
	else
		ilog "WARN: SHASUMS256.txt 中没有该文件的记录，跳过校验"
	fi
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
			oc_download "$url" "$dest" "下载 Node.js $NODE_V" 600 || die "Node.js 下载失败：$url"
		fi
		node_verify_sum "$base/$NODE_V" "$tarball" "$dest"
		# 清空目标目录。这里刻意不用 rm -rf：find -depth -delete 只删目录内容，
		# 且默认不跟随符号链接（preflight 已确认它本身不是链接）。
		mkdir -p "$OC_NODE_GLOBAL_DIR"
		find "$OC_NODE_GLOBAL_DIR" -depth -delete 2>/dev/null || true
		mkdir -p "$OC_NODE_GLOBAL_DIR" 2>/dev/null \
			|| die "无法重建 $OC_NODE_GLOBAL_DIR"
		ilog "解压中（$OC_NODE_GLOBAL_DIR） ..."
		if command -v xz >/dev/null 2>&1; then
			tar -xJf "$dest" -C "$OC_NODE_GLOBAL_DIR" --strip-components=1 || die "解压失败（xz）"
		else
			tar -xf "$dest" -C "$OC_NODE_GLOBAL_DIR" --strip-components=1 || die "解压失败（tar）"
		fi
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
			oc_download "$url" "$dest" "下载 Node.js $NODE_V" 600 || die "Node.js 下载失败：$url"
		fi
		node_verify_sum "$base/$NODE_V" "$tarball" "$dest"
		rm -rf "$NODE_DIR"
		mkdir -p "$NODE_DIR"
		ilog "解压中 ..."
		if command -v xz >/dev/null 2>&1; then
			tar -xJf "$dest" -C "$NODE_DIR" --strip-components=1 || die "解压失败（xz）"
		else
			tar -xf "$dest" -C "$NODE_DIR" --strip-components=1 || die "解压失败（tar）"
		fi
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
	local reg npmcache npmcli
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

	ilog "npm install -g openclaw@$OCV  (registry=$reg)"
	# NOTE: piping through tee would swallow npm's exit status (we would only
	# ever see tee's 0). Appending to the log keeps the live progress readable
	# from the install-status endpoint, and the rc tells us the truth.
	if "$NODE_BIN" "$npmcli" install -g --prefix "$OC_DIR" --registry "$reg" \
		--no-audit --no-fund --loglevel=info "openclaw@$OCV" >>"$OC_INSTALLLOG" 2>&1; then
		ilog "npm install 完成"
	else
		die "npm install 失败（退出码 $?，完整日志：$OC_INSTALLLOG）"
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
	oc_fix_perms
	ilog "配置文件: $conf"
}

install_default_providers() {
	# DeepSeek ships as an official plugin; zai (Z.AI/GLM) is bundled upstream.
	local OC="$OC_DIR/bin/openclaw"
	local pre
	pre="$(uci_get main.preinstall_providers deepseek)"
	[ -n "$pre" ] || return 0
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

finish() {
	ilog "== 收尾 =="
	uci_set main.base_dir "$BASE_DIR"
	uci_set main.installed 1
	uci_set main.oc_version "$OCV"
	uci_set main.node_version "$NODE_V"
	uci_set main.node_mode "$NODE_MODE"
	uci_commit
	chmod +x /etc/init.d/openclaw 2>/dev/null
	/etc/init.d/openclaw enable >/dev/null 2>&1
	if [ "$NO_START" != "1" ]; then
		ilog "启动服务 ..."
		/etc/init.d/openclaw restart
	fi
	ilog "== 部署完成 =="
	ilog "OpenClaw $OCV  |  Node.js $NODE_V  |  目录 $BASE_DIR"
}

# ---------------------------------------------------------------- main
main() {
	preflight
	resolve_versions
	verify_node_version
	install_node
	install_openclaw
	bootstrap_config
	install_default_providers
	finish
}

main "$@"
