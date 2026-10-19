#!/bin/sh
# openclaw - 百度网盘云备份（后端）
#
# 本脚本只负责「云侧搬运」：组件安装、登录、上传、列表、下载、删除。
# 本地归档的创建 / 校验 / 还原仍由 backup.sh 负责（本批次不调用）。
#
# 用法：
#   cloud.sh status
#   cloud.sh install-cli
#   cloud.sh login-url
#   cloud.sh login-code <code>
#   cloud.sh logout
#   cloud.sh upload <local-path> <remote-name>
#   cloud.sh ls
#   cloud.sh download <remote-name> <local-path>
#   cloud.sh download-dec <remote-name> <local-path>   （口令从 stdin 第一行读）
#   cloud.sh rm <remote-name>
#   cloud.sh pass-status
#   cloud.sh set-pass          （口令从 stdin 读）
#   cloud.sh clear-pass
#
# 约定：
#   * stdout 只有一行 JSON；日志一律 oc_warn / oc_err（stderr）。
#   * 所有 bdpan 调用都带私有 HOME（登录态落点）并用 oc_timeout 包住。
#   * 绝不读取 / 打印 $HOME/.config/bdpan/config.json（内含 access_token）。
#   * 口令绝不进 argv / env / URL / 日志：set-pass 与 download-dec 从 stdin 读，
#     加密上传时从 $OC_CLOUD_DIR/pass（0600）读，经 heredoc 交给 node 的 stdin。
#
# 加密文件格式（AES-256-GCM，scrypt N=16384 r=8 p=1，salt 16 字节）：
#   偏移 0..5   魔数 "OCBK1\n"（6 字节）
#   偏移 6      版本号 1（1 字节）
#   偏移 7..22  salt（16 字节）
#   偏移 23..34 iv（12 字节）
#   偏移 35..50 GCM tag（16 字节）
#   偏移 51..   密文
# 加密后的远端文件名为 <原文件名>.enc。
#
# 目录（都在数据盘，重启不丢）：
#   $OC_CLOUD_DIR    组件目录
#   $OC_CLOUD_HOME   bdpan 的 HOME（登录态）
#   $OC_CLOUD_BIN    安装后的 bdpan（找不到时在组件目录内搜索）

OC_LIB="/usr/libexec/openclaw/lib.sh"
[ -f "$OC_LIB" ] || OC_LIB="$(dirname "$0")/lib.sh"
if [ ! -f "$OC_LIB" ]; then
	printf '{"ok":false,"error":"无法加载公共库 lib.sh"}\n'
	exit 1
fi
. "$OC_LIB" || {
	printf '{"ok":false,"error":"加载公共库 lib.sh 失败"}\n'
	exit 1
}

OC_CLOUD_DIR="$(oc_base_dir)/cloud"
OC_CLOUD_HOME="$OC_CLOUD_DIR/home"
OC_CLOUD_BIN="$OC_CLOUD_DIR/bdpan"
OC_CLOUD_REMOTE="openclaw-backups"
OC_CLOUD_PASS="$OC_CLOUD_DIR/pass"
OC_CLOUD_DEFAULT_VERSION="3.7.3"
OC_CLOUD_CDN="https://issuecdn.baidupcs.com/issue/netdisk/ai-bdpan/installer"

# ---------------------------------------------------------------- output
jstr() { oc_json_str "${1:-}"; }

cblog() {
	# oc_log 本身写 stdout（安装日志通道）；本脚本的 stdout 是 JSON，必须转 stderr。
	oc_log INFO "$@" >&2
}

cloud_fail() {
	# cloud_fail <message> [exit-code]
	printf '{"ok":false,"error":"%s"}\n' "$(jstr "${1:-未知错误}")"
	exit "${2:-1}"
}

# ---------------------------------------------------------------- redaction
cloud_redact() {
	# stdin -> stdout。疑似凭据的整行替换掉：宁可少显示一行，也不把 token
	# 回显到页面 / 日志 / 诊断导出。whoami 的原始输出也必须先过这里。
	awk '
		/[Tt][Oo][Kk][Ee][Nn]|[Ss][Ee][Cc][Rr][Ee][Tt]|[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]|[Cc][Oo][Oo][Kk][Ii][Ee]|[Bb][Dd][Uu][Ss][Ss]|[Cc][Rr][Ee][Dd][Ee][Nn][Tt][Ii][Aa][Ll]|[Aa][Cc][Cc][Ee][Ss][Ss][_-]?[Kk][Ee][Yy]/ {
			print "[已隐藏：输出包含疑似凭据]"
			next
		}
		{ print }
	'
}

cloud_tail_err() {
	# cloud_tail_err <file> [lines] -> 脱敏后的最后几行（截断）
	tail -n "${2:-5}" "$1" 2>/dev/null | cloud_redact | head -c 1500
}

cloud_scrub_code() {
	# cloud_scrub_code <file> <code>
	# 授权码只允许 [A-Za-z0-9_-]，作为 gsub 的正则字面量是安全的；
	# 仍然在动作入口做了白名单，这里是第二道防线。
	local f="$1" code="$2"
	[ -f "$f" ] || return 0
	if [ -z "$code" ]; then
		cat "$f"
		return 0
	fi
	awk -v c="$code" '{ gsub(c, "[已隐藏]"); print }' "$f"
}

# ---------------------------------------------------------------- dirs / arch
cloud_arch() {
	case "$(uname -m 2>/dev/null)" in
		aarch64|arm64) printf 'arm64' ;;
		x86_64|amd64)  printf 'amd64' ;;
		*)             printf 'unsupported' ;;
	esac
}

cloud_ensure_dirs() {
	mkdir -p "$OC_CLOUD_DIR" 2>/dev/null || return 1
	chmod 700 "$OC_CLOUD_DIR" 2>/dev/null || true
	mkdir -p "$OC_CLOUD_HOME" 2>/dev/null || return 1
	chmod 700 "$OC_CLOUD_HOME" 2>/dev/null || true
	return 0
}

cloud_bin() {
	# 打印 bdpan 路径（不要求可执行）；找不到时返回 1。
	if [ -f "$OC_CLOUD_BIN" ]; then
		printf '%s' "$OC_CLOUD_BIN"
		return 0
	fi
	[ -d "$OC_CLOUD_DIR" ] || return 1
	local p
	p="$(find "$OC_CLOUD_DIR" -maxdepth 4 \( -type f -o -type l \) -name bdpan 2>/dev/null | head -n1)"
	[ -n "$p" ] || return 1
	printf '%s' "$p"
}

cloud_bin_ready() {
	# 只返回可执行的 bdpan
	local b
	b="$(cloud_bin)" || return 1
	[ -n "$b" ] && [ -x "$b" ] || return 1
	printf '%s' "$b"
}

# ---------------------------------------------------------------- bdpan call
cloud_run() {
	# cloud_run <timeout> <cmd...>
	# 私有 HOME 是登录态落点；TMPDIR 指到 0700 的私有 rundir。
	# 放在子 shell 里 export：绝不把安装器追加的 PATH / 其它变量带回本进程。
	local t="$1"; shift
	(
		export HOME="$OC_CLOUD_HOME"
		export TMPDIR="$OC_RUNDIR"
		oc_timeout "$t" "$@"
	)
}

# ---------------------------------------------------------------- json parsing
cloud_json_scalar() {
	# cloud_json_scalar <file> <key> -> 第一个同名键的标量值（字符串已解转义）
	# 只做只读解析，不关心层级；调用方给的都是足够独特的键名。
	[ -f "$1" ] || return 0
	awk -v key="$2" '
	function h2d(h,   i,c,v,ch) {
		v = 0
		h = tolower(h)
		for (i = 1; i <= length(h); i++) {
			ch = substr(h, i, 1)
			c = index("0123456789abcdef", ch) - 1
			if (c < 0) c = 0
			v = v * 16 + c
		}
		return v
	}
	function unesc(s,   o,i,c,e,n) {
		o = ""
		for (i = 1; i <= length(s); i++) {
			c = substr(s, i, 1)
			if (c != "\\") { o = o c; continue }
			i++
			e = substr(s, i, 1)
			if (e == "n") o = o "\n"
			else if (e == "t") o = o "\t"
			else if (e == "r") o = o "\r"
			else if (e == "u") {
				n = h2d(substr(s, i + 1, 4))
				i += 4
				if (n >= 32 && n < 127) o = o sprintf("%c", n)
				else if (n == 9) o = o "\t"
				else o = o "?"
			}
			else o = o e
		}
		return o
	}
	function getkey(s, key,   i,n,c,depth,instr,esc,buf,val,want,last) {
		depth = 0; instr = 0; esc = 0; buf = ""; val = ""; want = 0; last = ""
		n = length(s)
		for (i = 1; i <= n; i++) {
			c = substr(s, i, 1)
			if (instr) {
				if (esc) { buf = buf "\\" c; esc = 0 }
				else if (c == "\\") esc = 1
				else if (c == "\"") { instr = 0; if (want) return unesc(buf); last = buf }
				else buf = buf c
				continue
			}
			if (want) {
				if (c == "\"") { instr = 1; buf = ""; continue }
				if (c == " " || c == "\t" || c == "\r" || c == "\n") continue
				if (c == "," || c == "}" || c == "]") return val
				val = val c
				continue
			}
			if (c == "\"") { instr = 1; buf = ""; continue }
			if (c == "{" || c == "[") { depth++; continue }
			if (c == "}" || c == "]") { depth--; continue }
			if (c == ":" && depth == 1 && last == key) { want = 1; val = "" }
		}
		return ""
	}
	{ s = s $0 "\n" }
	END { print getkey(s, key) }
	' "$1"
}

cloud_ls_tsv() {
	# cloud_ls_tsv <file> -> 每行 "isdir<TAB>mtime<TAB>name<TAB>size"
	# 支持两种形状：根数组，或对象里第一个数组（{"list":[...]} 之类）。
	# 找不到数组时返回 1；空数组返回 0 且无输出。
	[ -f "$1" ] || return 1
	awk '
	function h2d(h,   i,c,v,ch) {
		v = 0
		h = tolower(h)
		for (i = 1; i <= length(h); i++) {
			ch = substr(h, i, 1)
			c = index("0123456789abcdef", ch) - 1
			if (c < 0) c = 0
			v = v * 16 + c
		}
		return v
	}
	function unesc(s,   o,i,c,e,n) {
		o = ""
		for (i = 1; i <= length(s); i++) {
			c = substr(s, i, 1)
			if (c != "\\") { o = o c; continue }
			i++
			e = substr(s, i, 1)
			if (e == "n") o = o "\n"
			else if (e == "t") o = o "\t"
			else if (e == "r") o = o "\r"
			else if (e == "u") {
				n = h2d(substr(s, i + 1, 4))
				i += 4
				if (n >= 32 && n < 127) o = o sprintf("%c", n)
				else if (n == 9) o = o "\t"
				else o = o "?"
			}
			else o = o e
		}
		return o
	}
	function getkey(s, key,   i,n,c,depth,instr,esc,buf,val,want,last) {
		depth = 0; instr = 0; esc = 0; buf = ""; val = ""; want = 0; last = ""
		n = length(s)
		for (i = 1; i <= n; i++) {
			c = substr(s, i, 1)
			if (instr) {
				if (esc) { buf = buf "\\" c; esc = 0 }
				else if (c == "\\") esc = 1
				else if (c == "\"") { instr = 0; if (want) return unesc(buf); last = buf }
				else buf = buf c
				continue
			}
			if (want) {
				if (c == "\"") { instr = 1; buf = ""; continue }
				if (c == " " || c == "\t" || c == "\r" || c == "\n") continue
				if (c == "," || c == "}" || c == "]") return val
				val = val c
				continue
			}
			if (c == "\"") { instr = 1; buf = ""; continue }
			if (c == "{" || c == "[") { depth++; continue }
			if (c == "}" || c == "]") { depth--; continue }
			if (c == ":" && depth == 1 && last == key) { want = 1; val = "" }
		}
		return ""
	}
	function emit(el,   name,size,mt,d,t) {
		name = getkey(el, "server_filename")
		if (name == "") name = getkey(el, "name")
		if (name == "") name = getkey(el, "filename")
		if (name == "") return
		size = getkey(el, "size")
		if (size == "") size = getkey(el, "file_size")
		gsub(/[^0-9]/, "", size)
		if (size == "") size = "0"
		mt = getkey(el, "server_mtime")
		if (mt == "") mt = getkey(el, "mtime")
		if (mt == "") mt = getkey(el, "modified_time")
		if (mt == "") mt = getkey(el, "ctime")
		d = getkey(el, "isdir")
		if (d == "") d = getkey(el, "is_dir")
		t = getkey(el, "type")
		if (d == "true" || d == "1" || d == "yes" || t == "dir" || t == "folder" || t == "directory") d = "true"
		else d = "false"
		gsub(/[\t\r\n]/, " ", name)
		gsub(/[\t\r\n]/, " ", mt)
		printf "%s\t%s\t%s\t%s\n", d, mt, name, size
	}
	{ s = s $0 "\n" }
	END {
		n = length(s)
		start = index(s, "[")
		if (start == 0) exit 1
		depth = 0; instr = 0; esc = 0; cur = ""; found = 0
		for (i = start + 1; i <= n; i++) {
			c = substr(s, i, 1)
			if (instr) {
				cur = cur c
				if (esc) esc = 0
				else if (c == "\\") esc = 1
				else if (c == "\"") instr = 0
				continue
			}
			if (c == "\"") { instr = 1; cur = cur c; continue }
			if (c == "{" || c == "[") { depth++; cur = cur c; continue }
			if (c == "}" || c == "]") {
				if (c == "]" && depth == 0) {
					gsub(/[\r\n]+/, " ", cur)
					if (cur ~ /[^ \t]/) emit(cur)
					found = 1
					break
				}
				depth--
				cur = cur c
				continue
			}
			if (c == "," && depth == 0) {
				gsub(/[\r\n]+/, " ", cur)
				if (cur ~ /[^ \t]/) emit(cur)
				cur = ""
				continue
			}
			cur = cur c
		}
		if (!found) exit 1
	}
	' "$1"
}

# ---------------------------------------------------------------- validation
cloud_valid_remote_name() {
	# remote-name 会直接进 argv，也是远端路径的一段：这是唯一的防线。
	#   1..128 个 [A-Za-z0-9._-]，不能以 - 开头（防选项注入），
	#   且不能是 . / ..（否则 $REMOTE/.. 会指到 /apps/bdpan 上层）。
	local n="${1:-}"
	[ -n "$n" ] || return 1
	[ ${#n} -ge 1 ] && [ ${#n} -le 128 ] || return 1
	case "$n" in
		*[!A-Za-z0-9._-]*) return 1 ;;
	esac
	case "$n" in
		-*|.|..) return 1 ;;
	esac
	return 0
}

# ---------------------------------------------------------------- crypto / pass
# 加解密全部交给 Node（OpenWrt 上不保证有 openssl）。脚本经 -e 传入，本身不是
# 秘密；口令只走 stdin（调用方用 heredoc 喂入），因此不会出现在
# /proc/<pid>/cmdline 里。文件一律流式处理，几百 MB 的备份也不会整读进内存。
#
# 注意：下面这段 JS 里不要出现单引号 / 反引号 / $，否则会破坏 shell 的
# 单引号字符串（busybox ash 没有更省事的转义办法）。
OC_CRYPTO_JS='
const fs = require("fs");
const crypto = require("crypto");
const { pipeline } = require("stream");

const MAGIC = Buffer.from("OCBK1\n", "latin1");
const HDR = 51;
const VERSION = 1;
const mode = process.argv[1];
const src = process.argv[2];
const dst = process.argv[3];

function die(msg, code) {
	process.stderr.write(String(msg) + "\n");
	process.exit(code || 1);
}

function kdf(pass, salt) {
	return crypto.scryptSync(pass, salt, 32, { N: 16384, r: 8, p: 1, maxmem: 67108864 });
}

function enc(pass) {
	const salt = crypto.randomBytes(16);
	const iv = crypto.randomBytes(12);
	let key;
	try { key = kdf(pass, salt); } catch (e) { die("scrypt failed: " + e.message); }
	const hdr = Buffer.alloc(HDR);
	MAGIC.copy(hdr, 0);
	hdr[6] = VERSION;
	salt.copy(hdr, 7);
	iv.copy(hdr, 23);
	try {
		fs.writeFileSync(dst, hdr, { mode: 0o600, flag: "wx" });
	} catch (e) {
		die("cannot create output: " + e.message, e.code === "EEXIST" ? 3 : 1);
	}
	const cipher = crypto.createCipheriv("aes-256-gcm", key, iv);
	const rs = fs.createReadStream(src);
	const ws = fs.createWriteStream(dst, { flags: "r+", start: HDR });
	pipeline(rs, cipher, ws, function (err) {
		if (err) {
			try { fs.unlinkSync(dst); } catch (e2) {}
			die("encrypt failed: " + err.message);
		}
		let tag;
		try { tag = cipher.getAuthTag(); } catch (e) { die("no auth tag: " + e.message); }
		try {
			const fd = fs.openSync(dst, "r+");
			try {
				fs.writeSync(fd, tag, 0, tag.length, 35);
				fs.fsyncSync(fd);
			} finally {
				fs.closeSync(fd);
			}
		} catch (e) {
			try { fs.unlinkSync(dst); } catch (e2) {}
			die("cannot write tag: " + e.message);
		}
	});
}

function dec(pass) {
	let hdr;
	try {
		const fd = fs.openSync(src, "r");
		try {
			hdr = Buffer.alloc(HDR);
			const n = fs.readSync(fd, hdr, 0, HDR, 0);
			if (n !== HDR) die("header truncated");
		} finally {
			fs.closeSync(fd);
		}
	} catch (e) {
		die("cannot read header: " + e.message);
	}
	if (!hdr.subarray(0, 6).equals(MAGIC)) die("bad magic");
	if (hdr[6] !== VERSION) die("unsupported version: " + hdr[6]);
	const salt = hdr.subarray(7, 23);
	const iv = hdr.subarray(23, 35);
	const tag = hdr.subarray(35, 51);
	let key;
	try { key = kdf(pass, salt); } catch (e) { die("scrypt failed: " + e.message); }
	const ds = crypto.createDecipheriv("aes-256-gcm", key, iv);
	ds.setAuthTag(tag);
	const rs = fs.createReadStream(src, { start: HDR });
	const ws = fs.createWriteStream(dst, { flags: "wx", mode: 0o600 });
	pipeline(rs, ds, ws, function (err) {
		if (err) {
			// EEXIST 说明目标不是本次创建的，绝不能删掉它
			if (err.code !== "EEXIST") {
				try { fs.unlinkSync(dst); } catch (e2) {}
			}
			die("decrypt failed: " + err.message, err.code === "EEXIST" ? 3 : 1);
		}
	});
}

let pass = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", function (d) { pass += d; });
process.stdin.on("end", function () {
	pass = pass.replace(/\r?\n$/, "");
	if (pass.length === 0) die("empty password");
	if (mode === "enc") enc(pass);
	else if (mode === "dec") dec(pass);
	else die("unknown mode: " + mode);
});
'

# 失败原因（不含口令）；由 cloud_crypto 写入，调用方拼进 JSON。
OC_CRYPTO_ERR=""

cloud_node_ready() {
	local nb
	nb="$(oc_node_bin)"
	[ -n "$nb" ] && [ -x "$nb" ] || return 1
	printf '%s' "$nb"
}

cloud_crypto() {
	# cloud_crypto <enc|dec> <src> <dst>
	# 口令从 stdin 读（调用方用 heredoc 喂入）。成功 0；失败返回 node 的退出码
	# （3 = 目标已存在，调用方据此避免误删别人的文件），原因在 $OC_CRYPTO_ERR。
	local mode="$1" src="$2" dst="$3" nb errf msg rc
	nb="$(cloud_node_ready)" || {
		OC_CRYPTO_ERR="Node.js 不可用（$(oc_node_bin)）"
		return 1
	}
	errf="$OC_RUNDIR/cloud-crypto.$$.err"
	rm -f "$errf" 2>/dev/null
	"$nb" -e "$OC_CRYPTO_JS" "$mode" "$src" "$dst" 2>"$errf"
	rc=$?
	if [ "$rc" -eq 0 ]; then
		rm -f "$errf" 2>/dev/null
		OC_CRYPTO_ERR=""
		return 0
	fi
	msg="$(head -n 3 "$errf" 2>/dev/null | tr -d '\r' | tr '\n' ' ')"
	rm -f "$errf" 2>/dev/null
	OC_CRYPTO_ERR="${msg:-未知错误}"
	return "$rc"
}

# 临时文件统一登记在这里，由 EXIT / INT / TERM trap 清理。
# 只删具体文件 + rmdir，绝不递归删除。
OC_TMPDIR=""
OC_TMPFILE=""
OC_TMPFILE2=""

cloud_tmp_cleanup() {
	if [ -n "$OC_TMPFILE" ]; then
		rm -f "$OC_TMPFILE" 2>/dev/null
	fi
	if [ -n "$OC_TMPFILE2" ]; then
		rm -f "$OC_TMPFILE2" 2>/dev/null
	fi
	if [ -n "$OC_TMPDIR" ]; then
		rmdir "$OC_TMPDIR" 2>/dev/null
	fi
	OC_TMPFILE=""
	OC_TMPFILE2=""
	OC_TMPDIR=""
	return 0
}

cloud_tmp_trap() {
	trap 'cloud_tmp_cleanup' EXIT
	trap 'cloud_tmp_cleanup; exit 1' INT TERM HUP
}

cloud_pass_present() {
	# 存在且非空才算「已设置」：空的 pass 文件无法作为口令使用。
	[ -f "$OC_CLOUD_PASS" ] && [ -s "$OC_CLOUD_PASS" ]
}

cloud_pass_read() {
	# stdout: 口令原文；未设置 / 不可读时返回 1。
	# 调用方只能用命令替换接收，绝不能把它拼进日志或 JSON。
	cloud_pass_present || return 1
	cat "$OC_CLOUD_PASS" 2>/dev/null
}

cmd_pass_status() {
	local set=false hint
	if cloud_pass_present; then
		set=true
		hint="已设置（保存在本机，不会上传）"
	else
		hint="未设置（上传的备份不会加密）"
	fi
	# 只回 set / hint：绝不返回口令本身，也不返回任何可用来猜解的摘要。
	printf '{"ok":true,"set":%s,"hint":"%s"}\n' "$set" "$(jstr "$hint")"
}

cmd_set_pass() {
	local pass tmp n
	oc_validate_base_dir "$(oc_base_dir)" || cloud_fail "安装目录不可用：$(oc_base_dir)"
	cloud_ensure_dirs || cloud_fail "无法创建云备份目录：$OC_CLOUD_DIR"

	# 口令只从 stdin 读。tr -d '\r' 兼容 CRLF；命令替换会去掉行尾换行。
	pass="$(tr -d '\r')"
	n=${#pass}
	if [ "$n" -lt 8 ] || [ "$n" -gt 128 ]; then
		cloud_fail "口令长度必须为 8-128 个字符"
	fi
	case "$pass" in
		*[[:cntrl:]]*) cloud_fail "口令不能包含控制字符" ;;
	esac
	case "$pass" in
		*[![:space:]]*) ;;
		*) cloud_fail "口令不能全是空格" ;;
	esac

	# 先写同目录临时文件（umask 077 + chmod 600），再 mv 原子替换。
	# 下面这一处 printf 是口令唯一的落盘点：目标是 0600 私有文件，
	# 绝不重定向到 stdout / stderr / 日志。
	tmp="$OC_CLOUD_DIR/.pass.$$"
	rm -f "$tmp" 2>/dev/null
	if ! ( umask 077; printf '%s' "$pass" > "$tmp" ) 2>/dev/null; then
		rm -f "$tmp" 2>/dev/null
		cloud_fail "无法写入口令文件"
	fi
	chmod 600 "$tmp" 2>/dev/null
	chown 0:0 "$tmp" 2>/dev/null || true
	if ! mv -f "$tmp" "$OC_CLOUD_PASS" 2>/dev/null; then
		rm -f "$tmp" 2>/dev/null
		cloud_fail "无法保存口令文件"
	fi
	chmod 600 "$OC_CLOUD_PASS" 2>/dev/null
	pass=""
	printf '{"ok":true}\n'
}

cmd_clear_pass() {
	# 只删这一个文件；不存在也算成功（幂等）。
	if [ -f "$OC_CLOUD_PASS" ] || [ -L "$OC_CLOUD_PASS" ]; then
		rm -f "$OC_CLOUD_PASS" 2>/dev/null || cloud_fail "无法删除口令文件"
	fi
	printf '{"ok":true}\n'
}

# ---------------------------------------------------------------- status
cmd_status() {
	local arch bin installed=false path="" ver="" logged=false user="" expires="" raw=""
	local tmp rc out jlog k

	arch="$(cloud_arch)"

	bin="$(cloud_bin)" || bin=""
	if [ -n "$bin" ]; then
		installed=true
		path="$bin"
	fi

	if [ "$installed" = "true" ] && [ -x "$bin" ]; then
		ver="$(cloud_run 30 "$bin" version 2>/dev/null | head -n1)"
		ver="$(printf '%s' "$ver" | tr -d '\000-\037\177')"
	elif [ -n "$bin" ]; then
		oc_warn "找到 bdpan（$bin）但不可执行，请重新安装组件"
	fi

	if [ "$installed" = "true" ] && [ -x "$bin" ]; then
		tmp="$OC_RUNDIR/cloud-whoami.$$"
		rm -f "$tmp" 2>/dev/null
		cloud_run 25 "$bin" whoami --json >"$tmp" 2>&1
		rc=$?
		if [ "$rc" -ne 0 ]; then
			# 老版本 CLI 可能没有 --json
			cloud_run 25 "$bin" whoami >"$tmp" 2>&1
			rc=$?
		fi
		out="$(cat "$tmp" 2>/dev/null)"
		# raw 只放 whoami 的输出，且先脱敏、截断；绝不包含 config.json。
		raw="$(cloud_redact <"$tmp" 2>/dev/null | head -c 500)"

		jlog="$(cloud_json_scalar "$tmp" logged_in)"
		[ -n "$jlog" ] || jlog="$(cloud_json_scalar "$tmp" loggedIn)"
		[ -n "$jlog" ] || jlog="$(cloud_json_scalar "$tmp" is_login)"
		[ -n "$jlog" ] || jlog="$(cloud_json_scalar "$tmp" isLogin)"
		case "$jlog" in
			true|TRUE|True|1|yes|Yes)    logged=true ;;
			false|FALSE|False|0|no|No)   logged=false ;;
			*)
				case "$out" in
					*未登录*|*"not logged in"*|*"Not logged in"*|*"not login"*|*"no login"*|*"login required"*|*"please login"*|*请先登录*|*未授权*)
						logged=false ;;
					*已登录*|*"logged in"*|*"Logged in"*|*"login as"*|*用户名*|*[Uu]sername*)
						logged=true ;;
					*)
						[ "$rc" -eq 0 ] && logged=true || logged=false ;;
				esac ;;
		esac

		if [ "$logged" = "true" ]; then
			for k in user_name userName display_name displayName nickname nick_name username user name; do
				user="$(cloud_json_scalar "$tmp" "$k")"
				case "$user" in
					''|null|NULL) user="" ;;
					*) break ;;
				esac
			done
			if [ -z "$user" ]; then
				user="$(sed -n 's/.*用户名[[:space:]]*[:：][[:space:]]*\([^[:space:]]*\).*/\1/p' "$tmp" 2>/dev/null | head -n1)"
			fi
			if [ -z "$user" ]; then
				user="$(sed -n 's/.*[Uu]sername[[:space:]]*[:：=][[:space:]]*\([^[:space:]]*\).*/\1/p' "$tmp" 2>/dev/null | head -n1)"
			fi

			for k in expires_at expiresAt expire_time expireTime expires expire_at expireAt expiry valid_until; do
				expires="$(cloud_json_scalar "$tmp" "$k")"
				case "$expires" in
					''|null|NULL) expires="" ;;
					*) break ;;
				esac
			done
			if [ -z "$expires" ]; then
				expires="$(sed -n 's/.*\(有效期\|到期时间\|expire[sd]*\|expiry\)[[:space:]]*[:：=][[:space:]]*\([^[:space:]]*\).*/\2/p' "$tmp" 2>/dev/null | head -n1)"
			fi
		fi
		rm -f "$tmp" 2>/dev/null
	fi

	printf '{"ok":true,"arch":"%s","cli":{"installed":%s,"path":"%s","version":"%s"},"auth":{"logged_in":%s,"user":"%s","expires":"%s","raw":"%s"},"remote_dir":"%s","dir":"%s","home":"%s"}\n' \
		"$arch" "$installed" "$(jstr "$path")" "$(jstr "$ver")" \
		"$logged" "$(jstr "$user")" "$(jstr "$expires")" "$(jstr "$raw")" \
		"$(jstr "$OC_CLOUD_REMOTE")" "$(jstr "$OC_CLOUD_DIR")" "$(jstr "$OC_CLOUD_HOME")"
}

# ---------------------------------------------------------------- install-cli
cmd_install_cli() {
	local arch ver url dest size magic mach sha out rc err bin vout ver_out

	arch="$(cloud_arch)"
	if [ "$arch" = "unsupported" ]; then
		printf '{"ok":false,"error":"%s"}\n' "$(jstr "不支持的架构：$(uname -m 2>/dev/null)")"
		exit 2
	fi

	if ! oc_validate_base_dir "$(oc_base_dir)"; then
		cloud_fail "安装目录不可用：$(oc_base_dir)"
	fi
	if [ ! -d "$OC_RUNDIR" ] || [ ! -w "$OC_RUNDIR" ]; then
		cloud_fail "临时目录不可用：$OC_RUNDIR"
	fi
	cloud_ensure_dirs || cloud_fail "无法创建云备份目录：$OC_CLOUD_DIR"

	ver="$(uci_get main.bdpan_version "$OC_CLOUD_DEFAULT_VERSION")"
	[ -n "$ver" ] || ver="$OC_CLOUD_DEFAULT_VERSION"
	case "$ver" in
		*[!0-9A-Za-z._-]*) cloud_fail "bdpan 版本号非法：$ver" ;;
	esac
	url="$OC_CLOUD_CDN/$ver/bdpan-installer-linux-$arch"

	dest="$OC_RUNDIR/bdpan-installer-$arch.$$"
	rm -f "$dest" 2>/dev/null
	cblog "下载百度网盘组件安装器：$url"
	if ! oc_fetch "$url" "$dest" 600; then
		rm -f "$dest" 2>/dev/null
		cloud_fail "下载安装器失败：$url"
	fi
	[ -f "$dest" ] || cloud_fail "下载安装器失败：文件不存在"

	size="$(wc -c <"$dest" 2>/dev/null | tr -d ' ')"
	case "$size" in ''|*[!0-9]*) size=0 ;; esac
	if [ "$size" -le 5242880 ]; then
		rm -f "$dest" 2>/dev/null
		cloud_fail "安装器体积异常（${size} 字节，期望 > 5MB）"
	fi

	magic="$(od -An -tx1 -N4 "$dest" 2>/dev/null | tr -d ' \n')"
	if [ "$magic" != "7f454c46" ]; then
		rm -f "$dest" 2>/dev/null
		cloud_fail "下载内容不是 ELF 可执行文件（magic=${magic:-未知}）"
	fi

	# ELF e_machine（偏移 18，小端 2 字节）：arm64=0xb7，x86_64=0x3e
	mach="$(od -An -tx1 -j18 -N2 "$dest" 2>/dev/null | tr -d ' \n')"
	case "$arch:$mach" in
		arm64:b700|amd64:3e00) ;;
		*)
			rm -f "$dest" 2>/dev/null
			cloud_fail "安装器架构不匹配：期望 $arch，ELF machine=${mach:-未知}" ;;
	esac

	if command -v sha256sum >/dev/null 2>&1; then
		sha="$(sha256sum "$dest" 2>/dev/null | awk '{print $1}')"
		[ -n "$sha" ] && oc_warn "安装器 sha256：$sha（官方未公布校验值，仅记录备查）"
	fi
	chmod 700 "$dest" 2>/dev/null || true

	out="$OC_RUNDIR/bdpan-install-$$.log"
	rm -f "$out" 2>/dev/null
	cblog "运行安装器（私有 HOME=$OC_CLOUD_HOME）"
	(
		export HOME="$OC_CLOUD_HOME"
		export TMPDIR="$OC_RUNDIR"
		oc_timeout 600 "$dest" --install-dir "$OC_CLOUD_DIR" --yes
	) >"$out" 2>&1 </dev/null
	rc=$?
	if [ "$rc" -ne 0 ]; then
		oc_warn "安装器带 --install-dir/--yes 调用失败（rc=$rc），尝试裸调用"
		(
			export HOME="$OC_CLOUD_HOME"
			export TMPDIR="$OC_RUNDIR"
			oc_timeout 600 "$dest"
		) >>"$out" 2>&1 </dev/null
		rc=$?
	fi
	if [ "$rc" -ne 0 ]; then
		err="$(tail -n 20 "$out" 2>/dev/null | cloud_redact | head -c 2000)"
		[ -n "$err" ] || err="无输出"
		rm -f "$dest" "$out" 2>/dev/null
		cloud_fail "安装器执行失败（rc=$rc）：$err"
	fi
	rm -f "$dest" "$out" 2>/dev/null

	bin="$(cloud_bin)" || cloud_fail "安装完成但未找到 bdpan 可执行文件"
	chmod +x "$bin" 2>/dev/null || true
	[ -x "$bin" ] || cloud_fail "安装后的 bdpan 不可执行：$bin"

	vout="$OC_RUNDIR/bdpan-ver-$$.log"
	rm -f "$vout" 2>/dev/null
	cloud_run 30 "$bin" version >"$vout" 2>&1
	rc=$?
	ver_out="$(head -n1 "$vout" 2>/dev/null | cloud_redact | tr -d '\000-\037\177')"
	rm -f "$vout" 2>/dev/null
	if [ "$rc" -ne 0 ]; then
		cloud_fail "安装后无法执行：${ver_out:-rc=$rc}"
	fi

	printf '{"ok":true,"path":"%s","version":"%s","arch":"%s"}\n' \
		"$(jstr "$bin")" "$(jstr "$ver_out")" "$arch"
}

# ---------------------------------------------------------------- login
cmd_login_url() {
	local bin tmp rc out url

	bin="$(cloud_bin_ready)" || cloud_fail "请先安装网盘组件"
	tmp="$OC_RUNDIR/cloud-loginurl.$$"
	rm -f "$tmp" 2>/dev/null
	cloud_run 60 "$bin" login --get-auth-url >"$tmp" 2>&1
	rc=$?

	# 取输出里第一个 http(s) 链接（排除空白、引号、尖括号与右括号）
	url="$(awk 'match($0, /https?:\/\/[^[:space:]"<>)]+/) { print substr($0, RSTART, RLENGTH); exit }' "$tmp" 2>/dev/null)"
	out="$(cat "$tmp" 2>/dev/null)"
	rm -f "$tmp" 2>/dev/null

	if [ -z "$url" ]; then
		out="$(printf '%s' "$out" | cloud_redact | head -c 500)"
		cloud_fail "无法获取授权链接（rc=$rc）：${out:-无输出}"
	fi
	oc_safe_url "$url" || cloud_fail "授权链接格式异常：$url"
	printf '{"ok":true,"url":"%s"}\n' "$(jstr "$url")"
}

cloud_whoami_user() {
	# cloud_whoami_user <bdpan> -> 用户名（取不到时为空）
	local bin="$1" tmp user k
	tmp="$OC_RUNDIR/cloud-whoami.$$"
	rm -f "$tmp" 2>/dev/null
	cloud_run 25 "$bin" whoami --json >"$tmp" 2>&1 || \
		cloud_run 25 "$bin" whoami >"$tmp" 2>&1
	for k in user_name userName display_name displayName nickname nick_name username user name; do
		user="$(cloud_json_scalar "$tmp" "$k")"
		case "$user" in
			''|null|NULL) user="" ;;
			*) break ;;
		esac
	done
	if [ -z "$user" ]; then
		user="$(sed -n 's/.*用户名[[:space:]]*[:：][[:space:]]*\([^[:space:]]*\).*/\1/p' "$tmp" 2>/dev/null | head -n1)"
	fi
	if [ -z "$user" ]; then
		user="$(sed -n 's/.*[Uu]sername[[:space:]]*[:：=][[:space:]]*\([^[:space:]]*\).*/\1/p' "$tmp" 2>/dev/null | head -n1)"
	fi
	rm -f "$tmp" 2>/dev/null
	printf '%s' "$user"
}

cmd_login_code() {
	local code="${1:-}" bin tmp rc out user

	[ -n "$code" ] || cloud_fail "缺少授权码"
	# 授权码会直接进 argv：这是唯一的防线，只允许 [A-Za-z0-9_-]，长度 4..64。
	case "$code" in
		*[!A-Za-z0-9_-]*) cloud_fail "授权码格式不正确（只允许字母、数字、_ 和 -）" ;;
	esac
	if [ ${#code} -lt 4 ] || [ ${#code} -gt 64 ]; then
		cloud_fail "授权码长度不正确（应为 4-64 个字符）"
	fi

	bin="$(cloud_bin_ready)" || cloud_fail "请先安装网盘组件"
	tmp="$OC_RUNDIR/cloud-logincode.$$"
	rm -f "$tmp" 2>/dev/null
	cloud_run 60 "$bin" login --set-code "$code" >"$tmp" 2>&1
	rc=$?
	# 输出里若回显了授权码，一并抹掉；日志里也绝不写 code。
	out="$(cloud_scrub_code "$tmp" "$code" | cloud_redact | tail -n 5 | head -c 800)"
	rm -f "$tmp" 2>/dev/null

	[ "$rc" -eq 0 ] || cloud_fail "授权失败（rc=$rc）：${out:-无输出}"
	user="$(cloud_whoami_user "$bin")"
	printf '{"ok":true,"user":"%s"}\n' "$(jstr "$user")"
}

cmd_logout() {
	local bin tmp rc out

	bin="$(cloud_bin_ready)" || cloud_fail "请先安装网盘组件"
	tmp="$OC_RUNDIR/cloud-logout.$$"
	rm -f "$tmp" 2>/dev/null
	cloud_run 60 "$bin" logout >"$tmp" 2>&1
	rc=$?
	out="$(cloud_tail_err "$tmp" 5 | head -c 800)"
	rm -f "$tmp" 2>/dev/null
	[ "$rc" -eq 0 ] || cloud_fail "退出登录失败（rc=$rc）：${out:-无输出}"
	printf '{"ok":true}\n'
}

# ---------------------------------------------------------------- upload
cloud_remote_size() {
	# cloud_remote_size <bdpan> <name> -> 远端 size（取不到时返回 1）
	local bin="$1" name="$2" tmp rc sz
	tmp="$OC_RUNDIR/cloud-ls.$$"
	rm -f "$tmp" 2>/dev/null
	cloud_run 60 "$bin" ls "$OC_CLOUD_REMOTE" --json >"$tmp" 2>&1
	rc=$?
	if [ "$rc" -ne 0 ]; then
		rm -f "$tmp" 2>/dev/null
		return 1
	fi
	sz="$(cloud_ls_tsv "$tmp" | awk -F '\t' -v n="$name" '$3 == n { print $4; exit }')"
	rm -f "$tmp" 2>/dev/null
	[ -n "$sz" ] || return 1
	printf '%s' "$sz"
}

cmd_upload() {
	local local_path="${1:-}" name="${2:-}" bin tmp rc size lsize err
	local encrypted=false remote_name upload_path encdir enc_out csize magic ver pass

	[ -n "$local_path" ] || cloud_fail "缺少本地文件路径"
	[ -n "$name" ] || cloud_fail "缺少远端文件名"
	cloud_valid_remote_name "$name" || \
		cloud_fail "远端文件名不合法（只允许字母数字与 . _ -，不能以 - 开头，长度 1-128）"
	# .enc 是本批定义的加密标记：明文文件若以它结尾，下载时会被当成加密备份
	# 而无法恢复，所以上传阶段直接拒绝（加密上传会自行追加 .enc）。
	case "$name" in
		*.enc) cloud_fail "远端文件名不能以 .enc 结尾（该后缀保留给加密备份）" ;;
	esac
	case "$local_path" in
		/*) ;;
		*) cloud_fail "本地路径必须是绝对路径：$local_path" ;;
	esac
	[ -e "$local_path" ] || cloud_fail "本地文件不存在：$local_path"
	[ -f "$local_path" ] || cloud_fail "不是普通文件：$local_path"

	bin="$(cloud_bin_ready)" || cloud_fail "请先安装网盘组件"

	lsize="$(wc -c <"$local_path" 2>/dev/null | tr -d ' ')"
	case "$lsize" in ''|*[!0-9]*) lsize=0 ;; esac

	remote_name="$name"
	upload_path="$local_path"

	if cloud_pass_present; then
		# 有口令 -> 先加密到私有 rundir，校验通过后才上传。
		remote_name="$name.enc"
		cloud_valid_remote_name "$remote_name" || \
			cloud_fail "远端文件名过长：加密后为 $remote_name（上限 128 字符）"
		encdir="$OC_RUNDIR/cloud-enc.$$"
		rmdir "$encdir" 2>/dev/null || true
		# 与 oc_rundir 同样的处理：某些文件系统上 mkdir -m 会「建成了但改权限失败」，
		# 不能因此放弃；随后再 chmod 一次。
		mkdir -m 700 "$encdir" 2>/dev/null
		if [ ! -d "$encdir" ]; then
			cloud_fail "无法创建加密临时目录"
		fi
		chmod 700 "$encdir" 2>/dev/null || true
		OC_TMPDIR="$encdir"
		enc_out="$encdir/$remote_name"
		OC_TMPFILE="$enc_out"
		cloud_tmp_trap

		pass="$(cloud_pass_read)" || pass=""
		if [ -z "$pass" ]; then
			cloud_tmp_cleanup
			cloud_fail "未设置加密口令"
		fi
		cblog "加密 $(basename "$local_path") -> $remote_name"
		cloud_crypto enc "$local_path" "$enc_out" <<EOF
$pass
EOF
		rc=$?
		pass=""
		if [ "$rc" -ne 0 ]; then
			cloud_tmp_cleanup
			cloud_fail "加密失败：${OC_CRYPTO_ERR:-未知错误}"
		fi

		# 校验：GCM 是流式加密，密文长度必须正好是明文 + 51 字节头。
		# 头部魔数 / 版本也读一遍，确认写出的确实是本格式而不是半成品。
		csize="$(wc -c <"$enc_out" 2>/dev/null | tr -d ' ')"
		case "$csize" in ''|*[!0-9]*) csize=0 ;; esac
		if [ "$csize" -ne $((lsize + 51)) ]; then
			cloud_tmp_cleanup
			cloud_fail "加密校验失败：密文 ${csize} 字节，期望 $((lsize + 51)) 字节"
		fi
		magic="$(od -An -tx1 -N6 "$enc_out" 2>/dev/null | tr -d ' \n')"
		ver="$(od -An -tu1 -j6 -N1 "$enc_out" 2>/dev/null | tr -d ' \n')"
		if [ "$magic" != "4f43424b310a" ] || [ "$ver" != "1" ]; then
			cloud_tmp_cleanup
			cloud_fail "加密校验失败：文件头不是 OCBK1/v1"
		fi
		encrypted=true
		upload_path="$enc_out"
	fi

	# 远端目录：已存在会失败，忽略即可
	tmp="$OC_RUNDIR/cloud-upload.$$"
	rm -f "$tmp" 2>/dev/null
	cloud_run 60 "$bin" mkdir "$OC_CLOUD_REMOTE" >"$tmp" 2>&1 || true
	rm -f "$tmp" 2>/dev/null

	cblog "上传 $(basename "$upload_path") -> $OC_CLOUD_REMOTE/$remote_name"
	cloud_run 600 "$bin" upload "$upload_path" "$OC_CLOUD_REMOTE/$remote_name" >"$tmp" 2>&1
	rc=$?
	if [ "$rc" -ne 0 ]; then
		err="$(cloud_tail_err "$tmp" 8)"
		rm -f "$tmp" 2>/dev/null
		cloud_tmp_cleanup
		cloud_fail "上传失败（rc=$rc）：${err:-无输出}"
	fi
	rm -f "$tmp" 2>/dev/null

	size="$(cloud_remote_size "$bin" "$remote_name")"
	case "$size" in
		''|*[!0-9]*)
			if [ "$encrypted" = "true" ]; then
				size="$csize"
			else
				size="$lsize"
			fi
			oc_warn "上传成功但未能从远端列表确认大小，使用本地大小 $size" ;;
	esac
	cloud_tmp_cleanup
	printf '{"ok":true,"remote":"%s","size":%s,"encrypted":%s}\n' \
		"$(jstr "$OC_CLOUD_REMOTE/$remote_name")" "$size" "$encrypted"
}

# ---------------------------------------------------------------- ls
cmd_ls() {
	local bin tmp rc out tsv err d mt name size tab sorted display enc

	bin="$(cloud_bin_ready)" || {
		oc_warn "网盘组件未安装，返回空列表"
		printf '{"ok":true,"data":[]}\n'
		return 0
	}

	tmp="$OC_RUNDIR/cloud-ls.$$"
	rm -f "$tmp" 2>/dev/null
	cloud_run 60 "$bin" ls "$OC_CLOUD_REMOTE" --json >"$tmp" 2>&1
	rc=$?
	out="$(cat "$tmp" 2>/dev/null)"

	if [ "$rc" -ne 0 ]; then
		case "$out" in
			*不存在*|*"not exist"*|*"No such"*|*"no such file"*|*未登录*|*"not logged"*|*"login required"*|*请先登录*)
				rm -f "$tmp" 2>/dev/null
				printf '{"ok":true,"data":[]}\n'
				return 0 ;;
		esac
		err="$(cloud_tail_err "$tmp" 8)"
		rm -f "$tmp" 2>/dev/null
		cloud_fail "读取网盘目录失败（rc=$rc）：${err:-无输出}"
	fi

	if ! tsv="$(cloud_ls_tsv "$tmp")"; then
		case "$out" in
			''|*不存在*|*"not exist"*|*"No such"*|*"no such file"*|*未登录*|*"not logged"*|*"login required"*|*请先登录*)
				rm -f "$tmp" 2>/dev/null
				printf '{"ok":true,"data":[]}\n'
				return 0 ;;
		esac
		err="$(cloud_tail_err "$tmp" 8)"
		rm -f "$tmp" 2>/dev/null
		cloud_fail "网盘目录返回内容无法解析：${err:-无输出}"
	fi
	rm -f "$tmp" 2>/dev/null

	tab="$(printf '\t')"
	# 目录在前；其余按 mtime 倒序（ISO 时间串可直接按字符串比较）。
	sorted="$(printf '%s\n' "$tsv" | sort -t "$tab" -k1,1r -k2,2r 2>/dev/null)" || sorted="$tsv"

	printf '{"ok":true,"data":['
	# while 在管道里会进子 shell，"首项"标记回传不出来；改为每个对象单独一行，
	# 再由 awk 负责插入逗号。
	printf '%s\n' "$sorted" | while IFS="$tab" read -r d mt name size; do
		[ -n "$name" ] || continue
		case "$size" in ''|*[!0-9]*) size=0 ;; esac
		case "$d" in true) ;; *) d=false ;; esac
		# name 必须是真实远端名（下载要用它）；display 去掉 .enc 便于展示。
		enc=false
		display="$name"
		case "$name" in
			*.enc)
				enc=true
				display="${name%.enc}"
				# 文件正好叫 ".enc" 时不要展示成空串
				[ -n "$display" ] || display="$name" ;;
		esac
		printf '{"name":"%s","display":"%s","size":%s,"mtime":"%s","isdir":%s,"encrypted":%s}\n' \
			"$(jstr "$name")" "$(jstr "$display")" "$size" "$(jstr "$mt")" "$d" "$enc"
	done | awk 'BEGIN { first = 1 } NF {
		if (first) { printf "%s", $0; first = 0 }
		else { printf ",%s", $0 }
	}'
	printf ']}\n'
}

# ---------------------------------------------------------------- download
cloud_download_run() {
	# cloud_download_run <remote-name> <local-path> <pass>
	# <pass> 为空时回退到本机保存的口令。口令只是 shell 变量，不进 argv。
	# .enc 文件先下载到私有临时目录，再流式解密到 local-path。
	local name="$1" local_path="$2" pass="$3"
	local bin tmp rc size parent err encrypted=false workdir cin csize

	[ -n "$name" ] || cloud_fail "缺少远端文件名"
	[ -n "$local_path" ] || cloud_fail "缺少本地目标路径"
	cloud_valid_remote_name "$name" || \
		cloud_fail "远端文件名不合法（只允许字母数字与 . _ -，不能以 - 开头，长度 1-128）"
	case "$local_path" in
		/*) ;;
		*) cloud_fail "本地路径必须是绝对路径：$local_path" ;;
	esac
	case "$local_path" in
		*/) cloud_fail "本地路径不能以 / 结尾：$local_path" ;;
	esac
	# 不允许覆盖：-e 对悬空符号链接为假，必须同时看 -L
	if [ -e "$local_path" ] || [ -L "$local_path" ]; then
		cloud_fail "目标文件已存在，拒绝覆盖：$local_path"
	fi
	parent="$(dirname "$local_path")"
	[ -d "$parent" ] || cloud_fail "父目录不存在：$parent"
	[ -w "$parent" ] || cloud_fail "父目录不可写：$parent"

	bin="$(cloud_bin_ready)" || cloud_fail "请先安装网盘组件"

	case "$name" in
		*.enc)
			encrypted=true
			if [ -z "$pass" ]; then
				pass="$(cloud_pass_read)" || pass=""
			fi
			[ -n "$pass" ] || cloud_fail "这是加密备份，请提供解密口令"
			workdir="$OC_RUNDIR/cloud-dec.$$"
			rmdir "$workdir" 2>/dev/null || true
			mkdir -m 700 "$workdir" 2>/dev/null
			if [ ! -d "$workdir" ]; then
				cloud_fail "无法创建解密临时目录"
			fi
			chmod 700 "$workdir" 2>/dev/null || true
			OC_TMPDIR="$workdir"
			cin="$workdir/$name"
			OC_TMPFILE="$cin"
			cloud_tmp_trap ;;
	esac

	tmp="$OC_RUNDIR/cloud-download.$$"
	rm -f "$tmp" 2>/dev/null

	if [ "$encrypted" = "true" ]; then
		cblog "下载 $OC_CLOUD_REMOTE/$name -> 临时文件（加密备份）"
		cloud_run 900 "$bin" download "$OC_CLOUD_REMOTE/$name" "$cin" >"$tmp" 2>&1
		rc=$?
		if [ "$rc" -ne 0 ]; then
			err="$(cloud_tail_err "$tmp" 8)"
			rm -f "$tmp" 2>/dev/null
			rm -f "$cin" 2>/dev/null
			cloud_tmp_cleanup
			cloud_fail "下载失败（rc=$rc）：${err:-无输出}"
		fi
		rm -f "$tmp" 2>/dev/null
		if [ ! -f "$cin" ]; then
			cloud_tmp_cleanup
			cloud_fail "下载命令已返回，但临时文件不存在：$cin"
		fi
		csize="$(wc -c <"$cin" 2>/dev/null | tr -d ' ')"
		case "$csize" in ''|*[!0-9]*) csize=0 ;; esac
		if [ "$csize" -lt 51 ]; then
			rm -f "$cin" 2>/dev/null
			cloud_tmp_cleanup
			cloud_fail "口令错误或文件已损坏"
		fi

		cloud_crypto dec "$cin" "$local_path" <<EOF
$pass
EOF
		rc=$?
		pass=""
		if [ "$rc" -ne 0 ]; then
			# 3 = 目标已存在：那是别人/前一次留下的文件，不能删。
			if [ "$rc" -ne 3 ]; then
				rm -f "$local_path" 2>/dev/null
			fi
			cblog "解密失败：${OC_CRYPTO_ERR:-未知错误}"
			rm -f "$cin" 2>/dev/null
			cloud_tmp_cleanup
			if [ "$rc" -eq 3 ]; then
				cloud_fail "目标文件已存在，拒绝覆盖：$local_path"
			fi
			cloud_fail "口令错误或文件已损坏"
		fi
		rm -f "$cin" 2>/dev/null
		cloud_tmp_cleanup

		[ -f "$local_path" ] || cloud_fail "解密命令已返回，但目标文件不存在：$local_path"
		size="$(wc -c <"$local_path" 2>/dev/null | tr -d ' ')"
		case "$size" in ''|*[!0-9]*) size=0 ;; esac
		printf '{"ok":true,"path":"%s","size":%s,"decrypted":true}\n' \
			"$(jstr "$local_path")" "$size"
		return 0
	fi

	# 明文下载：保持上一批行为
	cblog "下载 $OC_CLOUD_REMOTE/$name -> $local_path"
	cloud_run 900 "$bin" download "$OC_CLOUD_REMOTE/$name" "$local_path" >"$tmp" 2>&1
	rc=$?
	if [ "$rc" -ne 0 ]; then
		err="$(cloud_tail_err "$tmp" 8)"
		rm -f "$tmp" 2>/dev/null
		# 目标文件在本次调用前并不存在，失败留下的半成品只可能是本次创建的
		[ -e "$local_path" ] && rm -f "$local_path" 2>/dev/null
		cloud_fail "下载失败（rc=$rc）：${err:-无输出}"
	fi
	rm -f "$tmp" 2>/dev/null

	[ -f "$local_path" ] || cloud_fail "下载命令已返回，但目标文件不存在：$local_path"
	size="$(wc -c <"$local_path" 2>/dev/null | tr -d ' ')"
	case "$size" in ''|*[!0-9]*) size=0 ;; esac
	if [ "$size" -le 0 ]; then
		rm -f "$local_path" 2>/dev/null
		cloud_fail "下载的文件为空：$local_path"
	fi
	printf '{"ok":true,"path":"%s","size":%s,"decrypted":false}\n' \
		"$(jstr "$local_path")" "$size"
}

cmd_download() {
	# 明文文件与 .enc 都走同一条实现；.enc 只能用本机保存的口令。
	cloud_download_run "${1:-}" "${2:-}" ""
}

cmd_download_dec() {
	# 口令从 stdin 第一行读（界面放在 POST body 里）；不进 argv / URL。
	# 空行 / 无输入时回退到本机保存的口令。
	local pass
	pass="$(tr -d '\r' | sed -n '1p')"
	cloud_download_run "${1:-}" "${2:-}" "$pass"
}

# ---------------------------------------------------------------- rm
cmd_rm() {
	local name="${1:-}" bin help sub tmp rc out err

	[ -n "$name" ] || cloud_fail "缺少远端文件名"
	cloud_valid_remote_name "$name" || \
		cloud_fail "远端文件名不合法（只允许字母数字与 . _ -，不能以 - 开头，长度 1-128）"
	bin="$(cloud_bin_ready)" || cloud_fail "请先安装网盘组件"

	# 只使用 CLI 自己声明的删除子命令；没有就明确拒绝，绝不自行拼 API。
	help="$(cloud_run 30 "$bin" help 2>&1)"
	[ -n "$help" ] || help="$(cloud_run 30 "$bin" --help 2>&1)"
	sub=""
	if printf '%s\n' "$help" | grep -qE '(^|[^A-Za-z0-9_-])rm([^A-Za-z0-9_-]|$)'; then
		sub="rm"
	elif printf '%s\n' "$help" | grep -qE '(^|[^A-Za-z0-9_-])delete([^A-Za-z0-9_-]|$)'; then
		sub="delete"
	elif printf '%s\n' "$help" | grep -qE '(^|[^A-Za-z0-9_-])remove([^A-Za-z0-9_-]|$)'; then
		sub="remove"
	fi

	tmp="$OC_RUNDIR/cloud-rm.$$"
	rm -f "$tmp" 2>/dev/null

	if [ -z "$sub" ]; then
		# help 不可用：试一次 rm，靠输出判断「没有这个子命令」。
		cloud_run 60 "$bin" rm "$OC_CLOUD_REMOTE/$name" >"$tmp" 2>&1
		rc=$?
		out="$(cat "$tmp" 2>/dev/null)"
		rm -f "$tmp" 2>/dev/null
		[ "$rc" -eq 0 ] && { printf '{"ok":true}\n'; return 0; }
		case "$out" in
			*unknown*|*Unknown*|*unrecognized*|*Unrecognized*|*"invalid command"*|*"no such command"*|*未知*|*不支持*)
				cloud_fail "当前 CLI 不支持删除，请在网盘 App 里删除" ;;
		esac
		err="$(printf '%s' "$out" | cloud_redact | tail -n 5 | head -c 800)"
		cloud_fail "删除失败（rc=$rc）：${err:-无输出}"
	fi

	cloud_run 60 "$bin" "$sub" "$OC_CLOUD_REMOTE/$name" >"$tmp" 2>&1
	rc=$?
	if [ "$rc" -ne 0 ]; then
		err="$(cloud_tail_err "$tmp" 8)"
		rm -f "$tmp" 2>/dev/null
		cloud_fail "删除失败（rc=$rc）：${err:-无输出}"
	fi
	rm -f "$tmp" 2>/dev/null
	printf '{"ok":true}\n'
}

# ---------------------------------------------------------------- dispatch
case "${1:-}" in
	status)      cmd_status ;;
	install-cli) cmd_install_cli ;;
	login-url)   cmd_login_url ;;
	login-code)  shift; cmd_login_code "$@" ;;
	logout)      cmd_logout ;;
	upload)      shift; cmd_upload "$@" ;;
	ls)          cmd_ls ;;
	download)    shift; cmd_download "$@" ;;
	download-dec) shift; cmd_download_dec "$@" ;;
	rm)          shift; cmd_rm "$@" ;;
	pass-status) cmd_pass_status ;;
	set-pass)    cmd_set_pass ;;
	clear-pass)  cmd_clear_pass ;;
	*)
		printf '{"ok":false,"error":"%s"}\n' "$(jstr "未知动作：${1:-}")"
		cat >&2 <<EOF
Usage: cloud.sh {status|install-cli|login-url|login-code <code>|logout|upload <local> <name>|ls|download <name> <local>|download-dec <name> <local>|rm <name>|pass-status|set-pass|clear-pass}
EOF
		exit 2 ;;
esac
