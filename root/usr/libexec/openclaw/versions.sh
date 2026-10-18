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

oc_versions_json() {
	# JSON array of {"version":..,"engines":..,"tag":..}
	local f tags line v e tag
	mkdir -p "$OC_CACHE_DIR"
	if [ "${1:-}" = "refresh" ] || [ ! -f "$OC_CACHE_DIR/oc-versions.tsv" ]; then
		f="$(fetch_oc_metadata)" || { printf '[]'; return 1; }
		oc_parse_versions <"$f" >"$OC_CACHE_DIR/oc-versions.tsv"
		oc_dist_tags <"$f" >"$OC_CACHE_DIR/oc-tags.tsv" 2>/dev/null || true
		rm -f "$f"
	fi
	printf '['
	local first=1
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

node_versions_json() {
	# JSON array of {"version":"v26.11.1","num":"26.11.1","lts":"Jod"}
	local src f
	mkdir -p "$OC_CACHE_DIR"
	if [ "${1:-}" = "refresh" ] || [ ! -f "$OC_CACHE_DIR/node-versions.tsv" ]; then
		f="$(mktemp "${OC_CACHE_DIR}/node.XXXXXX" 2>/dev/null || echo "${OC_CACHE_DIR}/node.$$")"
		oc_fetch "$(node_index_url)" "$f" 90 || { rm -f "$f"; printf '[]'; return 1; }
		node_parse_list <"$f" >"$OC_CACHE_DIR/node-versions.tsv"
		node_lts_list <"$f" >"$OC_CACHE_DIR/node-lts.tsv" 2>/dev/null || true
		rm -f "$f"
	fi
	printf '['
	local first=1 v lts num
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
Usage: versions.sh {oc-versions|node-versions|check|engines|urls} [args]
  oc-versions [refresh]              list OpenClaw versions + required node range
  node-versions [refresh]            list Node.js runtimes available for this box
  check <openclaw-ver> <node-ver>    verify node satisfies openclaw engines.node
  engines <openclaw-ver>             print required node range
  urls                               show data sources in use
EOF
		;;
esac
