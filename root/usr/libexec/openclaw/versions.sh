#!/bin/sh
# openclaw - online version discovery
#
# All version data is fetched live from upstream:
#   * OpenClaw releases + required Node.js range -> npm registry (official package)
#   * Node.js runtimes (musl only; OpenWrt has no glibc) -> unofficial-builds.nodejs.org
#
# 两个数据源都有国内镜像兜底（各回退一次）：npm 用 registry.npmmirror.com，
# Node 用 registry.npmmirror.com/-/binary/node-unofficial-builds —— 后者镜像的是
# **同一棵 unofficial-builds 树**，含 linux-*-musl tarball，不是 glibc 构建。
#
# Output is JSON so the LuCI controller can pass it straight through.

OC_LIB="$(dirname "$0")/lib.sh"
[ -f "$OC_LIB" ] || OC_LIB="/usr/libexec/openclaw/lib.sh"
. "$OC_LIB"

# Cache lives in the private rundir: a predictable name under world-writable
# /tmp can be pre-created as a symlink by any local user, and versions.sh
# writes these files as root.
OC_CACHE_DIR="${OC_RUNDIR:-/tmp/.openclaw}/cache"
OC_CACHE_TTL=300

# 单次下载上限。控制器一次 api_versions 请求会串行跑 oc-versions + node-versions，
# 前端最多等 90 秒（status.htm 传的 per-call timeout）。所以后端整条链必须远小于
# 90 秒：npm 20s + 镜像 20s + Node 20s = 60s 最坏，留 30s 余量。
# 旧值是 60s + 90s = 150s，比前端 20s 的超时还长，自动检查必然报「服务无响应」。
OC_FETCH_MT=20

# npm 精简文档（abbreviated metadata）：带 engines 字段，体积比完整文档小一个
# 数量级 —— 路由器内存有限，这个 Accept 头是必要的。wget/uclient-fetch 不发头，
# 只是拿到完整文档，解析逻辑两者都兼容。
NPM_ACCEPT='application/vnd.npm.install-v1+json'

# 国内镜像：官方 registry 拉不到时回退一次（仅此一次）。只用于本次请求，
# 绝不写回 main.npm_registry —— 那是用户在 LuCI 里的设置。
OC_MIRROR_REGISTRY="https://registry.npmmirror.com"

# Node.js 国内镜像。npmmirror 镜像的是**整棵 unofficial-builds 树**（不是
# nodejs.org 的 glibc 发布树）：index.json 与官方同尺寸，且带 linux-x64-musl /
# linux-arm64-musl / linux-loong64 等条目，tarball 也照发。所以 musl 设备可以
# 安全地用它兜底 —— 版本号与下载地址都还是同一棵树里的同一批文件。
# 同样只用于本次请求，绝不写回 main.node_mirror。
OC_MIRROR_NODE="https://registry.npmmirror.com/-/binary/node-unofficial-builds"

npm_registry() {
	local r
	r="$(uci_get main.npm_registry '')"
	[ -n "$r" ] || r="https://registry.npmjs.org"
	r="${r%/}"
	# user supplied in LuCI; never hand an arbitrary string to curl
	oc_safe_url "$r" || r="https://registry.npmjs.org"
	printf '%s' "$r"
}

node_url_is_glibc() {
	# node_url_is_glibc <base-url> -> 0 when the tree only carries glibc builds
	local u="${1:-}"
	u="${u%/}"
	case "$u" in
		http://nodejs.org/dist|https://nodejs.org/dist|\
		http://nodejs.org/download/release|https://nodejs.org/download/release)
			return 0 ;;
	esac
	return 1
}

# main.node_mirror 的有效值（进程内只算一次，见 node_mirror_user_load）。
OC_NODE_MIRROR_USER=""
OC_NODE_MIRROR_USER_SET=0

node_base_default() {
	# 内置基址：musl -> unofficial-builds（唯一发布 musl 构建的树），其余 -> nodejs.org
	if oc_is_musl; then
		printf 'https://unofficial-builds.nodejs.org/download/release'
	else
		printf 'https://nodejs.org/dist'
	fi
}

node_base_fallback() {
	# 官方基址不可达时的兜底基址。
	#
	# 只在 musl 上返回镜像：npmmirror 那棵树只提供 linux-*-musl（以及 loong64）
	# 构建，非 musl 机器用它只会拿到不存在的 tarball。非 musl 返回空串 = 不兜底。
	if oc_is_musl; then
		printf '%s' "$OC_MIRROR_NODE"
	fi
}

node_mirror_user_load() {
	# 计算并记忆 main.node_mirror 的有效值，结果放在全局 OC_NODE_MIRROR_USER。
	#
	# 为什么不用 `$(node_mirror_user)` 取值：命令替换是子 shell，记忆在里面
	# 丢掉，一次 status 请求会重复读 UCI、重复打印 glibc 告警。需要值的调用方
	# 直接读全局（或调用 node_mirror_user）。
	#
	# 输出空 = 未设置 / 不安全 / 在 musl 上指向 glibc 树，调用方可以兜底；
	# 输出非空 = 用户自己选了源，兜底一律不做。
	[ "${OC_NODE_MIRROR_USER_SET:-0}" = "1" ] && return 0
	local m
	m="$(uci_get main.node_mirror '')"
	if [ -n "$m" ]; then
		m="${m%/}"
		# user supplied in LuCI; never hand an arbitrary string to curl
		if ! oc_safe_url "$m"; then
			m=""
		elif oc_is_musl && node_url_is_glibc "$m"; then
			# OpenWrt is musl-only: the official nodejs.org release trees have no
			# musl builds, so honouring this value would install a node that
			# cannot even start (no ld-linux). Ignore it and use the musl source.
			oc_warn "配置的 Node 源指向 glibc 构建（$m），OpenWrt 无 glibc，已改用 musl 源"
			m=""
		fi
	fi
	OC_NODE_MIRROR_USER="$m"
	OC_NODE_MIRROR_USER_SET=1
	return 0
}

node_mirror_user() {
	# stdout: main.node_mirror 的有效值（可能为空）。需要判断「用户是否显式设了
	# 源」的调用方请先 node_mirror_user_load，然后读 $OC_NODE_MIRROR_USER ——
	# 命令替换会开子 shell，记忆带不回来。
	node_mirror_user_load
	printf '%s' "$OC_NODE_MIRROR_USER"
}

node_base_allowed() {
	# node_base_allowed <base> -> 0 仅当它是本脚本自己写下的两个基址之一。
	#
	# node-base.tsv 里的值会被当作下载地址的前缀（install.sh 用它拼 tarball
	# URL），而缓存文件在磁盘上 —— 只认白名单，绝不接受任意字符串。
	case "${1%/}" in
		"$OC_MIRROR_NODE"|https://unofficial-builds.nodejs.org/download/release|https://nodejs.org/dist)
			return 0 ;;
	esac
	return 1
}

node_base_save() {
	# node_base_save <base> —— 记下「上一次成功拉到索引的基址」。
	# 白名单之外的值（例如用户自填的镜像）直接忽略：那种基址不需要记住。
	local b="${1%/}"
	node_base_allowed "$b" || return 1
	mkdir -p "$OC_CACHE_DIR" 2>/dev/null || return 1
	printf '%s\n' "$b" >"$OC_CACHE_DIR/node-base.tsv" 2>/dev/null || return 1
	return 0
}

node_base_saved() {
	# node_base_saved -> 上一次成功的基址（没有 / 不在白名单时输出空）
	local b
	b="$(cat "$OC_CACHE_DIR/node-base.tsv" 2>/dev/null)"
	b="${b%/}"
	[ -n "$b" ] || return 0
	node_base_allowed "$b" || return 0
	printf '%s' "$b"
}

node_source_of() {
	# node_source_of <base> -> official | mirror（沿用 npm 那套字段名）
	case "${1%/}" in
		"$OC_MIRROR_NODE") printf 'mirror' ;;
		*) printf 'official' ;;
	esac
}

node_source_save() {
	# node_source_save <official|mirror> —— 缓存命中（不联网）时仍能如实报来源
	case "${1:-}" in
		official|mirror) printf '%s\n' "$1" >"$OC_CACHE_DIR/node-source.tsv" 2>/dev/null || true ;;
	esac
}

node_source_saved() {
	local s
	s="$(cat "$OC_CACHE_DIR/node-source.tsv" 2>/dev/null)"
	case "$s" in
		official|mirror) printf '%s' "$s" ;;
	esac
}

node_base_url() {
	# base url serving index.json + <version>/node-v<version>-linux-<arch>*.tar.xz
	#
	# 优先级（列表与下载共用同一个基址 —— 只让列表走镜像是不够的：列表能拉到、
	# 点升级时 tarball 却从不可达的官方站下，用户会以为升级按钮坏了）：
	#   1. main.node_mirror   用户显式设置，保持原语义与 glibc 拦截
	#   2. node-base.tsv      上一次成功拉到索引的基址
	#   3. 内置默认           musl -> unofficial-builds，其余 -> nodejs.org
	local s
	node_mirror_user_load
	if [ -n "$OC_NODE_MIRROR_USER" ]; then
		printf '%s' "$OC_NODE_MIRROR_USER"
		return
	fi
	s="$(node_base_saved)"
	if [ -n "$s" ]; then
		printf '%s' "$s"
		return
	fi
	node_base_default
}

cache_fresh() {
	# cache_fresh <name> -> 0 when the cache file exists and is younger than TTL
	# 原来两处命中判断写的是 `[ -s "$file" ]`：只看"非空"，不看 mtime，
	# 于是 OC_CACHE_TTL=300 从来没有生效 —— 列表一旦写入就永不过期，
	# 换了镜像源仍走旧数据，上游发了新版本也永远看不到。
	local f="$OC_CACHE_DIR/$1" now age
	[ -s "$f" ] || return 1
	now="$(date +%s 2>/dev/null)"
	age=$(( now - $(date -r "$f" +%s 2>/dev/null || echo 0) ))
	[ "$age" -lt "$OC_CACHE_TTL" ]
}

cache_get() {
	# cache_get <name> -> prints cached file if fresh
	local f="$OC_CACHE_DIR/$1"
	[ -f "$f" ] || return 1
	local now age
	now="$(date +%s)"
	age=$(( now - $(date -r "$f" +%s 2>/dev/null || echo 0) ))
	[ "$age" -lt "$OC_CACHE_TTL" ] || return 1
	cat "$f"
}

cache_put() {
	# cache_put <name>  (stdin)
	mkdir -p "$OC_CACHE_DIR"
	cat >"$OC_CACHE_DIR/$1"
}

# ---------------------------------------------------------------- fetch state
# `status` 子命令要回答三个问题：这次拿到列表了吗（ok）、列表是不是直接来自
# 缓存（cached）、没拿到时为什么（error）。busybox ash 没有输出参数，所以两个
# 列表函数把结果写进下面这几个全局变量，status 只负责汇总。
#
# stdout 契约不变：oc-versions / node-versions 仍然只输出 JSON 数组，失败时
# 仍然是 []。区别只在于原因不再被丢掉 —— 旧实现里失败信息直接消失，前端只
# 看到一个空数组，升级入口因此整块静默隐藏。
OC_V_OK=0
OC_V_CACHED=0
OC_V_COUNT=0
OC_V_ERROR=""
# 本次列表数据来自哪里：official（用户配置的 npm_registry）/ mirror（国内镜像）/
# cache（直接读本地缓存，本次没有联网）。前端据此提示「（已尝试国内镜像）」。
OC_V_SOURCE=""

# 失败后短时间内不重复重试：状态页一次刷新会依次调用 oc-versions /
# node-versions / status，离线设备上不缓存失败就要白等三个网络超时。
OC_FAIL_TTL=60
OC_FAIL_OC="oc-fail.tsv"
OC_FAIL_NODE="node-fail.tsv"

fail_note() {
	# fail_note <file> <reason>  —— 记录最近一次失败（时间戳<TAB>原因）
	mkdir -p "$OC_CACHE_DIR" 2>/dev/null || true
	printf '%s\t%s\n' "$(date +%s 2>/dev/null || echo 0)" \
		"$(printf '%s' "${2:-}" | tr '\t\n' '  ')" \
		>"$OC_CACHE_DIR/$1" 2>/dev/null || true
}

fail_recent() {
	# fail_recent <file> -> 打印仍在有效期内的失败原因，返回 0；否则返回 1
	local f="$OC_CACHE_DIR/$1" now ts reason
	[ -f "$f" ] || return 1
	now="$(date +%s 2>/dev/null)" || return 1
	case "$now" in ''|*[!0-9]*) return 1 ;; esac
	ts="$(awk -F'\t' 'NR==1{print $1}' "$f" 2>/dev/null)"
	case "$ts" in ''|*[!0-9]*) return 1 ;; esac
	[ $((now - ts)) -lt "$OC_FAIL_TTL" ] 2>/dev/null || return 1
	reason="$(awk -F'\t' 'NR==1{$1=""; sub(/^\t/, ""); print}' "$f" 2>/dev/null)"
	[ -n "$reason" ] || return 1
	printf '%s' "$reason"
}

fail_clear() { rm -f "$OC_CACHE_DIR/$1" 2>/dev/null || true; }

fetch_fail_reason() {
	# fetch_fail_reason <rc> <url> -> 可直接展示的中文原因
	# 区分「网络 / 镜像不可达」「本机没有下载工具」「数据源地址不合法」；
	# 调用方再决定要不要补一句「本地没有缓存」。
	local rc="${1:-0}" url="${2:-}"
	case "$rc" in
		126) printf '下载失败：数据源地址不合法（%s）' "$url" ;;
		127) printf '下载失败：本机没有可用的下载工具（curl / wget / uclient-fetch）' ;;
		6)   printf '下载失败：无法解析域名，网络可能未连通（%s）' "$url" ;;
		7)   printf '下载失败：无法连接镜像（%s）' "$url" ;;
		28)  printf '下载失败：连接超时（%s）' "$url" ;;
		22)  printf '下载失败：镜像返回错误状态（%s）' "$url" ;;
		*)   printf '下载失败：无法访问 %s（下载工具返回 %s）' "$url" "$rc" ;;
	esac
}

count_versions() {
	# count_versions <tsv> -> 条目数（文件不存在时输出 0）
	awk -F'\t' 'NF && $1 != "" { n++ } END { printf "%d", n + 0 }' "${1:-}" 2>/dev/null
}

# ---------------------------------------------------------------- OpenClaw
OC_V_TMP=""		# fetch_oc_metadata 落盘的临时文件（成功时）
OC_V_URL=""		# 实际成功下载用的 URL（官方或镜像）
OC_V_R1=""		# 官方源失败原因
OC_V_R2=""		# 国内镜像失败原因
OC_V_FETCH_ERR=""	# 两个源都失败时的完整原因（含两个 URL）

oc_source_save() {
	# oc_source_save <official|mirror> —— 记下缓存里的数据来自哪个源。
	# 下次命中缓存（不联网）时仍能如实告诉用户来源。
	case "${1:-}" in
		official|mirror) printf '%s\n' "$1" >"$OC_CACHE_DIR/oc-source.tsv" 2>/dev/null || true ;;
	esac
}

oc_source_saved() {
	local s
	s="$(cat "$OC_CACHE_DIR/oc-source.tsv" 2>/dev/null)"
	case "$s" in
		official|mirror) printf '%s' "$s" ;;
	esac
}

oc_fetch_err_text() {
	# 两个源的原因都要带上：只报最后一个会让用户以为官方源没试过，
	# 或者以为问题只出在镜像。
	if [ -n "$OC_V_R1" ] && [ -n "$OC_V_R2" ]; then
		printf '%s；国内镜像同样失败：%s' "$OC_V_R1" "$OC_V_R2"
	else
		printf '%s%s' "$OC_V_R1" "$OC_V_R2"
	fi
}

oc_try_fetch() {
	# oc_try_fetch <url> <slot>  slot = 1|2
	# 成功：OC_V_TMP / OC_V_URL / OC_V_SOURCE 就位，返回 0
	# 失败：对应 OC_V_R<slot> 记下原因，返回 1
	local url="$1" slot="$2" tmp rc reason
	tmp="$(mktemp "${OC_CACHE_DIR}/npm.XXXXXX" 2>/dev/null || echo "${OC_CACHE_DIR}/npm.$$")"

	# 必须走 oc_fetch：只有它会读 main.http_proxy 并加 -x / 导出 http_proxy。
	# 旧实现这里直接调 curl，代理设置被完全绕过 —— 只能通过代理上网的设备
	# 永远拉不到版本列表（真机 curl 返回 1 即为此类）。
	oc_fetch "$url" "$tmp" "$OC_FETCH_MT" "$NPM_ACCEPT"
	rc=$?
	if [ "$rc" -eq 0 ] && [ -s "$tmp" ]; then
		OC_V_TMP="$tmp"
		OC_V_URL="$url"
		return 0
	fi
	rm -f "$tmp"
	if [ "$rc" -eq 0 ]; then
		reason="下载失败：返回内容为空（$url）"
	else
		reason="$(fetch_fail_reason "$rc" "$url")"
	fi
	if [ "$slot" = "2" ]; then
		OC_V_R2="$reason"
	else
		OC_V_R1="$reason"
	fi
	return 1
}

fetch_oc_metadata() {
	# npm abbreviated document (includes engines for every version)
	#
	# 先试官方源（用户配置的 npm_registry），失败再回退国内镜像，各一次。
	#
	# 结果通过全局变量回传，**不要**用 $(fetch_oc_metadata)：命令替换是子 shell，
	# 里面设置的 OC_V_TMP / OC_V_SOURCE 传不回来，而 stdout 必须留给调用方的
	# JSON 数组契约。
	#   成功: 返回 0，OC_V_TMP=临时文件，OC_V_URL=实际 URL，OC_V_SOURCE=official|mirror
	#   失败: 返回非 0，OC_V_TMP=""，OC_V_FETCH_ERR=两个源各自的原因
	local url
	mkdir -p "$OC_CACHE_DIR" 2>/dev/null || true
	OC_V_TMP=""; OC_V_SOURCE=""; OC_V_URL=""
	OC_V_R1=""; OC_V_R2=""; OC_V_FETCH_ERR=""

	url="$(npm_registry)/openclaw"
	if oc_try_fetch "$url" 1; then
		OC_V_SOURCE="official"
		return 0
	fi

	# 官方源失败 → 回退到国内镜像，且只回退一次（不重试官方、不链式换源）。
	# 注意：这里只影响本次请求的取数地址，绝不写回 main.npm_registry。
	if oc_try_fetch "$OC_MIRROR_REGISTRY/openclaw" 2; then
		OC_V_SOURCE="mirror"
		return 0
	fi

	OC_V_FETCH_ERR="$(oc_fetch_err_text)"
	return 1
}

oc_parse_versions() {
	# stdin: npm doc  -> stdout: "<version>\t<engines.node>" lines
	sed 's/{"name":"openclaw"/\n{"name":"openclaw"/g' | \
	grep '^{"name":"openclaw"' | \
	awk '{
		v=""; e=""
		if (match($0, /"version":"[^"]*"/)) {
			v = substr($0, RSTART + 11, RLENGTH - 12)
		}
		if (match($0, /"engines":\{"node":"[^"]*"/)) {
			t = substr($0, RSTART, RLENGTH)
			sub(/^"engines":\{"node":"/, "", t)
			sub(/"$/, "", t)
			e = t
		}
		if (v != "") printf "%s\t%s\n", v, e
	}'
}

oc_dist_tags() {
	# stdout: "latest\t<v>\nextended-stable\t<v>\nbeta\t<v>"   (stdin: npm doc)
	sed 's/"dist-tags"/\n"dist-tags"/' | grep -m1 '^"dist-tags"' | \
	awk 'BEGIN{RS=","} {
		gsub(/[{}"\[]/, "", $0)
		n=$0; sub(/:.*$/, "", n); v=$0; sub(/^[^:]*:/, "", v)
		if (n ~ /latest|extended-stable|beta|next|stable/) printf "%s\t%s\n", n, v
	}' | grep -v '^dist-tags'
}

oc_emit_versions() {
	# 从 oc-versions.tsv 输出 JSON 数组（不联网，供缓存路径与刷新路径共用）
	local v e tag first=1
	printf '['
	while IFS="$(printf '\t')" read -r v e; do
		[ -n "$v" ] || continue
		tag=""
		if [ -f "$OC_CACHE_DIR/oc-tags.tsv" ]; then
			tag="$(awk -F'\t' -v x="$v" '$2==x{printf "%s", $1; exit}' "$OC_CACHE_DIR/oc-tags.tsv")"
		fi
		[ "$first" = "1" ] || printf ','
		first=0
		printf '{"version":"%s","engines":"%s","tag":"%s"}' "$v" "$e" "$tag"
	done <"$OC_CACHE_DIR/oc-versions.tsv"
	printf ']'
}

oc_versions_json() {
	# JSON array of {"version":..,"engines":..,"tag":..}
	#
	# 失败时仍然输出 []（stdout 契约不变），但原因写进 OC_V_ERROR，供 status
	# 子命令与前端展示 —— 旧实现把原因直接丢掉，前端只看到一个空数组。
	local f rc url reason
	OC_V_OK=0; OC_V_CACHED=0; OC_V_COUNT=0; OC_V_ERROR=""; OC_V_SOURCE=""
	mkdir -p "$OC_CACHE_DIR" 2>/dev/null || true
	url="$(npm_registry)/openclaw"

	if [ "${1:-}" != "refresh" ] && cache_fresh oc-versions.tsv; then
		OC_V_CACHED=1
		# 缓存里没有来源记录（旧版本写下的缓存）时留空，前端按普通情况处理。
		OC_V_SOURCE="$(oc_source_saved)"
	else
		reason=""
		# 未显式刷新时先看最近一次失败记录：刚失败过且没有缓存就不再联网。
		if [ "${1:-}" != "refresh" ]; then
			reason="$(fail_recent "$OC_FAIL_OC")" || reason=""
		fi
		if [ -n "$reason" ]; then
			OC_V_ERROR="$reason"
			printf '[]'
			return 1
		fi

		fetch_oc_metadata; rc=$?
		f="$OC_V_TMP"
		if [ "$rc" -eq 0 ] && [ -n "$f" ] && [ -s "$f" ]; then
			# 先解析到临时文件、确认非空再替换：镜像返回 HTML 错误页时
			# 解析结果为空，直接覆盖会把上一份好缓存冲成空文件。
			oc_parse_versions <"$f" >"$OC_CACHE_DIR/oc-versions.tsv.new" 2>/dev/null
			if [ -s "$OC_CACHE_DIR/oc-versions.tsv.new" ]; then
				mv -f "$OC_CACHE_DIR/oc-versions.tsv.new" "$OC_CACHE_DIR/oc-versions.tsv"
				oc_dist_tags <"$f" >"$OC_CACHE_DIR/oc-tags.tsv" 2>/dev/null || true
				rm -f "$f"
				fail_clear "$OC_FAIL_OC"
				# 只有解析成功才记来源：解析失败时这份数据并没有进缓存。
				oc_source_save "$OC_V_SOURCE"
			else
				rm -f "$f" "$OC_CACHE_DIR/oc-versions.tsv.new"
				OC_V_ERROR="解析失败：返回内容不是 npm 包文档（${OC_V_URL:-$url}）"
			fi
		else
			[ -n "$f" ] && rm -f "$f"
			# 下载失败：fetch_oc_metadata 已经把「官方源 + 国内镜像」两个原因
			# 都拼好了，直接用；兜底再走一次单 URL 的原因。
			if [ -n "$OC_V_FETCH_ERR" ]; then
				OC_V_ERROR="$OC_V_FETCH_ERR"
			else
				OC_V_ERROR="$(fetch_fail_reason "$rc" "$url")"
			fi
		fi

		if [ -n "$OC_V_ERROR" ]; then
			if [ -s "$OC_CACHE_DIR/oc-versions.tsv" ]; then
				# 刷新失败但手上还有旧缓存：继续用它，别把列表清空。
				# ok 仍为 0，前端据此提示"刷新失败"，同时保留手填升级入口。
				fail_note "$OC_FAIL_OC" "$OC_V_ERROR"
				OC_V_ERROR="$OC_V_ERROR（当前显示上次缓存）"
				OC_V_CACHED=1
				oc_emit_versions
				OC_V_COUNT="$(count_versions "$OC_CACHE_DIR/oc-versions.tsv")"
				return 1
			fi
			OC_V_ERROR="$OC_V_ERROR；本地没有缓存"
			fail_note "$OC_FAIL_OC" "$OC_V_ERROR"
			printf '[]'
			return 1
		fi
	fi

	oc_emit_versions
	OC_V_COUNT="$(count_versions "$OC_CACHE_DIR/oc-versions.tsv")"
	OC_V_OK=1
	return 0
}

oc_engines_of() {
	# oc_engines_of <openclaw_version>
	local v="$1"
	[ -f "$OC_CACHE_DIR/oc-versions.tsv" ] || oc_versions_json >/dev/null 2>&1
	awk -F'\t' -v x="$v" '$1==x{printf "%s", $2; exit}' "$OC_CACHE_DIR/oc-versions.tsv" 2>/dev/null
}

# ---------------------------------------------------------------- Node.js
node_index_url() {
	# node_index_url [base] —— every mirror (official + npmmirror) serves the
	# release index at <base>/index.json. 基址与路径只在这里拼一次，兜底时
	# 两个候选共用同一段代码，不会拼出两种形状。
	local b="${1:-}"
	[ -n "$b" ] || b="$(node_base_url)"
	printf '%s/index.json' "${b%/}"
}

node_arch_suffix() {
	# node tarball arch token (x64 / arm64 / armv7l / loong64 / riscv64)
	oc_node_arch
}

node_tarball_name() {
	# node_tarball_name <version(with v)>
	local v="$1" a
	a="$(node_arch_suffix)"
	if oc_is_musl; then
		printf 'node-%s-linux-%s-musl.tar.xz' "$v" "$a"
	else
		printf 'node-%s-linux-%s.tar.xz' "$v" "$a"
	fi
}

node_parse_list() {
	# stdin: nodejs index.json -> "version\thas_tarball"
	local want
	# nodejs index.json lists platform tokens (linux-x64-musl / linux-x64), not filenames
	if oc_is_musl; then
		want="\"linux-$(node_arch_suffix)-musl\""
	else
		want="\"linux-$(node_arch_suffix)\""
	fi
	sed 's/{"version":"/\n{"version":"/g' | grep '^{"version":"' | \
	awk -v want="$want" '{
		v=""
		if (match($0, /"version":"[^"]*"/)) v = substr($0, RSTART + 11, RLENGTH - 12)
		if (v == "") next
		if (index($0, want) > 0) printf "%s\t1\n", v
	}'
}

node_emit_versions() {
	# 从 node-versions.tsv 输出 JSON 数组（不联网）
	local first=1 v _ok lts num
	printf '['
	while IFS="$(printf '\t')" read -r v _ok; do
		[ -n "$v" ] || continue
		num="${v#v}"
		lts=""
		if [ -f "$OC_CACHE_DIR/node-lts.tsv" ]; then
			lts="$(awk -F'\t' -v x="$v" '$1==x{printf "%s", $2; exit}' "$OC_CACHE_DIR/node-lts.tsv")"
		fi
		[ "$first" = "1" ] || printf ','
		first=0
		printf '{"version":"%s","num":"%s","lts":"%s"}' "$v" "$num" "$lts"
	done <"$OC_CACHE_DIR/node-versions.tsv"
	printf ']'
}

# ---------------------------------------------------------------- Node.js fetch
# 本轮取数的状态。与 npm 侧共用 OC_V_R1 / OC_V_R2 / OC_V_TMP 这几个全局，
# 两个列表函数各自在入口重置，不会互相串。
OC_NODE_BASE_OK=""	# 本次成功拉到索引的基址（写进 node-base.tsv）

node_try_fetch() {
	# node_try_fetch <base> <slot>  slot = 1|2
	#   成功: OC_V_TMP / OC_V_URL / OC_NODE_BASE_OK 就位，返回 0
	#   失败: 对应 OC_V_R<slot> 记下原因，返回 1
	local base="${1%/}" slot="$2" url tmp rc reason
	url="$(node_index_url "$base")"
	tmp="$(mktemp "${OC_CACHE_DIR}/node.XXXXXX" 2>/dev/null || echo "${OC_CACHE_DIR}/node.$$")"

	# 必须走 oc_fetch：只有它会读 main.http_proxy 并加 -x / 导出 http_proxy。
	oc_fetch "$url" "$tmp" "$OC_FETCH_MT"
	rc=$?
	if [ "$rc" -eq 0 ] && [ -s "$tmp" ]; then
		OC_V_TMP="$tmp"
		OC_V_URL="$url"
		OC_NODE_BASE_OK="$base"
		return 0
	fi
	rm -f "$tmp"
	if [ "$rc" -eq 0 ]; then
		reason="下载失败：返回内容为空（$url）"
	else
		reason="$(fetch_fail_reason "$rc" "$url")"
	fi
	if [ "$slot" = "2" ]; then
		OC_V_R2="$reason"
	else
		OC_V_R1="$reason"
	fi
	return 1
}

node_versions_json() {
	# JSON array of {"version":"v26.11.1","num":"26.11.1","lts":"Jod"}
	#
	# 与 oc_versions_json 同一套约定：stdout 仍是 JSON 数组，失败原因写进
	# OC_V_ERROR，由 status 子命令汇总。
	local f base fb reason
	OC_V_OK=0; OC_V_CACHED=0; OC_V_COUNT=0; OC_V_ERROR=""; OC_V_SOURCE=""
	OC_V_TMP=""; OC_V_URL=""; OC_V_R1=""; OC_V_R2=""; OC_NODE_BASE_OK=""
	mkdir -p "$OC_CACHE_DIR" 2>/dev/null || true

	if [ "${1:-}" != "refresh" ] && cache_fresh node-versions.tsv; then
		OC_V_CACHED=1
		OC_V_SOURCE="$(node_source_saved)"
	else
		reason=""
		if [ "${1:-}" != "refresh" ]; then
			reason="$(fail_recent "$OC_FAIL_NODE")" || reason=""
		fi
		if [ -n "$reason" ]; then
			OC_V_ERROR="$reason"
			printf '[]'
			return 1
		fi

		# 先试当前基址（用户设置 > 上次成功的基址 > 内置默认），失败再兜底一次。
		#
		# 为什么兜底：真机上 unofficial-builds.nodejs.org 会 TLS 握手失败
		# （curl 35），而 npmmirror 镜的是同一棵 unofficial-builds 树、带 musl
		# 构建 —— 版本号与 tarball 都是同一批文件，不存在「版本对不上」的风险。
		#
		# 用户显式设置过 main.node_mirror 时不兜底：那是用户的决定，失败就如实
		# 报错（错误里会提示可以换源）。
		base="$(node_base_url)"
		if ! node_try_fetch "$base" 1; then
			fb=""
			# 读全局而不是 $(node_mirror_user)：命令替换是子 shell，UCI 会被
			# 重复读、glibc 告警会重复打印。
			node_mirror_user_load
			if [ -z "$OC_NODE_MIRROR_USER" ]; then
				fb="$(node_base_fallback)"
				# 上次成功的基址就是镜像时，兜底基址与它相同：改试内置默认，
				# 否则会对着同一个 URL 白等两次，还永远试不到官方源。
				if [ -n "$fb" ] && [ "$fb" = "$base" ]; then
					fb="$(node_base_default)"
				fi
				[ "$fb" = "$base" ] && fb=""
				[ -n "$fb" ] && node_try_fetch "$fb" 2
			fi
		fi

		f="$OC_V_TMP"
		if [ -n "$f" ] && [ -s "$f" ]; then
			# 同 oc-versions：先写临时文件、确认非空再替换缓存。
			node_parse_list <"$f" >"$OC_CACHE_DIR/node-versions.tsv.new" 2>/dev/null
			if [ -s "$OC_CACHE_DIR/node-versions.tsv.new" ]; then
				mv -f "$OC_CACHE_DIR/node-versions.tsv.new" "$OC_CACHE_DIR/node-versions.tsv"
				node_lts_list <"$f" >"$OC_CACHE_DIR/node-lts.tsv" 2>/dev/null || true
				rm -f "$f"
				fail_clear "$OC_FAIL_NODE"
				# 列表与下载必须共用基址：记下这次能用的那个，install.sh 的
				# node_base_url() 会直接读到它。
				node_base_save "$OC_NODE_BASE_OK"
				OC_V_SOURCE="$(node_source_of "$OC_NODE_BASE_OK")"
				node_source_save "$OC_V_SOURCE"
			else
				# 索引本身有版本条目、但没有本机架构的构建：不是解析失败，
				# 而是这台设备装不了，两种原因要分开说。
				if grep -q '"version"' "$f" 2>/dev/null; then
					OC_V_ERROR="没有适用于本机架构（$(node_arch_suffix)）的 Node.js 构建"
				else
					OC_V_ERROR="解析失败：返回内容不是 Node.js 版本索引（${OC_V_URL:-$base}）"
				fi
				rm -f "$f" "$OC_CACHE_DIR/node-versions.tsv.new"
			fi
		else
			# 两个源都失败时把两边的 URL 都带上（与 npm 侧同一口径）：
			# 只报最后一个会让人以为官方源没试过，或者以为问题只出在镜像。
			OC_V_ERROR="$(oc_fetch_err_text)"
			# 用户显式设了源时我们刻意没兜底：说清楚这一点，否则失败信息
			# 看起来和「镜像也没试过」一样，用户不知道还能换源。
			if [ -n "$OC_NODE_MIRROR_USER" ]; then
				OC_V_ERROR="$OC_V_ERROR（当前使用设置里指定的 Node 源，未自动切换；可在设置中换源后重试）"
			fi
		fi

		if [ -n "$OC_V_ERROR" ]; then
			if [ -s "$OC_CACHE_DIR/node-versions.tsv" ]; then
				fail_note "$OC_FAIL_NODE" "$OC_V_ERROR"
				OC_V_ERROR="$OC_V_ERROR（当前显示上次缓存）"
				OC_V_CACHED=1
				node_emit_versions
				OC_V_COUNT="$(count_versions "$OC_CACHE_DIR/node-versions.tsv")"
				return 1
			fi
			OC_V_ERROR="$OC_V_ERROR；本地没有缓存"
			fail_note "$OC_FAIL_NODE" "$OC_V_ERROR"
			printf '[]'
			return 1
		fi
	fi

	node_emit_versions
	OC_V_COUNT="$(count_versions "$OC_CACHE_DIR/node-versions.tsv")"
	OC_V_OK=1
	return 0
}

node_lts_list() {
	# stdin: index.json -> "version\tlts"
	sed 's/{"version":"/\n{"version":"/g' | grep '^{"version":"' | \
	awk '{
		v=""
		if (match($0, /"version":"[^"]*"/)) v = substr($0, RSTART + 11, RLENGTH - 12)
		l=""
		if (match($0, /"lts":"[^"]*"/)) { t = substr($0, RSTART, RLENGTH); sub(/^"lts":"/, "", t); sub(/"$/, "", t); l = t }
		else if (match($0, /"lts":false/)) l = ""
		if (v != "") printf "%s\t%s\n", v, l
	}'
}

# ---------------------------------------------------------------- compat
check_compat() {
	# check_compat <openclaw_version|latest> <node_version>
	local ocv="$1" nv="$2" e
	nv="${nv#v}"

	# The tag lookup below reads oc-tags.tsv directly. If the cache was never
	# populated (fresh boot, no refresh yet) that file does not exist, `ocv`
	# came out empty, `e` came out empty, and engines_match happily returned
	# "match" for an empty spec - i.e. an unknown requirement was reported as
	# "compatible". Populate first, then treat "still unknown" as a failure.
	if [ ! -f "$OC_CACHE_DIR/oc-versions.tsv" ]; then
		oc_versions_json >/dev/null 2>&1
	fi

	if [ "$ocv" = "latest" ] || [ "$ocv" = "extended-stable" ] || [ "$ocv" = "beta" ]; then
		ocv="$(awk -F'\t' -v x="$ocv" '$1==x{printf "%s", $2; exit}' "$OC_CACHE_DIR/oc-tags.tsv" 2>/dev/null)"
	fi
	e="$(oc_engines_of "$ocv")"
	[ -n "$e" ] || e="$(oc_engines_of "$(oc_latest_version)")"

	if [ -z "$nv" ]; then
		printf '{"ok":false,"engines":"%s","reason":"node version required"}' "$(oc_json_str "$e")"
		return 1
	fi
	if [ -z "$e" ]; then
		printf '{"ok":false,"engines":"","openclaw":"%s","node":"%s","reason":"cannot resolve engines.node for openclaw %s (network?)"}' \
			"$(oc_json_str "$ocv")" "$(oc_json_str "$nv")" "$(oc_json_str "$ocv")"
		return 1
	fi
	if engines_match "$nv" "$e"; then
		printf '{"ok":true,"engines":"%s","openclaw":"%s","node":"%s"}' \
			"$(oc_json_str "$e")" "$(oc_json_str "$ocv")" "$(oc_json_str "$nv")"
		return 0
	fi
	printf '{"ok":false,"engines":"%s","openclaw":"%s","node":"%s","reason":"Node.js %s does not satisfy openclaw %s (requires %s)"}' \
		"$(oc_json_str "$e")" "$(oc_json_str "$ocv")" "$(oc_json_str "$nv")" \
		"$(oc_json_str "$nv")" "$(oc_json_str "$ocv")" "$(oc_json_str "$e")"
	return 1
}

oc_latest_version() {
	awk -F'\t' '$1=="latest"{printf "%s", $2; exit}' "$OC_CACHE_DIR/oc-tags.tsv" 2>/dev/null
}

versions_status_json() {
	# 一行 JSON，供控制器原样透传给前端：
	#   {"oc":{"ok":true,"count":42,"cached":true,"source":"mirror","error":""},"node":{...}}
	# source: official（用户配置的 npm_registry）/ mirror（国内镜像）/ ""（未知，
	# 例如旧版本留下的缓存）。前端据此显示「已尝试国内镜像」提示。
	# 不额外联网：两个列表函数自己决定要不要拉取（缓存命中时纯本地）。
	# 本函数只往 stdout 写这一行，日志一律走 stderr —— 控制器只取 stdout。
	local oc_ok oc_cnt oc_cached oc_err oc_src nd_ok nd_cnt nd_cached nd_err nd_src reason

	oc_versions_json >/dev/null 2>&1
	oc_ok="$OC_V_OK"; oc_cnt="$OC_V_COUNT"; oc_cached="$OC_V_CACHED"
	oc_err="$OC_V_ERROR"; oc_src="$OC_V_SOURCE"

	node_versions_json >/dev/null 2>&1
	nd_ok="$OC_V_OK"; nd_cnt="$OC_V_COUNT"; nd_cached="$OC_V_CACHED"; nd_err="$OC_V_ERROR"
	nd_src="$OC_V_SOURCE"

	# 刷新失败后 60 秒内必须如实回报失败：控制器一次请求里先调 oc-versions
	# （刷新失败时回退到旧缓存、ok=1），再调 status —— 不在这里覆盖，用户点
	# 「重试」后仍看不到任何失败提示。
	reason="$(fail_recent "$OC_FAIL_OC")" && { oc_ok=0; oc_err="$reason"; }
	reason="$(fail_recent "$OC_FAIL_NODE")" && { nd_ok=0; nd_err="$reason"; }

	printf '{"oc":{"ok":%s,"count":%s,"cached":%s,"source":"%s","error":"%s"},"node":{"ok":%s,"count":%s,"cached":%s,"source":"%s","error":"%s"}}\n' \
		"$([ "$oc_ok" = "1" ] && printf true || printf false)" "$oc_cnt" \
		"$([ "$oc_cached" = "1" ] && printf true || printf false)" "$(oc_json_str "$oc_src")" \
		"$(oc_json_str "$oc_err")" \
		"$([ "$nd_ok" = "1" ] && printf true || printf false)" "$nd_cnt" \
		"$([ "$nd_cached" = "1" ] && printf true || printf false)" "$(oc_json_str "$nd_src")" \
		"$(oc_json_str "$nd_err")"
}

# ---------------------------------------------------------------- cli
case "${1:-}" in
	oc-versions)
		shift
		oc_versions_json "${1:-}"
		;;
	node-versions)
		shift
		node_versions_json "${1:-}"
		;;
	status)
		versions_status_json
		;;
	check)
		# versions.sh check <oc-version> <node-version>
		if [ -f "$OC_CACHE_DIR/oc-versions.tsv" ]; then :; else oc_versions_json >/dev/null 2>&1; fi
		check_compat "$2" "$3"
		;;
	engines)
		if [ -f "$OC_CACHE_DIR/oc-versions.tsv" ]; then :; else oc_versions_json >/dev/null 2>&1; fi
		e="$(oc_engines_of "$2")"
		printf '{"openclaw":"%s","engines":"%s"}\n' "$2" "$e"
		;;
	urls)
		printf '{"npm":"%s","node":"%s","arch":"%s","musl":"%s","libc":"%s"}\n' \
			"$(npm_registry)" "$(node_base_url)" "$(oc_arch)" \
			"$(oc_is_musl && echo 1 || echo 0)" "$(oc_is_musl && echo musl || echo glibc)"
		;;
	*)
		cat <<EOF
Usage: versions.sh {oc-versions|node-versions|status|check|engines|urls} [args]
  oc-versions [refresh]              list OpenClaw versions + required node range
  node-versions [refresh]            list Node.js runtimes available for this box
  status                             one-line JSON: ok / count / cached / error
  check <openclaw-ver> <node-ver>    verify node satisfies openclaw engines.node
  engines <openclaw-ver>             print required node range
  urls                               show data sources in use
EOF
		;;
esac
