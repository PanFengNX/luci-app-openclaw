#!/bin/sh
# openclaw - shared helpers
# POSIX sh (busybox ash) compatible.

OC_NAME="openclaw"
OC_UCI="openclaw"
OC_LOGDIR="/var/log"
OC_LOGFILE="$OC_LOGDIR/openclaw.log"
OC_INSTALLLOG="$OC_LOGDIR/openclaw-install.log"
OC_TASKLOG="$OC_LOGDIR/openclaw-task.log"

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

	# someone else beat us to it - take it back (root) or refuse (non-root)
	if [ "$(oc_dir_uid "$d")" != "$uid" ]; then
		if [ "$uid" = "0" ]; then
			chown "$uid" "$d" 2>/dev/null || true
		else
			# oc_err is defined further down; this runs at load time
			printf '%s\n' "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] 临时目录 $d 不属于当前用户，拒绝继续" >&2
			return 1
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
oc_log() {
	# oc_log <level> <message>
	local lvl="$1"; shift
	local line
	line="$(date '+%Y-%m-%d %H:%M:%S') [$lvl] $*"
	printf '%s\n' "$line"
	# never let a read-only /var/log break the caller
	if [ -d "$OC_LOGDIR" ] && [ -w "$OC_LOGDIR" ]; then
		printf '%s\n' "$line" >>"$OC_LOGFILE" 2>/dev/null || true
	fi
}

oc_info() { oc_log INFO "$@"; }
# WARN and ERROR go to stderr: several commands (info / diag-poll / install-status)
# print a JSON payload on stdout and a stray log line would corrupt it.
oc_warn() { oc_log WARN "$@" >&2; }
oc_err()  { oc_log ERROR "$@" >&2; }
oc_raw()  { printf '%s\n' "$*"; }

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

oc_node_dir()  { printf '%s/node' "$(oc_base_dir)"; }
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
oc_home_dir()  { printf '%s/home' "$(oc_base_dir)"; }
oc_data_dir()  { printf '%s/home/.openclaw' "$(oc_base_dir)"; }
oc_conf()      { printf '%s/home/.openclaw/openclaw.json' "$(oc_base_dir)"; }
oc_node_bin()  { printf '%s/node/bin/node' "$(oc_base_dir)"; }
oc_oc_bin()    { printf '%s/bin/openclaw' "$(oc_oc_dir)"; }

# ---------------------------------------------------------------- http
oc_fetch() {
	# oc_fetch <url> <dest> [max-time]
	local url="$1" dest="$2" mt="${3:-60}"
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
		if [ -n "$proxy" ]; then
			curl -fsSL --connect-timeout 10 --max-time "$mt" -x "$proxy" -o "$dest" "$url"
		else
			curl -fsSL --connect-timeout 10 --max-time "$mt" -o "$dest" "$url"
		fi
	elif command -v wget >/dev/null 2>&1; then
		wget -q -T "$mt" -O "$dest" "$url"
	elif command -v uclient-fetch >/dev/null 2>&1; then
		uclient-fetch -q -T "$mt" -O "$dest" "$url"
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
	# oc_safe_url <url> -> 0 when it is a plain http(s) URL we may hand to curl.
	# Blocks option injection (leading "-") and URLs with embedded whitespace,
	# and stops a configured mirror from silently downgrading to plain http.
	case "${1:-}" in
		https://*) ;;
		http://*) ;;
		*) return 1 ;;
	esac
	case "$1" in
		*' '*|*'	'*) return 1 ;;
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

oc_free_mb() {
	# free space in MB of a path
	local p="$1"
	df -m "$p" 2>/dev/null | awk 'NR==2{print $4}'
}

oc_mounts() {
	# list candidate mount points with free MB and fs type
	df -m 2>/dev/null | awk 'NR>1 && $4>0 {print $6"\t"$4"\t"$1}' | grep -E '^/(mnt|tmp|sda|sd|nvme|mmc|overlay|data)' 
	[ -s /proc/mounts ] || true
}

oc_rand_hex() {
	# 32 bytes hex
	if [ -r /dev/urandom ]; then
		dd if=/dev/urandom bs=32 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n'
	else
		awk 'BEGIN{srand();for(i=0;i<32;i++)printf "%02x", int(rand()*256)}'
	fi
}

oc_kill_tree() {
	# Kill ONLY the actual gateway process (and its direct children).
	# The old form was `pgrep -f openclaw | kill -9`: it matched *anything* with
	# "openclaw" in the command line - including this very script and a user's
	# `tail -f openclaw.log` - and the uninstall would kill itself halfway.
	local p kids
	for p in $(oc_gateway_pids); do
		kids="$(pgrep -P "$p" 2>/dev/null)"
		# shellcheck disable=SC2086
		[ -n "$kids" ] && kill -9 $kids 2>/dev/null
		kill -9 "$p" 2>/dev/null
	done
	return 0
}

oc_gateway_pids() {
	# pids of the real gateway process: argv[0] is exactly our private node
	# binary and the command line contains the gateway subcommand.
	# Matching /proc/<pid>/cmdline (NUL separated) avoids every false positive
	# from grepping pgrep -f output.
	local p cmd nb
	nb="$(oc_node_bin)"
	[ -x "$nb" ] || return 0
	for p in $(pgrep -x node 2>/dev/null; pgrep -f 'gateway run' 2>/dev/null); do
		[ -n "$p" ] || continue
		cmd="$(tr '\0' ' ' </proc/"$p"/cmdline 2>/dev/null)" || continue
		case "$cmd" in
			"$nb "*) case "$cmd" in *" gateway "*) printf '%s\n' "$p" ;; esac ;;
		esac
	done | awk '!seen[$0]++'
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

oc_lock_acquire() {
	# returns 0 on success, 2 when another operation holds the lock
	if mkdir "$OC_LOCK_DIR" 2>/dev/null; then
		echo "$$" >"$OC_LOCK_DIR/pid" 2>/dev/null || true
		trap 'rm -rf "$OC_LOCK_DIR" 2>/dev/null || true' EXIT
		trap 'rm -rf "$OC_LOCK_DIR" 2>/dev/null || true; exit 1' INT TERM HUP
		return 0
	fi

	local pid
	pid="$(cat "$OC_LOCK_DIR/pid" 2>/dev/null || true)"
	if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
		if oc_pid_in_ancestry "$pid"; then
			oc_warn "检测到自身持有的陈旧锁，自动恢复：$OC_LOCK_DIR"
		else
			oc_err "另一个操作正在运行（锁 $OC_LOCK_DIR，pid $pid）"
			return 2
		fi
	else
		oc_warn "检测到陈旧锁（pid ${pid:-未知} 已退出），自动清理：$OC_LOCK_DIR"
	fi

	rm -rf "$OC_LOCK_DIR" 2>/dev/null || true
	if mkdir "$OC_LOCK_DIR" 2>/dev/null; then
		echo "$$" >"$OC_LOCK_DIR/pid" 2>/dev/null || true
		trap 'rm -rf "$OC_LOCK_DIR" 2>/dev/null || true' EXIT
		trap 'rm -rf "$OC_LOCK_DIR" 2>/dev/null || true; exit 1' INT TERM HUP
		return 0
	fi
	oc_err "无法获取操作锁：$OC_LOCK_DIR"
	return 2
}

oc_lock_release() {
	rm -rf "$OC_LOCK_DIR" 2>/dev/null || true
	trap - EXIT INT TERM HUP 2>/dev/null || true
}

oc_locked() { [ -d "$OC_LOCK_DIR" ]; }

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
