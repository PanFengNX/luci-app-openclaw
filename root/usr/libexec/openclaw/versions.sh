#!/bin/sh
# openclaw - online version discovery
#
# All version data is fetched live from upstream:
#   * OpenClaw releases + required Node.js range -> npm registry (official package)
#   * Node.js runtimes (musl only; OpenWrt has no glibc) -> unofficial-builds.nodejs.org
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

node_base_url() {
	# base url serving index.json + <version>/node-v<version>-linux-<arch>*.tar.xz
	local m
	m="$(uci_get main.node_mirror '')"
	if [ -n "$m" ]; then
		m="${m%/}"
		# user supplied in LuCI; fall back to the official mirror when unsafe
		if oc_safe_url "$m"; then
			# OpenWrt is musl-only: the official nodejs.org release trees have
			# no musl builds, so honouring this value would install a node that
			# cannot even start (no ld-linux). Ignore it and use the musl source.
			if oc_is_musl && node_url_is_glibc "$m"; then
				oc_warn "配置的 Node 源指向 glibc 构建（$m），OpenWrt 无 glibc，已改用 musl 源"
			else
				printf '%s' "$m"; return
			fi
		fi
	fi
	if oc_is_musl; then
		printf 'https://unofficial-builds.nodejs.org/download/release'
	else
		printf 'https://nodejs.org/dist'
	fi
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
fetch_oc_metadata() {
	# npm abbreviated document (includes engines for every version)
	local reg url tmp
	reg="$(npm_registry)"
	url="$reg/openclaw"
	mkdir -p "$OC_CACHE_DIR" 2>/dev/null || true
	tmp="$(mktemp "${OC_CACHE_DIR}/npm.XXXXXX" 2>/dev/null || echo "${OC_CACHE_DIR}/npm.$$")"
	if command -v curl >/dev/null 2>&1; then
		curl -fsSL --connect-timeout 10 --max-time 60 \
			-H 'Accept: application/vnd.npm.install-v1+json' -o "$tmp" "$url" || {
			rm -f "$tmp"; return 1; }
	else
		oc_fetch "$url" "$tmp" 60 || { rm -f "$tmp"; return 1; }
	fi
	printf '%s' "$tmp"
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
	OC_V_OK=0; OC_V_CACHED=0; OC_V_COUNT=0; OC_V_ERROR=""
	mkdir -p "$OC_CACHE_DIR" 2>/dev/null || true
	url="$(npm_registry)/openclaw"

	if [ "${1:-}" != "refresh" ] && [ -s "$OC_CACHE_DIR/oc-versions.tsv" ]; then
		OC_V_CACHED=1
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

		f="$(fetch_oc_metadata)"; rc=$?
		if [ "$rc" -eq 0 ] && [ -n "$f" ] && [ -s "$f" ]; then
			# 先解析到临时文件、确认非空再替换：镜像返回 HTML 错误页时
			# 解析结果为空，直接覆盖会把上一份好缓存冲成空文件。
			oc_parse_versions <"$f" >"$OC_CACHE_DIR/oc-versions.tsv.new" 2>/dev/null
			if [ -s "$OC_CACHE_DIR/oc-versions.tsv.new" ]; then
				mv -f "$OC_CACHE_DIR/oc-versions.tsv.new" "$OC_CACHE_DIR/oc-versions.tsv"
				oc_dist_tags <"$f" >"$OC_CACHE_DIR/oc-tags.tsv" 2>/dev/null || true
				rm -f "$f"
				fail_clear "$OC_FAIL_OC"
			else
				rm -f "$f" "$OC_CACHE_DIR/oc-versions.tsv.new"
				OC_V_ERROR="解析失败：返回内容不是 npm 包文档（$url）"
			fi
		else
			[ -n "$f" ] && rm -f "$f"
			OC_V_ERROR="$(fetch_fail_reason "$rc" "$url")"
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
	# every mirror (official + npmmirror) serves the release index at <base>/index.json
	printf '%s/index.json' "$(node_base_url)"
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

node_versions_json() {
	# JSON array of {"version":"v26.11.1","num":"26.11.1","lts":"Jod"}
	#
	# 与 oc_versions_json 同一套约定：stdout 仍是 JSON 数组，失败原因写进
	# OC_V_ERROR，由 status 子命令汇总。
	local f rc url reason
	OC_V_OK=0; OC_V_CACHED=0; OC_V_COUNT=0; OC_V_ERROR=""
	mkdir -p "$OC_CACHE_DIR" 2>/dev/null || true
	url="$(node_index_url)"

	if [ "${1:-}" != "refresh" ] && [ -s "$OC_CACHE_DIR/node-versions.tsv" ]; then
		OC_V_CACHED=1
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

		f="$(mktemp "${OC_CACHE_DIR}/node.XXXXXX" 2>/dev/null || echo "${OC_CACHE_DIR}/node.$$")"
		oc_fetch "$url" "$f" 90; rc=$?
		if [ "$rc" -eq 0 ] && [ -s "$f" ]; then
			# 同 oc-versions：先写临时文件、确认非空再替换缓存。
			node_parse_list <"$f" >"$OC_CACHE_DIR/node-versions.tsv.new" 2>/dev/null
			if [ -s "$OC_CACHE_DIR/node-versions.tsv.new" ]; then
				mv -f "$OC_CACHE_DIR/node-versions.tsv.new" "$OC_CACHE_DIR/node-versions.tsv"
				node_lts_list <"$f" >"$OC_CACHE_DIR/node-lts.tsv" 2>/dev/null || true
				rm -f "$f"
				fail_clear "$OC_FAIL_NODE"
			else
				# 索引本身有版本条目、但没有本机架构的构建：不是解析失败，
				# 而是这台设备装不了，两种原因要分开说。
				if grep -q '"version"' "$f" 2>/dev/null; then
					OC_V_ERROR="没有适用于本机架构（$(node_arch_suffix)）的 Node.js 构建"
				else
					OC_V_ERROR="解析失败：返回内容不是 Node.js 版本索引（$url）"
				fi
				rm -f "$f" "$OC_CACHE_DIR/node-versions.tsv.new"
			fi
		else
			rm -f "$f"
			OC_V_ERROR="$(fetch_fail_reason "$rc" "$url")"
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
	#   {"oc":{"ok":true,"count":42,"cached":true,"error":""},"node":{...}}
	# 不额外联网：两个列表函数自己决定要不要拉取（缓存命中时纯本地）。
	# 本函数只往 stdout 写这一行，日志一律走 stderr —— 控制器只取 stdout。
	local oc_ok oc_cnt oc_cached oc_err nd_ok nd_cnt nd_cached nd_err reason

	oc_versions_json >/dev/null 2>&1
	oc_ok="$OC_V_OK"; oc_cnt="$OC_V_COUNT"; oc_cached="$OC_V_CACHED"; oc_err="$OC_V_ERROR"

	node_versions_json >/dev/null 2>&1
	nd_ok="$OC_V_OK"; nd_cnt="$OC_V_COUNT"; nd_cached="$OC_V_CACHED"; nd_err="$OC_V_ERROR"

	# 刷新失败后 60 秒内必须如实回报失败：控制器一次请求里先调 oc-versions
	# （刷新失败时回退到旧缓存、ok=1），再调 status —— 不在这里覆盖，用户点
	# 「重试」后仍看不到任何失败提示。
	reason="$(fail_recent "$OC_FAIL_OC")" && { oc_ok=0; oc_err="$reason"; }
	reason="$(fail_recent "$OC_FAIL_NODE")" && { nd_ok=0; nd_err="$reason"; }

	printf '{"oc":{"ok":%s,"count":%s,"cached":%s,"error":"%s"},"node":{"ok":%s,"count":%s,"cached":%s,"error":"%s"}}\n' \
		"$([ "$oc_ok" = "1" ] && printf true || printf false)" "$oc_cnt" \
		"$([ "$oc_cached" = "1" ] && printf true || printf false)" "$(oc_json_str "$oc_err")" \
		"$([ "$nd_ok" = "1" ] && printf true || printf false)" "$nd_cnt" \
		"$([ "$nd_cached" = "1" ] && printf true || printf false)" "$(oc_json_str "$nd_err")"
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
