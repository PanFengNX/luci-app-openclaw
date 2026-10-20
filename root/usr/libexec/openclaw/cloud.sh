#!/bin/sh
# openclaw - 百度网盘云备份（后端）
#
# 本脚本只负责「云侧搬运」：组件安装、登录、上传、列表、下载、删除。
# 本地归档的创建 / 校验 / 还原仍由 backup.sh 负责（本批次不调用）。
#
# 用法：
#   cloud.sh status
#   cloud.sh install-cli
#   cloud.sh install-cli-bg [ver]   后台安装；立刻返回，进度用 install-cli-poll 读
#   cloud.sh install-cli-poll        {"ok":..,"running":..,"done":..,"rc":"..","log":".."}
#   cloud.sh cli-check          探测官方 CDN 上可用的最新组件版本
#   cloud.sh cli-update [ver]   更新组件（不给版本时用 cli-check 探测到的 latest）
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
#   cloud.sh encrypt-status    上传前加密开关 + 是否已设口令（不返回口令）
#   cloud.sh set-encrypt       stdin 读一行 0/1，写入 main.cloud_encrypt
#   cloud.sh schedule-status   当前定时备份设置 + crontab 里的那一行
#   cloud.sh schedule-apply    按 UCI 写入/更新 crontab（幂等）
#   cloud.sh schedule-set      stdin 读 key=value，校验后写 UCI 并同步 crontab
#   cloud.sh schedule-clear    从 crontab 删除本脚本的行
#   cloud.sh backup-run        定时任务入口：create -> upload -> prune
#
# 定时备份的约定：
#   * crontab 里只维护一行，行尾带 `# openclaw-cloud` 标记；其它行原样保留。
#   * 改 crontab 一律「同目录临时文件 + 校验 + 备份 + chmod 600 + mv」。
#   * backup-run 由 cron 调用：任何失败都只输出 JSON 并 exit 0，绝不返回非 0。
#   * backup-run 自己取锁（与安装 / 修复 / 还原互斥）、自己写 $OC_TASKLOG。
#
# 约定：
#   * stdout 只有一行 JSON；日志一律 oc_warn / oc_err（stderr）。
#   * 所有 bdpan 调用都带私有 HOME（登录态落点）并用 oc_timeout 包住。
#   * 绝不读取 / 打印 $HOME/.config/bdpan/config.json（内含 access_token）。
#   * 口令绝不进 argv / env / URL / 日志：set-pass 与 download-dec 从 stdin 读，
#     加密上传时从 $OC_CLOUD_PASS（0600）读，经 heredoc 交给 node 的 stdin。
#
# 加密是否启用由 UCI 的 main.cloud_encrypt 决定（0=明文，1=加密，默认 0）；
# 口令只是加密的**必要条件**：cloud_encrypt=1 但没有口令时上传直接报错，
# 绝不静默降级为明文上传。cloud_encrypt=0 时即使本机还留着口令也明文上传。
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
#   $OC_CLOUD_ROOT   云备份父目录（0700）
#   $OC_CLOUD_DIR    组件安装目录（只放程序；安装器 -dir 指这里）
#   $OC_CLOUD_HOME   bdpan 的 HOME（登录态）
#   $OC_CLOUD_PASS   加密口令文件（0600）
#   $OC_CLOUD_BIN    安装后的 bdpan（找不到时在 $OC_CLOUD_ROOT 内搜索）
#
# 分层目的：把「可被安装器覆盖的程序目录」与「登录态 / 口令」分开，
# 重装或更新组件只动 $OC_CLOUD_DIR，绝不会冲掉登录态与口令。

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

OC_CLOUD_ROOT="$(oc_base_dir)/cloud"
OC_CLOUD_DIR="$OC_CLOUD_ROOT/bin"
OC_CLOUD_HOME="$OC_CLOUD_ROOT/home"
OC_CLOUD_PASS="$OC_CLOUD_ROOT/pass"
OC_CLOUD_BIN="$OC_CLOUD_DIR/bdpan"
OC_CLOUD_VERSION_FILE="$OC_CLOUD_DIR/.installed-version"
OC_CLOUD_REMOTE="openclaw-backups"
OC_CLOUD_DEFAULT_VERSION="3.7.3"
# 官方没有版本清单接口（installer/latest/...、latest.json、version.json 都是 404），
# 只能按候选版本逐个探测安装器 URL 是否存在。候选按版本升序排列。
OC_CLOUD_CANDIDATES="3.7.1 3.7.3 3.8.0 3.8.1 3.8.2 3.8.3 3.8.4 3.8.5"
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

oc_byte_val() {
	# oc_byte_val <单个字节>：输出该字节的数值 0-255；判定不了时输出空。
	# `printf '%d' "'<字符>"` 是 POSIX 语义；必须强制 C locale 才是按字节取值。
	LC_ALL=C printf '%d' "'${1:-}" 2>/dev/null
}

oc_utf8_fix_tail() {
	# oc_utf8_fix_tail <字符串>：删掉末尾「不完整」的 UTF-8 序列（最多 3 字节），
	# 完整字符原样保留。只用于按字节截断之后的收尾。
	#
	# 判断方法：往回数末尾的 continuation 字节（0x80-0xBF），再看它们前面那个
	# 字节是不是 lead（0xC0-0xF7）以及它声明的长度是否正好等于 1+continuation 数。
	# 相等 = 完整字符，原样返回；否则把这段不完整的序列整段丢掉。
	local orig="${1:-}" s="${1:-}" len n=0 v need=0
	[ -n "$s" ] || return 0
	len="$(printf '%s' "$s" | wc -c | tr -cd '0-9')"
	[ -n "$len" ] || return 0
	while [ "$n" -lt 3 ] && [ "$n" -lt "$len" ]; do
		v="$(oc_byte_val "$(printf '%s' "$s" | tail -c 1)")"
		case "$v" in ''|*[!0-9]*) break ;; esac
		[ "$v" -ge 128 ] && [ "$v" -le 191 ] || break
		n=$((n + 1))
		len=$((len - 1))
		s="$(printf '%s' "$s" | head -c "$len")"
	done
	v="$(oc_byte_val "$(printf '%s' "$s" | tail -c 1)")"
	case "$v" in
		''|*[!0-9]*) printf '%s' "$s"; return 0 ;;
	esac
	if [ "$v" -ge 192 ] && [ "$v" -le 223 ]; then need=2
	elif [ "$v" -ge 224 ] && [ "$v" -le 239 ]; then need=3
	elif [ "$v" -ge 240 ] && [ "$v" -le 247 ]; then need=4
	fi
	if [ "$need" -eq $((n + 1)) ]; then
		printf '%s' "$orig"          # 完整字符：一个字节都不动
	elif [ "$need" -eq 0 ]; then
		printf '%s' "$s"             # 前面不是 lead：孤立的 continuation 已经丢掉
	else
		printf '%s' "$(printf '%s' "$s" | head -c $((len - 1)))"   # 丢掉残缺的 lead
	fi
}

oc_cut_utf8() {
	# oc_cut_utf8 <bytes>：stdin -> stdout，按字节上限截断但不切坏 UTF-8。
	#
	# `head -c N` 是按字节切的：中文报错很容易在边界上留下半个字符，拼进
	# JSON 后前端 JSON.parse 直接失败，反而看不到原因。这里先按字节截断，
	# 再丢掉最后一行（截断点所在的那行必然不完整），保证输出总是完整行。
	# 如果丢掉后为空（原文只有一行且被切到），回退到「按字节截断但不丢行」：
	# 宁可留半个字符，也不能把唯一的一行报错吞成空串。
	local n="${1:-500}" raw out ended_nl=0
	case "$n" in ''|*[!0-9]*) n=500 ;; esac
	# 末尾追加一个标记字符再取命令替换：$(...) 会吃掉结尾的换行，不补标记
	# 就分不清「原文正好结束在换行处」和「最后一行被切断」，前者会被误删一行。
	raw="$(head -c "$n" 2>/dev/null; printf 'x')"
	case "$raw" in
		*x)
			raw="${raw%x}"
			# 标记前一个字节是换行 = 截断点正好落在行边界上，全部行都完整。
			case "$raw" in
				*"
") ended_nl=1 ;;
			esac
			;;
		*) raw="" ;;
	esac
	[ -n "$raw" ] || return 0
	if [ "$ended_nl" -eq 1 ]; then
		printf '%s' "$raw"
		return 0
	fi
	# 截断点在行中间：最后一行可能只有半个字符，丢掉它。
	out="$(printf '%s\n' "$raw" | sed '$d')"
	if [ -z "$out" ]; then
		# 原文只有一行且被切到：不能返回空串（报错就丢了），也不能留半个汉字
		# （JSON 就坏了）。按 UTF-8 边界把末尾那段不完整的序列剪掉再返回。
		oc_utf8_fix_tail "$raw"
		return 0
	fi
	printf '%s\n' "$out"
}

cloud_tail_err() {
	# cloud_tail_err <file> [lines] -> 脱敏后的最后几行（截断）
	tail -n "${2:-5}" "$1" 2>/dev/null | cloud_redact | oc_cut_utf8 1500
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
	# root 0700；bin / home 都在 root 之下，同样收紧到 0700。
	# pass 是 root 下的普通文件，父目录已由下面第一段建好。
	mkdir -p "$OC_CLOUD_ROOT" 2>/dev/null || return 1
	chmod 700 "$OC_CLOUD_ROOT" 2>/dev/null || true
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
	[ -d "$OC_CLOUD_ROOT" ] || return 1
	# 兜底只在 $OC_CLOUD_ROOT 内找；只认普通文件（不收符号链接），
	# 且 basename 必须正好是 bdpan —— 目录内容由安装器写入，不能把它
	# 当成「可执行任意目标」的入口。
	local p
	p="$(find "$OC_CLOUD_ROOT" -maxdepth 4 -type f -name bdpan 2>/dev/null | head -n1)"
	[ -n "$p" ] || return 1
	[ "$(basename "$p" 2>/dev/null)" = "bdpan" ] || return 1
	[ -f "$p" ] || return 1
	printf '%s' "$p"
}

cloud_bin_ready() {
	# 只返回可执行的 bdpan
	local b
	b="$(cloud_bin)" || return 1
	[ -n "$b" ] && [ -x "$b" ] || return 1
	printf '%s' "$b"
}

# ---------------------------------------------------------------- version
cloud_version_valid() {
	# 版本号白名单：安装器 URL 与 UCI 值都会进 URL / 路径，必须严格。
	# 必须数字开头（可带 v 前缀），之后只允许字母、数字与 . _ -。
	# 只做「字符白名单」不够：`-rf`、`..`、`../..` 都只由白名单字符组成，
	# 却能改变拼出来的 URL 路径段。所以首字符必须是数字，且显式拒绝
	# `.` / `..` / 任何含 `..` 的值。
	case "${1:-}" in
		''|.|..) return 1 ;;
		*..*) return 1 ;;
		v[0-9]*) ;;
		[0-9]*) ;;
		*) return 1 ;;
	esac
	case "${1:-}" in
		*[!0-9A-Za-z._-]*) return 1 ;;
	esac
	[ "${#1}" -le 32 ] || return 1
	return 0
}

cloud_norm_version() {
	# cloud_norm_version <string> -> 归一化的 x.y.z；取不到时输出空。
	# `bdpan version` 的输出格式没有承诺（可能是 "bdpan version 3.7.3" 或
	# "v3.7.3"），所以只提取第一个 x.y.z；没有 x.y.z 时退回「去掉前导 v 的
	# 白名单串」，再不行就留空 —— 绝不把整行输出当成版本号去比较。
	local s="${1:-}" t
	s="$(printf '%s' "$s" | tr -d '\r\000-\037\177')"
	t="$(printf '%s' "$s" | grep -o '[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*' 2>/dev/null | head -n1)"
	if [ -z "$t" ]; then
		t="$(printf '%s' "$s" | sed -n 's/^[[:space:]]*[vV]\{0,1\}\([0-9][0-9A-Za-z._-]*\).*$/\1/p' | head -n1)"
	fi
	cloud_version_valid "$t" || t=""
	printf '%s' "$t"
}

cloud_version_file_read() {
	# 读 $OC_CLOUD_DIR/.installed-version（一行）；读不到返回 1。
	local v
	[ -f "$OC_CLOUD_VERSION_FILE" ] || return 1
	v="$(head -n1 "$OC_CLOUD_VERSION_FILE" 2>/dev/null | tr -d '\r\000-\037\177')"
	v="$(cloud_norm_version "$v")"
	[ -n "$v" ] || return 1
	printf '%s' "$v"
}

cloud_version_file_write() {
	# cloud_version_file_write <ver> -> 原子写一行版本号；失败返回 1。
	# 只是记录，写不进去不影响安装结果（调用方只告警）。
	local ver="$1" tmp
	cloud_version_valid "$ver" || return 1
	cloud_ensure_dirs || return 1
	tmp="$OC_CLOUD_VERSION_FILE.$$"
	rm -f "$tmp" 2>/dev/null
	if ! printf '%s\n' "$ver" >"$tmp" 2>/dev/null; then
		rm -f "$tmp" 2>/dev/null
		return 1
	fi
	chmod 600 "$tmp" 2>/dev/null
	if ! mv -f "$tmp" "$OC_CLOUD_VERSION_FILE" 2>/dev/null; then
		rm -f "$tmp" 2>/dev/null
		return 1
	fi
	return 0
}

cloud_current_version() {
	# 当前组件版本：优先 `bdpan version`，取不到退回 .installed-version；
	# 都没有时输出空（= 未安装 / 无法确认）。
	local bin v=""
	bin="$(cloud_bin_ready)" || bin=""
	if [ -n "$bin" ]; then
		v="$(cloud_run 30 "$bin" version 2>/dev/null | head -n1)"
		v="$(cloud_norm_version "$v")"
	fi
	if [ -z "$v" ]; then
		v="$(cloud_version_file_read)" || v=""
	fi
	printf '%s' "$v"
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
	# 临时文件必须与 $OC_CLOUD_PASS 同目录（$OC_CLOUD_ROOT），
	# 既保证 mv 是原子替换，也不会把口令临时落到安装器可覆盖的 bin/ 里。
	# 下面这一处 printf 是口令唯一的落盘点：目标是 0600 私有文件，
	# 绝不重定向到 stdout / stderr / 日志。
	tmp="$OC_CLOUD_ROOT/.pass.$$"
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

# ---------------------------------------------------------------- encrypt switch
cloud_encrypt_enabled() {
	# -> 1 / 0（兼容手写的 true/yes/on；缺省 0 = 明文上传）
	local v
	v="$(uci_get main.cloud_encrypt '0')"
	case "$v" in
		1|true|TRUE|True|yes|on) printf '1' ;;
		*)                       printf '0' ;;
	esac
}

cmd_encrypt_status() {
	# 只回 enabled / pass_set：绝不返回口令本身，也不返回任何可用来猜解的摘要。
	local enabled=false pass_set=false
	[ "$(cloud_encrypt_enabled)" = "1" ] && enabled=true
	cloud_pass_present && pass_set=true
	printf '{"ok":true,"enabled":%s,"pass_set":%s}\n' "$enabled" "$pass_set"
}

cmd_set_encrypt() {
	# 只读 stdin 第一行（0/1）：不进 argv，ps 看不到。
	# 与 schedule-set 一样「先校验、再写入」，非法输入一个字节都不落盘。
	local v old rc

	v="$(sed -n '1p' | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
	case "$v" in
		0|1) ;;
		*) cloud_fail "参数不合法：enabled 只能是 0 或 1" ;;
	esac

	old="$(uci_get main.cloud_encrypt '')"
	if ! uci -q set "${OC_UCI}.main.cloud_encrypt=${v}" 2>/dev/null; then
		cloud_fail "写入配置失败：cloud_encrypt=${v}"
	fi
	if ! uci -q commit "$OC_UCI" 2>/dev/null; then
		# 旧值为空时 `uci set k=` 等价于删除该选项，正是还原语义。
		uci -q set "${OC_UCI}.main.cloud_encrypt=${old}" 2>/dev/null || true
		uci -q commit "$OC_UCI" 2>/dev/null || true
		cloud_fail "写入配置失败：uci commit 失败（已回滚）"
	fi

	# 回读落盘后的真实值，而不是直接回显输入
	if [ "$(cloud_encrypt_enabled)" = "1" ]; then rc=true; else rc=false; fi
	printf '{"ok":true,"enabled":%s}\n' "$rc"
}

# ---------------------------------------------------------------- status
cmd_status() {
	local arch bin installed=false executable=false path="" ver="" logged=false user="" expires="" raw=""
	local uncertain=false tmp rc k

	arch="$(cloud_arch)"

	bin="$(cloud_bin)" || bin=""
	if [ -n "$bin" ]; then
		# installed 的语义是「文件存在」，保持不变；能不能跑单独用 executable
		# 报出去。否则前端只能看到 installed=true，把「二进制损坏 / 架构不符」
		# 也引导成「去登录」。
		installed=true
		path="$bin"
		if [ -x "$bin" ]; then
			executable=true
		fi
	fi

	if [ "$installed" = "true" ] && [ "$executable" != "true" ]; then
		oc_warn "找到 bdpan（$bin）但不可执行，请重新安装组件"
	fi
	# 版本优先取 `bdpan version`；取不到（二进制损坏 / 架构不匹配 / 临时
	# 不可执行）时退回安装时写下的 .installed-version，两者都没有才留空。
	ver="$(cloud_current_version)"

	if [ "$executable" = "true" ]; then
		tmp="$OC_RUNDIR/cloud-whoami.$$"
		rm -f "$tmp" 2>/dev/null
		cloud_run 25 "$bin" whoami --json >"$tmp" 2>&1
		rc=$?
		if [ "$rc" -ne 0 ]; then
			# 老版本 CLI 可能没有 --json
			cloud_run 25 "$bin" whoami >"$tmp" 2>&1
		fi
		# raw 只放 whoami 的输出，且先脱敏、截断；绝不包含 config.json。
		raw="$(cloud_redact <"$tmp" 2>/dev/null | oc_cut_utf8 500)"

		# 登录判定只有 cloud_is_logged_in 一处口径（默认未登录、无法确认也算
		# 未登录）。把刚取到的 whoami 输出交给它复用，避免重复执行 bdpan。
		# uncertain 只用于前端区分「明确未登录」与「组件在但登录态无法确认」。
		CLOUD_AUTH_SNAPSHOT="$tmp"
		if cloud_is_logged_in; then
			logged=true
		else
			logged=false
			if [ "$CLOUD_AUTH_STATE" = "unknown" ]; then
				uncertain=true
			fi
		fi

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

	printf '{"ok":true,"arch":"%s","cli":{"installed":%s,"executable":%s,"path":"%s","version":"%s"},"auth":{"logged_in":%s,"uncertain":%s,"user":"%s","expires":"%s","raw":"%s"},"remote_dir":"%s","root":"%s","dir":"%s","home":"%s"}\n' \
		"$arch" "$installed" "$executable" "$(jstr "$path")" "$(jstr "$ver")" \
		"$logged" "$uncertain" "$(jstr "$user")" "$(jstr "$expires")" "$(jstr "$raw")" \
		"$(jstr "$OC_CLOUD_REMOTE")" "$(jstr "$OC_CLOUD_ROOT")" \
		"$(jstr "$OC_CLOUD_DIR")" "$(jstr "$OC_CLOUD_HOME")"
}

# ---------------------------------------------------------------- install-cli
cloud_installer_url() {
	# cloud_installer_url <ver> -> 官方安装器 URL
	printf '%s/%s/bdpan-installer-linux-%s' "$OC_CLOUD_CDN" "$1" "$(cloud_arch)"
}

cloud_install_home_cleanup() {
	# 只清理 $OC_RUNDIR 下由 cloud_install_version 创建的一次性 HOME。
	# 不使用 rm -rf：先删文件 / 链接，再逐层 rmdir；清不掉也不影响结果
	# （它在 /tmp 的私有 rundir 里，重启即清空）。
	local d="$1"
	case "$d" in
		"$OC_RUNDIR"/cloud-install-home.*) ;;
		*) return 0 ;;
	esac
	[ -d "$d" ] || return 0
	find "$d" -mindepth 1 -depth -type f -exec rm -f {} + 2>/dev/null
	find "$d" -mindepth 1 -depth -type l -exec rm -f {} + 2>/dev/null
	find "$d" -mindepth 1 -depth -type d -exec rmdir {} + 2>/dev/null
	rmdir "$d" 2>/dev/null
	return 0
}

cloud_installer_has_flag() {
	# cloud_installer_has_flag <usage-file> <flag> -> 0 表示 usage 里列出了该参数
	#
	# 只看每行的**第一个词**：Go 的 flag 用法里，一个参数定义行必然是
	# `  -dir string  说明` 这种形状，第一个词就是参数名。
	# 不能在整行里搜子串 —— 安装器把错误信息也打到同一个输出里时
	# （例如 "flag provided but not defined: -install-dir"），那种行会
	# 让 -install-dir 被误判成"支持"，于是又传一个它不认识的参数，白跑一轮。
	# 同时兼容 "-flag=value" 的写法。
	awk -v f="$2" '
		$1 == f || substr($1, 1, length(f) + 1) == f "=" { found = 1; exit }
		END { exit(found ? 0 : 1) }
	' "$1"
}

# ---- 后台安装的运行目录 / 进度辅助 ----
# 全部放在 $OC_RUNDIR 下，名字统一带 cloud-install 前缀；锁目录只做 mkdir/rmdir，
# 临时文件只用 rm -f。
CLOUD_INSTALL_LOG="$OC_RUNDIR/cloud-install.log"
CLOUD_INSTALL_RC="$OC_RUNDIR/cloud-install.rc"
CLOUD_INSTALL_PID="$OC_RUNDIR/cloud-install.pid"
CLOUD_INSTALL_LOCK="$OC_RUNDIR/cloud-install.lock"
CLOUD_INSTALL_STAGE="$OC_RUNDIR/cloud-install.stage"

cloud_install_mb() {
	# cloud_install_mb <bytes> -> "X.X"（MB，一位小数）
	local b="${1:-0}"
	case "$b" in ''|*[!0-9]*) b=0 ;; esac
	awk -v b="$b" 'BEGIN { printf "%.1f", b / 1048576 }'
}

cloud_install_total() {
	# cloud_install_total <url> -> Content-Length（拿不到时输出空）
	# 只做一次 HEAD，短超时；失败绝不影响真正的下载。
	local url="$1" proxy len=""
	oc_safe_url "$url" || return 0
	proxy="$(uci_get main.http_proxy '')"
	if [ -n "$proxy" ]; then
		oc_safe_url "$proxy" || proxy=""
	fi
	if command -v curl >/dev/null 2>&1; then
		if [ -n "$proxy" ]; then
			len="$(oc_timeout 10 curl -sIL --connect-timeout 4 --max-time 8 \
				-x "$proxy" "$url" 2>/dev/null \
				| awk 'tolower($1) == "content-length:" { v = $2 } END { print v }')"
		else
			len="$(oc_timeout 10 curl -sIL --connect-timeout 4 --max-time 8 \
				"$url" 2>/dev/null \
				| awk 'tolower($1) == "content-length:" { v = $2 } END { print v }')"
		fi
	elif command -v wget >/dev/null 2>&1; then
		len="$(oc_timeout 10 wget -q --spider -S -T 8 "$url" 2>&1 \
			| awk 'tolower($1) == "content-length:" { v = $2 } END { print v }')"
	fi
	len="$(printf '%s' "$len" | tr -d ' \r\n')"
	case "$len" in ''|*[!0-9]*) return 0 ;; esac
	[ "$len" -gt 0 ] 2>/dev/null || return 0
	printf '%s' "$len"
}

cloud_install_stage_set() {
	# 只有后台安装会设置 OC_INSTALL_STAGE；同步安装时这里什么都不做。
	[ -n "${OC_INSTALL_STAGE:-}" ] || return 0
	printf '%s\n' "$1" >"$OC_INSTALL_STAGE" 2>/dev/null || true
	return 0
}

cloud_install_alive() {
	# cloud_install_alive <pid> -> 0 when the pid is a live (non-zombie) worker.
	# 不用 oc_pid_alive：它要求 cmdline 里出现 "openclaw/cloud.sh"，而命令行
	# 用相对路径启动时（例如 ./cloud.sh install-cli-bg）就匹配不上，会把活着
	# 的 worker 误判成已退出。
	#
	# 但只看 `*cloud.sh*` 又太宽：编辑器、`grep cloud.sh`、另一个实例的命令行
	# 里都含这几个字符，pid 回收后撞上它们就会把「worker 已死」误判成「仍在
	# 运行」，于是永远返回 busy。所以要求 cmdline 同时含 cloud.sh 与后台安装
	# 入口（install-cli-bg 或 cloud_install_bg_worker）才认。
	# 不比对 /proc/<pid>/exe：worker 是子 shell，exe 指向 /bin/sh（或 busybox），
	# 与脚本路径无关，比对它在这里区分不出是不是本脚本。
	local pid="${1:-}" statline state cmd
	case "$pid" in ''|*[!0-9]*) return 1 ;; esac
	[ -d "/proc/$pid" ] || return 1
	statline="$(cat "/proc/$pid/stat" 2>/dev/null)"
	[ -n "$statline" ] || return 1
	state="${statline##*) }"
	state="${state%% *}"
	[ "$state" = "Z" ] && return 1
	cmd="$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null)"
	case "$cmd" in
		*cloud.sh*) ;;
		*) return 1 ;;
	esac
	case "$cmd" in
		*install-cli-bg*|*cloud_install_bg_worker*) return 0 ;;
	esac
	return 1
}

cloud_install_progress_loop() {
	# cloud_install_progress_loop <dest> <log> <stage> <total>
	# 下载期间每秒写一行；阶段离开 download（或 worker 被 kill）就退出。
	# 三重退出条件，保证它绝不会变成孤儿进程：
	#   1) 阶段不再是 download（正常结束 / 失败返回）；
	#   2) 记录在 pid 文件里的 worker 已经不在了（被 kill -9 之类）；
	#   3) 达到硬上限（下载本身最多 600 秒）。
	local dest="$1" log="$2" stage="$3" total="$4" n st wpid i=0
	while [ "$i" -lt 900 ]; do
		i=$((i + 1))
		st="$(cat "$stage" 2>/dev/null)"
		case "$st" in
			''|download) ;;
			*) break ;;
		esac
		wpid="$(cat "$CLOUD_INSTALL_PID" 2>/dev/null | head -n1 | tr -d ' \r\n')"
		if [ -n "$wpid" ] && ! cloud_install_alive "$wpid"; then
			break
		fi
		n=0
		if [ -f "$dest" ]; then
			n="$(wc -c <"$dest" 2>/dev/null | tr -d ' \r\n')"
		fi
		case "$n" in ''|*[!0-9]*) n=0 ;; esac
		if [ -n "$total" ]; then
			printf '已下载 %s MB / %s MB\n' \
				"$(cloud_install_mb "$n")" "$(cloud_install_mb "$total")" \
				>>"$log" 2>/dev/null
		else
			printf '已下载 %s MB\n' "$(cloud_install_mb "$n")" \
				>>"$log" 2>/dev/null
		fi
		sleep 1
	done
}

cloud_install_log_tail() {
	# cloud_install_log_tail <log> -> 尾部（最多 8KB，按行对齐后脱敏）
	local log="$1" size out prev
	[ -f "$log" ] || return 0
	size="$(wc -c <"$log" 2>/dev/null | tr -d ' \r\n')"
	case "$size" in ''|*[!0-9]*) size=0 ;; esac
	if [ "$size" -gt 8192 ]; then
		# 从中间截断时丢掉第一行，避免把 UTF-8 字符切成两半。
		# 但边界正好落在换行之后时，首行是**完整**的一行（常常正是阶段切换
		# 那行），无条件删会把它吞掉。所以先看 8192 字节窗口的**前一个字节**
		# 是不是换行：是则窗口从行首开始，一行都不用删。
		# 多取 1 字节再看首字节即可，不依赖 od / xxd：命令替换会吃掉结尾
		# 换行，因此「首字节是换行」在这里表现为空串。
		prev="$(tail -c 8193 "$log" 2>/dev/null | head -c 1)"
		if [ -z "$prev" ]; then
			out="$(tail -c 8192 "$log" 2>/dev/null)"
		else
			out="$(tail -c 8192 "$log" 2>/dev/null | sed '1d')"
		fi
	else
		out="$(cat "$log" 2>/dev/null)"
	fi
	printf '%s' "$out" | cloud_redact
}

cloud_install_dest() {
	# cloud_install_dest <arch> -> 安装器下载目标路径（stdout）
	#
	# 后台 worker 用 OC_INSTALL_DEST 把目标路径传给 cloud_install_version，
	# 让进度循环能读到文件大小。这个变量来自环境，而调用方拿到路径后第一件事
	# 就是 `rm -f`，脚本又以 root 运行 —— 不校验就等于「删除任意文件」。
	# 只接受 $OC_RUNDIR/ 下、basename 以 bdpan-installer- 开头、且不含 ..
	# 的路径；不满足就忽略它并记一行日志，回退到默认路径。
	local arch="$1" d="$OC_RUNDIR/bdpan-installer-$arch.$$"
	local want="${OC_INSTALL_DEST:-}"

	[ -n "$want" ] || { printf '%s' "$d"; return 0; }

	case "$want" in
		*..*) ;;
		"$OC_RUNDIR"/*)
			case "${want##*/}" in
				bdpan-installer-*) printf '%s' "$want"; return 0 ;;
			esac ;;
	esac
	cblog "忽略不可信的 OC_INSTALL_DEST（必须是 $OC_RUNDIR/bdpan-installer-* 且不含 ..）：$want"
	printf '%s' "$d"
}

cloud_install_version() {
	# cloud_install_version <ver>
	# 下载 -> 校验 -> 安装，只写 $OC_CLOUD_DIR（安装器 -dir）。
	#
	# 成功：return 0，并设置
	#   OC_INSTALL_PATH  安装后的 bdpan 路径
	#   OC_INSTALL_VER   归一化后的版本号（取不到时为原始首行）
	# 失败：return 1，并设置 OC_INSTALL_ERR（已脱敏，可直接进 JSON）。
	#
	# 安装器的 HOME 指向 $OC_RUNDIR 下的一次性目录，而不是 $OC_CLOUD_HOME：
	# 这是「更新只允许动 $OC_CLOUD_DIR」的强制手段 —— 即使安装器忽略
	# -dir，也只能写进临时目录，碰不到登录态与口令。
	local ver="$1" arch url dest size magic head4 mach sha out rc err bin vout
	local hout usage dirflag yesflag
	local ver_raw ver_out ihome

	OC_INSTALL_ERR=""
	OC_INSTALL_PATH=""
	OC_INSTALL_VER=""

	cloud_version_valid "$ver" || {
		OC_INSTALL_ERR="bdpan 版本号非法：$ver"
		return 1
	}
	arch="$(cloud_arch)"
	if [ "$arch" = "unsupported" ]; then
		OC_INSTALL_ERR="不支持的架构：$(uname -m 2>/dev/null)"
		return 1
	fi

	if ! oc_validate_base_dir "$(oc_base_dir)"; then
		OC_INSTALL_ERR="安装目录不可用：$(oc_base_dir)"
		return 1
	fi
	if [ ! -d "$OC_RUNDIR" ] || [ ! -w "$OC_RUNDIR" ]; then
		OC_INSTALL_ERR="临时目录不可用：$OC_RUNDIR"
		return 1
	fi
	cloud_ensure_dirs || {
		OC_INSTALL_ERR="无法创建云备份目录：$OC_CLOUD_ROOT"
		return 1
	}

	url="$(cloud_installer_url "$ver")"

	# 后台安装会通过 OC_INSTALL_DEST 指定目标路径，进度循环据此读取文件大小；
	# 同步安装沿用原来的 $$ 命名。OC_INSTALL_DEST 来自环境，必须先校验：
	# 它下面马上就会被 rm -f，而本脚本以 root 运行。
	dest="$(cloud_install_dest "$arch")"
	rm -f "$dest" 2>/dev/null
	cloud_install_stage_set download
	cblog "下载百度网盘组件安装器：$url"
	if ! oc_fetch "$url" "$dest" 600; then
		rm -f "$dest" 2>/dev/null
		OC_INSTALL_ERR="下载安装器失败：$url"
		return 1
	fi
	if [ ! -f "$dest" ]; then
		OC_INSTALL_ERR="下载安装器失败：文件不存在"
		return 1
	fi
	cloud_install_stage_set verify
	cblog "下载完成，校验文件"

	size="$(wc -c <"$dest" 2>/dev/null | tr -d ' ')"
	case "$size" in ''|*[!0-9]*) size=0 ;; esac
	if [ "$size" -le 5242880 ]; then
		rm -f "$dest" 2>/dev/null
		OC_INSTALL_ERR="安装器体积异常（${size} 字节，期望 > 5MB）"
		return 1
	fi

	# ELF 魔数：前 4 字节是 0x7F 'E' 'L' 'F'，所以后 3 字节正好是 "ELF"。
	# 这里不用 od：部分 OpenWrt / iStoreOS 的 busybox 没编进 od，命令缺失时
	# 输出为空、报错又被 2>/dev/null 吞掉，会把正常下载一律判成「不是 ELF」。
	# head / tail 是 busybox 必备的，不依赖可选 applet。
	magic="$(head -c 4 "$dest" 2>/dev/null | tail -c 3)"
	if [ "$magic" != "ELF" ]; then
		# 不可打印字节换成 '?'，最多 4 个字符：下次出问题一眼能看出拿到的是
		# HTML 错误页（"<!DO"）还是别的什么东西。
		head4="$(head -c 4 "$dest" 2>/dev/null | tr -c ' -~' '?')"
		rm -f "$dest" 2>/dev/null
		OC_INSTALL_ERR="下载内容不是 ELF 可执行文件（大小 ${size} 字节，开头 \"${head4}\"）"
		return 1
	fi

	# 架构检查是尽力而为的：od 不存在时跳过，绝不因此拒绝安装。
	# 架构不对的二进制在执行时内核会直接拒绝（Exec format error），
	# 后面本来就要跑它，不缺这一道前置检查 —— 它只是让错误更早、更清楚。
	if command -v od >/dev/null 2>&1; then
		# ELF e_machine（偏移 18，小端 2 字节）：arm64=0xb7，x86_64=0x3e
		mach="$(od -An -tx1 -j18 -N2 "$dest" 2>/dev/null | tr -d ' \n')"
		case "$arch:$mach" in
			arm64:b700|amd64:3e00) ;;
			*)
				rm -f "$dest" 2>/dev/null
				OC_INSTALL_ERR="安装器架构不匹配：期望 $arch，ELF machine=${mach:-未知}"
				return 1 ;;
		esac
	else
		oc_warn "缺少 od，跳过 ELF 架构校验（架构不符时执行阶段会报 Exec format error）"
	fi

	if command -v sha256sum >/dev/null 2>&1; then
		sha="$(sha256sum "$dest" 2>/dev/null | awk '{print $1}')"
		[ -n "$sha" ] && oc_warn "安装器 sha256：$sha（官方未公布校验值，仅记录备查）"
	fi
	chmod 700 "$dest" 2>/dev/null || true

	# 一次性 HOME：安装器就算忽略 -dir，也只能写进这里。
	ihome="$OC_RUNDIR/cloud-install-home.$$"
	rm -f "$ihome" 2>/dev/null
	if ! mkdir -p "$ihome" 2>/dev/null; then
		rm -f "$dest" 2>/dev/null
		OC_INSTALL_ERR="无法创建安装临时目录：$ihome"
		return 1
	fi
	chmod 700 "$ihome" 2>/dev/null || true

	# 探测安装器支持的参数：各版本参数名并不一致（实测 3.7.3 只认 -dir，
	# 旧实现传的参数名安装器不认识，会以 rc=2 直接退出）。Go flag 的 -h 把
	# usage 打到 stderr 并以 2 退出，所以这里只看输出，不把非 0 退出码当成失败。
	hout="$OC_RUNDIR/bdpan-installer-help-$$.log"
	rm -f "$hout" 2>/dev/null
	(
		export HOME="$ihome"
		export TMPDIR="$OC_RUNDIR"
		oc_timeout 20 "$dest" -h
	) >"$hout" 2>&1 </dev/null

	dirflag=""
	if cloud_installer_has_flag "$hout" "-dir"; then
		dirflag="-dir"
	elif cloud_installer_has_flag "$hout" "-install-dir"; then
		dirflag="-install-dir"
	fi
	yesflag=""
	if cloud_installer_has_flag "$hout" "-yes"; then
		yesflag="-yes"
	elif cloud_installer_has_flag "$hout" "-y"; then
		yesflag="-y"
	fi
	# 折成一行：usage 要进 JSON 错误信息，换行会破坏 JSON。
	# 先按行对齐截断再压行，避免把中文切成半个字符。
	usage="$(oc_cut_utf8 4000 <"$hout" 2>/dev/null | tr '\n\r\t' '   ')"
	rm -f "$hout" 2>/dev/null
	[ -n "$usage" ] || usage="（安装器 -h 无输出）"

	if [ -z "$dirflag" ]; then
		# 绝不退回裸调用：裸调用没有 -dir，安装器会装到默认路径，
		# 破坏「只动 $OC_CLOUD_DIR」的约定。
		rm -f "$dest" 2>/dev/null
		cloud_install_home_cleanup "$ihome"
		OC_INSTALL_ERR="安装器不支持指定安装目录（尝试过 -dir / -install-dir），已中止以免装到错误位置：$(printf '%s\n' "$usage" | oc_cut_utf8 300)"
		return 1
	fi

	out="$OC_RUNDIR/bdpan-install-$$.log"
	rm -f "$out" 2>/dev/null
	cloud_install_stage_set install
	cblog "校验通过，运行安装器"
	cblog "运行安装器（$dirflag=$OC_CLOUD_DIR${yesflag:+，$yesflag}，临时 HOME=$ihome）"
	(
		export HOME="$ihome"
		export TMPDIR="$OC_RUNDIR"
		# yesflag 可能为空：空字符串不能当参数传给安装器。
		if [ -n "$yesflag" ]; then
			oc_timeout 600 "$dest" "$dirflag" "$OC_CLOUD_DIR" "$yesflag"
		else
			oc_timeout 600 "$dest" "$dirflag" "$OC_CLOUD_DIR"
		fi
	) >"$out" 2>&1 </dev/null
	rc=$?
	# 不再退化成裸调用：裸调用没有 -dir，安装器可能写进 HOME
	# 或默认路径，破坏「只动 $OC_CLOUD_DIR」的约定。
	if [ "$rc" -ne 0 ]; then
		err="$(tail -n 20 "$out" 2>/dev/null | cloud_redact | oc_cut_utf8 2000)"
		[ -n "$err" ] || err="无输出"
		rm -f "$dest" "$out" 2>/dev/null
		cloud_install_home_cleanup "$ihome"
		OC_INSTALL_ERR="安装器执行失败（rc=$rc）：$err"
		return 1
	fi
	rm -f "$dest" "$out" 2>/dev/null
	cloud_install_home_cleanup "$ihome"

	bin="$(cloud_bin)" || {
		OC_INSTALL_ERR="安装完成但未找到 bdpan 可执行文件"
		return 1
	}
	chmod +x "$bin" 2>/dev/null || true
	if [ ! -x "$bin" ]; then
		OC_INSTALL_ERR="安装后的 bdpan 不可执行：$bin"
		return 1
	fi

	vout="$OC_RUNDIR/bdpan-ver-$$.log"
	rm -f "$vout" 2>/dev/null
	cloud_run 30 "$bin" version >"$vout" 2>&1
	rc=$?
	ver_raw="$(head -n1 "$vout" 2>/dev/null | cloud_redact | tr -d '\000-\037\177')"
	rm -f "$vout" 2>/dev/null
	if [ "$rc" -ne 0 ]; then
		OC_INSTALL_ERR="安装后无法执行：${ver_raw:-rc=$rc}"
		return 1
	fi

	ver_out="$(cloud_norm_version "$ver_raw")"
	[ -n "$ver_out" ] || ver_out="$ver_raw"
	# 记录已装版本（一行版本号）。优先用目标版本（安装器的 version 输出
	# 格式不稳定），目标版本不可用时退回运行时输出。
	if cloud_version_valid "$ver"; then
		cloud_version_file_write "$ver" || oc_warn "无法写入版本文件：$OC_CLOUD_VERSION_FILE"
	elif cloud_version_valid "$ver_out"; then
		cloud_version_file_write "$ver_out" || oc_warn "无法写入版本文件：$OC_CLOUD_VERSION_FILE"
	fi

	OC_INSTALL_PATH="$bin"
	OC_INSTALL_VER="$ver_out"
	cloud_install_stage_set done
	return 0
}

cmd_install_cli() {
	# 首次安装：版本取 UCI main.bdpan_version（缺省用 OC_CLOUD_DEFAULT_VERSION）。
	local arch ver

	arch="$(cloud_arch)"
	if [ "$arch" = "unsupported" ]; then
		printf '{"ok":false,"error":"%s"}\n' "$(jstr "不支持的架构：$(uname -m 2>/dev/null)")"
		exit 2
	fi

	ver="$(uci_get main.bdpan_version "$OC_CLOUD_DEFAULT_VERSION")"
	[ -n "$ver" ] || ver="$OC_CLOUD_DEFAULT_VERSION"

	if ! cloud_install_version "$ver"; then
		cloud_fail "${OC_INSTALL_ERR:-安装失败}"
	fi

	printf '{"ok":true,"path":"%s","version":"%s","arch":"%s"}\n' \
		"$(jstr "$OC_INSTALL_PATH")" "$(jstr "$OC_INSTALL_VER")" "$arch"
}

cloud_install_bg_worker() {
	# cloud_install_bg_worker <ver> <dest>
	# 在后台子 shell 里跑：复用 cloud_install_version，只把过程写进日志。
	local ver="$1" dest="$2" total rc mp

	cblog "开始下载安装器" >>"$CLOUD_INSTALL_LOG" 2>&1
	total="$(cloud_install_total "$(cloud_installer_url "$ver")")"

	cloud_install_progress_loop "$dest" "$CLOUD_INSTALL_LOG" \
		"$CLOUD_INSTALL_STAGE" "$total" &
	mp=$!

	# 让 cloud_install_version 用固定的目标路径 / 阶段文件；这两个变量只在
	# 本 worker 子 shell 里生效。
	OC_INSTALL_DEST="$dest"
	OC_INSTALL_STAGE="$CLOUD_INSTALL_STAGE"
	cloud_install_version "$ver" >>"$CLOUD_INSTALL_LOG" 2>&1
	rc=$?

	# 下载结束（或失败）后立刻收掉进度循环，绝不留孤儿进程。
	kill "$mp" 2>/dev/null
	wait "$mp" 2>/dev/null

	if [ "$rc" -eq 0 ]; then
		cblog "安装完成" >>"$CLOUD_INSTALL_LOG" 2>&1
		printf '0\n' >"$CLOUD_INSTALL_RC" 2>/dev/null
	else
		cblog "失败：${OC_INSTALL_ERR:-未知错误}" >>"$CLOUD_INSTALL_LOG" 2>&1
		printf '%s\n' "$rc" >"$CLOUD_INSTALL_RC" 2>/dev/null
	fi

	rm -f "$CLOUD_INSTALL_PID" 2>/dev/null
	rmdir "$CLOUD_INSTALL_LOCK" 2>/dev/null
}

cmd_install_cli_bg() {
	# 后台安装：前置校验与 install-cli 一致，通过后立刻返回 started。
	# 版本号参数可选；不给时与 install-cli 一样取 UCI 值。
	local ver="${1:-}" arch pid dest

	if [ -z "$ver" ]; then
		ver="$(uci_get main.bdpan_version "$OC_CLOUD_DEFAULT_VERSION")"
		[ -n "$ver" ] || ver="$OC_CLOUD_DEFAULT_VERSION"
	fi
	cloud_version_valid "$ver" || cloud_fail "bdpan 版本号非法：$ver" 2

	arch="$(cloud_arch)"
	[ "$arch" != "unsupported" ] || \
		cloud_fail "不支持的架构：$(uname -m 2>/dev/null)" 2

	if ! oc_validate_base_dir "$(oc_base_dir)"; then
		cloud_fail "安装目录不可用：$(oc_base_dir)" 2
	fi
	if [ ! -d "$OC_RUNDIR" ] || [ ! -w "$OC_RUNDIR" ]; then
		cloud_fail "临时目录不可用：$OC_RUNDIR" 2
	fi
	cloud_ensure_dirs || cloud_fail "无法创建云备份目录：$OC_CLOUD_ROOT" 2

	# 已有安装在跑：锁存在且 pid 还活着，直接报 busy。
	if [ -d "$CLOUD_INSTALL_LOCK" ]; then
		pid="$(cat "$CLOUD_INSTALL_PID" 2>/dev/null | head -n1 | tr -d ' \r\n')"
		if [ -n "$pid" ] && { oc_pid_alive "$pid" || cloud_install_alive "$pid"; }; then
			printf '{"ok":false,"busy":true,"error":"%s"}\n' \
				"$(jstr "已有安装任务在运行，请等它结束")"
			return 0
		fi
		rm -f "$CLOUD_INSTALL_PID" 2>/dev/null
		if ! rmdir "$CLOUD_INSTALL_LOCK" 2>/dev/null; then
			printf '{"ok":false,"error":"%s"}\n' \
				"$(jstr "无法清理旧的安装锁：$CLOUD_INSTALL_LOCK")"
			return 1
		fi
	fi
	if ! mkdir "$CLOUD_INSTALL_LOCK" 2>/dev/null; then
		# 目录已经存在 = 别人抢先一步；否则是真的建不出来（权限 / 只读）。
		if [ -d "$CLOUD_INSTALL_LOCK" ]; then
			printf '{"ok":false,"busy":true,"error":"%s"}\n' \
				"$(jstr "已有安装任务在运行，请等它结束")"
			return 0
		fi
		printf '{"ok":false,"error":"%s"}\n' \
			"$(jstr "无法创建安装锁：$CLOUD_INSTALL_LOCK")"
		return 1
	fi
	chmod 700 "$CLOUD_INSTALL_LOCK" 2>/dev/null || true

	# 先写占位 pid：并发 start 在 spawn 之前不会把新锁误判成陈旧锁。
	printf '%s\n' "$$" >"$CLOUD_INSTALL_PID" 2>/dev/null || true
	rm -f "$CLOUD_INSTALL_RC" 2>/dev/null
	if ! : >"$CLOUD_INSTALL_LOG" 2>/dev/null; then
		rm -f "$CLOUD_INSTALL_PID" 2>/dev/null
		rmdir "$CLOUD_INSTALL_LOCK" 2>/dev/null
		cloud_fail "无法写入安装日志：$CLOUD_INSTALL_LOG"
	fi
	printf 'download\n' >"$CLOUD_INSTALL_STAGE" 2>/dev/null || true

	dest="$OC_RUNDIR/bdpan-installer-$arch.$$"
	( cloud_install_bg_worker "$ver" "$dest" ) >/dev/null 2>&1 </dev/null &
	pid=$!
	# 子 shell 里的 $$ 仍是父进程 pid，所以 worker 的真实 pid 取 $!。
	printf '%s\n' "$pid" >"$CLOUD_INSTALL_PID" 2>/dev/null || true

	printf '{"ok":true,"started":true}\n'
}

cmd_install_cli_poll() {
	local pid running=false done=false rc="" out=""

	# 从未启动过：不返回 done，避免前端把「没开始」当成「已中断」。
	if [ ! -f "$CLOUD_INSTALL_LOG" ] && [ ! -f "$CLOUD_INSTALL_RC" ] && \
		[ ! -f "$CLOUD_INSTALL_PID" ]; then
		printf '{"ok":true,"running":false,"done":false,"rc":"","log":""}\n'
		return 0
	fi

	pid="$(cat "$CLOUD_INSTALL_PID" 2>/dev/null | head -n1 | tr -d ' \r\n')"
	if [ -n "$pid" ] && { oc_pid_alive "$pid" || cloud_install_alive "$pid"; }; then
		running=true
	fi

	# worker 还在跑就先不下结论：它写完 rc 才会清理 pid 文件，而新一轮启动
	# 也可能在删除旧 rc 之前被轮询到。以「进程是否还活着」为准，最多多等一轮。
	if [ "$running" = "true" ]; then
		:
	elif [ -f "$CLOUD_INSTALL_RC" ]; then
		done=true
		rc="$(head -n1 "$CLOUD_INSTALL_RC" 2>/dev/null | tr -d ' \r\n')"
		case "$rc" in ''|*[!0-9]*) rc=1 ;; esac
	else
		# worker 已消失但没有退出码：按被中断处理，并落盘 rc 防止重复追加。
		done=true
		rc=124
		# 两个页面同时轮询时可能同时走到这里；用日志里的标记保证只追加一次。
		if ! grep -qF "安装进程已中断" "$CLOUD_INSTALL_LOG" 2>/dev/null; then
			printf '%s\n' "安装进程已中断（可能被终止或超时），以上为已产生的日志。" \
				>>"$CLOUD_INSTALL_LOG" 2>/dev/null
		fi
		printf '124\n' >"$CLOUD_INSTALL_RC" 2>/dev/null || true
		rm -f "$CLOUD_INSTALL_PID" 2>/dev/null
		rmdir "$CLOUD_INSTALL_LOCK" 2>/dev/null
	fi

	out="$(cloud_install_log_tail "$CLOUD_INSTALL_LOG")"
	printf '{"ok":true,"running":%s,"done":%s,"rc":"%s","log":"%s"}\n' \
		"$running" "$done" "$(jstr "$rc")" "$(jstr "$out")"
}

# ---------------------------------------------------------------- check / update
cloud_probe_status() {
	# cloud_probe_status <url> -> stdout HTTP 状态码（探测失败时输出空）
	# 只做 HEAD（-I）并跟随重定向（-L），单次 10 秒上限；外层再用 oc_timeout
	# 兜底（没有 timeout applet 时它会退化为直接执行）。
	local url="$1" proxy code=""

	oc_safe_url "$url" || return 1
	proxy="$(uci_get main.http_proxy '')"
	if [ -n "$proxy" ]; then
		oc_safe_url "$proxy" || proxy=""
	fi

	if command -v curl >/dev/null 2>&1; then
		if [ -n "$proxy" ]; then
			code="$(oc_timeout 15 curl -sIL --connect-timeout 10 --max-time 10 \
				-x "$proxy" -o /dev/null -w '%{http_code}' "$url" 2>/dev/null)"
		else
			code="$(oc_timeout 15 curl -sIL --connect-timeout 10 --max-time 10 \
				-o /dev/null -w '%{http_code}' "$url" 2>/dev/null)"
		fi
	elif command -v wget >/dev/null 2>&1; then
		# 没有 curl 时退化为 wget --spider -S，取最后一个状态码。
		code="$(oc_timeout 15 wget -q --spider -S -T 10 "$url" 2>&1 \
			| awk '/^[[:space:]]*HTTP\// { c = $2 } END { print c }')"
	fi
	case "$code" in
		''|*[!0-9]*) code="" ;;
	esac
	printf '%s' "$code"
}

cloud_candidate_versions() {
	# stdout: 去重并按版本升序排列的候选版本（空格分隔）。
	# 官方没有版本清单接口，只能拿「缺省版本 + 固定候选」逐个探测。
	local all v out="" sorted="" new placed s

	all="$OC_CLOUD_DEFAULT_VERSION $OC_CLOUD_CANDIDATES"
	for v in $all; do
		cloud_version_valid "$v" || continue
		case " $out " in
			*" $v "*) continue ;;
		esac
		out="$out $v"
	done

	# 插入排序：候选很少，用 ver_lt 保证 3.8.10 vs 3.8.9 这类位数也正确。
	for v in $out; do
		new=""
		placed=0
		for s in $sorted; do
			if [ "$placed" -eq 0 ] && ver_lt "$v" "$s"; then
				new="$new $v"
				placed=1
			fi
			new="$new $s"
		done
		[ "$placed" -eq 1 ] || new="$new $v"
		sorted="$new"
	done
	printf '%s' "${sorted# }"
}

cloud_probe_latest() {
	# 逐个探测候选版本；stdout: 可用的最大版本号（一个都没有时为空）。
	# 设置：
	#   OC_PROBED_LIST  探测到 200 的版本（空格分隔，升序）
	#   OC_PROBE_OK     探测到 200 的个数
	# 单个候选失败（超时 / 404 / 网络错误）只跳过它，不影响其它候选。
	local cand v code latest=""

	OC_PROBED_LIST=""
	OC_PROBE_OK=0
	cand="$(cloud_candidate_versions)"
	for v in $cand; do
		code="$(cloud_probe_status "$(cloud_installer_url "$v")")"
		[ "$code" = "200" ] || continue
		OC_PROBED_LIST="$OC_PROBED_LIST $v"
		OC_PROBE_OK=$((OC_PROBE_OK + 1))
		if [ -z "$latest" ] || ver_gt "$v" "$latest"; then
			latest="$v"
		fi
	done
	OC_PROBED_LIST="${OC_PROBED_LIST# }"
	printf '%s' "$latest"
}

cmd_cli_check() {
	# 检查更新：只读探测，不下载、不安装。
	local latest current update=false probed="" v

	if [ "$(cloud_arch)" = "unsupported" ]; then
		cloud_fail "不支持的架构：$(uname -m 2>/dev/null)"
	fi

	latest="$(cloud_probe_latest)"
	if [ "${OC_PROBE_OK:-0}" -le 0 ]; then
		# 全部候选都探测失败只能是网络问题：绝不谎报「已是最新」。
		cloud_fail "无法连接官方下载源，请检查网络"
	fi

	current="$(cloud_current_version)"
	if [ -z "$current" ]; then
		# 未安装 / 无法确认当前版本：视为需要更新
		update=true
	elif ver_lt "$current" "$latest"; then
		update=true
	fi

	for v in $OC_PROBED_LIST; do
		if [ -z "$probed" ]; then
			probed="\"$v\""
		else
			probed="$probed,\"$v\""
		fi
	done

	printf '{"ok":true,"current":"%s","latest":"%s","update":%s,"probed":[%s],"checked_at":"%s"}\n' \
		"$(jstr "$current")" "$(jstr "$latest")" "$update" "$probed" \
		"$(date '+%Y-%m-%d %H:%M:%S')"
}

cmd_cli_update() {
	# 更新组件：版本来源 = 参数 > cli-check 探测到的 latest。
	# 只写 $OC_CLOUD_DIR；$OC_CLOUD_HOME 与 $OC_CLOUD_PASS 全程只 stat，不写不删。
	local want="${1:-}" latest current from to bak oldbin restored err warn=""
	local had_cfg=false now_cfg=false

	if [ -n "$want" ]; then
		cloud_version_valid "$want" || \
			cloud_fail "版本号不合法（只允许字母、数字与 . _ -，长度 1-32）"
	fi

	if [ -z "$want" ]; then
		latest="$(cloud_probe_latest)"
		if [ "${OC_PROBE_OK:-0}" -le 0 ] || [ -z "$latest" ]; then
			cloud_fail "无法连接官方下载源，请检查网络"
		fi
		want="$latest"
	fi

	current="$(cloud_current_version)"
	from="$current"
	if [ -n "$current" ] && ver_eq "$current" "$want"; then
		printf '{"ok":true,"updated":false,"current":"%s","message":"已是最新"}\n' \
			"$(jstr "$current")"
		return 0
	fi

	# 更新前记录登录态是否存在；更新后只读复查，绝不写入 / 删除。
	if [ -f "$OC_CLOUD_HOME/.config/bdpan/config.json" ]; then
		had_cfg=true
	fi

	# 旧二进制备份到 rundir（安装目录之外，安装器碰不到）。
	bak=""
	oldbin="$(cloud_bin_ready)" || oldbin=""
	if [ -n "$oldbin" ]; then
		bak="$OC_RUNDIR/bdpan-old.$$"
		rm -f "$bak" 2>/dev/null
		if cp -f "$oldbin" "$bak" 2>/dev/null; then
			chmod 700 "$bak" 2>/dev/null
		else
			bak=""
		fi
	fi

	if ! cloud_install_version "$want"; then
		err="$OC_INSTALL_ERR"
		[ -n "$err" ] || err="更新失败"
		restored=false
		# 安装器可能删掉了旧文件、或留下不可执行的文件：能用备份就恢复。
		if [ -n "$bak" ] && [ -f "$bak" ]; then
			if [ ! -f "$OC_CLOUD_DIR/bdpan" ] || [ ! -x "$OC_CLOUD_DIR/bdpan" ]; then
				if cp -f "$bak" "$OC_CLOUD_DIR/bdpan" 2>/dev/null; then
					chmod +x "$OC_CLOUD_DIR/bdpan" 2>/dev/null
					restored=true
				fi
			fi
		fi
		rm -f "$bak" 2>/dev/null
		if [ "$restored" = "true" ]; then
			cloud_fail "$err（已恢复旧版本 ${from:-未知}）"
		fi
		if [ ! -f "$OC_CLOUD_DIR/bdpan" ] || [ ! -x "$OC_CLOUD_DIR/bdpan" ]; then
			cloud_fail "$err；旧版本文件已不存在，请重新安装组件"
		fi
		cloud_fail "$err"
	fi
	rm -f "$bak" 2>/dev/null

	# 登录态复查：只判断文件是否存在，不读内容（config.json 含 access_token）。
	if [ -f "$OC_CLOUD_HOME/.config/bdpan/config.json" ]; then
		now_cfg=true
	fi
	if [ "$had_cfg" = "true" ] && [ "$now_cfg" != "true" ]; then
		warn="组件已更新，但登录信息丢失，请重新登录"
	fi

	to="$(cloud_current_version)"
	[ -n "$to" ] || to="$want"

	if [ -n "$warn" ]; then
		printf '{"ok":true,"updated":true,"from":"%s","to":"%s","warn":"%s"}\n' \
			"$(jstr "$from")" "$(jstr "$to")" "$(jstr "$warn")"
	else
		printf '{"ok":true,"updated":true,"from":"%s","to":"%s"}\n' \
			"$(jstr "$from")" "$(jstr "$to")"
	fi
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
		out="$(printf '%s\n' "$out" | cloud_redact | oc_cut_utf8 500)"
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
	out="$(cloud_scrub_code "$tmp" "$code" | cloud_redact | tail -n 5 | oc_cut_utf8 800)"
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
	out="$(cloud_tail_err "$tmp" 5 | oc_cut_utf8 800)"
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

cloud_upload_file() {
	# cloud_upload_file <local-path> <remote-name>
	#
	# 上传主体：校验 -> （cloud_encrypt=1 且已设口令时）加密 -> mkdir -> upload
	# -> 回读远端大小。手动上传（cmd_upload）与定时备份（backup-run）共用这一份
	# 实现，判定只有这一处。
	#
	# 加密判定（唯一口径）：
	#   main.cloud_encrypt=1 且口令已设置 -> 加密成 <name>.enc
	#   main.cloud_encrypt=1 但口令未设置 -> 报错退出（绝不降级为明文上传）
	#   main.cloud_encrypt=0 -> 明文上传（本机残留的口令不参与）
	#
	# 失败走 cloud_fail（exit 1）；调用方若在子 shell 里调用，只会结束子 shell。
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

	if [ "$(cloud_encrypt_enabled)" = "1" ]; then
		# 开关打开：必须已有口令，否则明确报错。绝不能在这里悄悄走明文分支——
		# 用户以为数据已加密，实际却把明文传了上去。
		if ! cloud_pass_present; then
			cloud_fail "已启用加密但未设置口令，请先设置口令或关闭加密"
		fi
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

cmd_upload() {
	cloud_upload_file "${1:-}" "${2:-}"
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
# 删除失败原因（不含凭据）；由 cloud_rm_remote 写入，调用方拼进 JSON / 日志。
OC_RM_ERR=""

cloud_rm_remote() {
	# cloud_rm_remote <remote-name> -> 0 成功 / 1 失败（原因在 $OC_RM_ERR）
	# 不往 stdout 写任何东西：手动删除（cmd_rm）与远端轮转（backup-run）共用。
	local name="${1:-}" bin help sub tmp rc out err

	OC_RM_ERR=""
	[ -n "$name" ] || { OC_RM_ERR="缺少远端文件名"; return 1; }
	cloud_valid_remote_name "$name" || {
		OC_RM_ERR="远端文件名不合法（只允许字母数字与 . _ -，不能以 - 开头，长度 1-128）"
		return 1
	}
	bin="$(cloud_bin_ready)" || { OC_RM_ERR="请先安装网盘组件"; return 1; }

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
		[ "$rc" -eq 0 ] && return 0
		case "$out" in
			*unknown*|*Unknown*|*unrecognized*|*Unrecognized*|*"invalid command"*|*"no such command"*|*未知*|*不支持*)
				OC_RM_ERR="当前 CLI 不支持删除，请在网盘 App 里删除"
				return 1 ;;
		esac
		err="$(printf '%s\n' "$out" | cloud_redact | tail -n 5 | oc_cut_utf8 800)"
		OC_RM_ERR="删除失败（rc=$rc）：${err:-无输出}"
		return 1
	fi

	cloud_run 60 "$bin" "$sub" "$OC_CLOUD_REMOTE/$name" >"$tmp" 2>&1
	rc=$?
	if [ "$rc" -ne 0 ]; then
		err="$(cloud_tail_err "$tmp" 8)"
		rm -f "$tmp" 2>/dev/null
		OC_RM_ERR="删除失败（rc=$rc）：${err:-无输出}"
		return 1
	fi
	rm -f "$tmp" 2>/dev/null
	return 0
}

cmd_rm() {
	local name="${1:-}"

	[ -n "$name" ] || cloud_fail "缺少远端文件名"
	cloud_valid_remote_name "$name" || \
		cloud_fail "远端文件名不合法（只允许字母数字与 . _ -，不能以 - 开头，长度 1-128）"
	cloud_rm_remote "$name" || cloud_fail "${OC_RM_ERR:-删除失败}"
	printf '{"ok":true}\n'
}

# ---------------------------------------------------------------- schedule
# 定时备份：由本脚本自己维护 /etc/crontabs/root 里的一行。
#
# 规则（这一节最容易写错，改动前先读完）：
#   * 我们的行整行带 `# openclaw-cloud` 标记；cron 把 `#` 之后当 shell 注释，
#     所以标记既能被我们识别，也不影响命令本身。
#   * 只删除带标记的行，其它行（别人的任务、注释、空行）原样保留、顺序不变。
#   * 改 crontab 必须：同目录临时文件 -> 校验 -> 备份 root.openclaw.bak ->
#     chmod 600 -> mv（同目录 rename 才是原子替换）。
#   * 校验两条：新文件里标记行 <= 1；非标记行数量与原文完全一致。
#   * 幂等：重复调用不会堆出多行。
OC_CRONTAB="/etc/crontabs/root"
OC_CRON_MARK="# openclaw-cloud"
OC_CRON_CMD="/usr/libexec/openclaw/cloud.sh backup-run"

# 本地归档由 backup.sh 负责。标准安装位置优先；脚本与 backup.sh 同目录
# （测试 / 非标准布局）时退回同目录，避免把路径写死后无法复用。
OC_CLOUD_BACKUP="/usr/libexec/openclaw/backup.sh"
[ -f "$OC_CLOUD_BACKUP" ] || OC_CLOUD_BACKUP="$(dirname "$0")/backup.sh"

cloud_sched_int() {
	# cloud_sched_int <value> <default> <min> <max> <label> -> 合法整数
	# 非法 / 越界值回落到默认并 oc_warn（只写 stderr），函数本身恒定成功。
	local v="${1:-}" def="$2" lo="$3" hi="$4" label="$5" n

	case "$v" in
		'')
			oc_warn "定时备份：$label 未设置，使用默认值 $def"
			printf '%s' "$def"; return 0 ;;
		*[!0-9]*)
			oc_warn "定时备份：$label 不是整数（$v），使用默认值 $def"
			printf '%s' "$def"; return 0 ;;
	esac
	# 去掉前导 0：既避免 "08" 被当成八进制，也顺手压缩超长数字
	n="$(printf '%s' "$v" | sed 's/^0*//')"
	[ -n "$n" ] || n=0
	# busybox 的 test 对超长整数会溢出，先按长度截断（与 oc_safe_port 同口径）
	if [ ${#n} -gt 4 ]; then
		oc_warn "定时备份：$label 超出范围（$v），使用默认值 $def"
		printf '%s' "$def"; return 0
	fi
	if [ "$n" -lt "$lo" ] || [ "$n" -gt "$hi" ]; then
		oc_warn "定时备份：$label 超出范围（$v，应为 $lo-$hi），使用默认值 $def"
		printf '%s' "$def"; return 0
	fi
	printf '%s' "$n"
}

cloud_sched_enabled() {
	# -> 1 / 0（兼容手写的 true/yes/on）
	local v
	v="$(uci_get main.cloud_enabled '0')"
	case "$v" in
		1|true|TRUE|True|yes|on) printf '1' ;;
		*)                        printf '0' ;;
	esac
}

cloud_sched_period() {
	local v
	v="$(uci_get main.cloud_period 'daily')"
	case "$v" in
		daily|weekly) printf '%s' "$v" ;;
		*)
			oc_warn "定时备份：周期取值非法（$v，应为 daily/weekly），使用 daily"
			printf 'daily' ;;
	esac
}

cloud_sched_vals() {
	# 读取并校验全部 6 个值，结果写进全局变量（busybox ash 没有数组 / local -n）。
	# uci 不存在、或配置段/键不存在时 uci_get 返回默认值，所以这里不会失败。
	OC_SCH_ENABLED="$(cloud_sched_enabled)"
	OC_SCH_PERIOD="$(cloud_sched_period)"
	OC_SCH_WEEKDAY="$(cloud_sched_int "$(uci_get main.cloud_weekday '0')" 0 0 6 '星期（cloud_weekday）')"
	OC_SCH_HOUR="$(cloud_sched_int "$(uci_get main.cloud_hour '4')" 4 0 23 '小时（cloud_hour）')"
	OC_SCH_MINUTE="$(cloud_sched_int "$(uci_get main.cloud_minute '30')" 30 0 59 '分钟（cloud_minute）')"
	OC_SCH_KEEP="$(cloud_sched_int "$(uci_get main.cloud_keep '7')" 7 1 30 '保留份数（cloud_keep）')"
}

cloud_cron_count_mark() {
	# cloud_cron_count_mark <file> -> 带标记的行数
	awk -v m="$OC_CRON_MARK" 'index($0, m) { n++ } END { print n + 0 }' "$1" 2>/dev/null
}

cloud_cron_count_other() {
	# cloud_cron_count_other <file> -> 不带标记的行数（用于确认别人的行一条都没丢）
	awk -v m="$OC_CRON_MARK" 'index($0, m) == 0 { n++ } END { print n + 0 }' "$1" 2>/dev/null
}

cloud_cron_count() {
	# cloud_cron_count <file> <marker|other>
	# 用 index() 做字面匹配：标记里有 `#`，正则里不会出错，也不受 locale 影响。
	[ -f "$1" ] || { printf '0'; return 0; }
	awk -v m="$OC_CRON_MARK" -v want="$2" '
		{
			hit = (index($0, m) > 0)
			if ((want == "marker" && hit) || (want == "other" && !hit)) n++
		}
		END { printf "%d", n + 0 }
	' "$1" 2>/dev/null
}

cloud_cron_line() {
	# 当前 crontab 里属于我们的那一行（没有则空串）
	[ -f "$OC_CRONTAB" ] || return 0
	awk -v m="$OC_CRON_MARK" '
		index($0, m) { sub(/\r$/, ""); print; exit }
	' "$OC_CRONTAB" 2>/dev/null
}

cloud_cron_render() {
	# 依赖 OC_SCH_*。cron 的星期字段 0 和 7 都表示周日，这里统一写 0。
	if [ "$OC_SCH_PERIOD" = "weekly" ]; then
		printf '%s %s * * %s %s %s' \
			"$OC_SCH_MINUTE" "$OC_SCH_HOUR" "$OC_SCH_WEEKDAY" \
			"$OC_CRON_CMD" "$OC_CRON_MARK"
	else
		printf '%s %s * * * %s %s' \
			"$OC_SCH_MINUTE" "$OC_SCH_HOUR" "$OC_CRON_CMD" "$OC_CRON_MARK"
	fi
}

cloud_cron_write() {
	# cloud_cron_write <line|""> -> 0 成功 / 1 失败（已 oc_warn）
	#
	# <line> 为空表示「只删除我们的行」。任何一步失败都不动原文件。
	# n_other_* 是「不带标记的行数」（别人的任务 / 注释 / 空行）。
	local line="$1" dir tmp new bak n_other_old n_other_new

	dir="$(dirname "$OC_CRONTAB")"
	[ -d "$dir" ] || { oc_warn "crontab 目录不存在：$dir"; return 1; }
	# 没有原文件、也没有要写的行：什么都不做（不凭空创建空 crontab）
	if [ ! -f "$OC_CRONTAB" ] && [ -z "$line" ]; then
		return 0
	fi

	tmp="$dir/.openclaw-cron.$$"
	new="$dir/.openclaw-cron.$$.new"
	rm -f "$tmp" "$new" 2>/dev/null

	# 1) 先把现有内容读进同目录临时文件（后续所有判断都基于这份快照）
	if [ -f "$OC_CRONTAB" ]; then
		if ! cat "$OC_CRONTAB" >"$tmp" 2>/dev/null; then
			rm -f "$tmp" 2>/dev/null
			oc_warn "无法读取 crontab：$OC_CRONTAB"
			return 1
		fi
	else
		: >"$tmp" 2>/dev/null || {
			rm -f "$tmp" 2>/dev/null
			oc_warn "无法创建临时文件：$tmp"
			return 1
		}
	fi

	# 没有任何标记行、也没有新行要写：不必重写（保持 mtime 与内容不变）
	if [ -z "$line" ] && [ "$(cloud_cron_count "$tmp" marker)" -eq 0 ]; then
		rm -f "$tmp" 2>/dev/null
		return 0
	fi

	n_other_old="$(cloud_cron_count_other "$tmp")"

	# 2) 删掉所有标记行，末尾按需追加一行新的
	if ! awk -v m="$OC_CRON_MARK" -v add="$line" '
		index($0, m) == 0 { print }
		END { if (add != "") print add }
	' "$tmp" >"$new" 2>/dev/null; then
		rm -f "$tmp" "$new" 2>/dev/null
		oc_warn "生成新 crontab 失败"
		return 1
	fi

	# 校验 1：我们的行最多一条
	if [ "$(cloud_cron_count_mark "$new")" -gt 1 ]; then
		rm -f "$tmp" "$new" 2>/dev/null
		oc_warn "校验失败：新 crontab 里有多条 openclaw-cloud 行，已放弃写入"
		return 1
	fi
	# 校验 2：别人的行一条都不能少
	n_other_new="$(cloud_cron_count_other "$new")"
	if [ "$n_other_new" -ne "$n_other_old" ]; then
		rm -f "$tmp" "$new" 2>/dev/null
		oc_warn "校验失败：其它行数量发生变化（$n_other_old -> $n_other_new），已放弃写入"
		return 1
	fi

	# 4) 备份原文件（存在才备份；备份失败就不动原文件）
	if [ -f "$OC_CRONTAB" ]; then
		bak="$OC_CRONTAB.openclaw.bak"
		if ! cp -p "$OC_CRONTAB" "$bak" 2>/dev/null; then
			rm -f "$tmp" "$new" 2>/dev/null
			oc_warn "无法备份 crontab 到 $bak，已放弃写入"
			return 1
		fi
		chmod 600 "$bak" 2>/dev/null || true
	fi

	# 5) 原子替换：chmod 600 + mv（同目录 rename）
	chmod 600 "$new" 2>/dev/null || true
	chown 0:0 "$new" 2>/dev/null || true
	if ! mv -f "$new" "$OC_CRONTAB" 2>/dev/null; then
		rm -f "$tmp" "$new" 2>/dev/null
		oc_warn "无法替换 crontab：$OC_CRONTAB"
		return 1
	fi
	chmod 600 "$OC_CRONTAB" 2>/dev/null || true
	rm -f "$tmp" 2>/dev/null
	return 0
}

cloud_cron_reload() {
	# 重载 cron：reload -> restart -> kill -HUP $(pidof crond)。
	# 全部失败只告警，绝不让调用方判定为失败。
	local p
	if [ -x /etc/init.d/cron ]; then
		/etc/init.d/cron reload >/dev/null 2>&1 && return 0
		/etc/init.d/cron restart >/dev/null 2>&1 && return 0
	fi
	if command -v pidof >/dev/null 2>&1; then
		p="$(pidof crond 2>/dev/null)"
		if [ -n "$p" ]; then
			# shellcheck disable=SC2086  # pidof 可能返回多个 pid
			kill -HUP $p 2>/dev/null && return 0
		fi
	fi
	oc_warn "crontab 已更新，但未能通知 cron 重载；请手动重启 cron 使计划生效"
	return 1
}

cmd_schedule_status() {
	local enabled=false installed=false line

	cloud_sched_vals
	line="$(cloud_cron_line)"
	[ -n "$line" ] && installed=true
	[ "$OC_SCH_ENABLED" = "1" ] && enabled=true

	printf '{"ok":true,"enabled":%s,"period":"%s","weekday":%s,"hour":%s,"minute":%s,"keep":%s,"installed":%s,"line":"%s"}\n' \
		"$enabled" "$OC_SCH_PERIOD" "$OC_SCH_WEEKDAY" "$OC_SCH_HOUR" \
		"$OC_SCH_MINUTE" "$OC_SCH_KEEP" "$installed" "$(jstr "$line")"
}

cmd_schedule_apply() {
	local enabled=false line=""

	cloud_sched_vals
	if [ "$OC_SCH_ENABLED" = "1" ]; then
		enabled=true
		line="$(cloud_cron_render)"
	fi

	cloud_cron_write "$line" || cloud_fail "写入 crontab 失败：$OC_CRONTAB"
	cloud_cron_reload || true

	printf '{"ok":true,"enabled":%s,"line":"%s"}\n' "$enabled" "$(jstr "$line")"
}

cmd_schedule_clear() {
	cloud_cron_write "" || cloud_fail "清理 crontab 失败：$OC_CRONTAB"
	cloud_cron_reload || true
	printf '{"ok":true,"cleared":true}\n'
}

# ---- schedule-set ---------------------------------------------------------
# stdin 每行一个 key=value（空行 / 未知 key 忽略，缺省的 key 保持 UCI 原值）。
#
# key 与 UCI 选项名的映射必须显式写出来：界面上的 `enabled` 指的是「定时备份
# 开关」，配置里叫 `cloud_enabled`；直接写 main.enabled 会覆盖「服务开机自启」
# 那个同名但完全无关的选项，而且 schedule-apply 读不到新值。
cloud_sched_opt() {
	case "$1" in
		enabled) printf 'cloud_enabled' ;;
		period)  printf 'cloud_period' ;;
		weekday) printf 'cloud_weekday' ;;
		hour)    printf 'cloud_hour' ;;
		minute)  printf 'cloud_minute' ;;
		keep)    printf 'cloud_keep' ;;
		*)       return 1 ;;
	esac
}

cloud_sched_check() {
	# cloud_sched_check <key> <value> -> 0 合法（结果放 OC_SCH_OUT）/ 1 非法
	#
	# 与读路径的 cloud_sched_int() 不同：这里**绝不回落到默认值**。这些值是
	# 用户在界面上的显式输入，静默改掉只会让人以为保存成功。
	local key="$1" v="$2" lo hi

	case "$key" in
		enabled)
			case "$v" in 0|1) OC_SCH_OUT="$v"; return 0 ;; esac
			return 1 ;;
		period)
			case "$v" in daily|weekly) OC_SCH_OUT="$v"; return 0 ;; esac
			return 1 ;;
		weekday) lo=0; hi=6 ;;
		hour)    lo=0; hi=23 ;;
		minute)  lo=0; hi=59 ;;
		keep)    lo=1; hi=30 ;;
		*)       return 1 ;;
	esac

	# 只认十进制数字：挡掉空值、正负号、空格、十六进制与超长串
	case "$v" in
		''|*[!0-9]*) return 1 ;;
	esac
	[ ${#v} -le 3 ] || return 1
	# 去掉前导 0：避免 busybox test 把 "08" 当八进制
	v="$(printf '%s' "$v" | sed 's/^0*//')"
	[ -n "$v" ] || v=0
	[ "$v" -ge "$lo" ] 2>/dev/null || return 1
	[ "$v" -le "$hi" ] 2>/dev/null || return 1
	OC_SCH_OUT="$v"
	return 0
}

cloud_sched_rollback() {
	# cloud_sched_rollback <"opt=旧值" 换行分隔> -> 0 全部写回 / 1 有失败
	# 尽力而为：每个旧值都试一遍，不因一条失败就放弃后面的。
	local rec opt val rc=0

	while IFS= read -r rec; do
		[ -n "$rec" ] || continue
		opt="${rec%%=*}"
		val="${rec#*=}"
		# 旧值为空时 `uci set k=` 等价于删除该选项，正是我们要的还原语义。
		uci -q set "${OC_UCI}.main.${opt}=${val}" 2>/dev/null || rc=1
	done <<EOF
$1
EOF
	uci -q commit "$OC_UCI" 2>/dev/null || rc=1
	return "$rc"
}

cmd_schedule_set() {
	# line 同时用于「读 stdin → 构建待写清单」与「遍历待写清单」；必须声明为
	# local，否则第二个循环退出后会把 main 里的循环变量改掉。
	local line key val opt apply_out enabled
	local seen="" oldvals="" pending=""

	# 1) 先全部解析 + 校验，一个字节都不写：非法输入不能留下半套配置。
	while IFS= read -r line || [ -n "$line" ]; do
		# 去 CRLF 与首尾空白；空行直接跳过
		line="$(printf '%s\n' "$line" | sed 's/\r$//; s/^[[:space:]]*//; s/[[:space:]]*$//')"
		[ -n "$line" ] || continue
		key="${line%%=*}"
		# 没有 '=' 的行按「未知格式」忽略，与未知 key 同等对待
		[ "$key" != "$line" ] || continue
		val="${line#*=}"
		opt="$(cloud_sched_opt "$key")" || continue

		cloud_sched_check "$key" "$val" || cloud_fail "参数不合法：$key=$val"
		# 同一个 key 出现多次时后者生效；回滚记录只保留最早一次的原值。
		case " $seen " in
			*" $opt "*) ;;
			*) seen="$seen $opt"
			   oldvals="${oldvals}${opt}=$(uci_get "main.${opt}" '')
" ;;
		esac
		pending="${pending}${opt}=${OC_SCH_OUT}
"
	done

	# 2) 逐个写；任何一步失败都回滚已写入的部分。
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		opt="${line%%=*}"
		val="${line#*=}"
		if ! uci -q set "${OC_UCI}.main.${opt}=${val}" 2>/dev/null; then
			cloud_sched_rollback "$oldvals" >/dev/null 2>&1
			cloud_fail "写入配置失败：${opt}=${val}"
		fi
	done <<EOF
$pending
EOF

	# 3) commit；失败时把旧值写回并再次 commit。
	if ! uci -q commit "$OC_UCI" 2>/dev/null; then
		if cloud_sched_rollback "$oldvals" >/dev/null 2>&1; then
			cloud_fail "写入配置失败：uci commit 失败（已回滚）"
		fi
		cloud_fail "写入配置失败：uci commit 失败，且回滚未完全成功，请检查 /etc/config/openclaw"
	fi

	# 4) 复用已有的 apply 逻辑（直接调函数，不 exec 自己）把 crontab 同步过去。
	#    apply 失败时它自己会 cloud_fail 并以 JSON 报错；这里把它的输出原样透传，
	#    否则重定向到 /dev/null 会让前端只看到空响应。
	if ! apply_out="$(cmd_schedule_apply)"; then
		printf '%s\n' "$apply_out"
		exit 1
	fi

	# 5) 回读 UCI + crontab，确保输出反映的是落盘后的真实状态。
	cloud_sched_vals
	line="$(cloud_cron_line)"
	if [ "$OC_SCH_ENABLED" = "1" ]; then enabled=true; else enabled=false; fi

	printf '{"ok":true,"enabled":%s,"period":"%s","weekday":%s,"hour":%s,"minute":%s,"keep":%s,"line":"%s"}\n' \
		"$enabled" "$OC_SCH_PERIOD" "$OC_SCH_WEEKDAY" "$OC_SCH_HOUR" \
		"$OC_SCH_MINUTE" "$OC_SCH_KEEP" "$(jstr "$line")"
}

# ---------------------------------------------------------------- backup-run
# cron 调用的入口。约束：
#   * 任何失败都只输出一行 JSON 并 exit 0 —— cron 会把非 0 退出码当任务失败。
#   * 自己取锁（与安装 / 修复 / 还原同一把），拿不到就记日志后退出 0。
#   * 每一步都写 $OC_TASKLOG（带时间戳）；日志里绝不出现口令 / token。
#   * 上传直接调用 cloud_upload_file，不 exec 自己。
br_log() {
	# 只写 $OC_TASKLOG，不写 stderr：cron 可能把 stderr 当邮件内容。
	# /var/log 在只读根文件系统上可能不可写，写失败绝不能影响主流程。
	[ -n "${OC_TASKLOG:-}" ] || return 0
	printf '%s [cloud-backup] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" \
		>>"$OC_TASKLOG" 2>/dev/null || true
	return 0
}

br_fail() {
	# br_fail <message>：记一行汇总日志 + 输出 JSON + 退出 0（cron 入口专用）
	br_log "失败：$1"
	printf '{"ok":false,"error":"%s"}\n' "$(jstr "$1")"
	exit 0
}

br_cleanup() {
	# 锁与临时文件都显式收尾。上传在子 shell 里跑，它可能覆盖过 EXIT trap，
	# 这里不依赖任何继承下来的 trap 状态（两个动作都是幂等的）。
	cloud_tmp_cleanup
	oc_lock_release
	return 0
}

cloud_json_known_key() {
	# cloud_json_known_key <file> -> 0 when any key we understand has a value.
	# 用于区分「这是结构化输出，只是没给出登录证据」与「这是自由文本」：
	# 前者绝不能交给文本兜底去猜。
	local k v
	for k in logged_in loggedIn is_login isLogin login ok \
		user_name username uname uid account display_name; do
		v="$(cloud_json_scalar "$1" "$k")"
		[ -n "$v" ] && return 0
	done
	return 1
}

cloud_auth_state() {
	# cloud_auth_state <file> -> true / false / unknown
	#
	# 只看输出内容，不看退出码：退出码 0 只说明命令跑完了，不说明已登录。
	# 登录是「必须有正面证据」的判断，判定顺序：
	#   1) JSON 布尔字段（logged_in / loggedIn / is_login / isLogin / login）
	#   2) JSON 账号类字段有非空值
	#   3) 结构化 JSON 输出到此为止：不再跑文本兜底，一律 unknown
	#   4) 非 JSON 文本：先判未登录，再判已登录
	#   5) 其余一律 unknown（调用方按未登录处理）
	local f="$1" k v acct low first

	acct=""
	for k in user_name username uname uid account display_name; do
		v="$(cloud_json_scalar "$f" "$k")"
		case "$v" in
			''|null|NULL|undefined) ;;
			*) acct="$v"; break ;;
		esac
	done

	# JSON 布尔字段优先。ok 只表示「请求成功」，单独出现不算证据：必须
	# 同时存在非空账号类字段才采信；ok:false 也不作为「未登录」的证据。
	for k in logged_in loggedIn is_login isLogin login ok; do
		v="$(cloud_json_scalar "$f" "$k")"
		case "$v" in
			''|null|NULL) continue ;;
			true|TRUE|True|1|yes|Yes|YES)
				if [ "$k" != "ok" ] || [ -n "$acct" ]; then
					printf 'true'
					return 0
				fi ;;
			false|FALSE|False|0|no|No|NO)
				if [ "$k" != "ok" ]; then
					printf 'false'
					return 0
				fi ;;
		esac
	done

	# 账号类字段有值 -> 已登录
	if [ -n "$acct" ]; then
		printf 'true'
		return 0
	fi

	# 结构化输出不跑文本兜底。
	# 文本兜底的正则只剥「键名 + 冒号」，值里的单词原样保留，于是
	# {"error":"invalid username or password"} 会被剥成
	# {"invalid username or password"} 并命中 username —— 未登录被判成已登录。
	# 所以：只要输出看起来是 JSON 且我们能认出任意一个已知键，就直接 unknown，
	# 把「这条 JSON 里没有登录证据」如实报出来，而不是去猜它的文本。
	first="$(sed -n 's/^[[:space:]]*\(.\).*/\1/p' "$f" 2>/dev/null | head -n1)"
	case "$first" in
		'{'|'[')
			if cloud_json_known_key "$f"; then
				printf 'unknown'
				return 0
			fi
			;;
	esac

	# 文本兜底：先把 JSON 的键名剥掉（只保留值），避免 {"username":""} 的
	# 键名被当成登录证据；统一转小写，省掉逐个大写变体。
	# 顺序必须是「先未登录、再已登录」：输出里同时出现「未登录，请登录」
	# 这种话时，必须命中前者。
	# 已登录词表里不再有 *username*：键名已经剥掉了，值里再出现这个词基本
	# 都是 "invalid username" 一类的报错，留着只会造成误判。
	low="$(sed 's/"[^"]*"[[:space:]]*:[[:space:]]*//g' "$f" 2>/dev/null | tr 'A-Z' 'a-z')"
	case "$low" in
		*未登录*|*没有登录*|*请先登录*|*请登录*|*"not logged in"*|*"not login"*|*"login required"*|*"please login"*|*unauthorized*|*未授权*|*expired*|*过期*|*"invalid token"*|*无效*|*"invalid username"*|*"incorrect password"*|*"authentication failed"*|*"login failed"*|*"failed to login"*|*密码错误*|*账号或密码*)
			printf 'false' ;;
		*已登录*|*"logged in"*|*"login as"*|*用户名*|*"uid:"*)
			printf 'true' ;;
		*)
			printf 'unknown' ;;
	esac
}

# cmd_status 已经执行过一次 whoami 时，把输出文件路径放在这里复用，避免为了
# 判定登录态再跑一次 bdpan。cloud_is_logged_in 读取后立即清空。
CLOUD_AUTH_SNAPSHOT=""
# cloud_is_logged_in 最近一次的判定结果：true / false / unknown（给 status 用）
CLOUD_AUTH_STATE=""

cloud_is_logged_in() {
	# 0 = 已登录；1 = 未登录 / 无法确认。判定口径只有 cloud_auth_state 一处。
	# 默认未登录：无法确认时也返回 1，并留一行可排查的日志（stderr）。
	local bin tmp rc state snip own snap

	snap="$CLOUD_AUTH_SNAPSHOT"
	CLOUD_AUTH_SNAPSHOT=""
	CLOUD_AUTH_STATE=""
	tmp=""
	own=0
	if [ -n "$snap" ] && [ -f "$snap" ]; then
		tmp="$snap"
	else
		bin="$(cloud_bin_ready)" || return 1
		tmp="$OC_RUNDIR/cloud-auth.$$"
		own=1
		rm -f "$tmp" 2>/dev/null
		cloud_run 25 "$bin" whoami --json >"$tmp" 2>&1
		rc=$?
		if [ "$rc" -ne 0 ]; then
			# 老版本 CLI 可能没有 --json
			cloud_run 25 "$bin" whoami >"$tmp" 2>&1
		fi
	fi

	state="$(cloud_auth_state "$tmp")"
	CLOUD_AUTH_STATE="$state"
	snip=""
	if [ "$state" != "true" ] && [ "$state" != "false" ]; then
		# 脱敏 + 按行截断 + 压成一行；只进日志，绝不进 stdout 的 JSON。
		snip="$(cloud_redact <"$tmp" 2>/dev/null | oc_cut_utf8 120 | tr '\n\r\t' '   ')"
	fi
	if [ "$own" -eq 1 ]; then
		rm -f "$tmp" 2>/dev/null
	fi

	case "$state" in
		true)  return 0 ;;
		false) return 1 ;;
	esac
	cblog "登录状态无法确认，按未登录处理：${snip:-无输出}"
	return 1
}

cloud_remote_list_tsv() {
	# 远端目录列表："isdir<TAB>mtime<TAB>name<TAB>size"；读不到时返回 1。
	local bin tmp out rc

	bin="$(cloud_bin_ready)" || return 1
	tmp="$OC_RUNDIR/cloud-ls.$$"
	rm -f "$tmp" 2>/dev/null
	cloud_run 60 "$bin" ls "$OC_CLOUD_REMOTE" --json >"$tmp" 2>&1 || {
		rm -f "$tmp" 2>/dev/null
		return 1
	}
	out="$(cloud_ls_tsv "$tmp")"
	rc=$?
	rm -f "$tmp" 2>/dev/null
	[ "$rc" -eq 0 ] || return 1
	[ -n "$out" ] || return 0
	printf '%s\n' "$out"
}

br_prune() {
	# br_prune <keep> -> stdout: 实际删除的份数；列不出远端时返回 1。
	#
	# 只处理符合 openclaw-*.tar.gz / openclaw-*.tar.gz.enc 的普通文件；
	# 目录、别人的文件、其它命名一律不碰。删除失败只告警、继续下一份。
	local keep="$1" listing cand tab total excess n name

	listing="$(cloud_remote_list_tsv)" || return 1
	tab="$(printf '\t')"
	# 排序键：mtime 里的数字（epoch 与 ISO 时间串都能归一），左补零后按字符串
	# 比较即可；同值时按文件名（我们的名字自带时间戳）。输出为「最旧在前」。
	cand="$(printf '%s\n' "$listing" | awk -F "$tab" '
		$1 == "false" && ($3 ~ /^openclaw-.+\.tar\.gz$/ || $3 ~ /^openclaw-.+\.tar\.gz\.enc$/) {
			mt = $2
			gsub(/[^0-9]/, "", mt)
			if (mt == "") mt = "0"
			while (length(mt) < 12) mt = "0" mt
			printf "%s\t%s\n", mt, $3
		}' | sort -t "$tab" -k1,1 -k2,2)"

	total="$(printf '%s\n' "$cand" | awk 'NF { n++ } END { printf "%d", n + 0 }')"
	case "$total" in ''|*[!0-9]*) total=0 ;; esac
	excess=$((total - keep))
	if [ "$excess" -le 0 ]; then
		printf '0'
		return 0
	fi

	n=0
	# 用 here-doc 而不是管道：管道里的 while 在子 shell 里跑，n 回传不出来。
	while IFS="$tab" read -r _ name; do
		[ -n "$name" ] || continue
		[ "$n" -lt "$excess" ] || break
		if cloud_rm_remote "$name"; then
			n=$((n + 1))
		else
			oc_warn "清理旧备份失败（$name）：${OC_RM_ERR:-未知错误}"
		fi
	done <<EOF
$(printf '%s\n' "$cand" | awk -v n="$excess" 'NF && c < n { print; c++ }')
EOF
	printf '%s' "$n"
}

cmd_backup_run() {
	local enabled out errf file dir local_path remote pruned rc
	local local_removed drop_reason dir_phys par_phys

	# ---- 前置：启用 / 组件 / 登录；任一不满足都只记日志 + JSON + exit 0 ----
	cloud_sched_vals
	enabled="$OC_SCH_ENABLED"
	if [ "$enabled" != "1" ]; then
		br_log "跳过：定时备份未启用（main.cloud_enabled）"
		printf '{"ok":false,"error":"定时备份未启用"}\n'
		exit 0
	fi
	# 这里只需要知道「组件能不能跑」，返回值本身后面用不到，不存变量。
	cloud_bin_ready >/dev/null || {
		br_log "跳过：网盘组件未安装"
		printf '{"ok":false,"error":"网盘组件未安装"}\n'
		exit 0
	}
	if ! cloud_is_logged_in; then
		# cloud_is_logged_in 把判定结果留在 CLOUD_AUTH_STATE：
		# false = 明确未登录，unknown = 输出无法判定。两者对定时任务的
		# 结论相同（都跳过），但日志与 JSON 必须分开说，否则用户看到
		# 「尚未登录」会以为重新登录就好，实际可能是组件输出异常。
		if [ "$CLOUD_AUTH_STATE" = "unknown" ]; then
			br_log "跳过：登录状态无法确认（whoami 输出无法判定）"
			printf '{"ok":false,"error":"%s"}\n' \
				"$(jstr "登录状态无法确认，请在云备份页面重新登录")"
		else
			br_log "跳过：尚未登录百度网盘"
			printf '{"ok":false,"error":"尚未登录百度网盘"}\n'
		fi
		exit 0
	fi
	[ -f "$OC_CLOUD_BACKUP" ] || {
		br_log "跳过：找不到本地备份脚本（$OC_CLOUD_BACKUP）"
		printf '{"ok":false,"error":"找不到本地备份脚本"}\n'
		exit 0
	}

	# ---- 互斥锁：与安装 / 修复 / 还原共用同一把 ----
	if ! oc_lock_acquire; then
		br_log "跳过：另一个操作正在运行（$OC_LOCK_DIR）"
		printf '{"ok":false,"error":"另一个操作正在运行，请稍后再试"}\n'
		exit 0
	fi
	trap 'br_cleanup' EXIT
	trap 'br_cleanup; exit 0' INT TERM HUP

	out="$OC_RUNDIR/cloud-br-out.$$"
	errf="$OC_RUNDIR/cloud-br-err.$$"
	rm -f "$out" "$errf" 2>/dev/null

	# ---- a) 本地备份：复用 backup.sh create ----
	# 范围就是 backup.sh 的默认范围：/etc/config/openclaw + 数据目录
	# （配置、会话、工作区）；程序目录与 Node 运行时本来就不在备份里。
	br_log "开始：创建本地备份（配置 + 会话 + 工作区；不含程序与 Node）"
	sh "$OC_CLOUD_BACKUP" create >"$out" 2>"$errf"
	rc=$?
	if [ "$rc" -ne 0 ] || ! grep -q '"ok":true' "$out" 2>/dev/null; then
		# 只取最后几行、脱敏后进日志；绝不把整段输出塞进去
		br_log "本地备份失败（rc=$rc）：$(cloud_tail_err "$errf" 3 | tr '\n' ' ')"
		rm -f "$out" "$errf" 2>/dev/null
		br_fail "本地备份失败"
	fi
	[ -s "$errf" ] && br_log "backup.sh：$(cloud_tail_err "$errf" 3 | tr '\n' ' ')"
	file="$(sed -n 's/.*"file":"\([^"]*\)".*/\1/p' "$out" 2>/dev/null | head -n1)"
	rm -f "$out" "$errf" 2>/dev/null

	case "$file" in
		'') br_fail "本地备份未返回文件名" ;;
		*/*|*..*) br_fail "本地备份返回的文件名不合法：$file" ;;
	esac
	case "$file" in
		openclaw-*.tar.gz) ;;
		*) br_fail "本地备份文件名不符合 openclaw-*.tar.gz：$file" ;;
	esac

	dir="$(sh "$OC_CLOUD_BACKUP" path 2>/dev/null)"
	[ -n "$dir" ] || dir="$(oc_base_dir)/backups"
	local_path="$dir/$file"
	[ -f "$local_path" ] || br_fail "本地备份文件不存在：$local_path"
	br_log "本地备份完成：$file"

	# ---- b) 上传：直接调用函数（放子 shell，失败只结束子 shell，不带走锁）----
	br_log "开始上传：$file"
	out="$OC_RUNDIR/cloud-br-up.$$"
	errf="$OC_RUNDIR/cloud-br-uperr.$$"
	rm -f "$out" "$errf" 2>/dev/null
	( cloud_upload_file "$local_path" "$file" ) >"$out" 2>"$errf"
	rc=$?
	if [ "$rc" -ne 0 ] || ! grep -q '"ok":true' "$out" 2>/dev/null; then
		remote="$(sed -n 's/.*"error":"\([^"]*\)".*/\1/p' "$out" 2>/dev/null | head -n1)"
		[ -n "$remote" ] || remote="上传失败（rc=$rc）"
		br_log "上传失败：$remote"
		rm -f "$out" "$errf" 2>/dev/null
		br_fail "$remote"
	fi
	remote="$(sed -n 's/.*"remote":"\([^"]*\)".*/\1/p' "$out" 2>/dev/null | head -n1)"
	rm -f "$out" "$errf" 2>/dev/null

	case "$remote" in
		"$OC_CLOUD_REMOTE"/*) ;;
		'') br_fail "上传成功但未返回远端文件名" ;;
		*)  br_fail "上传返回的远端路径异常：$remote" ;;
	esac
	br_log "上传完成：$remote"

	# ---- c) 轮转：只删符合命名规则的，删到只剩 keep 份 ----
	pruned="$(br_prune "$OC_SCH_KEEP")" || pruned=""
	case "$pruned" in
		''|*[!0-9]*)
			br_log "警告：无法列出远端目录，本次跳过清理"
			pruned=0 ;;
	esac

	# ---- d) 本机副本：上传已确认成功，删掉本次创建的归档 ----
	# 定时任务每天跑一次，若不在本地清理，含工作区的 tar.gz 会无限堆积。
	# 三重校验，任一不满足都保留并记日志；删除失败也不让任务失败。
	local_removed=false
	drop_reason=""
	case "$local_path" in
		/*) ;;
		*) drop_reason="本地路径不是绝对路径：$local_path" ;;
	esac
	case "$file" in
		openclaw-*.tar.gz) ;;
		*) [ -n "$drop_reason" ] || drop_reason="文件名不符合 openclaw-*.tar.gz：$file" ;;
	esac
	case "$file" in
		*/*|*..*) [ -n "$drop_reason" ] || drop_reason="文件名含路径分隔符或 ..：$file" ;;
	esac
	if [ -z "$drop_reason" ]; then
		# 规范化后再比较：cd -P 会解析符号链接，避免 /a/../ 之类绕过。
		dir_phys="$(oc_canonical_dir "$dir" 2>/dev/null)" || dir_phys=""
		par_phys="$(oc_canonical_dir "$(dirname "$local_path")" 2>/dev/null)" || par_phys=""
		if [ -z "$dir_phys" ] || [ -z "$par_phys" ]; then
			drop_reason="无法解析备份目录：${dir:-?}"
		else
			dir_phys="${dir_phys%/}"
			[ -n "$dir_phys" ] || dir_phys="/"
			case "$par_phys/" in
				"$dir_phys"/*) ;;
				*) drop_reason="本地归档不在备份目录下：$local_path" ;;
			esac
		fi
	fi
	if [ -n "$drop_reason" ]; then
		br_log "保留本机副本：$drop_reason"
	elif rm -f "$local_path" 2>/dev/null; then
		local_removed=true
		br_log "已删除本机副本：$file（已确认上传成功，云端保留 $OC_SCH_KEEP 份）"
	else
		br_log "警告：删除本机副本失败（$file），已保留"
	fi

	br_log "完成：已上传 $remote；清理 $pruned 份旧备份（保留 $OC_SCH_KEEP 份）"
	printf '{"ok":true,"uploaded":"%s","pruned":%s,"local_removed":%s}\n' \
		"$(jstr "$remote")" "$pruned" "$local_removed"
	exit 0
}

# ---------------------------------------------------------------- dispatch
case "${1:-}" in
	status)      cmd_status ;;
	install-cli) cmd_install_cli ;;
	install-cli-bg) shift; cmd_install_cli_bg "$@" ;;
	install-cli-poll) cmd_install_cli_poll ;;
	cli-check)   cmd_cli_check ;;
	cli-update)  shift; cmd_cli_update "$@" ;;
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
	encrypt-status) cmd_encrypt_status ;;
	set-encrypt)    cmd_set_encrypt ;;
	schedule-status) cmd_schedule_status ;;
	schedule-apply)  cmd_schedule_apply ;;
	schedule-set)    cmd_schedule_set ;;
	schedule-clear)  cmd_schedule_clear ;;
	backup-run)      cmd_backup_run ;;
	*)
		printf '{"ok":false,"error":"%s"}\n' "$(jstr "未知动作：${1:-}")"
		cat >&2 <<EOF
Usage: cloud.sh {status|install-cli|install-cli-bg [version]|install-cli-poll|cli-check|cli-update [version]|login-url|login-code <code>|logout|upload <local> <name>|ls|download <name> <local>|download-dec <name> <local>|rm <name>|pass-status|set-pass|clear-pass|encrypt-status|set-encrypt|schedule-status|schedule-apply|schedule-set|schedule-clear|backup-run}
EOF
		exit 2 ;;
esac
