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
#   * $HOME/.config/bdpan/config.json 内含 access_token。只有在需要直连
#     网盘接口删除时（bdpan 没有删除子命令）才读取一次，且：写进 0600 的
#     curl 配置文件（-K），绝不进 argv、绝不打印、绝不写日志；请求只发往
#     https://pan.baidu.com。其余任何路径都不读这个文件。
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

# 状态缓存：status 里的 `bdpan whoami` 是**联网**调用（25 秒上限，失败还会
# 再试一次不带 --json 的），而备份页每次打开都会问一次 status。
# 实测：组件在、但网盘侧慢或不通时，光这一项就能把页面卡到几十秒，
# 用户看到的是「一直读取中」。
#
# 缓存整份 JSON 而不是只缓存登录态：status 的字段（版本、路径、用户名、
# 到期时间）在一次会话内几乎不变，而重算其中任何一个都要再起一次 5900 行
# 的脚本。TTL 用 OC_CLOUD_STATUS_TTL。
#
# 失效点（这些操作会改变 status 的任一字段）：
#   安装 / 更新组件、登录、登出 —— 见 cloud_status_cache_drop。
# 另外 cache 目录若不可写就静默跳过缓存，行为退回原样（慢但不坏）。
OC_CLOUD_STATUS_CACHE="$OC_RUNDIR/cloud-status.json"
OC_CLOUD_STATUS_TTL="${OC_CLOUD_STATUS_TTL:-30}"
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

cloud_fail_reason() {
	# cloud_fail_reason <reason> <message> [exit-code]
	#
	# reason 是给程序和前端消费的稳定标识，error 才是给人看的中文。
	# 页面按 reason 决定提示措辞，按 error 显示细节。
	printf '{"ok":false,"reason":"%s","error":"%s"}\n' \
		"$(jstr "${1:-unknown}")" "$(jstr "${2:-未知错误}")"
	exit "${3:-1}"
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
	# Every directory in the root-executed component chain is root-only.
	# Do not remove or silently migrate an existing path: a failed hardening
	# operation must leave the old installation intact and explain the failure.
	local d
	for d in "$OC_CLOUD_ROOT" "$OC_CLOUD_DIR" "$OC_CLOUD_HOME"; do
		if [ -e "$d" ] || [ -L "$d" ]; then
			[ -d "$d" ] && [ ! -L "$d" ] || { printf '%s\n' "云组件路径不是安全目录：$d" >&2; return 1; }
		else
			mkdir "$d" 2>/dev/null || { printf '%s\n' "无法创建云组件目录：$d" >&2; return 1; }
		fi
		chown root:root "$d" 2>/dev/null || { printf '%s\n' "无法把云组件目录设为 root 属主：$d" >&2; return 1; }
		chmod 700 "$d" 2>/dev/null || { printf '%s\n' "无法把云组件目录收紧为 0700：$d" >&2; return 1; }
		[ "$(stat -c %u "$d" 2>/dev/null)" = 0 ] && [ "$(stat -c %a "$d" 2>/dev/null)" = 700 ] || {
			printf '%s\n' "云组件目录权限复核失败：$d" >&2; return 1
		}
	done
	return 0
}

cloud_secure_reason() {
	# cloud_secure_reason <path> -> stdout 一个原因码；只有 ready 时返回 0。
	#
	# 这个函数是「组件能不能用」的**唯一判据**。以前 status 只看 -f + -x，
	# 而 ls/upload 走 cloud_bin_secure，于是同一台设备上 status 说「已安装
	# v3.8.4、已登录」、ls 说「组件未安装」—— 现场就是这么自相矛盾的。
	# 现在两边都从这里取结论，并且带上原因码，页面才能给出可操作提示。
	#
	# 原因码：
	#   ready               可用
	#   missing             文件不存在
	#   not-executable      文件在但没有执行位
	#   symlink             文件或父目录是符号链接
	#   insecure-owner      属主不是 root:root（现场故障就是这一条：998:998）
	#   insecure-mode       权限位不在白名单内（含 group/other 写、特殊位）
	#   outside-root        路径不在 $OC_CLOUD_ROOT 之下
	#   insecure-path       路径里带 .. / .
	local b="${1:-}" d dir_mode bin_mode

	[ -n "$b" ] || { printf 'missing'; return 1; }
	# 判据依赖 OC_CLOUD_ROOT 的绝对路径语义。它为空的退化情形是 fail-open
	# 且会死循环：case 模式变成 `""|/*`（任何绝对路径都算在根内），而循环
	# 终止条件 `[ "$d" = "" ]` 永假、dirname / 恒为 / 就会一直转。这里
	# 先 fail-closed，并让 status 这类高频入口不会卡住。
	[ -n "${OC_CLOUD_ROOT:-}" ] || { printf 'insecure-path'; return 1; }
	# 先检查路径文本和根目录范围，再触碰文件系统；否则不存在路径会掩盖
	# outside-root / insecure-path，且路径类拒绝必须优先于文件存在判断。
	case "$b" in
		*"/../"*|*"/./"*|*/..|*/.) printf 'insecure-path'; return 1 ;;
	esac
	# 只检查组件链本身（云根目录到可执行文件），系统祖先如 /usr 不要求私有。
	d="$(dirname "$b")"
	case "$d" in "$OC_CLOUD_ROOT"|"$OC_CLOUD_ROOT"/*) ;; *) printf 'outside-root'; return 1 ;; esac
	[ -L "$b" ] && { printf 'symlink'; return 1; }
	[ -f "$b" ] || { printf 'missing'; return 1; }
	while :; do
		[ -L "$d" ] && { printf 'symlink'; return 1; }
		[ -d "$d" ] || { printf 'missing'; return 1; }
		[ "$(stat -c '%u:%g' "$d" 2>/dev/null)" = '0:0' ] || { printf 'insecure-owner'; return 1; }
		# 目录只接受显式组合。0701/0711/0751 是安装器上真实见过的权限，
		# 都不含任何写位给组/其他。
		dir_mode="$(stat -c '%a' "$d" 2>/dev/null)"
		case "$dir_mode" in
			700|701|710|711|750|751|755) ;;
			*) printf 'insecure-mode'; return 1 ;;
		esac
		[ "$d" = "$OC_CLOUD_ROOT" ] && break
		# 走到 / 还没碰到根目录，说明根本不在根内。这条同时是循环终止的
		# 兜底：dirname / 恒为 /，没有它就会原地打转。
		[ "$d" = "/" ] && { printf 'outside-root'; return 1; }
		d="$(dirname "$d")"
		case "$d" in "$OC_CLOUD_ROOT"|"$OC_CLOUD_ROOT"/*) ;; *) printf 'outside-root'; return 1 ;; esac
	done
	[ "$(stat -c '%u:%g' "$b" 2>/dev/null)" = '0:0' ] || { printf 'insecure-owner'; return 1; }
	# 可执行文件有自己的白名单：group/other 写以及 setuid/setgid/sticky 全部拒绝。
	bin_mode="$(stat -c '%a' "$b" 2>/dev/null)"
	# 先判可执行位：白名单里每一档都带 owner 的 x，所以 0644 这类文件落到
	# 下面只会被判成 insecure-mode，永远得不到「没有执行权限」这个更准确、
	# 也更可操作的结论（重新安装/补执行位）。
	[ -x "$b" ] || { printf 'not-executable'; return 1; }
	case "$bin_mode" in
		700|701|710|711|750|751|755) ;;
		*) printf 'insecure-mode'; return 1 ;;
	esac
	printf 'ready'
	return 0
}

cloud_bin_secure() {
	# 兼容包装：只关心能不能用，不关心原因。判据统一在 cloud_secure_reason。
	cloud_secure_reason "${1:-}" >/dev/null 2>&1
}

cloud_bin() {
	# Print bdpan only after rejecting symlink targets.
	if [ -f "$OC_CLOUD_BIN" ]; then
		[ ! -L "$OC_CLOUD_BIN" ] || return 1
		printf '%s' "$OC_CLOUD_BIN"
		return 0
	fi
	[ -d "$OC_CLOUD_ROOT" ] || return 1
	local p
	p="$(find "$OC_CLOUD_ROOT" -maxdepth 4 -type f -name bdpan 2>/dev/null | head -n1)"
	[ -n "$p" ] && [ "$(basename "$p" 2>/dev/null)" = bdpan ] || return 1
	[ ! -L "$p" ] || return 1
	printf '%s' "$p"
}

cloud_bin_ready() {
	local b
	b="$(cloud_bin)" || return 1
	cloud_bin_secure "$b" || { oc_warn "拒绝执行不安全的云组件路径：$b"; return 1; }
	[ -x "$b" ] || return 1
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
	// 先写 <dst>.tmp，回填 auth tag 之后再 rename 成最终名。
	// 直接写最终名时，tag 区要等密文写完才能 seek 回去回填；这中间被
	// SIGKILL / 断电，就会留下一个「名字完整、tag 全 0」的成品文件，
	// 解密必然失败，而且调用方会把它当成功产物继续上传。
	const tmp = dst + ".tmp";
	// 目标已存在：沿用原来的 EEXIST 语义（exit 3），调用方据此避免误删别人的文件。
	if (fs.existsSync(dst)) die("output exists: " + dst, 3);
	// 上一次异常退出可能在同一私有目录留下 .tmp，先清掉它。
	// 只动 .tmp，不碰最终名，因此不影响「不覆盖已有备份」的语义。
	try { if (fs.existsSync(tmp)) fs.unlinkSync(tmp); } catch (e) {}
	try {
		fs.writeFileSync(tmp, hdr, { mode: 0o600, flag: "wx" });
	} catch (e) {
		die("cannot create output: " + e.message, e.code === "EEXIST" ? 3 : 1);
	}
	const cipher = crypto.createCipheriv("aes-256-gcm", key, iv);
	const rs = fs.createReadStream(src);
	const ws = fs.createWriteStream(tmp, { flags: "r+", start: HDR });
	pipeline(rs, cipher, ws, function (err) {
		if (err) {
			try { fs.unlinkSync(tmp); } catch (e2) {}
			die("encrypt failed: " + err.message);
		}
		let tag;
		try {
			tag = cipher.getAuthTag();
		} catch (e) {
			try { fs.unlinkSync(tmp); } catch (e2) {}
			die("no auth tag: " + e.message);
		}
		try {
			const fd = fs.openSync(tmp, "r+");
			try {
				fs.writeSync(fd, tag, 0, tag.length, 35);
				fs.fsyncSync(fd);
			} finally {
				fs.closeSync(fd);
			}
		} catch (e) {
			try { fs.unlinkSync(tmp); } catch (e2) {}
			die("cannot write tag: " + e.message);
		}
		// rename 之前再确认一次：保留 flag:"wx" 的「不覆盖」语义。
		if (fs.existsSync(dst)) {
			try { fs.unlinkSync(tmp); } catch (e2) {}
			die("output exists: " + dst, 3);
		}
		try {
			fs.renameSync(tmp, dst);
		} catch (e) {
			try { fs.unlinkSync(tmp); } catch (e2) {}
			die("cannot finalize output: " + e.message, e.code === "EEXIST" ? 3 : 1);
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
	# 临时文件名不用 PID：PID 可预测，同文件其它临时文件都已改用 mktemp。
	# mktemp 会先以 0600 建好文件并占位；失败（老 busybox / 目录异常）时退回
	# 原来的 PID 写法并记一行日志 —— 宁可可预测，也不要因为建不出临时文件
	# 就让用户完全无法设置口令。
	tmp="$(mktemp "$OC_CLOUD_ROOT/.pass.XXXXXX" 2>/dev/null)" || tmp=""
	if [ -n "$tmp" ]; then
		# 文件已由 mktemp 建好：直接写入，不再 rm -f 后重建（重建会重新
		# 引入可预测窗口）。先把权限收到 0600 再写 —— busybox mktemp 本来就是
		# 0600，但别把口令的安全性押在 applet 的实现细节上。umask 077 作为
		# 写入期间的第二道保险。
		chmod 600 "$tmp" 2>/dev/null
		if ! ( umask 077; printf '%s' "$pass" > "$tmp" ) 2>/dev/null; then
			rm -f "$tmp" 2>/dev/null
			cloud_fail "无法写入口令文件"
		fi
	else
		oc_warn "mktemp 不可用，口令临时文件退回 PID 命名"
		tmp="$OC_CLOUD_ROOT/.pass.$$"
		rm -f "$tmp" 2>/dev/null
		if ! ( umask 077; printf '%s' "$pass" > "$tmp" ) 2>/dev/null; then
			rm -f "$tmp" 2>/dev/null
			cloud_fail "无法写入口令文件"
		fi
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

# ---------------------------------------------------------------- overview
cmd_overview() {
	# 备份页需要的全部只读状态，**一次脚本启动**全部返回。
	#
	# 为什么要有这个命令：备份页原先并发打 4 个端点（status / pass-status /
	# encrypt-status / schedule-status），每个都独立启动一次本脚本 ——
	# lib.sh 2060 行 + 本文件 3900 行，每启动一次都要把 6000 行 shell 解析一遍。
	# 在路由器上这不是可以忽略的开销，而且 4 个请求还会排队抢 uhttpd 的 worker。
	#
	# 输出结构与 status 保持兼容（顶层 cli / auth 字段不变），另外加
	# encrypt / pass / schedule 三个子对象。这样前端只需要换一个端点地址，
	# 解析逻辑基本不动。
	#
	# 参数：--fresh 透传给 cmd_status（绕过状态缓存）。
	local fresh="" base
	[ "${1:-}" = "--fresh" ] && fresh="--fresh"

	# status 部分：直接复用，避免两处各拼一份（迟早会不一致）。
	if [ -n "$fresh" ]; then
		base="$(cmd_status --fresh)"
	else
		base="$(cmd_status)"
	fi

	# status 失败时**必须整包失败**。它的错误是 {"ok":false,"error":"..."}，
	# 格式与成功时不同 —— 直接往下拼会产出
	#   {"ok":true,{"ok":false,... —— 非法 JSON，前端解析失败后整页状态全空。
	# 而「组件未安装」正是最常见的情形（刚装上插件就是这个状态），
	# 所以这条路径一定会被走到。
	case "$base" in
		*'"ok":false'*)
			# 原样透传 status 的失败结果：错误文案已经在里面了。
			printf '%s\n' "$base"
			exit 1 ;;
	esac

	# 到这里 base 一定是 {"ok":true,...}，剥掉外层只留字段，
	# 好把三块新内容拼进同一个对象。用 sed 去掉首尾 —— 输入格式固定，
	# 够用且不必引入 jq。
	base="$(printf '%s' "$base" | sed -e 's/^{"ok":true,//' -e 's/}$//')"

	# pass / encrypt 共用 cloud_pass_present，不重复判断
	local pass_set=false enc_on=false
	cloud_pass_present && pass_set=true
	[ "$(cloud_encrypt_enabled)" = "1" ] && enc_on=true

	# 删除密码是否已设置。走的是 lib.sh 的同一个函数（cli.sh 的
	# delpass-status 用的也是它），所以两处判据不会分叉。
	local dp_set=false
	if command -v oc_delpass_present >/dev/null 2>&1; then
		oc_delpass_present && dp_set=true
	fi

	# schedule
	cloud_sched_vals
	local sch_installed=false sch_enabled=false sch_line
	sch_line="$(cloud_cron_line)"
	[ -n "$sch_line" ] && sch_installed=true
	# enabled 必须是 JSON 布尔，与 cmd_schedule_status 的输出一致。
	# 前端用 d.enabled === true 判定；这里若输出数字 1，页面每次打开
	# 都会把「启用」勾选框强制清空（保存其实已成功）。
	[ "$OC_SCH_ENABLED" = "1" ] && sch_enabled=true

	printf '{"ok":true,%s,"encrypt":{"enabled":%s,"pass_set":%s},"pass":{"set":%s},"delpass":{"set":%s},"schedule":{"enabled":%s,"period":"%s","weekday":%s,"hour":%s,"minute":%s,"keep":%s,"keep_local":%s,"installed":%s,"line":"%s"}}\n' \
		"$base" "$enc_on" "$pass_set" "$pass_set" "$dp_set" \
		"$sch_enabled" "$OC_SCH_PERIOD" "$OC_SCH_WEEKDAY" "$OC_SCH_HOUR" \
		"$OC_SCH_MINUTE" "$OC_SCH_KEEP" "$OC_SCH_KEEP_LOCAL" "$sch_installed" "$(jstr "$sch_line")"
}

# ---------------------------------------------------------------- status cache
clock_status_cache_read() {
	# 命中则把缓存的 JSON 打到 stdout 并返回 0；未命中返回 1。
	#
	# 判新鲜度用 oc_mtime（stat -c %Y），**不要用 date -r** ——
	# busybox 的 date 没有 -r，配上 || echo 0 会静默得到 0，
	# age 恒等于当前时间，缓存永不命中。这一点在 versions.sh 里已经踩过。
	local f="$OC_CLOUD_STATUS_CACHE" now mt age
	[ -s "$f" ] || return 1
	mt="$(oc_mtime "$f")"
	[ -n "$mt" ] || return 1
	now="$(date +%s 2>/dev/null)"
	case "$now" in ''|*[!0-9]*) return 1 ;; esac
	age=$(( now - mt ))
	[ "$age" -ge 0 ] || return 1
	# 不能拿未来的时间当新鲜（时钟被改过）
	[ "$age" -lt "$OC_CLOUD_STATUS_TTL" ] || return 1
	cat "$f" 2>/dev/null
}

clock_status_cache_write() {
	# clock_status_cache_write <json>；失败静默（缓存只是优化）。
	# 原子写：先写同目录临时文件再 mv，避免半截 JSON 被下一次读走。
	local json="$1" d tmp
	d="$(dirname "$OC_CLOUD_STATUS_CACHE")"
	[ -d "$d" ] || mkdir -p "$d" 2>/dev/null || return 1
	tmp="$OC_CLOUD_STATUS_CACHE.$$"
	rm -f "$tmp" 2>/dev/null
	printf '%s\n' "$json" >"$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
	mv -f "$tmp" "$OC_CLOUD_STATUS_CACHE" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
	return 0
}

clock_status_cache_drop() {
	# 使缓存失效。由会改状态的操作调用（装 / 更新组件、登录、登出）。
	rm -f "$OC_CLOUD_STATUS_CACHE" 2>/dev/null || true
}

# ---------------------------------------------------------------- status
cmd_status() {
	# 参数：--fresh 强制重新探测（忽略缓存）。
	# 默认走缓存：`bdpan whoami` 是联网调用，而备份页每次打开都问一次。
	# 只有明确要实时值的调用方（cli-update 之后自查）才传 --fresh。
	local force=0
	[ "${1:-}" = "--fresh" ] && force=1

	if [ "$force" = "0" ]; then
		local _c
		if _c="$(clock_status_cache_read)"; then
			printf '%s\n' "$_c"
			return 0
		fi
	fi

	local arch bin installed=false executable=false path="" ver="" logged=false user="" expires="" raw=""
	local uncertain=false tmp rc k secure_reason="missing" secure=false

	arch="$(cloud_arch)"

	bin="$OC_CLOUD_BIN"
	# -L 也要算「存在」：断链的符号链接仍然要被 cloud_secure_reason 判成
	# symlink，否则状态页会显示「未安装」，而列表接口说「路径不安全」。
	{ [ -e "$bin" ] || [ -L "$bin" ]; } || bin=""
	if [ -n "$bin" ]; then
		# installed 只表示「找到了文件」；能不能用一律由 cloud_secure_reason
		# 判定 —— 与 ls / upload / backup-run 完全同一条判据。以前这里只查
		# -f + -x，于是组件属主是 998（安全校验会拒绝）时 status 照样报
		# executable=true，页面显示「已安装 v3.8.4 · 已登录」，而同一个页面
		# 的云端列表说「组件未安装」。
		installed=true
		path="$bin"
		secure_reason="$(cloud_secure_reason "$bin")" || true
		if [ "$secure_reason" = "ready" ]; then
			executable=true
			secure=true
		fi
	fi

	if [ "$installed" = "true" ] && [ "$executable" != "true" ]; then
		oc_warn "找到 bdpan（$bin）但不可用：$secure_reason（请重新安装组件或跑一键修复）"
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

	local _json
	_json="$(printf '{"ok":true,"arch":"%s","cli":{"installed":%s,"executable":%s,"secure":%s,"reason":"%s","path":"%s","version":"%s"},"auth":{"logged_in":%s,"uncertain":%s,"user":"%s","expires":"%s","raw":"%s"},"remote_dir":"%s","root":"%s","dir":"%s","home":"%s"}' \
		"$arch" "$installed" "$executable" "$secure" "$(jstr "$secure_reason")" "$(jstr "$path")" "$(jstr "$ver")" \
		"$logged" "$uncertain" "$(jstr "$user")" "$(jstr "$expires")" "$(jstr "$raw")" \
		"$(jstr "$OC_CLOUD_REMOTE")" "$(jstr "$OC_CLOUD_ROOT")" \
		"$(jstr "$OC_CLOUD_DIR")" "$(jstr "$OC_CLOUD_HOME")")"
	printf '%s\n' "$_json"
	# 只在探测成功时写缓存。上面任一失败都会提前 cloud_fail 退出，
	# 能走到这里的都是完整结果。
	clock_status_cache_write "$_json"
}

# ---------------------------------------------------------------- install-cli
cloud_installer_url() {
	# cloud_installer_url <ver> -> 官方安装器 URL
	# 前端展示版本通常带 v 前缀，下载路径不带 v；统一归一化，
	# 避免把 /v3.8.4/ 拼进官方 CDN 导致 404。
	local ver
	ver="$(cloud_norm_version "$1" 2>/dev/null)"
	[ -n "$ver" ] || ver="$1"
	printf '%s/%s/bdpan-installer-linux-%s' "$OC_CLOUD_CDN" "$ver" "$(cloud_arch)"
}

cloud_installer_sha() {
	# cloud_installer_sha <ver> <arch> -> 期望的 sha256；未收录时输出空
	#
	# 安装器是下载后以 root 直接执行的二进制，只记录哈希没有任何防护作用：
	# CDN 被劫持 / 发版被污染 / 企业出口做 TLS 替换，都会变成 root 代码执行。
	# 官方没有公布校验清单，下面的值是对官方 URL 下载后实测得到的，按
	# 「版本 + 架构」精确匹配；新版本未收录时退回「只记录」，日志会写明未校验。
	# 这里刻意不做前缀 / 模糊匹配：宁可漏校验（日志可见），也不要把错误的哈希
	# 当成通过。
	case "${1:-}:${2:-}" in
		3.7.3:arm64) printf '%s' '7692f828a1af10289274e6951225fcbe9ad3c0664ebee0b492c410855220c197' ;;
		3.7.3:amd64) printf '%s' '1678837c5ce6978f6491e76b10e344fba2beef6f81eb067c7ecc5668cf38fedb' ;;
		3.8.4:arm64) printf '%s' 'abb39a1f7dc0bf44883bbb30b057e6e65c5db64ffdce7c2ae92dea60a136362a' ;;
		3.8.4:amd64) printf '%s' '02050e9a5ed5c5ddc314bf920c103238a669366a130e3bd43a125d83fdd00548' ;;
		3.7.1:arm64) printf '%s' 'cbebb8d5b1fd1c880feedf4766067386aa8006112c18758fa43d3bb8195d4592' ;;
		3.7.1:amd64) printf '%s' '41ef80f0372c0ca881df0a361564b78fc7070126060e0b00fedc6c9310565698' ;;
		*) return 1 ;;
	esac
	return 0
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
# 手动云备份的后台任务（进度可查）。与组件安装各自独立一套状态文件：
# 两者可能先后发起，共用会互相覆盖 pid / rc。
CLOUD_BK_LOG="$OC_RUNDIR/cloud-bk.log"
CLOUD_BK_RC="$OC_RUNDIR/cloud-bk.rc"
CLOUD_BK_PID="$OC_RUNDIR/cloud-bk.pid"
CLOUD_BK_LOCK="$OC_RUNDIR/cloud-bk.lock"
CLOUD_INSTALL_STAGE="$OC_RUNDIR/cloud-install.stage"

cloud_install_lock_clear() {
	# cloud_install_lock_clear -> 0 锁目录已不存在 / 1 清理失败（OC_LOCK_ERR 说明原因）
	#
	# 陈旧锁目录里可能有残留文件，rmdir 会以 ENOTEMPTY 失败。以前这里直接报错，
	# 用户只能手工 rm -rf 才能继续。自愈路径：先删**已知文件名**的残留，再试一次
	# rmdir。绝不扫目录、绝不用通配符 —— 锁目录路径可预测，若被替换成符号链接，
	# 扫目录就等于把「删除任意文件」的入口交出去。
	local left
	OC_LOCK_ERR=""
	[ -d "$CLOUD_INSTALL_LOCK" ] || return 0

	# 已知残留：pid 文件可能被写在锁目录里，也可能在 $OC_RUNDIR 下（旧版本）。
	rm -f "$CLOUD_INSTALL_LOCK/pid" 2>/dev/null
	rmdir "$CLOUD_INSTALL_LOCK" 2>/dev/null && return 0

	# 仍失败：列出目录里还剩什么（只读，不删），交给调用方报错。
	left="$(find "$CLOUD_INSTALL_LOCK" -mindepth 1 -maxdepth 1 2>/dev/null \
		| head -n 5 | tr '\n' ' ')"
	OC_LOCK_ERR="无法清理陈旧的安装锁：$CLOUD_INSTALL_LOCK（残留：${left:-未知}）"
	return 1
}

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
		# busybox wget 没有 -x/--proxy，只认 http_proxy / https_proxy 环境变量。
		# 代理为空时不导出这两个变量，避免把调用方已有的代理覆盖成空串。
		if [ -n "$proxy" ]; then
			len="$(oc_timeout 10 sh -c \
				'http_proxy="$1" https_proxy="$1" wget -q --spider -S -T 8 "$2" 2>&1' \
				sh "$proxy" "$url" \
				| awk 'tolower($1) == "content-length:" { v = $2 } END { print v }')"
		else
			len="$(oc_timeout 10 wget -q --spider -S -T 8 "$url" 2>&1 \
				| awk 'tolower($1) == "content-length:" { v = $2 } END { print v }')"
		fi
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

cloud_enc_header_ok() {
	# cloud_enc_header_ok <file> -> 0 表示文件头是 "OCBK1\n" + 版本字节 1
	#
	# 不用 od：见调用处的说明。版本字节 0x01 可以放进 shell 变量
	# （只有 NUL 不行），所以第 7 字节直接与 printf '\001' 比较。
	local f="$1" magic ver
	magic="$(head -c 5 "$f" 2>/dev/null)"
	[ "$magic" = "OCBK1" ] || return 1
	ver="$(head -c 7 "$f" 2>/dev/null | tail -c 1)"
	[ "$ver" = "$(printf '\001')" ] || return 1
	return 0
}

cloud_installer_arch_ok() {
	# cloud_installer_arch_ok <file> <arch> -> 0 通过 / 1 不匹配（并设置 OC_INSTALL_ERR）
	#
	# 只在「该版本未收录 sha256」时调用：有哈希可对时，哈希本身已经证明了
	# 架构，再读 ELF 头是重复劳动，还会因为 busybox 没有 od 而冒出一条
	# 让人以为出问题的 WARN。
	local dest="$1" arch="$2" mach
	if ! command -v od >/dev/null 2>&1; then
		oc_warn "缺少 od，跳过 ELF 架构校验（该版本未收录 sha256；架构不符时执行阶段会报 Exec format error）"
		return 0
	fi
	# ELF e_machine（偏移 18，小端 2 字节）：arm64=0xb7，x86_64=0x3e
	mach="$(od -An -tx1 -j18 -N2 "$dest" 2>/dev/null | tr -d ' \n')"
	case "$arch:$mach" in
		arm64:b700|amd64:3e00) return 0 ;;
	esac
	OC_INSTALL_ERR="安装器架构不匹配：期望 $arch，ELF machine=${mach:-未知}"
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
		# 先等一秒再写第一行：本循环是独立进程、比 worker 先启动，立刻写会
		# 出现「已下载 0.0 MB / 14.2 MB」排在「下载…：<url>」之前，
		# 看着像还没开始就已经下完了。
		sleep 1
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
	local ver="$1" arch url dest size magic head4 mach sha want out rc err bin vout
	local hout usage dirflag yesflag
	local ver_raw ver_out ihome

	OC_INSTALL_ERR=""
	OC_INSTALL_PATH=""
	OC_INSTALL_VER=""

	cloud_version_valid "$ver" || {
		OC_INSTALL_ERR="bdpan 版本号非法：$ver"
		return 1
	}
	# UI 版本通常带 v 前缀（例如 v3.8.4），官方 CDN 路径和哈希表使用
	# 纯数字版本；统一归一化，避免 URL 404 或哈希白名单未命中。
	ver="$(cloud_norm_version "$ver" 2>/dev/null)"
	cloud_version_valid "$ver" || {
		OC_INSTALL_ERR="bdpan 版本号无法归一化：$1"
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

	# 安装器是可执行文件，必须走 https：oc_fetch 内部的 oc_safe_url 也接受
	# http://，那是给普通下载用的宽松口径，不能作为这里的唯一防线。
	case "$url" in
		https://*) ;;
		*)
			OC_INSTALL_ERR="安装器 URL 不是 https，已拒绝下载：$url"
			return 1 ;;
	esac
	case "$url" in
		*' '*|*'	'*)
			OC_INSTALL_ERR="安装器 URL 含空白字符，已拒绝下载：$url"
			return 1 ;;
	esac

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

	# ---- 完整性校验：执行前最后一道闸 ----
	# 命中白名单就必须一致，不一致直接删文件并失败；未收录的版本保持原行为
	# （只记录 sha256），但日志必须写明「未校验」，事后能从安装日志判断
	# 这一次到底有没有校验过。这里没有、也不应该有 UCI 开关：哈希不符就是
	# 可疑，应该让人看到，而不是给一条绕过校验的路。
	want="$(cloud_installer_sha "$ver" "$arch" 2>/dev/null)" || want=""
	if [ -n "$want" ]; then
		if ! command -v sha256sum >/dev/null 2>&1; then
			# 有期望值却算不出实际值：继续执行等于回到「不校验就执行」。
			rm -f "$dest" 2>/dev/null
			OC_INSTALL_ERR="安装器需要校验 sha256，但系统缺少 sha256sum，已中止（版本 $ver/$arch）"
			return 1
		fi
		sha="$(sha256sum "$dest" 2>/dev/null | awk '{print $1}' | tr 'A-F' 'a-f')"
		if [ -z "$sha" ]; then
			rm -f "$dest" 2>/dev/null
			OC_INSTALL_ERR="无法计算安装器 sha256（版本 $ver/$arch），已中止"
			return 1
		fi
		if [ "$sha" != "$want" ]; then
			rm -f "$dest" 2>/dev/null
			OC_INSTALL_ERR="安装器 sha256 校验失败（期望 $want，实际 $sha）。可能是官方重新发布了该版本，请更新本插件"
			return 1
		fi
		cblog "安装器 sha256 校验通过（$ver/$arch）"
		# 哈希命中就等于证明了架构：白名单是 (版本, 架构) → 哈希 的映射，
		# 两个架构的包哈希不同。这时再去读 ELF 头纯属多余，也就不再需要
		# od —— 这正是之前那行「缺少 od，跳过 ELF 架构校验」的由来，
		# 明明已经用 sha256 证明了，却还留一条 WARN 吓人。
	else
		if command -v sha256sum >/dev/null 2>&1; then
			sha="$(sha256sum "$dest" 2>/dev/null | awk '{print $1}')"
			oc_warn "安装器 sha256：${sha:-无法计算}（版本 $ver/$arch 该版本未收录，未校验）"
		else
			oc_warn "安装器未校验：版本 $ver/$arch 该版本未收录，且系统缺少 sha256sum"
		fi
		# 没有哈希可依赖时才做架构检查。尽力而为：od 不存在就跳过，
		# 绝不因此拒绝安装 —— 架构不对时内核会在执行阶段报 Exec format error。
		if ! cloud_installer_arch_ok "$dest" "$arch"; then
			rm -f "$dest" 2>/dev/null
			return 1
		fi
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
	# 组件由 root 执行，属主与权限必须在**落盘后立刻**收回。
	#
	# 安装器是原地覆写：目录会被 cloud_ensure_dirs 收紧成 root:root 0700，
	# 但被覆写的**文件**沿用了旧 inode 的属主。历史上某次 oc_fix_perms
	# 留下的 998 就这样一直留在 bdpan 上，随后被 cloud_bin_secure 拒绝，
	# 而目录看起来完全合规 —— 现场表现为「状态页说已装、列表说没装」。
	local _reason _secure_pre
	# cloud_secure_reason 在非 ready 时返回 1；赋值语句处于非条件位置，
	# 统一 || true 吞掉退出码，避免将来有人给本文件加 set -e 时静默中断。
	_reason="$(cloud_secure_reason "$bin")" || true
	case "$_reason" in
		symlink|outside-root|insecure-path)
			OC_INSTALL_ERR="安装后的 bdpan 路径不安全（$_reason）：$bin"
			return 1 ;;
	esac
	if [ "$_reason" != "ready" ]; then
		_secure_pre="$_reason"
		chown root:root "$bin" 2>/dev/null || true
		# 无条件收敛到 755，而不是「只在没有 x 位时才 chmod」。
		# 0744/0745 这类 owner 带 x、但不在白名单里的组合，用条件写法修不动：
		# -x 为真 → 跳过 chmod；chmod go-w 对 0744 又是空操作 → 复核仍失败，
		# 用户按提示重装也修不好。这里直接给出白名单内的确定结果。
		chmod 755 "$bin" 2>/dev/null || true
		_reason="$(cloud_secure_reason "$bin")" || true
		if [ "$_reason" != "ready" ]; then
			OC_INSTALL_ERR="安装后的 bdpan 未通过安全校验（$_reason）：$bin"
			return 1
		fi
		cblog "已把安装后的 bdpan 收回 root:root（原状态：$_secure_pre）"
	fi
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
	# 这次操作会改变 status 的字段（版本 / 登录态 / 用户名），
	# 让状态缓存立即失效，否则页面会拿旧结论显示最多 TTL 秒。
	clock_status_cache_drop
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
		if ! cloud_install_lock_clear; then
			printf '{"ok":false,"error":"%s"}\n' "$(jstr "$OC_LOCK_ERR")"
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
	# 逐个探测候选版本。结果**全部通过全局变量返回，不再往 stdout 打**：
	#   OC_PROBE_LATEST    可用的最大版本号（一个都没有时为空）
	#   OC_PROBED_LIST     探测到 200 的版本（空格分隔，升序）
	#   OC_PROBE_OK        探测到 200 的个数
	#   OC_PROBE_REACHABLE 是否至少拿到过一个 HTTP 状态码
	#
	# 为什么不用返回值：调用方若写成 latest="$(cloud_probe_latest)"，函数体
	# 就在子 shell 里跑，上面这几个变量一个都传不回来 —— 调用方拿到的
	# OC_PROBE_OK 永远是 0，于是"探测成功"被判成"网络不通"。这个 bug 让
	# 检查更新永远显示"无法连接官方下载源"。
	# 单个候选失败（超时 / 404 / 网络错误）只跳过它，不影响其它候选。
	local cand v code latest="" rev="" any_http=0

	OC_PROBED_LIST=""
	OC_PROBE_OK=0
	OC_PROBE_LATEST=""
	# 官方没有版本清单接口，只能按候选逐个探测。**从新到旧探、命中即停**：
	# 早先是"全部探一遍再取最大"，8 个候选 × 每个最多 10 秒 = 最坏 80 秒，
	# 而页面 20 秒就超时 —— 于是永远显示"无法连接官方下载源"，
	# 哪怕最新版本其实一次 HEAD 就能问到。
	cand="$(cloud_candidate_versions)"
	for v in $cand; do rev="$v $rev"; done
	for v in $rev; do
		code="$(cloud_probe_status "$(cloud_installer_url "$v")")"
		# 只要拿到了 HTTP 状态码（哪怕是 404），就说明源是通的 ——
		# 这和"网络不可达"是两回事，错误提示必须分开。
		[ -n "$code" ] && any_http=1
		[ "$code" = "200" ] || continue
		OC_PROBED_LIST="$OC_PROBED_LIST $v"
		OC_PROBE_OK=$((OC_PROBE_OK + 1))
		latest="$v"
		break
	done
	OC_PROBED_LIST="${OC_PROBED_LIST# }"
	# 供调用方区分两种失败：源不通 vs 源通了但没有可用安装包
	OC_PROBE_REACHABLE="$any_http"
	OC_PROBE_LATEST="$latest"
}

cmd_cli_check() {
	# 检查更新：只读探测，不下载、不安装。
	local latest current update=false probed="" v

	if [ "$(cloud_arch)" = "unsupported" ]; then
		cloud_fail "不支持的架构：$(uname -m 2>/dev/null)"
	fi

	# 必须**直接调用**，不能用 latest="$(cloud_probe_latest)"：
	# 命令替换在子 shell 里执行，函数设置的 OC_PROBE_OK / OC_PROBE_REACHABLE /
	# OC_PROBED_LIST 全都随子 shell 一起消失。结果就是 latest 拿到了版本号，
	# 而 OC_PROBE_OK 仍是初始的 0 —— 于是无论探测成功与否都报
	# "无法连接官方下载源"。函数改成把结果写进 OC_PROBE_LATEST。
	cloud_probe_latest
	latest="$OC_PROBE_LATEST"
	if [ "${OC_PROBE_OK:-0}" -le 0 ]; then
		# 绝不谎报「已是最新」，但也要说清是哪一种失败：
		#   拿到了 HTTP 状态码（多为 404）→ 源是通的，只是没有可用安装包；
		#   一个状态码都没拿到 → 才是网络 / DNS / TLS 的问题。
		if [ "${OC_PROBE_REACHABLE:-0}" = "1" ]; then
			cloud_fail "官方源可以访问，但没有找到可用的组件安装包（探测的版本都返回 404）"
		else
			cloud_fail "无法连接官方下载源，请检查网络（或设置里的 HTTP 代理）"
		fi
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
	# 这次操作会改变 status 的字段（版本 / 登录态 / 用户名），
	# 让状态缓存立即失效，否则页面会拿旧结论显示最多 TTL 秒。
	clock_status_cache_drop
	# 更新组件：版本来源 = 参数 > cli-check 探测到的 latest。
	# 只写 $OC_CLOUD_DIR；$OC_CLOUD_HOME 与 $OC_CLOUD_PASS 全程只 stat，不写不删。
	local want="${1:-}" latest current from to bak oldbin restored err warn=""
	local had_cfg=false now_cfg=false

	if [ -n "$want" ]; then
		cloud_version_valid "$want" || \
			cloud_fail "版本号不合法（只允许字母、数字与 . _ -，长度 1-32）"
	fi

	if [ -z "$want" ]; then
		cloud_probe_latest
		latest="$OC_PROBE_LATEST"
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
# 新版 bdpan 在非交互环境（uhttpd 下 stdin 不是 tty）要求显式
# --accept-disclaimer，否则 login 直接 rc=1 并打印 usage：
#   Error: 首次使用请添加 --accept-disclaimer 参数，或在交互式环境下运行 bdpan login 进行确认
# 老版本不认识这个参数（Go flag 会以 "flag provided but not defined" 拒绝），
# 所以先探测 usage 再决定加不加 —— 与安装器 -dir / -install-dir 的探测同一思路。
cloud_login_has_flag() {
	# cloud_login_has_flag <usage-file> <flag> -> 0 表示 usage 里列出了该参数
	#
	# 只看**行首 token**：Go 的 flag 用法里一个参数定义行是
	# `  -accept-disclaimer  说明` 这种形状，第一个词就是参数名。
	# 绝不能在整行里搜子串：bdpan 的报错文案里本身就写着
	# "--accept-disclaimer"（见上面那句 Error），子串匹配会把「不支持」判成
	# 「支持」，然后传一个它不认识的参数，白跑一轮 —— 安装器参数探测就是这么
	# 栽的（"flag provided but not defined: -install-dir"）。
	#
	# 前导 "-" 的数量不参与比较：Go 的 flag 包打印用法时用单破折号
	# （-accept-disclaimer），但接受双破折号写法，两种都要认。
	awk -v f="$2" '
		{
			s = $0
			sub(/^[ \t]+/, "", s)
			if (s == "") next
			n = split(s, w, /[ \t]+/)
			t = w[1]
			if (n < 1) next
			# 归一化前导破折号：-flag 与 --flag 视为同一个
			sub(/^-+/, "", t)
			want = f
			sub(/^-+/, "", want)
			if (t == want) { found = 1; exit }
			# 兼容 "-flag=value" / "--flag=value" 写法
			if (substr(t, 1, length(want) + 1) == want "=") { found = 1; exit }
		}
		END { exit(found ? 0 : 1) }
	' "$1"
}

cloud_login_flags() {
	# cloud_login_flags <bin> -> 登录命令要追加的参数（空串 / "--accept-disclaimer"）
	#
	# 取不到帮助时**保守**按新版行为加上该参数：调用方（cloud_login_exec）在
	# 被拒时会自动去掉它重试一次，所以猜错只多花一次调用，猜「不加」则会
	# 让新版 bdpan 必然失败。
	# `login -h` 的退出码不可用：Go flag 把 usage 打到 stderr 并以 2 退出，
	# 成功打印帮助也可能是非 0，所以只判断输出是否为空。
	local bin="$1" tmp
	tmp="$OC_RUNDIR/cloud-login-help.$$"
	rm -f "$tmp" 2>/dev/null
	cloud_run 20 "$bin" login -h >"$tmp" 2>&1 </dev/null
	if [ -s "$tmp" ] && ! cloud_login_has_flag "$tmp" "--accept-disclaimer"; then
		rm -f "$tmp" 2>/dev/null
		return 0
	fi
	rm -f "$tmp" 2>/dev/null
	printf '%s' "--accept-disclaimer"
}

cloud_login_flag_error() {
	# cloud_login_flag_error <file> -> 0 表示输出是「不认识这个参数」
	grep -qiE 'unknown flag|unknown shorthand flag|flag provided but not defined' "$1" 2>/dev/null
}

cloud_login_exec() {
	# cloud_login_exec <timeout> <outfile> <bin> <arg...>
	# 统一入口：自动带上探测到的登录参数；参数被拒时去掉它重试一次。
	# 输出（stdout+stderr）落在 <outfile>，返回最后一次调用的退出码。
	local t="$1" out="$2" bin="$3" flags rc
	shift 3
	flags="$(cloud_login_flags "$bin")"
	rm -f "$out" 2>/dev/null
	# flags 是脚本内的常量（不是用户输入），按空白拆成参数是安全的；
	# 用户可控的值（授权码）始终以 "$@" 原样转发，绝不拼进字符串。
	# shellcheck disable=SC2086
	cloud_run "$t" "$bin" login $flags "$@" >"$out" 2>&1 </dev/null
	rc=$?
	if [ "$rc" -ne 0 ] && [ -n "$flags" ] && cloud_login_flag_error "$out"; then
		oc_warn "bdpan 不支持 $flags（老版本），已去掉该参数重试"
		rm -f "$out" 2>/dev/null
		cloud_run "$t" "$bin" login "$@" >"$out" 2>&1 </dev/null
		rc=$?
	fi
	return "$rc"
}

cloud_login_err() {
	# cloud_login_err [file] -> 脱敏 + 去掉 usage 段 + 截断的错误文本
	# 不给参数时读 stdin（cmd_login_code 里是 `cloud_scrub_code ... | cloud_login_err`）。
	#
	# bdpan 失败时会把整段 usage（Usage / Flags 几十行）打在错误后面，原样回给
	# 页面既长又盖住真正的原因。只保留第一个 "Usage:" / "Flags:" 之前的部分。
	# 截断仍走 oc_cut_utf8，避免把中文切成半个字符破坏 JSON。
	#
	# ${1:+"$1"} 而不是 "$1"：空参数会被 awk 当成文件名去打开，报
	# `can't open file ""`，2>/dev/null 把错误吞掉、输出为空 —— 于是管道那一侧
	# 永远显示「无输出」，真正的失败原因反而丢了。
	awk '
		{ sub(/\r$/, "") }
		$1 == "Usage:" || $1 == "Flags:" || $1 == "Global" { exit }
		{ print }
	' ${1:+"$1"} 2>/dev/null | cloud_redact | oc_cut_utf8 500
}

cmd_login_url() {
	local bin tmp rc out url

	bin="$(cloud_bin_ready)" || cloud_fail "请先安装网盘组件"
	tmp="$OC_RUNDIR/cloud-loginurl.$$"
	rm -f "$tmp" 2>/dev/null
	# --accept-disclaimer 在前，--get-auth-url 在后（探测结果决定前者是否出现）
	cloud_login_exec 60 "$tmp" "$bin" --get-auth-url
	rc=$?

	# 取输出里第一个 http(s) 链接（排除空白、引号、尖括号与右括号）
	url="$(awk 'match($0, /https?:\/\/[^[:space:]"<>)]+/) { print substr($0, RSTART, RLENGTH); exit }' "$tmp" 2>/dev/null)"
	out="$(cloud_login_err "$tmp")"
	rm -f "$tmp" 2>/dev/null

	if [ -z "$url" ]; then
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
	# 这次操作会改变 status 的字段（版本 / 登录态 / 用户名），
	# 让状态缓存立即失效，否则页面会拿旧结论显示最多 TTL 秒。
	clock_status_cache_drop
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
	# 与 login-url 走同一个入口：参数探测 + 被拒时去掉重试一次。
	# 授权码只经 "$@" 转发，不拼进任何字符串。
	cloud_login_exec 60 "$tmp" "$bin" --set-code "$code"
	rc=$?
	# 输出里若回显了授权码，一并抹掉；日志里也绝不写 code。
	out="$(cloud_scrub_code "$tmp" "$code" | cloud_login_err)"
	rm -f "$tmp" 2>/dev/null

	[ "$rc" -eq 0 ] || cloud_fail "授权失败（rc=$rc）：${out:-无输出}"
	user="$(cloud_whoami_user "$bin")"
	printf '{"ok":true,"user":"%s"}\n' "$(jstr "$user")"
}

cmd_logout() {
	# 这次操作会改变 status 的字段（版本 / 登录态 / 用户名），
	# 让状态缓存立即失效，否则页面会拿旧结论显示最多 TTL 秒。
	clock_status_cache_drop
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
	# 加密产物目录与上传超时：未 local 会污染全局（cloud.sh 是长脚本）
	local _encroot up_bytes up_to encrypted
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
		# 加密产物必须落在**数据盘**，不能放 $OC_RUNDIR（/tmp，tmpfs 内存盘）。
		# 加密后的文件与原始备份同样大小（1.4G 备份 → 1.4G 密文），
		# tmpfs 通常只有几 G 且要跟系统共享：空间不足时这里会写到一半失败，
		# 报的还是"加密失败"，看不出是空间问题。
		# 优先用数据盘的 tmp/，它不可写时才退回 rundir。
		_encroot="$(oc_base_dir 2>/dev/null)/tmp"
		mkdir -p "$_encroot" 2>/dev/null
		[ -d "$_encroot" ] && [ -w "$_encroot" ] || _encroot="$OC_RUNDIR"
		encdir="$_encroot/cloud-enc.$$"
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
		# 加密先写 <name>.tmp 再 rename（见 OC_CRYPTO_JS 的 enc）：中断时可能
		# 留下这个半成品，一并登记，让 trap / cloud_tmp_cleanup 能清掉。
		OC_TMPFILE2="$enc_out.tmp"
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
		# 文件头校验**不能依赖 od**：部分 OpenWrt / iStoreOS 的 busybox 没编进
		# od，命令缺失时输出为空，于是正常加密文件会被判成"文件头不对"，
		# 加密上传必然失败。这里用 head / tail（busybox 必备）读魔数与版本字节。
		# 注意命令替换会吃掉尾部换行，所以只比前 5 字节 "OCBK1"。
		if ! cloud_enc_header_ok "$enc_out"; then
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

	local up_bytes="$lsize"
	[ "$encrypted" = "true" ] && up_bytes="${csize:-$lsize}"

	# 超时不能写死。原先是固定 600 秒：1.4G 的备份在 20Mbps 上行（约 2.5MB/s）
	# 需要 560 秒，带宽再低一点（或网盘限速）就必然超时；而超时之后远端会留下
	# 一个**半截对象**，br_prune 会把它当成"最新一份"保留下来，下次还原才发现
	# 是坏的。按体积推算，并留 3 倍余量 + 120 秒固定开销，下限 300 秒、上限 3 小时。
	local up_to
	up_to=$(( up_bytes / 120 / 1024 ))          # 保守按 ~120KB/s 估算
	up_to=$(( up_to * 3 + 120 ))
	[ "$up_to" -lt 300 ] && up_to=300
	[ "$up_to" -gt 10800 ] && up_to=10800

	cblog "上传 $(basename "$upload_path")（${up_bytes} 字节，超时 ${up_to}s）-> $OC_CLOUD_REMOTE/$remote_name"
	cloud_run "$up_to" "$bin" upload "$upload_path" "$OC_CLOUD_REMOTE/$remote_name" >"$tmp" 2>&1
	rc=$?
	if [ "$rc" -ne 0 ]; then
		err="$(cloud_tail_err "$tmp" 8)"
		rm -f "$tmp" 2>/dev/null
		# 失败/超时后必须清掉远端半截对象，否则它会冒充"最新一份备份"，
		# 轮转还会因此删掉真正可用的旧备份。
		if cloud_rm_remote "$remote_name" 2>/dev/null; then
			cblog "已删除远端的未完成上传：$remote_name"
		else
			oc_warn "上传失败后未能删除远端残留（${OC_RM_ERR:-原因未知}）；请在网盘里手动删除 $remote_name，否则它会被当成一份有效备份"
		fi
		cloud_tmp_cleanup
		cloud_fail "上传失败（rc=$rc）：${err:-无输出}"
	fi
	rm -f "$tmp" 2>/dev/null

	# 上传成功也要核对远端大小：网盘客户端偶发"返回 0 但对象不完整"。
	# 拿不到远端大小（ls 不支持/限流）时只告警，不判失败 —— 那种情况下
	# 拒绝备份比留下一份可能不完整的备份更糟。
	size="$(cloud_remote_size "$bin" "$remote_name")"
	case "$size" in
		''|*[!0-9]*)
			size="$up_bytes"
			oc_warn "上传成功但未能从远端列表确认大小，使用本地大小 $size" ;;
		*)
			if [ "$size" -ne "$up_bytes" ]; then
				# 大小不一致说明对象被截断：删掉它，别让它冒充有效备份。
				if cloud_rm_remote "$remote_name" 2>/dev/null; then
					cloud_tmp_cleanup
					cloud_fail "上传后远端大小不一致（远端 $size / 本地 $up_bytes），已删除该对象"
				fi
				cloud_tmp_cleanup
				cloud_fail "上传后远端大小不一致（远端 $size / 本地 $up_bytes），且未能删除；请手动删除 $remote_name"
			fi ;;
	esac
	cloud_tmp_cleanup
	printf '{"ok":true,"remote":"%s","size":%s,"encrypted":%s}\n' \
		"$(jstr "$OC_CLOUD_REMOTE/$remote_name")" "$size" "$encrypted"
}

cmd_upload() {
	cloud_upload_file "${1:-}" "${2:-}"
}

# ---------------------------------------------------------------- ls
cloud_ls_empty_state() {
	# cloud_ls_empty_state <output> -> 0 表示"这不是错误，只是还没有东西"
	#
	# 远端目录 openclaw-backups 只在**首次上传时**才创建（见 cmd_upload 里的
	# mkdir），所以从未上传过的设备上 ls 必然失败。这是正常的初始状态，
	# 不该报错 —— 否则新装用户第一次打开备份页就是"读取云端列表失败"，
	# 而且没有任何线索指向"你还没传过备份"。
	#
	# 判定覆盖三类形状，全部来自实测输出：
	#   * 中文 / 英文的"找不到 / 不存在"
	#   * 未登录已拆分到 cloud_ls_not_logged_in
	#   * 错误码：百度 PCS 用 -9 表示文件/目录不存在、-3 表示路径无效
	#
	# 实测真实输出长这样（rc=0，但内容是个错误对象）：
	#   {"code":1,"data":null,"error":"找不到指定的文件或目录（错误码 -9），请检查路径是否正确。"}
	# 两个坑都在这一句里：措辞是「找不到」不是「不存在」，错误码是文本里的
	# 「错误码 -9」而不是 JSON 字段 "errno":-9。只按后者写会全部漏掉。
	case "$1" in
		'') return 0 ;;
		*不存在*|*找不到*|*未找到*|*"not exist"*|*"does not exist"*|*"No such"*|*"no such file"*) return 0 ;;
		*"path not found"*|*"file not found"*|*目录无效*|*路径无效*|*"invalid path"*) return 0 ;;
	esac

	# 数值错误码：**先去掉所有空白再比对**。这样 "errno": -9 与
	# 「错误码 -9」用同一组模式就能覆盖，不必为空格写六种变体；
	# 也顺带兼容全角冒号。
	local norm
	norm="$(printf '%s' "$1" | tr -d '[:space:]')"
	case "$norm" in
		*'"errno":-9'*|*'"errno":-3'*|*'"code":-9'*|*'"code":-3'*) return 0 ;;
		*错误码-9*|*错误码：-9*|*错误码:-9*) return 0 ;;
		*错误码-3*|*错误码：-3*|*错误码:-3*) return 0 ;;
	esac
	return 1
}

cloud_ls_not_logged_in() {
	# cloud_ls_not_logged_in <output> -> 0 表示未登录 / 需要登录
	case "$1" in
		*未登录*|*没有登录*|*请先登录*|*请登录*|*"not logged"*|*"login required"*|*"not login"*) return 0 ;;
	esac
	return 1
}

cmd_ls() {
	local bin tmp rc out tsv err d mt name size tab sorted display enc _reason

	# 组件不可用必须报错，不能再返回 ok:true + 空数组。
	#
	# 这条曾经是 fail-open：cloud_bin_ready 失败只写一行 oc_warn（stderr，
	# 页面上看不见），然后返回 {"ok":true,"data":[]}。前端拿到「成功 + 空」
	# 就显示「暂无备份」，于是「组件被安全策略拒绝」在界面上变成了
	# 「你没有备份」—— 现场 4 份云端备份就是这么"消失"的。
	if ! bin="$(cloud_bin_ready)"; then
		# 用 $OC_CLOUD_BIN 而不是 cloud_bin 取路径：cloud_bin 会先把 symlink
		# 过滤成空，那样就分不清「没装」和「是链接」了。
		_reason="$(cloud_secure_reason "$OC_CLOUD_BIN")" || true
		case "$_reason" in
			missing)
				cloud_fail_reason component-missing \
					"网盘组件未安装：未找到 $OC_CLOUD_BIN，请在上方第一步安装组件" ;;
			not-executable)
				cloud_fail_reason component-not-executable \
					"网盘组件没有执行权限：$OC_CLOUD_BIN" ;;
			symlink|outside-root|insecure-path)
				cloud_fail_reason component-insecure \
					"网盘组件路径不安全（$_reason）：$OC_CLOUD_BIN" ;;
			*)
				# insecure-owner / insecure-mode：现场主因（bdpan 被 chown 成
				# 998:998）。提示必须指向真正可操作的动作。
				cloud_fail_reason component-insecure \
					"网盘组件被安全策略拒绝（$_reason）：$OC_CLOUD_BIN，请点上方「一键修复」或重装组件" ;;
		esac
	fi

	tmp="$OC_RUNDIR/cloud-ls.$$"
	rm -f "$tmp" 2>/dev/null
	cloud_run 60 "$bin" ls "$OC_CLOUD_REMOTE" --json >"$tmp" 2>&1
	rc=$?
	out="$(cat "$tmp" 2>/dev/null)"

	if [ "$rc" -ne 0 ]; then
		if cloud_ls_not_logged_in "$out"; then
			rm -f "$tmp" 2>/dev/null
			# 未登录是**预期状态**不是故障：保持 ok:true + note，前端按
			# 中性提示渲染。只有组件不可用才是硬错误（见上面的 fail-loud）。
			printf '{"ok":true,"data":[],"note":"尚未登录百度网盘，登录后这里会显示云端备份"}\n'
			return 0
		fi
		if cloud_ls_empty_state "$out"; then
			rm -f "$tmp" 2>/dev/null
			# 远端目录只在首次上传时才创建，新装设备 ls 必然失败。这是
			# 「还没有备份」而不是错误，报错会让新用户第一次进页面就看到红字。
			printf '{"ok":true,"data":[]}\n'
			return 0
		fi
		err="$(cloud_tail_err "$tmp" 8)"
		rm -f "$tmp" 2>/dev/null
		cloud_fail_reason network \
			"读取网盘目录 $OC_CLOUD_REMOTE 失败（rc=$rc）：${err:-无输出}"
	fi

	if ! tsv="$(cloud_ls_tsv "$tmp")"; then
		if cloud_ls_not_logged_in "$out"; then
			rm -f "$tmp" 2>/dev/null
			printf '{"ok":true,"data":[],"note":"尚未登录百度网盘，登录后这里会显示云端备份"}\n'
			return 0
		fi
		if cloud_ls_empty_state "$out"; then
			rm -f "$tmp" 2>/dev/null
			printf '{"ok":true,"data":[]}\n'
			return 0
		fi
		err="$(cloud_tail_err "$tmp" 8)"
		rm -f "$tmp" 2>/dev/null
		cloud_fail_reason network \
			"网盘目录 $OC_CLOUD_REMOTE 返回内容无法解析：${err:-无输出}"
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
# 复验无法确认时的具体原因，由 cloud_rm_verify 写入。
OC_RM_VERIFY_ERR=""
# 最近一次读取远端列表失败的具体原因（退出码 + stderr 摘要），
# 由 cloud_rm_list 写入。只回一句「读取失败」在现场无法定位。
OC_LS_ERR=""

# bdpan 至今（实测 3.8.9）没有删除子命令：help 里只有 whoami / ls / upload /
# download / transfer / share / version / init / update。网盘侧能真正删除的
# 只有开放平台的 filemanager 接口，于是用它自己保存的 access_token 直接调用。
#
# 凭据规则（不可放宽）：
#   * 只在需要时读一次，写进 0700 私有目录下 0600 的 curl 配置文件（-K）；
#     token 绝不进 argv（/proc/<pid>/cmdline 全局可读）、绝不打印、绝不进日志。
#   * 只请求 https://pan.baidu.com，不跟随重定向。
#   * 用完立刻删配置文件；任何回显先过 cloud_redact。
OC_API_ERR=""
OC_API_TOKEN=""

cloud_json_deep() {
	# cloud_json_deep <file> <key> -> 任意层级里第一个同名键的标量值。
	#
	# 与 cloud_json_scalar 的区别只有一条：不限制 depth == 1。bdpan 的登录
	# 配置可能把凭据放在 {"tokens": {...}} 这种子对象里，按顶层找会得到空值，
	# 页面就只能报「未登录」——真机 1.8.91 正是这样。
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
			else if (e == "u") { n = h2d(substr(s, i + 1, 4)); i += 4; o = o "?" }
			else o = o e
		}
		return o
	}
	{ buf = buf $0 "\n" }
	END {
		n = length(buf); instr = 0; esc = 0; val = ""; want = 0; last = ""
		for (i = 1; i <= n; i++) {
			c = substr(buf, i, 1)
			if (instr) {
				if (esc) { cur = cur "\\" c; esc = 0 }
				else if (c == "\\") esc = 1
				else if (c == "\"") { instr = 0; last = cur; if (want) { print unesc(cur); exit } }
				else cur = cur c
				continue
			}
			if (want) {
				if (c == "\"") { instr = 1; cur = ""; continue }
				if (c == " " || c == "\t" || c == "\r" || c == "\n") continue
				if (c == "," || c == "}" || c == "]") { print val; exit }
				val = val c
				continue
			}
			if (c == "\"") { instr = 1; cur = ""; continue }
			if (c == ":") {
				gsub(/[ \t\r\n]/, "", last)
				if (last == key) { want = 1; val = "" }
			}
		}
	}
	' "$1"
}

cloud_json_keys() {
	# cloud_json_keys <file> <上限> -> 前 N 个出现的字段名（逗号分隔，不含值）。
	#
	# 只在凭据取不到时用来解释「配置文件里到底有什么」。**只回显键名**，
	# 值一个字符都不回显 —— 这不是调试开关，是给用户看的失败原因。
	[ -f "$1" ] || return 0
	awk -v lim="${2:-10}" '
	{
		line = $0
		while (match(line, /"[A-Za-z0-9_.-]+"[ 	]*:/)) {
			k = substr(line, RSTART, RLENGTH)
			gsub(/[" 	]/, "", k)
			sub(/:$/, "", k)
			if (!(k in seen)) { seen[k] = 1; out = (out == "" ? k : out "," k); n++ }
			line = substr(line, RSTART + RLENGTH)
			if (n >= lim) { print out; exit }
		}
	}
	END { if (out != "") print out }
	' "$1"
}

cloud_api_conf() {
	# 组件用私有 HOME 安装，登录态固定落在 <home>/.config/bdpan/config.json。
	printf '%s' "$OC_CLOUD_HOME/.config/bdpan/config.json"
}

cloud_api_token() {
	# 结果写进 OC_API_TOKEN 并返回 0；失败返回 1，原因写 OC_API_ERR。
	#
	# 刻意不用 stdout 回传：调用方一旦写成 tok="$(cloud_api_token)"，函数就
	# 在子 shell 里执行，OC_API_ERR 会随子 shell 一起消失，界面只剩一句
	# 没有原因的空错误。
	local cfg tok _k _ks _hint _hitk _try _why _c _prev _un1 _un2 _enc
	OC_API_TOKEN=""
	cfg="$(cloud_api_conf)"
	if [ ! -f "$cfg" ]; then
		OC_API_ERR="找不到网盘组件的登录配置，请先在组件设置里登录"
		return 1
	fi
	if [ ! -s "$cfg" ]; then
		OC_API_ERR="网盘组件的登录配置是空的，请在组件设置里重新登录"
		return 1
	fi
	# 先按顶层找，再按任意层级找（bdpan 可能把凭据放在子对象里），
	# 最后试几个常见别名。顺序固定，取到即止。
	_hitk=""
	for _k in access_token accessToken token; do
		[ -n "$tok" ] && break
		tok="$(cloud_json_deep "$cfg" "$_k" 2>/dev/null | sed -n '1p' | tr -d '\r')"
		[ -n "$tok" ] && _hitk="$_k"
	done
	unset _k
	if [ -z "$tok" ]; then
		# 只报字段名，绝不回显值：用于区分「没有这个字段」和「字段名不同」。
		_ks="$(cloud_json_keys "$cfg" 10 2>/dev/null)"
		OC_API_ERR="网盘组件未登录（配置里取不到 access_token；现有字段：${_ks:-无}），请重新登录"
		unset _ks
		return 1
	fi
	# 规范化：有的版本会把值再包一层引号（JSON 里存的是 "\"xxx\""），
	# 也可能带 Bearer 前缀。只在**字符集校验之前**做，剥完仍要过校验。
	case "$tok" in
		\"*\") tok="${tok#\"}"; tok="${tok%\"}" ;;
	esac
	case "$tok" in
		[Bb]earer\ *) tok="${tok#* }" ;;
	esac

	# token 会被拼进 curl 配置文件的 url= 行：一旦掺入引号 / 空白 / 换行，
	# 就等于让外部内容写入 curl 选项。字符集之外一律拒绝。
	#
	# 拒绝时只说清「长度 + 出现了哪类字符」，绝不回显凭据本身 —— 用来区分
	# 「多包了一层」「带 enc: 前缀」「是加密后的二进制」这几种情况。
	# 候选按可能性排序：整串 -> 冒号前 -> 冒号后。真机上 bdpan 存的是
	# 「前缀:令牌」（长度 155、含冒号），而百度原始 token 不含冒号；到底哪
	# 一段有效只能问网盘，所以逐个做只读探测，第一个通过的即采用。
	# 解包：整串与「冒号后」两段都可能只是 base64 包装。
	_un1="$(cloud_api_unwrap "$tok")"
	_un2="$(cloud_api_unwrap "${tok##*:}")"
	_enc=0
	# 只有「带冒号的打包值」才谈得上加密包：明文 token 本身也是 base64 字符集，
	# 拿它去 base64 -d 必然解出二进制，会把普通 token 误判成加密包。
	case "$tok" in
		*:*) [ -z "$_un1" ] && [ -z "$_un2" ] && \
			cloud_api_unwrap_binary "${tok##*:}" && _enc=1 ;;
	esac
	_try=0
	_why=""
	for _c in "$tok" "${tok%%:*}" "${tok##*:}" "$_un1" "$_un2"; do
		[ "$_try" -lt 4 ] || break
		cloud_api_cand_ok "$_c" || continue
		[ "$_c" = "$_prev" ] && continue
		_prev="$_c"
		_try=$((_try + 1))
		if cloud_api_probe "$_c"; then
			OC_API_TOKEN="$_c"
			unset _try _why _c _prev
			return 0
		fi
		_why="$OC_API_ERR"
	done
	if [ "$_try" -eq 0 ]; then
		_hint=""
		case "$tok" in *:* ) _hint="$_hint 冒号" ;; esac
		case "$tok" in *%* ) _hint="$_hint 百分号" ;; esac
		case "$tok" in *'"'* ) _hint="$_hint 引号" ;; esac
		case "$tok" in *'{'*|*'}'* ) _hint="$_hint 花括号" ;; esac
		case "$tok" in *'['*|*']'* ) _hint="$_hint 方括号" ;; esac
		case "$tok" in *[![:print:]]* ) _hint="$_hint 不可打印字节" ;; esac
		OC_API_ERR="网盘登录凭据格式异常（取自字段 ${_hitk:-?}，长度 ${#tok}${_hint:+，含：$_hint}），请在组件里重新登录"
	else
		OC_API_ERR="网盘登录凭据不可用（试了 $_try 个候选都被拒绝：${_why:-原因未知}）。"
		if [ "${_enc:-0}" = "1" ]; then
			OC_API_ERR="$OC_API_ERR 组件把凭据加密保存了，插件没法直接拿它调删除接口 —— 请在百度网盘 App 的 bdpan → openclaw-backups 目录里删除这份备份。"
		else
			OC_API_ERR="$OC_API_ERR 请在组件里重新登录后再试。"
		fi
	fi
	unset _try _why _hint _c _prev _un1 _un2 _enc
	return 1
	OC_API_TOKEN="$tok"
	return 0
}

cloud_api_unwrap() {
	# cloud_api_unwrap <值> -> 若该值是 base64（含 URL-safe）且解出来还有一层
	# access_token，就把它取出来；否则输出空。
	#
	# 真机上 bdpan 存的 access_token 是「v1:<base64>」这种打包形态。若 base64
	# 解出来是明文 JSON，说明只是套了一层编码，可以直接用；若是二进制，那就是
	# 加密包，谁也没法用（调用方据此给出准确说法）。
	command -v base64 >/dev/null 2>&1 || return 0
	printf '%s' "$1" | tr '_-' '/+' | base64 -d 2>/dev/null | \
		sed -n 's/.*"access_token"[[:space:]]*:[[:space:]]*"\([A-Za-z0-9._~+/=-]\{8,\}\)".*/\1/p' | \
		sed -n '1p'
}

cloud_api_unwrap_binary() {
	# cloud_api_unwrap_binary <值> -> 0 表示 base64 解出来是不可打印内容（加密包）
	command -v base64 >/dev/null 2>&1 || return 1
	local f="$OC_RUNDIR/.xpan-b64.$$" nprint
	printf '%s' "$1" | tr '_-' '/+' | base64 -d 2>/dev/null >"$f" || { rm -f "$f"; return 1; }
	[ -s "$f" ] || { rm -f "$f"; return 1; }
	# 按字节数判断有没有不可打印内容：grep/head 遇到 NUL 会当成空行，
	# 用 wc 数出来才可靠（密文里 NUL 很常见）。
	nprint="$(LC_ALL=C tr -d '[:print:]\n\r\t' <"$f" 2>/dev/null | wc -c | tr -d ' ')"
	rm -f "$f" 2>/dev/null
	case "$nprint" in
		''|*[!0-9]*) return 1 ;;
	esac
	[ "$nprint" -gt 0 ]
}

cloud_api_cand_ok() {
	# 候选凭据是否满足「可以拼进 URL」的最低要求。
	case "$1" in
		''|*[!A-Za-z0-9._~+/=-]*) return 1 ;;
	esac
	[ "${#1}" -ge 8 ]
}

cloud_api_probe() {
	# cloud_api_probe <token> -> 0 可用 / 1 不可用（原因在 OC_API_ERR）
	#
	# 真机上 bdpan 存的 access_token 是「前缀:令牌」的打包形态（长度 155、
	# 含冒号），直接拿去调接口会被拒绝。拆出来的哪一段才是真 token 只有网盘
	# 知道，所以用一次**只读的列目录请求**去挑：errno=0 的就是它。探测不带
	# 任何写操作，失败也不会动到任何文件。
	local tok="$1" conf out code rc errno http last detail ok
	[ -n "$tok" ] || { OC_API_ERR="凭据为空"; return 1; }
	case "$tok" in
		*[!A-Za-z0-9._~+/=-]*)
			OC_API_ERR="凭据含非法字符"
			return 1 ;;
	esac
	[ -d "$OC_RUNDIR" ] || { OC_API_ERR="私有运行目录不存在"; return 1; }
	conf="$OC_RUNDIR/.xpan-probe.$$.conf"
	out="$OC_RUNDIR/.xpan-probe.$$.out"
	code="$OC_RUNDIR/.xpan-probe.$$.code"
	rm -f "$conf" "$out" "$code" 2>/dev/null
	( umask 077; : >"$conf" ) || { OC_API_ERR="无法创建临时文件"; return 1; }
	{
		printf 'url = "https://pan.baidu.com/rest/2.0/xpan/file?method=list&access_token=%s"\n' "$tok"
		printf 'header = "User-Agent: pan.baidu.com"\n'
	} >"$conf" 2>/dev/null
	chmod 600 "$conf" 2>/dev/null
	( umask 077; oc_timeout 30 curl -sS -K "$conf" -o "$out" \
		-w 'OC_HTTP:%{http_code}' \
		--data-urlencode "dir=/apps/bdpan/$OC_CLOUD_REMOTE" \
		>"$code" 2>&1 )
	rc=$?
	http=""
	last="$(tail -c 60 "$code" 2>/dev/null)"
	case "$last" in
		*OC_HTTP:*) http="${last##*OC_HTTP:}"; http="${http%%[!0-9]*}" ;;
	esac
	errno="$(cloud_json_scalar "$out" errno 2>/dev/null | sed -n '1p' | tr -d '\r')"
	ok=1
	if [ "$errno" = "0" ] && [ "$rc" -eq 0 ]; then
		case "$http" in
			2??|'') ok=0 ;;
		esac
	fi
	if [ "$ok" -ne 0 ]; then
		detail="$(cloud_redact <"$out" 2>/dev/null | tr -d '\r' | tail -n 1 | oc_cut_utf8 120)"
		OC_API_ERR="网盘拒绝了这份凭据（errno=${errno:-?}${http:+，HTTP $http}）${detail:+：$detail}"
	fi
	rm -f "$conf" "$out" "$code" 2>/dev/null
	return "$ok"
}

cloud_api_delete() {
	# cloud_api_delete <remote-name> -> 0 接口受理 / 1 失败（原因在 OC_API_ERR）
	#
	# 路径固定在应用沙箱 /apps/bdpan/ 下：bdpan 所有命令都作用于这个目录，
	# 传相对路径时它自己也是这么映射的。
	local name="$1" tok conf out code rc errno http last detail url
	if ! command -v curl >/dev/null 2>&1; then
		OC_API_ERR="设备上没有 curl，无法调用网盘删除接口"
		return 1
	fi
	# 本函数可能被单独调用（将来轮转若直接走接口），入口自己再校验一次，
	# 不依赖调用方已经校验过。
	cloud_valid_remote_name "$name" || {
		OC_API_ERR="远端文件名不合法"
		return 1
	}
	# 目录名与文件名同一口径：只允许字母数字与 . _ -，否则拼出来可能是
	# /apps/bdpan//x 甚至跳出沙箱。
	case "$OC_CLOUD_REMOTE" in
		''|.|..|.*|*[!A-Za-z0-9._-]*)
			OC_API_ERR="云端目录名不合法（$OC_CLOUD_REMOTE），请检查配置"
			return 1 ;;
	esac
	cloud_api_token || return 1
	tok="$OC_API_TOKEN"
	if [ ! -d "$OC_RUNDIR" ]; then
		OC_API_ERR="私有运行目录不存在（$OC_RUNDIR），请跑一次一键修复"
		return 1
	fi
	conf="$OC_RUNDIR/.xpan-rm.$$.conf"
	out="$OC_RUNDIR/.xpan-rm.$$.out"
	code="$OC_RUNDIR/.xpan-rm.$$.code"
	rm -f "$conf" "$out" "$code" 2>/dev/null
	( umask 077; : >"$conf" ) || {
		OC_API_ERR="无法创建临时配置文件，请检查磁盘空间"
		return 1
	}
	url="https://pan.baidu.com/rest/2.0/xpan/file?method=filemanager&opera=delete&async=0&access_token=$tok"
	{
		printf 'url = "%s"\n' "$url"
		printf 'header = "User-Agent: pan.baidu.com"\n'
	} >"$conf"
	chmod 600 "$conf" 2>/dev/null
	# filelist 里只有文件名（已通过 cloud_valid_remote_name 校验，不含引号与
	# 空白），不含凭据，因此允许留在 argv。
	( umask 077; oc_timeout 90 curl -sS -K "$conf" -o "$out" \
		-w 'OC_HTTP:%{http_code}' \
		--data-urlencode "filelist=[\"/apps/bdpan/$OC_CLOUD_REMOTE/$name\"]" \
		>"$code" 2>&1 )
	rc=$?
	rm -f "$conf" 2>/dev/null
	# 状态码单独取：curl 的 -w 输出和错误文本都落在 $code 里。只看退出码会把
	# 「HTTP 502 但 body 恰好是合法 JSON」当成成功。用纯 shell 提取（sed 的
	# 转义写法在 busybox 与 MSYS 上表现不一致），只取末尾片段再截数字。
	http=""
	last="$(tail -c 60 "$code" 2>/dev/null)"
	case "$last" in
		*OC_HTTP:*)
			http="${last##*OC_HTTP:}"
			http="${http%%[!0-9]*}" ;;
	esac
	errno="$(cloud_json_scalar "$out" errno 2>/dev/null | sed -n '1p' | tr -d '\r')"

	if [ "$rc" -ne 0 ]; then
		# body 与 curl 自己的错误文本都并进来，但先脱敏、去掉状态码标记。
		detail="$( { cloud_redact <"$out" 2>/dev/null
			cloud_redact <"$code" 2>/dev/null; } | grep -v 'OC_HTTP:' \
			| tail -n 2 | oc_cut_utf8 200)"
		rm -f "$out" "$code" 2>/dev/null
		case "$rc" in
			6|7)      OC_API_ERR="解析不了网盘接口域名（DNS 失败），请检查设备网络或代理" ;;
			28)       OC_API_ERR="连接网盘接口超时，请稍后重试" ;;
			35|51|60) OC_API_ERR="与网盘接口的 HTTPS 握手失败（设备可能缺 CA 证书）" ;;
			*)
				if [ -n "$detail" ]; then
					OC_API_ERR="调用网盘删除接口失败：$detail"
				else
					OC_API_ERR="调用网盘删除接口失败（curl 退出码 $rc）"
				fi ;;
		esac
		return 1
	fi

	# errno=0 但状态码不是 2xx：接口层面的失败，绝不按成功处理。
	if [ "$errno" = "0" ]; then
		# http 为空（-w 输出没落到 $code）不算失败：此时不能凭猜，改由
		# 下面的远端复验判定 —— 复验要求「目标消失且条数恰好少 1」，接口
		# 假成功进不了成功分支。
		case "$http" in
			''|2[0-9][0-9]) : ;;
			*)
				rm -f "$out" "$code" 2>/dev/null
				OC_API_ERR="网盘删除接口返回 HTTP $http（不是 2xx），未按成功处理"
				return 1 ;;
		esac
		# 接口说成功不等于真删掉了，调用方仍要复验。
		rm -f "$out" "$code" 2>/dev/null
		return 0
	fi

	case "$errno" in
		-7|-9|105|31066)
			# 文件本来就不存在：交给复验判定（此时复验会成功）。若复验说还在，
			# 说明是分页/权限问题，调用方会照实报失败。
			rm -f "$out" "$code" 2>/dev/null
			return 0 ;;
		-6|110|111|31061|31064)
			OC_API_ERR="网盘登录态已失效，请在组件设置里重新登录后再删除" ;;
		2|-2|422|31023)
			OC_API_ERR="网盘拒绝删除这个路径（可能不属于本应用的数据目录）" ;;
		'')
			detail="$(cloud_redact <"$out" 2>/dev/null | tail -n 1 | oc_cut_utf8 160)"
			case "$http" in
				401|403)
					OC_API_ERR="网盘接口拒绝访问（HTTP $http），请重新登录组件" ;;
				404)
					OC_API_ERR="网盘接口不存在（HTTP 404），组件版本可能过旧" ;;
				'')
					OC_API_ERR="网盘删除接口没有返回可识别的结果：${detail:-无输出}" ;;
				*)
					OC_API_ERR="网盘删除接口返回 HTTP $http，且没有可识别的错误码" ;;
			esac ;;
		*)
			detail="$(cloud_redact <"$out" 2>/dev/null | tail -n 1 | oc_cut_utf8 160)"
			OC_API_ERR="网盘删除接口返回错误码 $errno：${detail:-无输出}" ;;
	esac
	rm -f "$out" "$code" 2>/dev/null
	return 1
}


# 读取一次远端列表，转成 TSV 写入 <out>。
# 返回：0 成功 / 2 列表读不到或无法解析（绝不返回 0 却留下不完整文件）。
#
# 重试一次：bdpan 是单实例 CLI，和页面轮询撞车、或一次网络抖动都会让 ls
# 非 0 退出。真机实测过一次点击里 6 次 ls 有一两次失败——而删除流程对
# 列表的依赖是「必须全量」，一次抖动就让整次删除前功尽弃。两次都失败才
# 判读不到，并把退出码与 stderr 摘要留在 OC_LS_ERR 里给用户看。
cloud_rm_list() {
	local bin="$1" out="$2" tmp rc try detail
	tmp="$OC_RUNDIR/cloud-rm-ls.$$"
	OC_LS_ERR=""
	try=0
	while [ "$try" -lt 2 ]; do
		try=$((try + 1))
		rm -f "$tmp" "$out" 2>/dev/null
		cloud_run 60 "$bin" ls "$OC_CLOUD_REMOTE" --json >"$tmp" 2>&1
		rc=$?
		if [ "$rc" -eq 0 ]; then
			rc=0
			cloud_ls_tsv "$tmp" >"$out" 2>/dev/null || rc=$?
			if [ "$rc" -eq 0 ]; then
				rm -f "$tmp" 2>/dev/null
				return 0
			fi
			OC_LS_ERR="列表解析失败（网盘返回的不是可识别的 JSON）"
		else
			detail="$(cloud_redact <"$tmp" 2>/dev/null | tr -d '\r' | tail -n 2 | oc_cut_utf8 200)"
			OC_LS_ERR="网盘列表命令退出码 $rc${detail:+：$detail}"
			# 超时/被杀（timeout 的 124、TERM 的 143、KILL 的 137）不重试：
			# 再等一个 60 秒，页面请求会先一步超时，用户反而看不到原因。
			case "$rc" in
				124|137|143)
					OC_LS_ERR="网盘列表命令超时或被杀（退出码 $rc），请稍后重试"
					break ;;
			esac
		fi
		[ "$try" -lt 2 ] && sleep 1
	done
	rm -f "$tmp" "$out" 2>/dev/null
	return 2
}

# cloud_rm_stat <tsv-file> <name> -> "<条数> <目标是否出现(0/1)>"
# 只数第三列非空的记录；空列表输出 "0 0"。
cloud_rm_stat() {
	local tab
	tab="$(printf '\t')"
	awk -F "$tab" -v n="$2" \
		'NF >= 3 && $3 != "" { c++; if ($3 == n) h=1 } END { printf "%d %d\n", c+0, h+0 }' \
		"$1" 2>/dev/null
}

# 删除后的复验。bdpan 有些版本对不存在的路径也返回 0，help 里探测到的
# 子命令也可能与实际不符 —— 只看退出码会把「没删掉」报成成功。
#
# 不能只看「目标是否还在」：ls 若分页或截断，后面的文件会补进第一页，
# 目标从列表里消失但文件其实还在。因此三条都要满足：
#   * 删除前的列表里必须包含目标（否则无法判断）
#   * 删除后的列表里不含目标
#   * 删除后条数恰好比删除前少 1（分页补齐时条数不变，判「无法确认」）
# 返回：0 目标已消失 / 1 仍在 / 2 无法确认
#
# 这三条是删除结果的**最终判据**，CLI 退出码与接口 errno 都只是线索：
# 条数恰好少 1 这一条专门对付「ls 分页/截断让目标滑出列表」的假成功。
cloud_rm_verify() {
	local bin="$1" name="$2" before="$3" after bc bh ac ah
	OC_RM_VERIFY_ERR=""
	after="$OC_RUNDIR/cloud-rm-after.$$"
	set -- $(cloud_rm_stat "$before" "$name")
	bc="${1:-0}"; bh="${2:-0}"
	if [ "$bh" -ne 1 ]; then
		OC_RM_VERIFY_ERR="删除前的列表里没有 $name（列表可能未返回全量）"
		return 2
	fi
	cloud_rm_list "$bin" "$after" || {
		OC_RM_VERIFY_ERR="读取远端列表失败（${OC_LS_ERR:-原因未知}）"
		rm -f "$after" 2>/dev/null
		return 2
	}
	set -- $(cloud_rm_stat "$after" "$name")
	ac="${1:-0}"; ah="${2:-0}"
	rm -f "$after" 2>/dev/null
	if [ "$ah" -ne 0 ]; then
		return 1
	fi
	if [ "$ac" -ne "$((bc - 1))" ]; then
		OC_RM_VERIFY_ERR="远端列表条数由 $bc 变为 $ac（期望 $((bc - 1))，疑似分页或并发写入）"
		return 2
	fi
	return 0
}

# 执行一次删除并复验。返回 0 成功 / 1 目标仍在 / 2 无法确认。
cloud_rm_attempt() {
	local bin="$1" sub="$2" name="$3" tmp="$4" before="$5" vrc
	cloud_run 60 "$bin" "$sub" "$OC_CLOUD_REMOTE/$name" >"$tmp" 2>&1
	cloud_rm_verify "$bin" "$name" "$before"
	vrc=$?
	return "$vrc"
}

cloud_rm_remote() {
	# cloud_rm_remote <remote-name> -> 0 成功 / 1 失败（原因在 $OC_RM_ERR）
	# 不往 stdout 写任何东西：手动删除（cmd_rm）与远端轮转（backup-run）共用。
	local name="${1:-}" bin help sub tmp out err cand tried arc c before api_tried cli_arc

	OC_RM_ERR=""
	OC_API_ERR=""
	OC_RM_VERIFY_ERR=""
	# 显式清一次：即使本次没走到读列表的分支（例如组件未安装），也不会
	# 把上一轮残留的原因拼进本次文案。
	OC_LS_ERR=""
	cli_arc=0
	[ -n "$name" ] || { OC_RM_ERR="缺少远端文件名"; return 1; }
	cloud_valid_remote_name "$name" || {
		OC_RM_ERR="远端文件名不合法（只允许字母数字与 . _ -，不能以 - 开头，长度 1-128）"
		return 1
	}
	bin="$(cloud_bin_ready)" || { OC_RM_ERR="请先安装网盘组件"; return 1; }

	# 删除前先取一次基线；拿不到就不执行删除，避免「删了却没法确认」。
	# 这份基线是**任何删除动作之前**的快照，CLI 尝试与接口调用共用它：
	# 判据是「相对删除前少了这一条」，中途谁删的不重要。
	before="$OC_RUNDIR/cloud-rm-before.$$"
	rm -f "$before" 2>/dev/null
	cloud_rm_list "$bin" "$before" || {
		rm -f "$before" 2>/dev/null
		OC_RM_ERR="无法读取远端列表确认结果（${OC_LS_ERR:-原因未知}），未执行删除，请稍后重试"
		return 1
	}
	# 目标不在基线里就不必再试：这通常表示列表已过期，或文件已被别处删掉。
	if [ "$(cloud_rm_stat "$before" "$name" | awk '{ print $2 }')" != "1" ]; then
		rm -f "$before" 2>/dev/null
		OC_RM_ERR="远端列表里没有 $name，请刷新备份列表后重试"
		return 1
	fi

	# 只使用 CLI 自己声明的删除子命令；没有就按常见命名试，绝不自行拼 API。
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
	tried=""
	arc=1
	# help 里探测到的名字也可能与实际实现不符：探测结果排最前，其余候选
	# 仍依次兜底。每次都以远端复验判定，不会对已消失的文件重复删除。
	#
	# help 里**一个删除命令都没有**时（bdpan 3.8.9 正是如此）不再跑三个注定
	# 失败的候选：真机上叠的是 3 次失败进程 + 3 次列表读取，既慢又容易撞上
	# 网盘 CLI 的瞬时失败，最后报出一句与真正原因无关的「unknown command」。
	# 这种情况下直接走开放平台接口。
	if [ -n "$sub" ]; then
		set -- "$sub"
		for c in rm delete remove; do
			[ "$c" = "$sub" ] || set -- "$@" "$c"
		done
		for cand in "$@"; do
			tried="${tried:+$tried/}$cand"
			cloud_rm_attempt "$bin" "$cand" "$name" "$tmp" "$before"
			arc=$?
			[ "$arc" -eq 0 ] && break
			# 无法确认时不再试后面的候选：多删一轮也判不出来，
			# 只会再多两次列表读取。剩下的交给接口通道。
			[ "$arc" -eq 2 ] && break
		done
	fi
	# CLI 通道删不掉（bdpan 目前根本没有删除子命令）：改走开放平台接口。
	# 接口返回 0 也仍然要复验，绝不再拿退出码当结论。
	#
	# arc=2（CLI 之后读不到列表、无法判定）同样要走接口：这是本机上唯一真能
	# 删掉的通道，此时放弃等于「永远删不掉」。删除目标在基线里已确认存在，
	# 接口对已经不存在的文件返回 -9 会走「交给复验」分支，重复调用不会误删
	# 别的东西。
	if [ "$arc" -ne 0 ]; then
		tried="${tried:+$tried/}xpan-api"
		api_tried=1
		cli_arc="$arc"
		if cloud_api_delete "$name"; then
			cloud_rm_verify "$bin" "$name" "$before"
			arc=$?
			# 接口返回 0 也可能是假成功（路径不对、权限不足、异步未执行）。
			# 复验说还在，就照实报「接口成功但文件仍在」，别退回一句
			# 「CLI 不支持删除」把真正的原因盖掉。
			if [ "$arc" -eq 1 ]; then
				OC_API_ERR="网盘删除接口返回成功，但远端仍有该文件（可能路径不在本应用目录内）"
			fi
		else
			# 接口也没成功。CLI 侧本来就是「无法确认」时不要把结论
			# 降级成「删除失败」——分页/并发上传的线索比一句失败更有用。
			[ "$cli_arc" -eq 2 ] || arc=1
		fi
	fi
	rm -f "$before" 2>/dev/null

	out="$(cat "$tmp" 2>/dev/null)"
	rm -f "$tmp" 2>/dev/null
	[ "$arc" -eq 0 ] && return 0
	err="$(printf '%s\n' "$out" | cloud_redact | tail -n 5 | oc_cut_utf8 800)"
	if [ "$arc" -eq 2 ]; then
		# 没走到接口通道时，CLI 输出是有用线索；走了接口通道还缀一句
		# 「unknown command」，只会让人以为删除命令打错了，盖掉真正原因。
		if [ -n "${api_tried:-}" ] && [ -n "$OC_API_ERR" ]; then
			OC_RM_ERR="删除未确认：${OC_RM_VERIFY_ERR:-远端列表未返回全量}；接口通道也没成功（${OC_API_ERR}）。请刷新备份列表核对 $name 是否还在"
		elif [ -n "${api_tried:-}" ]; then
			OC_RM_ERR="网盘删除接口返回成功，但列表读不到、无法确认是否真的删掉（接口成功不等于已落到存储）：${OC_RM_VERIFY_ERR:-远端列表未返回全量}。请刷新备份列表核对 $name 是否还在"
		else
			OC_RM_ERR="删除未确认：${OC_RM_VERIFY_ERR:-远端列表未返回全量}，请刷新备份列表核对。CLI 输出：${err:-无输出}"
		fi
		return 1
	fi
	if [ "$arc" -eq 1 ] && [ -n "${api_tried:-}" ] && [ -z "$OC_API_ERR" ]; then
		OC_API_ERR="调用网盘删除接口失败（原因未知），请刷新备份列表确认 $name 是否还在"
	fi
	# 接口给出了明确原因（登录态失效 / 路径被拒 / 网络）就照实说，
	# 不要在能定位的时候丢一句「不支持删除」。
	if [ -n "$OC_API_ERR" ]; then
		OC_RM_ERR="删除失败：$OC_API_ERR"
		return 1
	fi
	case "$out" in
		*unknown*|*Unknown*|*unrecognized*|*Unrecognized*|*"invalid command"*|*"no such command"*|*未知*|*不支持*)
			OC_RM_ERR="网盘组件没有删除命令，登录态也不能直接删除（已试 ${tried:-无}），请在网盘 App 里删除" ;;
		*)
			OC_RM_ERR="删除未生效（已试 ${tried:-无}），远端仍存在 $name。CLI 输出：${err:-无输出}" ;;
	esac
	return 1
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
#   * 改 crontab 必须：同目录临时文件 -> 校验 -> 备份（插件私有目录） ->
#     chmod 600 -> mv（同目录 rename 才是原子替换）。
#   * 备份**不能**放在 /etc/crontabs/ 下：busybox crond 把该目录里的每个文件名
#     当成用户名加载，root.openclaw.bak 会被当成一个用户，轻则刷 syslog，
#     重则按备份再调度一遍。
#   * 校验三条：标记行 <= 1；非标记行数量与原文完全一致；要写入的命令可执行。
#   * 幂等：重复调用不会堆出多行。
OC_CRONTAB="/etc/crontabs/root"
OC_CRON_MARK="# openclaw-cloud"

# 定时任务要执行的脚本。与 OC_CLOUD_BACKUP 同一套兜底：标准安装位置优先，
# 脚本被挪到别处（测试 / 非标准前缀）时退回脚本自己所在目录。
# 写死绝对路径的后果是 cron 每天静默失败，用户以为备份在跑，实际一份都没有。
OC_CRON_SCRIPT="/usr/libexec/openclaw/cloud.sh"
if [ ! -x "$OC_CRON_SCRIPT" ]; then
	OC_CRON_SCRIPT="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/cloud.sh"
fi
OC_CRON_CMD="$OC_CRON_SCRIPT backup-run"

# crontab 备份的位置：插件私有目录，**不在** /etc/crontabs/ 下。
# 备份只用于「写坏了能恢复」，不需要留在 crontab 目录里。
OC_CRON_BAK="$OC_CLOUD_ROOT/crontab.bak"

# 旧版本把备份写在 /etc/crontabs/root.openclaw.bak；升级后要主动清掉，
# 否则老设备上的误调度会一直存在。只删这一个确切文件名。
OC_CRON_BAK_LEGACY="$OC_CRONTAB.openclaw.bak"

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
	# 本地留存份数：定时备份上传成功后本地也保留副本，按 mtime 轮转。
	# 默认 2（当前一份 + 上一份）；0 = 不保留本地（旧行为：上传后删本地）。
	# 老配置没有这个键也能跑（uci_get 回落默认值），符合 UPGRADE-COMP 第 4 条。
	OC_SCH_KEEP_LOCAL="$(cloud_sched_int "$(uci_get main.cloud_keep_local '2')" 2 0 30 '本地保留份数（cloud_keep_local）')"
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

# cloud_cron_write() 的失败原因（供调用方拼进 JSON；避免只报“写入失败”）
OC_CRON_ERR=""

cloud_cron_backup() {
	# -> 0 已备份 / 1 失败（原因放 OC_CRON_ERR）
	#
	# 备份写到插件私有目录，**绝不**写进 /etc/crontabs/：busybox crond 把该目录下
	# 每个文件名当用户名加载，root.openclaw.bak 会被当成一个叫这个名字的用户，
	# 轻则持续报错刷 syslog，重则按这份备份再调度一遍。
	local dir bak
	OC_CRON_ERR=""
	[ -f "$OC_CRONTAB" ] || return 0
	# 测试夹具只抽出本函数，不会定义这两个变量；此时跳过备份而不是往 "/" 下写。
	[ -n "${OC_CRON_BAK:-}" ] || return 0

	bak="$OC_CRON_BAK"
	dir="$(dirname "$bak")"
	if ! mkdir -p "$dir" 2>/dev/null; then
		bak=""
	fi
	if [ -n "$bak" ]; then
		chmod 700 "$dir" 2>/dev/null || true
		cp -p "$OC_CRONTAB" "$bak" 2>/dev/null || bak=""
	fi

	if [ -z "$bak" ]; then
		# 数据盘不可用（未挂载 / 只读）时退回私有临时目录：同样 0700、同样
		# 不在 crontab 目录里，重启后丢失也无所谓 —— 它只是「写坏了能恢复」。
		[ -n "${OC_RUNDIR:-}" ] || return 0
		bak="$OC_RUNDIR/crontab.bak"
		dir="$(dirname "$bak")"
		if ! mkdir -p "$dir" 2>/dev/null || \
			! cp -p "$OC_CRONTAB" "$bak" 2>/dev/null; then
			OC_CRON_ERR="无法备份 crontab 到 $bak"
			return 1
		fi
	fi
	chmod 600 "$bak" 2>/dev/null || true
	return 0
}

cloud_cron_legacy_cleanup() {
	# 删除旧版本留在 /etc/crontabs/ 下的备份（确切的一个文件名）。
	# 不删它，老设备上的误调度会一直存在。
	[ -f "$OC_CRON_BAK_LEGACY" ] || return 0
	if rm -f "$OC_CRON_BAK_LEGACY" 2>/dev/null; then
		oc_warn "已删除旧版 crontab 备份（crond 会把它当成用户）：$OC_CRON_BAK_LEGACY"
	fi
	return 0
}

cloud_cron_write() {
	# cloud_cron_write <line|""> -> 0 成功 / 1 失败（原因同时写进 OC_CRON_ERR）
	#
	# <line> 为空表示「只删除我们的行」。任何一步失败都不动原文件。
	# n_other_* 是「不带标记的行数」（别人的任务 / 注释 / 空行）。
	local line="$1" dir tmp new n_other_old n_other_new

	OC_CRON_ERR=""
	dir="$(dirname "$OC_CRONTAB")"
	[ -d "$dir" ] || {
		OC_CRON_ERR="crontab 目录不存在：$dir"
		oc_warn "$OC_CRON_ERR"
		return 1
	}

	# 0) 要写入的命令必须真的可执行：写一条注定失败的 cron 比不写更糟 ——
	#    用户看到「已启用」就再也不会去检查，而备份一份都不会产生。
	#    （只校验新增行；删除我们的行不需要脚本存在。）
	#    OC_CRON_SCRIPT 未定义时（测试夹具只抽出本函数）跳过校验。
	if [ -n "$line" ] && [ -n "${OC_CRON_SCRIPT:-}" ]; then
		if [ ! -f "$OC_CRON_SCRIPT" ] || [ ! -x "$OC_CRON_SCRIPT" ]; then
			OC_CRON_ERR="定时任务脚本不可执行：$OC_CRON_SCRIPT"
			oc_warn "$OC_CRON_ERR"
			return 1
		fi
	fi

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
			OC_CRON_ERR="无法读取 crontab：$OC_CRONTAB"
			oc_warn "$OC_CRON_ERR"
			return 1
		fi
	else
		: >"$tmp" 2>/dev/null || {
			rm -f "$tmp" 2>/dev/null
			OC_CRON_ERR="无法创建临时文件：$tmp"
			oc_warn "$OC_CRON_ERR"
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
		OC_CRON_ERR="生成新 crontab 失败（临时文件：$new）"
		oc_warn "$OC_CRON_ERR"
		return 1
	fi

	# 校验 1：我们的行最多一条
	if [ "$(cloud_cron_count_mark "$new")" -gt 1 ]; then
		rm -f "$tmp" "$new" 2>/dev/null
		OC_CRON_ERR="校验失败：新 crontab 里有多条 openclaw-cloud 行，已放弃写入"
		oc_warn "$OC_CRON_ERR"
		return 1
	fi
	# 校验 2：别人的行一条都不能少
	n_other_new="$(cloud_cron_count_other "$new")"
	if [ "$n_other_new" -ne "$n_other_old" ]; then
		rm -f "$tmp" "$new" 2>/dev/null
		OC_CRON_ERR="校验失败：其它行数量发生变化（$n_other_old -> $n_other_new），已放弃写入"
		oc_warn "$OC_CRON_ERR"
		return 1
	fi

	# 4) 备份原文件（存在才备份）。备份只用于「写坏了能恢复」，失败不阻断写入：
	#    写到 /etc/crontabs 之外，crond 就不会把它当成一个用户的 crontab。
	if [ -f "$OC_CRONTAB" ]; then
		cloud_cron_backup || oc_warn "无法备份 crontab（继续写入）：$OC_CRON_ERR"
	fi

	# 5) 原子替换：chmod 600 + mv（同目录 rename）
	chmod 600 "$new" 2>/dev/null || true
	chown 0:0 "$new" 2>/dev/null || true
	if ! mv -f "$new" "$OC_CRONTAB" 2>/dev/null; then
		rm -f "$tmp" "$new" 2>/dev/null
		OC_CRON_ERR="无法替换 crontab：$OC_CRONTAB"
		oc_warn "$OC_CRON_ERR"
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

	printf '{"ok":true,"enabled":%s,"period":"%s","weekday":%s,"hour":%s,"minute":%s,"keep":%s,"keep_local":%s,"installed":%s,"line":"%s"}\n' \
		"$enabled" "$OC_SCH_PERIOD" "$OC_SCH_WEEKDAY" "$OC_SCH_HOUR" \
		"$OC_SCH_MINUTE" "$OC_SCH_KEEP" "$OC_SCH_KEEP_LOCAL" "$installed" "$(jstr "$line")"
}

cmd_schedule_apply() {
	local enabled=false line=""

	cloud_sched_vals
	if [ "$OC_SCH_ENABLED" = "1" ]; then
		enabled=true
		line="$(cloud_cron_render)"
	fi

	cloud_cron_legacy_cleanup
	cloud_cron_write "$line" || cloud_fail "${OC_CRON_ERR:-写入 crontab 失败：$OC_CRONTAB}"
	cloud_cron_reload || true

	printf '{"ok":true,"enabled":%s,"line":"%s"}\n' "$enabled" "$(jstr "$line")"
}

cmd_schedule_clear() {
	cloud_cron_legacy_cleanup
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
		keep_local) printf 'cloud_keep_local' ;;
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
		# keep_local：0 = 不保留本地副本（旧行为），因此下限是 0。
		keep_local) lo=0; hi=30 ;;
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

	printf '{"ok":true,"enabled":%s,"period":"%s","weekday":%s,"hour":%s,"minute":%s,"keep":%s,"keep_local":%s,"line":"%s"}\n' \
		"$enabled" "$OC_SCH_PERIOD" "$OC_SCH_WEEKDAY" "$OC_SCH_HOUR" \
		"$OC_SCH_MINUTE" "$OC_SCH_KEEP" "$OC_SCH_KEEP_LOCAL" "$(jstr "$line")"
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
	# 追加之前先轮转：/var 是 tmpfs，任务日志无限增长会吃内存。
	oc_log_rotate "$OC_TASKLOG"
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
	for k in logged_in loggedIn is_login isLogin login authenticated ok \
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
	for k in logged_in loggedIn is_login isLogin login authenticated ok; do
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
	#
	# 排序键统一归一化成「秒级 epoch 整数」再比较：远端 mtime 可能是 epoch 秒、
	# 毫秒，也可能是 ISO 串，混在一起按「取出所有数字再补零」排序会得到与真实
	# 时间无关的结果（001760000000 排在 20261020104630 前面），从而删掉最新的。
	# 归一化失败的行标记为 U，**不参与删除**，只记一条日志 —— 宁可少删。
	local keep="$1" listing all cand unparsed tab total excess n name drop

	listing="$(cloud_remote_list_tsv)" || return 1
	tab="$(printf '\t')"
	all="$(printf '%s\n' "$listing" | awk -F "$tab" '
		# Howard Hinnant 的 civil-from-days：不依赖 busybox date -d。
		function days_from_civil(y, m, d,   era, yoe, doy, doe) {
			if (m <= 2) y--
			era = (y >= 0 ? int(y / 400) : int((y - 399) / 400))
			yoe = y - era * 400
			doy = int((153 * (m + (m > 2 ? -3 : 9)) + 2) / 5) + d - 1
			doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
			return era * 146097 + doe - 719468
		}
		# to_epoch(s) -> 秒级整数字符串；无法解析时返回 ""。
		function to_epoch(s,   y, mo, da, hh, mi, ss) {
			gsub(/^[ \t]+/, "", s)
			gsub(/[ \t]+$/, "", s)
			if (s == "") return ""
			if (s ~ /^[0-9]+$/) {
				if (length(s) >= 13) return substr(s, 1, length(s) - 3)
				if (length(s) == 10 || length(s) == 9) return s
				return ""
			}
			if (s !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/) return ""
			y = substr(s, 1, 4) + 0
			mo = substr(s, 6, 2) + 0
			da = substr(s, 9, 2) + 0
			hh = 0; mi = 0; ss = 0
			if (length(s) >= 19) {
				if (s !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9][ T][0-9][0-9]:[0-9][0-9]:[0-9][0-9]/)
					return ""
				hh = substr(s, 12, 2) + 0
				mi = substr(s, 15, 2) + 0
				ss = substr(s, 18, 2) + 0
			}
			if (mo < 1 || mo > 12 || da < 1 || da > 31) return ""
			if (hh > 23 || mi > 59 || ss > 60) return ""
			return sprintf("%d", days_from_civil(y, mo, da) * 86400 + hh * 3600 + mi * 60 + ss)
		}
		$1 == "false" && ($3 ~ /^openclaw-.+\.tar\.gz$/ || $3 ~ /^openclaw-.+\.tar\.gz\.enc$/) {
			mt = to_epoch($2)
			if (mt == "") printf "U\t%s\n", $3
			else printf "%s\t%s\n", mt, $3
		}')"

	# 时间不可信的排除在外：既不参与排序，也不计入 total（等价于多保留）。
	unparsed="$(printf '%s\n' "$all" | awk -F "$tab" '$1 == "U" { print $2 }')"
	if [ -n "$unparsed" ]; then
		br_log "警告：以下远端备份的修改时间无法解析，本次不参与清理：$(printf '%s\n' "$unparsed" | tr '\n' ' ')"
	fi
	cand="$(printf '%s\n' "$all" | awk -F "$tab" '$1 != "U"' \
		| sort -t "$tab" -k1,1n -k2,2)"

	total="$(printf '%s\n' "$cand" | awk 'NF { n++ } END { printf "%d", n + 0 }')"
	case "$total" in ''|*[!0-9]*) total=0 ;; esac
	excess=$((total - keep))
	if [ "$excess" -le 0 ]; then
		printf '0'
		return 0
	fi

	drop="$(printf '%s\n' "$cand" | awk -F "$tab" -v n="$excess" 'NF && c < n { print $2; c++ }')"
	# 删除前先把清单写进日志：事后能核对到底删了哪几份。
	br_log "将删除 $excess 份旧备份（保留 $keep 份）：$(printf '%s\n' "$drop" | tr '\n' ' ')"

	n=0
	# 用 here-doc 而不是管道：管道里的 while 在子 shell 里跑，n 回传不出来。
	while IFS= read -r name; do
		[ -n "$name" ] || continue
		[ "$n" -lt "$excess" ] || break
		if cloud_rm_remote "$name"; then
			n=$((n + 1))
		else
			oc_warn "清理旧备份失败（$name）：${OC_RM_ERR:-未知错误}"
		fi
	done <<EOF
$drop
EOF
	printf '%s' "$n"
}

br_prune_local() {
	# br_prune_local <dir> <keep> <except> -> stdout: 实际删除的份数
	#
	# 本地副本轮转（与远端 br_prune 同一语义）：把 <dir> 下符合
	# openclaw-backup-*.tar.gz 的普通文件按 mtime 从新到旧排序，保留最新
	# <keep> 份（<except> 指名的文件不参与统计也不参与删除——它是本次任务
	# 刚产出的归档，去留由调用方决定，这里绝不碰）。
	#
	# 安全边界：glob 锚定在 <dir> 内、模式固定、只删普通文件；所有被删的
	# 名字都来自 glob 展开结果，不拼任何用户输入。目录不存在 / keep 非法
	# / keep < 1 时原样返回 0。删除失败只告警、继续，不让整个备份任务失败。
	#
	# 排序键用 mtime（oc_mtime -> stat -c %Y，GNU 与 busybox 都可用），
	# 与 backup.sh cmd_list 的排序口径一致。
	local dir="$1" keep="$2" except="$3" tab f n drop

	[ -d "$dir" ] || { printf '0'; return 0; }
	case "$keep" in ''|*[!0-9]*) printf '0'; return 0 ;; esac
	[ "$keep" -ge 1 ] || { printf '0'; return 0; }
	# except 只可能是纯文件名（backup.sh create 的返回值）；带路径一律视为空
	case "$except" in ''|*/|*..*|*/*) except='' ;; esac

	tab="$(printf '\t')"
	drop="$(
		{
			for f in "$dir"/openclaw-backup-*.tar.gz; do
				[ -f "$f" ] || continue
				n="${f##*/}"
				[ "$n" = "$except" ] && continue
				printf '%s\t%s\n' "$(oc_mtime "$f")" "$n"
			done
		} | sort -rn 2>/dev/null | awk -F "$tab" -v keep="$keep" '
			# 排序后第 keep 行之后的就是要删的旧副本
			NR > keep { print $2 }
		'
	)"

	# 用 here-doc 而不是管道：管道里的 while 在子 shell 里跑，n 回传不出来
	# （与 br_prune 同一个坑）。
	n=0
	while IFS= read -r f; do
		[ -n "$f" ] || continue
		case "$f" in
			openclaw-backup-*.tar.gz) ;;
			*) continue ;;
		esac
		if rm -f "$dir/$f" 2>/dev/null; then
			n=$((n + 1))
			br_log "本地轮转：删除旧副本 $f"
		else
			br_log "警告：删除本地旧副本失败：$f"
		fi
	done <<EOF
$drop
EOF
	printf '%s' "$n"
}

# ---------------------------------------------------------------- 手动备份（带进度）
bk_log() {
	# 写进度日志：前端轮询这个文件。
	# 与 br_log 的区别：br_log 写任务总日志（给定时任务事后查），
	# bk_log 写**本次**手动备份的独立日志（给进度框实时看）。
	[ -n "${CLOUD_BK_LOG:-}" ] || return 0
	printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" >>"$CLOUD_BK_LOG" 2>/dev/null || true
	return 0
}

bk_pid_alive() {
	# bk_pid_alive <pid> -> 0 当且仅当该 pid 是**本次手动备份的 worker**
	#
	# 为什么不能直接用 oc_pid_alive：它把任何 openclaw/cloud.sh 进程都算作
	# "我们的进程"。而 backup-poll 本身就是 cloud.sh —— 一旦 pid 文件里的
	# 陈旧 pid 被复用到一个轮询请求上，busy 判定就永久为真，用户再也无法
	# 启动备份（只能手工删 pid 文件）。这里要求 cmdline 里出现 backup-bg，
	# 精确到"就是那个后台任务"。
	local pid="${1:-}" cmd
	case "$pid" in ''|*[!0-9]*) return 1 ;; esac
	[ -d "/proc/$pid" ] || return 1
	# 先过一遍通用的存活检查（挡僵尸与已退出）
	oc_pid_alive "$pid" || return 1
	cmd="$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null)"
	case "$cmd" in
		*backup-bg*) return 0 ;;
	esac
	return 1
}

cmd_backup_bg() {
	# backup-bg [--no-workspace]
	#
	# 手动备份改成后台执行：打包几 GB + 上传几十 MB 可能要几分钟，
	# 同步等会让前端一直空白。这里立刻返回 started，前端轮询 backup-poll。
	# 定时任务（backup-run）保持原样：静默、只写任务日志。
	local ws="1"
	while [ $# -gt 0 ]; do
		case "$1" in
			--no-workspace) ws="0"; shift ;;
			*) shift ;;
		esac
	done

	# 前置检查（与定时任务同口径，但失败要明确回给用户，因为这是手动触发的）
	cloud_bin_ready >/dev/null 2>&1 || cloud_fail "网盘组件未安装，请先完成上面的步骤" 2
	if ! cloud_is_logged_in; then
		if [ "$CLOUD_AUTH_STATE" = "unknown" ]; then
			cloud_fail "登录状态无法确认，请重新登录后再试" 2
		fi
		cloud_fail "尚未登录百度网盘，请先完成授权" 2
	fi
	cloud_ensure_dirs || cloud_fail "无法创建云备份目录" 2
	[ -d "$OC_RUNDIR" ] && [ -w "$OC_RUNDIR" ] || cloud_fail "临时目录不可用：$OC_RUNDIR" 2

	# 已有任务在跑：pid 活着就报 busy；否则清掉陈旧状态继续。
	# 占位值是 "starting <epoch>"。它在 worker 起来前也算忙；但必须会过期 ——
	# 否则 worker 启动失败时占位永远留着，用户再也没法启动备份（只能手工删）。
	if [ -f "$CLOUD_BK_PID" ]; then
		local _p _ts _now
		_p="$(head -n1 "$CLOUD_BK_PID" 2>/dev/null | tr -d '\r\n')"
		case "$_p" in
			starting\ *) _ts="${_p#starting }" ;;
			*) _ts="" ;;
		esac
		if [ -n "$_ts" ]; then
			# 时间戳就在占位里，不用 stat（精简 busybox 未必支持 stat -c）
			case "$_ts" in ''|*[!0-9]*) _ts="" ;; esac
			_now="$(date +%s 2>/dev/null | tr -d ' \r\n')"
			case "$_now" in ''|*[!0-9]*) _now="" ;; esac
			if [ -n "$_ts" ] && [ -n "$_now" ] && [ $((_now - _ts)) -le 120 ]; then
				printf '{"ok":false,"busy":true,"error":"%s"}\n' \
					"$(jstr "已有备份任务正在启动，请稍等")"
				return 0
			fi
			rm -f "$CLOUD_BK_PID" "$CLOUD_BK_RC" 2>/dev/null
		elif [ -n "$_p" ] && bk_pid_alive "$_p"; then
			printf '{"ok":false,"busy":true,"error":"%s"}\n' \
				"$(jstr "已有备份任务在运行，请等它结束")"
			return 0
		else
			rm -f "$CLOUD_BK_PID" "$CLOUD_BK_RC" 2>/dev/null
		fi
	fi
	# 定时备份（backup-run）自己会取全局锁；手动这条不取锁，所以必须显式问
	# 一次锁：否则「定时任务正在打包时用户又点立即备份」会同时跑两份 tar，
	# 既互相抢磁盘，也会在轮转时把对方刚写的归档算进待删集合。
	if oc_lock_busy; then
		printf '{"ok":false,"busy":true,"error":"%s"}\n' \
			"$(jstr "另一个备份/安装任务正在运行，请等它结束")"
		return 0
	fi
	rm -f "$CLOUD_BK_RC" 2>/dev/null
	: >"$CLOUD_BK_LOG" 2>/dev/null || cloud_fail "无法写入进度日志：$CLOUD_BK_LOG"

	# 阶段前缀 [local] / [cloud] 供前端分别显示"本地备份""云端上传"两行状态。
	# 文本本身仍然可读：日志同时要能直接给人看。
	bk_log "[local] 开始打包（$([ "$ws" = "1" ] && echo '配置 + 会话 + 工作区' || echo '配置 + 会话，不含工作区')）"
	bk_log "[local] tar 不提供可靠总量，故不显示百分比；完成时给出文件名与体积"

	# 用 setsid 脱离当前会话再跑：用户点完「立即备份」就关页面 / 关 SSH 时，
	# uhttpd 的 CGI 进程会退出，挂在它下面的子进程会收到 SIGHUP 被打断，
	# 备份就半途死掉（表现为「进度停在打包中，之后没了」）。
	# setsid 让 worker 自成一个会话，父进程退出不再影响它。
	# 没有 setsid（精简 busybox）时退回普通后台启动：至少不比原来差。
	#
	# setsid 是外部程序，无法执行当前 shell 函数，必须调用脚本自身的真实入口。
	# PID 文件先写 sentinel "starting"，由 worker 用自己真实的 $$ 覆盖：
	# 父进程若也写 $!，与 worker 的 $$ 会互相覆盖（setsid 可能 fork，$! 未必
	# 等于 worker），轮询可能追踪到已退出的中间进程而误判"任务已中断"。
	# 只留一个写者，才没有竞态。
	local _self
	_self="$0"
	case "$_self" in
		/*) ;;
		*/*) _self="$(cd "$(dirname "$_self")" 2>/dev/null && pwd)/$(basename "$_self")" ;;
		*) _self="$(command -v "$_self" 2>/dev/null || printf '%s' "$_self")" ;;
	esac
	[ -x "$_self" ] || _self="/usr/libexec/openclaw/cloud.sh"
	# 找不到自身可执行文件时明确报错。以前这种情况会被 2>&1 吞掉，
	# 页面显示"已启动"但备份根本没跑（审计指出的静默失效）。
	# 此处还没写过任何状态文件，不要动 PID/rc（可能是别的任务的）。
	if [ ! -x "$_self" ]; then
		cloud_fail "无法定位 cloud.sh 自身路径（$_self），请重新安装插件"
	fi
	# PID 文件只由 worker 自己写一次，父进程只留占位 "starting <epoch>"：
	# 若父进程也写 $!，setsid 可能 fork，$! 未必是 worker，两个写者会互相
	# 覆盖，轮询可能追踪到已退出的中间进程而误判"任务已中断"。
	# 单一写者 = 没有竞态。
	#
	# 占位里带时间戳（而不是靠 stat 取 mtime）：精简 busybox 未必有
	# `stat -c`，拿不到时间就永远判不出"启动失败"，会一直转圈。
	# date +%s 是 busybox 必备，用它最稳。
	printf 'starting %s\n' "$(date +%s 2>/dev/null)" >"$CLOUD_BK_PID" 2>/dev/null || true
	if command -v setsid >/dev/null 2>&1; then
		# setsid 是外部程序，只能 exec 可执行文件，不能执行 shell 函数，
		# 所以走脚本自身的真实子命令入口 backup-bg-worker。
		setsid sh -c 'exec "$1" backup-bg-worker "$2"' sh "$_self" "$ws" \
			</dev/null >/dev/null 2>&1 &
	else
		"$_self" backup-bg-worker "$ws" </dev/null >/dev/null 2>&1 &
	fi
	printf '{"ok":true,"started":true}\n'
}

backup_bg_worker() {
	# 后台 worker：打包 → 上传。所有输出进进度日志，最后写 rc。
	local ws="${1:-1}" out errf rc file dir local_path remote _sz _szh

	# 真正的互斥防线：cmd_backup_bg 里的 oc_lock_busy 只是「立即回 busy」的
	# 快速路径，检查到启动之间有空窗。这里原子取锁（成功即挂 EXIT trap 自动
	# 释放），才能挡住反向竞态 —— 手动备份运行期间，定时备份 oc_lock_acquire
	# 必然失败而跳过，反之亦然。
	#
	# 必须先取锁、再写 PID：抢锁失败说明另一个任务正在跑，此时绝不能
	# 覆盖/删除它的 PID 与 rc 文件，否则会把对方正在进行的备份标记成
	# 「已中断」。也不能 bk_log —— 那是同一个日志文件，写进去会把对方
	# 正在显示的进度污染成「已取消本次备份」。
	if ! oc_lock_acquire; then
		# 抢锁失败说明另一个任务在跑。只有在 PID 文件仍是我们父进程留下的
		# 占位值时才收尾 —— 那说明没有别人的手动任务写过它，写 rc 不会
		# 覆盖对方结果；否则保持原样。
		# 注意 tr 只删换行不删空格：占位是 "starting <epoch>"，删空格会
		# 把两个字段粘成一个，判定随之失效。
		if head -n1 "$CLOUD_BK_PID" 2>/dev/null | grep -q '^starting '; then
			bk_log "[local] ✗ 另一个备份/安装任务正在运行，本次未启动"
			printf '1\n' >"$CLOUD_BK_RC" 2>/dev/null || true
			rm -f "$CLOUD_BK_PID" 2>/dev/null
		fi
		return 0
	fi

	# 取锁成功，本次才是真正的执行者：写自己真实的 $$，这是 PID 文件的
	# 唯一写入点（父进程只写占位值）。
	printf '%s\n' "$$" >"$CLOUD_BK_PID" 2>/dev/null || true

	out="$OC_RUNDIR/bk-bg-out.$$"
	errf="$OC_RUNDIR/bk-bg-err.$$"
	rm -f "$out" "$errf" 2>/dev/null

	# ---- 打包 ----
	if [ "$ws" = "1" ]; then
		sh "$OC_CLOUD_BACKUP" create >"$out" 2>"$errf"
	else
		sh "$OC_CLOUD_BACKUP" create --no-workspace >"$out" 2>"$errf"
	fi
	rc=$?
	if [ "$rc" -ne 0 ] || ! grep -q '"ok":true' "$out" 2>/dev/null; then
		bk_log "[local] ✗ 打包失败（rc=$rc）：$(cloud_tail_err "$errf" 3 | tr '\n' ' ')"
		rm -f "$out" "$errf" 2>/dev/null
		printf '1\n' >"$CLOUD_BK_RC" 2>/dev/null || true
		rm -f "$CLOUD_BK_PID" 2>/dev/null
		return 0
	fi
	file="$(sed -n 's/.*"file":"\([^"]*\)".*/\1/p' "$out" 2>/dev/null | head -n1)"
	rm -f "$out" "$errf" 2>/dev/null
	case "$file" in
		'') bk_log "[local] ✗ 打包未返回文件名"
			printf '1\n' >"$CLOUD_BK_RC" 2>/dev/null || true
			rm -f "$CLOUD_BK_PID" 2>/dev/null
			return 0 ;;
		*/*|*..*) bk_log "[local] ✗ 打包返回的文件名不合法：$file"
			printf '1\n' >"$CLOUD_BK_RC" 2>/dev/null || true
			rm -f "$CLOUD_BK_PID" 2>/dev/null
			return 0 ;;
	esac

	dir="$(sh "$OC_CLOUD_BACKUP" path 2>/dev/null)"
	[ -n "$dir" ] || dir="$(oc_base_dir)/backups"
	local_path="$dir/$file"
	if [ ! -f "$local_path" ]; then
		bk_log "[local] ✗ 打包产物不存在：$local_path"
		printf '1\n' >"$CLOUD_BK_RC" 2>/dev/null || true
		rm -f "$CLOUD_BK_PID" 2>/dev/null
		return 0
	fi
	_sz="$(stat -c %s "$local_path" 2>/dev/null | tr -d ' \r\n')"
	case "$_sz" in ''|*[!0-9]*) _sz=0 ;; esac
	if [ "$_sz" -ge 1048576 ]; then
		_szh="$((_sz / 1048576)) MB"
	elif [ "$_sz" -ge 1024 ]; then
		_szh="$((_sz / 1024)) KB"
	else
		_szh="$_sz B"
	fi
	bk_log "[local] ✓ 打包完成：$file（$_szh）"

	# ---- 上传 ----
	bk_log "[cloud] 开始上传到 $OC_CLOUD_REMOTE/ …"
	out="$OC_RUNDIR/bk-bg-up.$$"
	errf="$OC_RUNDIR/bk-bg-uperr.$$"
	rm -f "$out" "$errf" 2>/dev/null
	( cloud_upload_file "$local_path" "$file" ) >"$out" 2>"$errf"
	rc=$?
	if [ "$rc" -ne 0 ] || ! grep -q '"ok":true' "$out" 2>/dev/null; then
		remote="$(sed -n 's/.*"error":"\([^"]*\)".*/\1/p' "$out" 2>/dev/null | head -n1)"
		[ -n "$remote" ] || remote="上传失败（rc=$rc）"
		bk_log "[cloud] ✗ $remote"
		[ -s "$errf" ] && bk_log "[cloud]   $(cloud_tail_err "$errf" 3 | tr '\n' ' ')"
		rm -f "$out" "$errf" 2>/dev/null
		printf '1\n' >"$CLOUD_BK_RC" 2>/dev/null || true
		rm -f "$CLOUD_BK_PID" 2>/dev/null
		return 0
	fi
	remote="$(sed -n 's/.*"remote":"\([^"]*\)".*/\1/p' "$out" 2>/dev/null | head -n1)"
	rm -f "$out" "$errf" 2>/dev/null
	bk_log "[cloud] ✓ 上传完成：${remote:-$file}"
	bk_log "[done] 全部完成。"
	printf '0\n' >"$CLOUD_BK_RC" 2>/dev/null || true
	rm -f "$CLOUD_BK_PID" 2>/dev/null
	return 0
}

cmd_backup_poll() {
	# backup-poll -> {"ok":true,"running":bool,"done":bool,"rc":"","log":"..."}
	local pid running=false done=false rc="" out="" _st_ts _st_now

	# 从未启动过：不返回 done，避免前端把"没开始"当成"已完成"
	if [ ! -f "$CLOUD_BK_LOG" ] && [ ! -f "$CLOUD_BK_RC" ] && [ ! -f "$CLOUD_BK_PID" ]; then
		printf '{"ok":true,"running":false,"done":false,"rc":"","log":""}\n'
		return 0
	fi

	# 只删行尾换行，不删空格：占位是 "starting <epoch>"，两个字段靠空格分隔。
	pid="$(head -n1 "$CLOUD_BK_PID" 2>/dev/null | tr -d '\r\n')"
	# 占位值是 "starting <epoch>"，时间戳自带，不依赖 stat。
	_st_ts=""
	case "$pid" in
		starting\ *) _st_ts="${pid#starting }" ;;
	esac
	# 与 cmd_backup_bg 用同一个精确判据：宽松判据会把轮询请求本身
	# （也是 cloud.sh）误判成"任务在跑"，于是 running 永远为 true。
	if [ -n "$pid" ] && bk_pid_alive "$pid"; then
		running=true
	elif [ -n "$_st_ts" ]; then
		# worker 还没写下自己的 pid（刚 spawn）。这一段不能判 done ——
		# 否则前端会立刻显示"任务已中断"，而备份其实正在启动。
		# 但也不能无限等：worker 启动失败时占位会一直留着，超时就判失败。
		#
		# 时间戳来自占位本身（"starting <epoch>"），不用 stat —— 精简
		# busybox 未必支持 stat -c，拿不到时间就会永远转圈。两侧都必须是
		# 纯数字才计算差值，否则按「还在启动」处理，不猜。
		case "$_st_ts" in
			''|*[!0-9]*) running=true ;;
			*)
				_st_now="$(date +%s 2>/dev/null | tr -d ' \r\n')"
				case "$_st_now" in
					''|*[!0-9]*) running=true ;;
					*)
						if [ $((_st_now - _st_ts)) -gt 120 ]; then
							printf '1\n' >"$CLOUD_BK_RC" 2>/dev/null || true
							printf '%s\n' "任务未能启动（超过 120 秒没有进度写入），请重试。" \
								>>"$CLOUD_BK_LOG" 2>/dev/null
							rm -f "$CLOUD_BK_PID" 2>/dev/null
						else
							running=true
						fi ;;
				esac ;;
		esac
	fi

	if [ "$running" = "true" ]; then
		:
	elif [ -f "$CLOUD_BK_RC" ]; then
		done=true
		rc="$(head -n1 "$CLOUD_BK_RC" 2>/dev/null | tr -d ' \r\n')"
		case "$rc" in ''|*[!0-9]*) rc=1 ;; esac
	else
		# 进程没了又没留 rc：被中断（OOM / 手动 kill / 断电）
		done=true
		rc=124
		if ! grep -qF "任务已中断" "$CLOUD_BK_LOG" 2>/dev/null; then
			printf '%s\n' "任务已中断（进程已退出但没有结果），以上为已产生的日志。" \
				>>"$CLOUD_BK_LOG" 2>/dev/null
		fi
		printf '124\n' >"$CLOUD_BK_RC" 2>/dev/null || true
		rm -f "$CLOUD_BK_PID" 2>/dev/null
	fi

	out="$(cloud_install_log_tail "$CLOUD_BK_LOG")"
	printf '{"ok":true,"running":%s,"done":%s,"rc":"%s","log":"%s"}\n' \
		"$running" "$done" "$(jstr "$rc")" "$(jstr "$out")"
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

	# ---- a0) 本地副本先腾位置 ----
	# 本地保留 N 份（main.cloud_keep_local，默认 2）时，打包前先把旧副本
	# 轮转到 N-1 份：否则旧副本占着空间，backup.sh create 的空间预检可能
	# 直接失败，连云端备份都做不成。上传随后失败也只丢最旧一份本地副本
	# （云端仍有它），可接受。keep_local = 0 时跳过（旧行为：不保留本地）。
	if [ "$OC_SCH_KEEP_LOCAL" -ge 1 ]; then
		local pre_dir pre_dropped
		pre_dir="$(sh "$OC_CLOUD_BACKUP" path 2>/dev/null)"
		[ -n "$pre_dir" ] || pre_dir="$(oc_base_dir)/backups"
		pre_dropped="$(br_prune_local "$pre_dir" $((OC_SCH_KEEP_LOCAL - 1)) '')"
		case "$pre_dropped" in ''|*[!0-9]*) pre_dropped=0 ;; esac
		[ "$pre_dropped" -gt 0 ] && br_log \
			"打包前本地轮转：删除 ${pre_dropped} 份旧副本（本地保留 ${OC_SCH_KEEP_LOCAL} 份）"
	fi

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

	# ---- d) 本机副本：本地与云端都留存，本地按份数轮转 ----
	# 需求（2026-10-29）：定时备份不能只留云端 —— 网盘账号失效 / 断网时，
	# 本地必须还有可恢复的副本。本地与云端一样按份数轮转：
	# main.cloud_keep_local 份（默认 2；0 = 不保留本地，即旧行为）。
	#
	# keep_local >= 1：本次归档保留（a0 已提前腾位）；这里再兜底轮转一次，
	# 压回 keep_local 份总量 —— a0 之后可能有手动备份落了新文件。
	# 本次归档在排除名单里，不会被删。
	local keep_local pruned_local
	keep_local="$OC_SCH_KEEP_LOCAL"
	local_removed=false
	if [ "$keep_local" -ge 1 ]; then
		# 总量 = keep_local-1 份旧的 + 本次 1 份 = keep_local 份
		pruned_local="$(br_prune_local "$dir" $((keep_local - 1)) "$file")"
		case "$pruned_local" in ''|*[!0-9]*) pruned_local=0 ;; esac
		[ "$pruned_local" -gt 0 ] && br_log \
			"上传后本地轮转：再删除 ${pruned_local} 份旧副本（本地保留 ${keep_local} 份）"
	else
	# keep_local = 0：旧行为 —— 上传已确认成功，删掉本次创建的归档。
	# 三重校验，任一不满足都保留并记日志；删除失败也不让任务失败。
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
	fi  # keep_local = 0 的旧删除逻辑到这里结束

	br_log "完成：已上传 $remote；云端清理 $pruned 份旧备份（保留 $OC_SCH_KEEP 份），本地保留 ${keep_local} 份"
	printf '{"ok":true,"uploaded":"%s","pruned":%s,"local_removed":%s,"local_kept":%s}\n' \
		"$(jstr "$remote")" "$pruned" "$local_removed" "${keep_local:-0}"
	exit 0
}

# ---------------------------------------------------------------- dispatch
case "${1:-}" in
	status)      cmd_status "$@" ;;
	overview)    cmd_overview "$@" ;;
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
	backup-bg)       cmd_backup_bg "$@" ;;
	backup-bg-worker) shift; backup_bg_worker "$@" ;;
	backup-poll)     cmd_backup_poll ;;
	*)
		printf '{"ok":false,"error":"%s"}\n' "$(jstr "未知动作：${1:-}")"
		cat >&2 <<EOF
Usage: cloud.sh {status|install-cli|install-cli-bg [version]|install-cli-poll|cli-check|cli-update [version]|login-url|login-code <code>|logout|upload <local> <name>|ls|download <name> <local>|download-dec <name> <local>|rm <name>|pass-status|set-pass|clear-pass|encrypt-status|set-encrypt|schedule-status|schedule-apply|schedule-set|schedule-clear|backup-run}
EOF
		exit 2 ;;
esac
