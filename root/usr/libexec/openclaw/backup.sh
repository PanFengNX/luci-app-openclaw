#!/bin/sh
# openclaw - one click backup / restore
#
# 备份内容（只备份"不可再生"的部分）：
#   $BASE_DIR/home/.openclaw   配置、模型、渠道、会话、工作区数据
#   /etc/config/openclaw    UCI 设置
#
# 刻意不备份（体积大且可重新获取）：
#   $BASE_DIR/node  $BASE_DIR/openclaw  npm-cache  cache  logs
#
# ⚠️ 备份里含 API Key（.env / openclaw.json），所以归档一律 600，
#    并且在 UI 上明确提示"不要外传"。
#
# 用法：
#   backup.sh create [--name <n>] [--no-workspace]
#   backup.sh list
#   backup.sh verify <file>
#   backup.sh restore <file> [--no-safety]
#   backup.sh delete <file>
#   backup.sh path
#
# 所有输出均为单行 JSON（除 path）。
#
# 审计日志：每次 create / verify / restore / delete 的结果追加到
#   $OC_BKUPLOG（/var/log/openclaw-backup.log），格式：
#   YYYY-MM-DD HH:MM:SS <ACTION> <RESULT> <detail>
# 读取用 istorec/openclaw.sh 的 backup-log [N] 子命令。

OC_LIB="/usr/libexec/openclaw/lib.sh"
[ -f "$OC_LIB" ] || OC_LIB="$(dirname "$0")/lib.sh"
. "$OC_LIB"

BACKUP_FORMAT=1
BACKUP_DIR_NAME="backups"

# 还原时允许的最大解压体积（防 zip bomb / 塞满磁盘）
MAX_RESTORE_MB=512

backup_dir() { printf '%s/%s' "$(oc_base_dir)" "$BACKUP_DIR_NAME"; }

jstr() { oc_json_str "${1:-}"; }

# 本脚本的 stdout 契约是"只有一行 JSON"。lib.sh 的 oc_info 是往 stdout 写的
# （它是给安装日志用的进度通道），在会输出 JSON 的命令里必须换成 stderr 版本，
# 否则一行进度就会把 JSON 破坏掉。
blog() { printf '%s [INFO] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }

# ---------------------------------------------------------------- audit log
# 一行一条：YYYY-MM-DD HH:MM:SS <ACTION> <RESULT> <detail>
#   ACTION: CREATE / RESTORE / DELETE / VERIFY / PRUNE
#           （PRUNE 是保留字：轮转只做 mv，不删除归档，当前没有调用点）
#   RESULT: OK / FAIL
# detail 只放文件名、体积、重启状态这类信息，绝不放凭据。
#
# 写失败绝不能影响主流程：/var/log 在只读根文件系统上可能不可写，
# 所以整条链路以 2>/dev/null || true 收尾，函数恒定返回 0。
oc_bklog() {
	local action="$1" result="$2" detail="${3:-}" size
	case "$action" in
		CREATE|RESTORE|DELETE|VERIFY|PRUNE) ;;
		*) return 0 ;;
	esac
	case "$result" in
		OK|FAIL) ;;
		*) return 0 ;;
	esac
	# 日志按行解析：detail 里的换行/控制字符可以伪造出另一条记录，
	# 必须在写盘前全部剥掉（与 oc_json_str 的处理口径一致）。
	detail="$(printf '%s' "$detail" | tr -d '\000-\037\177')"
	[ -n "$detail" ] || detail="-"

	# 轮转：超过 512KB 就把当前文件改名保留一份，再重新开始。
	# 不用 rm、不用 logrotate：始终只留 .1 一份历史。
	if [ -f "$OC_BKUPLOG" ]; then
		size="$(wc -c <"$OC_BKUPLOG" 2>/dev/null | tr -d ' ')"
		case "$size" in ''|*[!0-9]*) size=0 ;; esac
		[ "$size" -le 524288 ] || mv -f "$OC_BKUPLOG" "$OC_BKUPLOG.1" 2>/dev/null || true
	fi

	printf '%s %s %s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" \
		"$action" "$result" "$detail" >>"$OC_BKUPLOG" 2>/dev/null || true
	return 0
}

# 当前动作的审计状态。失败记录集中在两个"出口"上，不在每个 if 分支里重复：
#   * die_json()        —— create/verify/restore/delete 的全部业务失败
#   * bk_require_dir()  —— oc_require_dir 的 exit 2（不经过 die_json）
#   * oc_restore_abort()—— INT/TERM/HUP 中断
# 成功路径在动作末尾显式调用一次 bk_finish_ok()。BK_DONE 保证每个动作
# 最多写一条记录（成功后再走到 die_json 也不会重复记 FAIL）。
BK_ACTION=""
BK_DETAIL=""
BK_DONE=0

bk_begin() { BK_ACTION="$1"; BK_DETAIL="${2:-}"; BK_DONE=0; }
bk_detail() { BK_DETAIL="${1:-}"; }

bk_finish_ok() {
	[ "$BK_DONE" = "1" ] && return 0
	[ -n "$BK_ACTION" ] || return 0
	BK_DONE=1
	oc_bklog "$BK_ACTION" OK "$BK_DETAIL"
}

bk_finish_fail() {
	[ "$BK_DONE" = "1" ] && return 0
	[ -n "$BK_ACTION" ] || return 0
	BK_DONE=1
	oc_bklog "$BK_ACTION" FAIL "$BK_DETAIL"
}

bk_size_h() {
	# bk_size_h <bytes> -> "12.3MB" / "512B"
	local b="${1:-0}"
	case "$b" in ''|*[!0-9]*) b=0 ;; esac
	awk -v b="$b" 'BEGIN {
		if (b >= 1048576) printf "%.1fMB", b / 1048576
		else printf "%dB", b
	}'
}

bk_require_dir() {
	# oc_require_dir 失败时直接 exit 2：既不输出 JSON，也不经过 die_json。
	# 放进子 shell 里跑，既保留原有的 stderr 文案与退出码，又能在退出前
	# 补一条 FAIL 审计记录。
	if ( oc_require_dir "${1:-}" ); then
		return 0
	fi
	BK_DETAIL="${BK_DETAIL:+$BK_DETAIL }安装目录不可用"
	bk_finish_fail
	exit 2
}

die_json() {
	# 所有业务失败的唯一出口：先把原因补进 detail，再记 FAIL。
	BK_DETAIL="${BK_DETAIL:+$BK_DETAIL }$1"
	bk_finish_fail
	printf '{"ok":false,"error":"%s"}\n' "$(jstr "$1")"
	exit 1
}

# ---------------------------------------------------------------- 路径约束
oc_backup_resolve() {
	# oc_backup_resolve <name|abs-path> -> prints a safe absolute archive path
	# 只接受两种输入：
	#   1) 纯文件名  -> 解析到 $BACKUP_DIR 下
	#   2) $OC_RUNDIR 下的绝对路径（LuCI 上传的临时文件）
	# 其余一律拒绝，避免通过 API 读写任意文件。
	local in="$1" d
	d="$(backup_dir)"

	case "$in" in
		'') return 1 ;;
		*/*)
			case "$in" in
				"${OC_RUNDIR:-/nonexistent}"/*) ;;
				*) return 1 ;;
			esac
			# 前缀匹配是纯字符串比较，不归一化：`$OC_RUNDIR/../..` 也能匹配上。
			# 这里必须再挡一次 `..`，否则就能引用 RUNDIR 之外的任意文件。
			case "$in" in
				*"/../"*|*"/..") return 1 ;;
			esac
			[ -f "$in" ] || return 1
			printf '%s' "$in"
			return 0
			;;
	esac

	# 纯文件名：禁止任何路径成分
	case "$in" in
		*..*) return 1 ;;
	esac
	case "$in" in
		*.tar.gz) ;;
		*) return 1 ;;
	esac
	[ -f "$d/$in" ] || return 1
	printf '%s/%s' "$d" "$in"
}

# ---------------------------------------------------------------- 归档校验
oc_archive_inspect() {
	# oc_archive_inspect <archive> -> "entries<TAB>bytes" on stdout, rc!=0 on reject
	#
	# 这是还原路径上最重要的一道防线。仅靠 tar 解压是不够的：
	#   * 绝对路径条目 / `..` 条目可以直接写到目标树之外
	#   * 符号链接 / 硬链接条目可以在目标树里埋一个指向 /etc 的链接，
	#     后续条目再顺着它写出去
	#   * 设备 / FIFO 条目同理
	# 所以这里逐条检查类型与路径，任何一条不合规就整体拒绝。
	local f="$1" tmp="$OC_RUNDIR/bk-list.$$" bad entries bytes

	# 带 PID：两个并发 verify/restore 不能共用同一份清单，否则 A 会读到
	# B 写入的合法清单而放行。写之前先 rm -f，避免该名字预先是个符号链接
	# 时被 `>` 跟随写穿（本脚本以 root 运行）。
	rm -f "$tmp" 2>/dev/null
	tar -tzvf "$f" >"$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
	[ -s "$tmp" ] || { rm -f "$tmp"; return 1; }

	# busybox/gnu tar 的 -tv 格式：<类型><权限> <属主> <大小> <日期> <时间> <名字>
	bad="$(awk '
		{
			type = substr($0, 1, 1)
			name = ""
			for (i = 6; i <= NF; i++) name = name (i > 6 ? " " : "") $i
			# busybox tar 不对名字做转义：含换行的条目名会被拆成两行，
			# 伪造出"看似合法"的清单行；链接条目还会把 " -> 目标" 打进清单。
			# 这两种都说明"靠首字符判类型"不可靠，直接拒绝。
			if (name ~ /[[:cntrl:]]/) { print "条目名含控制字符（疑似伪造清单）：" name; exit }
			if (name ~ / -> /) { print "链接条目的名字被打印进清单：" name; exit }
			if (type != "-" && type != "d") { print "非普通文件/目录的条目（" type "）：" name; exit }
			if (name ~ /^\//)    { print "绝对路径条目：" name; exit }
			if (name ~ /\.\./)   { print "含 .. 的条目：" name; exit }
			if (name !~ /^\.\//) { print "非相对路径条目：" name; exit }
		}
	' "$tmp")"
	if [ -n "$bad" ]; then
		rm -f "$tmp" 2>/dev/null
		oc_err "归档校验失败：$bad"
		return 1
	fi

	# 必须是我们自己的备份
	if ! grep -q ' \./BACKUP-INFO$' "$tmp"; then
		rm -f "$tmp" 2>/dev/null
		oc_err "缺少 BACKUP-INFO，不是本程序生成的备份"
		return 1
	fi

	entries="$(wc -l <"$tmp" 2>/dev/null | tr -d ' ')"
	bytes="$(awk '{ s=$3; if (s ~ /^[0-9]+$/) t += s } END { printf "%d", t }' "$tmp")"
	rm -f "$tmp" 2>/dev/null
	case "$entries" in ''|*[!0-9]*) entries=0 ;; esac
	case "$bytes"   in ''|*[!0-9]*) bytes=0 ;; esac

	printf '%s\t%s\n' "$entries" "$bytes"
	return 0
}

oc_archive_summary() {
	# oc_archive_summary <archive> -> 一行 JSON 片段（不含外层大括号）
	#
	# 「校验」原来只回答"安全吗"，用户看不到里面有什么 —— 150 KB 的包会让人
	# 怀疑是不是没备份全。这里把条目数、解压后体积、以及关键区域的条目数
	# 一并报出来：配置 / 数据根 / 会话 / 工作区 / 密钥文件。
	local f="$1" tmp="$OC_RUNDIR/bk-sum.$$" n_cfg n_data n_sess n_ws n_env total
	rm -f "$tmp" 2>/dev/null
	tar -tzf "$f" >"$tmp" 2>/dev/null || { rm -f "$tmp"; printf '"entries":0'; return 1; }
	total="$(wc -l <"$tmp" 2>/dev/null | tr -d ' ')"
	n_cfg="$(grep -c '^\./etc/config/openclaw$' "$tmp" 2>/dev/null)"
	n_env="$(grep -c '^\./home/\.openclaw/\.env$' "$tmp" 2>/dev/null)"
	n_sess="$(grep -c '^\./home/\.openclaw/agents/.*/sessions/' "$tmp" 2>/dev/null)"
	n_ws="$(grep -c '^\./home/\.openclaw/workspace/' "$tmp" 2>/dev/null)"
	n_data="$(grep -c '^\./home/\.openclaw/' "$tmp" 2>/dev/null)"
	rm -f "$tmp" 2>/dev/null
	for v in total n_cfg n_env n_sess n_ws n_data; do
		eval "x=\$$v"
		case "$x" in ''|*[!0-9]*) eval "$v=0" ;; esac
	done
	printf '"entries":%s,"has_config":%s,"has_env":%s,"sessions":%s,"workspace":%s,"data_files":%s' \
		"$total" "$([ "$n_cfg" -gt 0 ] && echo true || echo false)" \
		"$([ "$n_env" -gt 0 ] && echo true || echo false)" "$n_sess" "$n_ws" "$n_data"
	return 0
}

oc_archive_ok_size() {
	# 体积上限检查：解压后不得超过 MAX_RESTORE_MB（防 zip bomb / 塞满磁盘）
	local f="$1" bytes
	bytes="$(tar -tzvf "$f" 2>/dev/null | awk '{ s=$3; if (s ~ /^[0-9]+$/) t += s } END { printf "%d", t }')"
	case "$bytes" in ''|*[!0-9]*) bytes=0 ;; esac
	[ "$bytes" -le $((MAX_RESTORE_MB * 1048576)) ] || return 1
	return 0
}

# ---------------------------------------------------------------- create
cmd_create() {
	local name="" ws=1 data_override=""
	while [ $# -gt 0 ]; do
		case "$1" in
			--name) shift; name="${1:-}"; [ $# -eq 0 ] || shift ;;
			--no-workspace) ws=0; shift ;;
			--data-dir) shift; data_override="${1:-}"; [ $# -eq 0 ] || shift ;;
			*) shift ;;
		esac
	done

	bk_begin CREATE
	bk_require_dir "$(oc_base_dir)"
	local base home data dir stamp out stage ts
	base="$(oc_base_dir)"
	home="$(oc_home_dir)"
	data="$(oc_data_dir)"
	# --data-dir 是给 migrate 用的内部参数：migrate 可能在「当前 UCI 的
	# state_dir 指向外部目录、但即将被替换的是 base 内的物理目标」时，
	# 需要快照后者而不是 oc_data_dir()。只接受绝对路径并复用 base_dir 的
	# 形态校验，避免把 /etc 之类的位置当数据目录打包。
	if [ -n "$data_override" ]; then
		data_override="${data_override%/}"
		oc_validate_base_dir_shape "$data_override" \
			|| die_json "非法的数据目录：$data_override"
		data="$data_override"
	fi
	dir="$(backup_dir)"

	[ -d "$data" ] || die_json "数据目录不存在：$data（尚未安装或未初始化？）"

	mkdir -p "$dir" || die_json "无法创建备份目录 $dir"
	chmod 700 "$dir" 2>/dev/null
	# 与文件级权限处理保持一致：目录收紧失败同样要告警，不能静默放过
	# （0755 的目录会让其他本地用户枚举出备份文件名与数量）。
	local dmode
	dmode="$(stat -c %a "$dir" 2>/dev/null)"
	case "$dmode" in
		700) ;;
		'')  oc_warn "无法确认备份目录权限，请自行确认 $dir 不可被他人访问" ;;
		*)   oc_warn "备份目录权限为 $dmode（期望 700）：$dir" ;;
	esac

	stamp="$(date +%Y%m%d-%H%M%S)"
	if [ -n "$name" ]; then
		case "$name" in
			*[!A-Za-z0-9._-]*) die_json "备份名只能包含字母数字与 . _ -" ;;
			# `..` 能通过上面的字符集，但 oc_backup_resolve 对纯文件名一律
			# 拒绝含 `..` 的输入 —— 那样会造出无法 verify/delete/restore 的备份。
			*..*) die_json "备份名不能包含 .." ;;
		esac
		out="$dir/openclaw-backup-$stamp-$name.tar.gz"
	else
		out="$dir/openclaw-backup-$stamp.tar.gz"
	fi
	# 后续失败（空间不足、复制失败、打包失败）都能带上目标文件名
	bk_detail "$(basename "$out")"

	# 需要的空间 ≈ 数据目录大小；先粗查一下
	local need
	need="$(du -sm "$data" 2>/dev/null | awk '{print $1}')"
	case "$need" in ''|*[!0-9]*) need=0 ;; esac
	local free
	free="$(oc_free_mb "$dir")"
	case "$free" in ''|*[!0-9]*) free=0 ;; esac
	if [ "$need" -gt 0 ] && [ "$free" -lt $((need + 8)) ]; then
		die_json "备份空间不足：需要约 ${need}MB，可用 ${free}MB"
	fi
	# 归档不是直接从 $data 生成的：先 cp -a 到 $OC_RUNDIR 下的暂存目录，
	# 而 $OC_RUNDIR 在 OpenWrt 上通常是 tmpfs。上面那次检查查的是 $dir 所在
	# 文件系统，漏掉了真正会被写满的暂存目标，这里补上。
	local stage_free
	stage_free="$(oc_free_mb "$OC_RUNDIR")"
	case "$stage_free" in ''|*[!0-9]*) stage_free=0 ;; esac
	if [ "$need" -gt 0 ] && [ "$stage_free" -gt 0 ] && [ "$stage_free" -lt $((need + 8)) ]; then
		die_json "暂存空间不足：复制数据目录需要约 ${need}MB，$OC_RUNDIR 可用 ${stage_free}MB"
	fi

	stage="$OC_RUNDIR/bkstage.$$"
	# 只回收 60 分钟以上的陈旧残留。无差别 rm -rf 会连另一个并发实例正在
	# 使用的暂存目录一起删掉（restore 的安全快照就是通过 create 并发跑起来的）。
	find "$OC_RUNDIR" -maxdepth 1 -name 'bkstage.*' -mmin +60 -exec rm -rf {} \; 2>/dev/null
	rm -rf "$stage"
	mkdir -p "$stage/etc/config" "$stage/home" || die_json "无法创建暂存目录"
	# 被打断也要清掉（/tmp 是 tmpfs，残留会一直占内存）
	trap 'rm -rf "${stage:-}" 2>/dev/null' EXIT INT TERM HUP

	cp /etc/config/openclaw "$stage/etc/config/openclaw" 2>/dev/null
	cp -a "$data" "$stage/home/.openclaw" 2>/dev/null || {
		rm -rf "$stage"; die_json "复制数据目录失败"
	}

	# 清单：还原时用它确认"这是我们自己的备份"
	{
		printf 'format=%s\n' "$BACKUP_FORMAT"
		printf 'created=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
		printf 'openclaw=%s\n' "$(uci_get main.oc_version 'unknown')"
		printf 'node=%s\n' "$(uci_get main.node_version 'unknown')"
		printf 'base_dir=%s\n' "$base"
		printf 'data_dir=%s\n' "$data"
		printf 'openclaw_dir=%s\n' "$(oc_oc_dir)"
		printf 'arch=%s\n' "$(oc_arch)"
		printf 'system=OpenWrt %s\n' "$(oc_sys_version)"
		printf 'with_workspace=%s\n' "$ws"
	} >"$stage/BACKUP-INFO"

	# 排除运行时产物：日志、缓存、临时文件、锁。
	# 用 set -- 逐个传参而不是拼成一个字符串：拼字符串时 *.log 可能先被
	# shell 做 glob 展开，tar 就会收到错误的排除模式。
	set -- --exclude='*.log' --exclude='logs' --exclude='log' \
		--exclude='cache' --exclude='tmp' --exclude='*.tmp' \
		--exclude='*.lock' --exclude='*.pid' --exclude='*.sock' \
		--exclude='node_modules'
	[ "$ws" = "1" ] || set -- "$@" --exclude='workspace'

	if ! tar -czf "$out" -C "$stage" "$@" . 2>"$OC_RUNDIR/bk-tar.err"; then
		rm -rf "$stage"
		rm -f "$out"
		die_json "打包失败：$(head -n1 "$OC_RUNDIR/bk-tar.err" 2>/dev/null)"
	fi
	rm -rf "$stage"

	chmod 600 "$out" 2>/dev/null

	# 有些文件系统上 chmod 不生效（挂载选项、非 POSIX 后端）。备份里含 API Key，
	# 所以不能静默放过：收紧失败要明确告警，并把实际权限回报给 UI。
	local mode
	mode="$(stat -c %a "$out" 2>/dev/null)"
	case "$mode" in
		600|400) ;;
		'') oc_warn "无法确认备份文件权限，请自行确认 $out 不可被他人读取" ;;
		*)  oc_warn "备份文件权限为 $mode（期望 600）。该文件含 API Key，请手动执行：chmod 600 $out" ;;
	esac

	ts="$(date +%s)"
	local size
	size="$(wc -c <"$out" 2>/dev/null | tr -d ' ')"
	case "$size" in ''|*[!0-9]*) size=0 ;; esac

	blog "已创建备份 $out (${size} 字节)"
	bk_detail "$(basename "$out") $(bk_size_h "$size")"
	bk_finish_ok
	printf '{"ok":true,"file":"%s","size":%s,"created":%s,"mode":"%s","contains_secrets":true}\n' \
		"$(jstr "$(basename "$out")")" "$size" "$ts" "$(jstr "${mode:-unknown}")"
}

# ---------------------------------------------------------------- list
cmd_list() {
	local dir first=1 f n size ts
	dir="$(backup_dir)"
	printf '['
	[ -d "$dir" ] || { printf ']\n'; return 0; }
	# 新的在前
	for f in $(ls -1t "$dir"/openclaw-backup-*.tar.gz 2>/dev/null); do
		[ -f "$f" ] || continue
		n="$(basename "$f")"
		size="$(wc -c <"$f" 2>/dev/null | tr -d ' ')"
		case "$size" in ''|*[!0-9]*) size=0 ;; esac
		ts="$(date -r "$f" +%s 2>/dev/null)"
		case "$ts" in ''|*[!0-9]*) ts=0 ;; esac
		[ "$first" = "1" ] || printf ','
		first=0
		printf '{"file":"%s","size":%s,"mtime":%s}' "$(jstr "$n")" "$size" "$ts"
	done
	printf ']\n'
}

# ---------------------------------------------------------------- verify
cmd_verify() {
	local in="$1" p
	bk_begin VERIFY "$in"
	p="$(oc_backup_resolve "$in")" || die_json "非法的备份文件引用：$in"
	[ -f "$p" ] || die_json "备份不存在：$in"

	if ! oc_archive_ok_size "$p"; then
		die_json "归档解压体积超过 ${MAX_RESTORE_MB}MB 上限，已拒绝"
	fi
	if ! oc_archive_inspect "$p" >/dev/null; then
		die_json "归档未通过安全校验（路径越界 / 链接 / 设备文件 / 缺少清单）"
	fi
	local vsize
	vsize="$(wc -c <"$p" 2>/dev/null | tr -d ' ')"
	case "$vsize" in ''|*[!0-9]*) vsize=0 ;; esac
	bk_detail "$(basename "$p") $(bk_size_h "$vsize")"
	local sum
	sum="$(oc_archive_summary "$p")"
	bk_finish_ok
	printf '{"ok":true,"file":"%s","size":%s,%s}\n' "$(jstr "$(basename "$p")")" "$vsize" "$sum"
}

# ---------------------------------------------------------------- restore
cmd_restore() {
	local in="" safety=1
	while [ $# -gt 0 ]; do
		case "$1" in
			--no-safety) safety=0; shift ;;
			*) [ -z "$in" ] && in="$1"; shift ;;
		esac
	done
	bk_begin RESTORE "$in"
	[ -n "$in" ] || die_json "未指定备份文件"

	bk_require_dir "$(oc_base_dir)"
	local p
	p="$(oc_backup_resolve "$in")" || die_json "非法的备份文件引用：$in"

	# 1) 先校验，再动任何东西
	if ! oc_archive_ok_size "$p"; then
		die_json "归档解压体积超过 ${MAX_RESTORE_MB}MB 上限，已拒绝"
	fi
	oc_archive_inspect "$p" >/dev/null || die_json "归档未通过安全校验，已拒绝还原"

	# 2) 安全快照：还原失败时还能回去
	local safety_file=""
	if [ "$safety" = "1" ]; then
		local before
		before="$(cmd_create --name "pre-restore" 2>/dev/null)"
		case "$before" in
			*'"ok":true'*)
				safety_file="$(printf '%s' "$before" | sed -n 's/.*"file":"\([^"]*\)".*/\1/p')"
				;;
		esac
		[ -n "$safety_file" ] || oc_warn "未能创建还原前快照，继续（--no-safety 可静默跳过）"
	fi

	# 3) 停网关（配置正在被替换）
	[ -x /etc/init.d/openclaw ] && /etc/init.d/openclaw stop >/dev/null 2>&1

	# 4) 解压到暂存区（绝不直接解到目标树）
	# home/data 必须在装 trap 之前就定义好：中断处理函数会用到它们。
	local home data
	home="$(oc_home_dir)"
	data="$(oc_data_dir)"

	local stage terr old="" moved=0
	stage="$OC_RUNDIR/restore.$$"
	terr="$OC_RUNDIR/bk-tar.$$.err"
	# 同上：只回收陈旧残留，避免删掉并发实例正在用的目录。
	find "$OC_RUNDIR" -maxdepth 1 -name 'restore.*' -mmin +60 -exec rm -rf {} \; 2>/dev/null
	rm -rf "$stage"
	mkdir -p "$stage" || die_json "无法创建暂存目录"

	# 中断处理分两级：
	#   EXIT         只清暂存区（正常路径也走这里，行为不变）
	#   INT/TERM/HUP 还要把数据目录从 $old 挪回去 —— 否则 mv 之后被中断会留下
	#                "数据目录不存在"的半残状态，网关重启会以空数据起。
	oc_restore_cleanup() { rm -rf "${stage:-}" 2>/dev/null; }
	oc_restore_abort() {
		oc_restore_cleanup
		if [ "$moved" = "1" ] && [ -n "${old:-}" ] && [ -d "$old" ] && [ ! -d "$data" ]; then
			mv "$old" "$data" 2>/dev/null && moved=0
		fi
		exit 1
	}
	trap 'oc_restore_cleanup' EXIT
	trap 'oc_restore_abort' INT TERM HUP

	rm -f "$terr" 2>/dev/null
	if ! tar -xzf "$p" -C "$stage" 2>"$terr"; then
		rm -rf "$stage"
		die_json "解压失败：$(head -n1 "$terr" 2>/dev/null)"
	fi
	rm -f "$terr"

	# 5) UCI 配置
	if [ -f "$stage/etc/config/openclaw" ]; then
		cp "$stage/etc/config/openclaw" /etc/config/openclaw 2>/dev/null \
			|| oc_warn "写入 /etc/config/openclaw 失败"
	fi

	# 6) 数据目录（整体替换，先移到一边以便失败回滚）
	if [ -d "$stage/home/.openclaw" ]; then
		mkdir -p "$home" 2>/dev/null
		# 名字带 PID：既不与上一次中断留下的残留同名（否则下面那句 rm -rf
		# 会把唯一一份原数据删掉），也让中断 trap 能精确回滚。
		old="$home/.openclaw.pre-restore.$$"
		rm -rf "$old" 2>/dev/null
		if [ -d "$data" ]; then
			if mv "$data" "$old" 2>/dev/null; then
				moved=1
			else
				# mv 失败必须立刻中止：若继续 cp -a 而 $data 仍在，
				# 内容会被嵌成 $data/.openclaw，还原结果静默错误。
				rm -rf "$stage"
				die_json "无法移动现有数据目录 $data（原数据未改动，已中止）"
			fi
		fi
		if ! cp -a "$stage/home/.openclaw" "$data" 2>/dev/null; then
			rm -rf "$data" 2>/dev/null
			[ "$moved" = "1" ] && mv "$old" "$data" 2>/dev/null && moved=0
			rm -rf "$stage"
			die_json "写入数据目录失败，已回滚到还原前状态"
		fi
		# 只有确实搬走了原数据才删，否则会把"没搬动的原目录"误删
		[ "$moved" = "1" ] && rm -rf "$old" 2>/dev/null
		moved=0
	else
		oc_warn "备份里没有 home/.openclaw，数据目录保持不变"
	fi

	rm -rf "$stage"

	# 7) 凭据文件重新收紧权限，并修正属主
	[ -f "$data/.env" ] && chmod 600 "$data/.env" 2>/dev/null
	oc_fix_perms >/dev/null 2>&1

	# 8) 起网关
	local started=0
	if [ -x /etc/init.d/openclaw ]; then
		/etc/init.d/openclaw start >/dev/null 2>&1 && started=1
	fi

	blog "已从备份还原：$(basename "$p")"
	bk_detail "$(basename "$p")"
	bk_finish_ok
	printf '{"ok":true,"file":"%s","safety_backup":"%s","restarted":%s}\n' \
		"$(jstr "$(basename "$p")")" "$(jstr "$safety_file")" \
		"$([ "$started" = "1" ] && echo true || echo false)"
}

# ---------------------------------------------------------------- delete
cmd_delete() {
	local in="$1" p
	[ -n "$in" ] || die_json "未指定备份文件"
	p="$(oc_backup_resolve "$in")" || die_json "非法的备份文件引用：$in"
	# 审计：$p 已是解析后的绝对路径，日志里只记文件名（与 create/verify 口径一致）。
	# 放在解析之后、真正删除之前：解析失败的非法调用不产生记录，失败分支统一由
	# die_json 记 FAIL，这里不重复记。
	bk_begin DELETE "$(basename "$p")"
	# 只允许删备份目录里的文件（oc_backup_resolve 已保证），再确认一次
	case "$p" in
		"$(backup_dir)"/*) ;;
		*) die_json "只允许删除备份目录内的文件" ;;
	esac
	rm -f "$p" || die_json "删除失败"
	bk_finish_ok
	printf '{"ok":true,"file":"%s"}\n' "$(jstr "$(basename "$p")")"
}

# ---------------------------------------------------------------- dispatch
case "${1:-}" in
	create)  shift; cmd_create "$@" ;;
	list)    cmd_list ;;
	verify)  shift; cmd_verify "$@" ;;
	restore) shift; cmd_restore "$@" ;;
	delete)  shift; cmd_delete "$@" ;;
	path)    backup_dir; printf '\n' ;;
	*)
		cat <<EOF
Usage: backup.sh {create [--name n] [--no-workspace]|list|verify <f>|restore <f> [--no-safety]|delete <f>|path}
EOF
		exit 1
		;;
esac
