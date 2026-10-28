#!/bin/sh
# openclaw - luci-app-openclaw 自更新（GitHub Release）
#
# 只在 LuCI「安装」页被显式点击时调用。约定：
#   * stdout 只有一个 JSON 文档；进度、诊断一律走 stderr 与 $LOG；
#   * 目标仓库固定为 PanFengNX/luci-app-openclaw，资产下载地址必须是
#     该仓库 releases/download 下的 https 地址；
#   * Release tag 必须是严格的数字版本号，解析不出来就不判定为可更新；
#   * 下载有连接/总超时与大小上限，落在私有 0700 目录；
#   * Release 提供 SHA256 时校验，不匹配直接拒绝安装；
#   * 安装前把当前已安装文件打成回滚包（最多保留 2 份，失败不删）；
#   * 安装成功后才刷新 rpcd / LuCI 缓存。
#
# 子命令：
#   check                检查最新 Release（不下载、不安装）
#   install --confirm 1  用户已确认，下载 + 校验 + 备份 + 安装（后台执行）
#   status               读取当前状态与日志尾部
#   rollback             用最近一份回滚包恢复

OC_LIB="/usr/libexec/openclaw/lib.sh"
. "$OC_LIB"

GH_REPO="PanFengNX/luci-app-openclaw"
GH_API="https://api.github.com/repos/$GH_REPO/releases/latest"
GH_DL_PREFIX="https://github.com/$GH_REPO/releases/download/"

PKG_NAME="luci-app-openclaw"
MAX_BYTES=8388608      # 8 MiB：本包是纯脚本，正常只有几十 KB
FETCH_TIMEOUT=30       # 元数据 / 校验和：30s
PKG_TIMEOUT=180        # 插件包本体：3min
MAX_ASSET_SCAN=64      # Release 里最多扫描的资产数

WORK="$OC_RUNDIR/github-update"
ROLLBACK_DIR="$WORK/rollback"
LOG="$WORK/update.log"
STATE="$WORK/state"
LOCK="$WORK/lock"
# check 的产物必须是**一份**原子快照，不能是四个独立文件。
#
# 为什么：以前 check 依次写 version / url / digest / name 四个文件，install
# 再逐个读。两次 check 并发（或一次 check 与一次 install 交错）时，install
# 可能读到"上次的版本号 + 这次的名字 + 另一个 digest"这种混合组合，要么
# 校验失败、要么把 A 版本的资产名配 B 版本的 digest。虽然 SHA256 能挡住
# 装错包，但状态本身不该出现撕裂。
# 现在：check 写临时文件后 rename 覆盖；rename 在同一文件系统上是原子的，
# install 只读这一个文件，拿到的永远是某一次 check 的完整结果。
CANDIDATE_FILE="$WORK/candidate"
# 临时文件必须带本进程 pid：`check` 不持锁（它是只读查询，持锁会和后台安装
# 互相阻塞），并发两次 check 若共用同一个 candidate.tmp，会互相截断/覆盖，
# 甚至把 rename 变成"半个文件"。带 pid 后每份写入独立，rename 仍原子，
# 最后一次完成的那份生效；install 只读一次快照，因此永远拿到完整组合。
CANDIDATE_TMP="$WORK/candidate.tmp.$$"

# ---------------------------------------------------------------- output
#
# stdout 契约：**只有一行 JSON**。
#
# ⚠️ stderr 也不能随便写：LuCI 控制器用 `cmd >out 2>&1` 捕获输出
# （见 lib.sh 的 run_capture 同款写法），stderr 会被合进同一份文本，
# 于是「诊断行 + JSON」让 jsonc.parse 失败，前端只看到「无法解析」，
# 真正的原因反而被吞掉。所以诊断一律只进 $LOG 文件，由 status 子命令
# 读回给页面；stderr 只在日志文件不可写时才兜底输出。
json() { printf '%s\n' "$1"; }
msg() {
	printf '%s %s\n' "$(date '+%H:%M:%S' 2>/dev/null)" "$*" >>"$LOG" 2>/dev/null && return 0
	printf '%s\n' "$*" >&2
	return 0
}
jstr() { oc_json_str "$1"; }
fail() { msg "$1"; json "{\"ok\":false,\"state\":\"failed\",\"error\":\"$(jstr "$1")\"}"; }

# ---------------------------------------------------------------- dirs
_perm_ok() {
	# _perm_ok <dir> —— 必须 0700、属主 uid=0、且非符号链接
	#
	# 这里放的是下载的包、回滚归档和它们的 sha256 sidecar。如果目录不是
	# root 独占，同目录的写入者可以把"归档 + sidecar"一起替换并重算哈希，
	# 校验就失去意义。所以属主与权限都必须强制成立，不接受"chown 失败也继续"。
	local d="$1" owner mode
	[ -d "$d" ] || return 1
	[ -L "$d" ] && return 1
	owner="$(stat -c %u "$d" 2>/dev/null)"
	mode="$(stat -c %a "$d" 2>/dev/null)"
	[ "$owner" = "0" ] || { msg "私有目录 $d 属主不是 root（uid=${owner:-未知}），拒绝继续"; return 1; }
	[ "$mode" = "700" ] || { msg "私有目录 $d 权限不是 700（实际 ${mode:-未知}），拒绝继续"; return 1; }
	return 0
}

_chain_ok() {
	# _chain_ok <dir> —— 校验从 <dir> 到 / 的整条父链
	#
	# 只钉末级目录不够：父目录可被非 root 写入时，攻击者可以在校验之后
	# rename 掉整棵子树、换成同名目录，后续写入全部落到替换后的目录里。
	#
	# 判据（对每一级）：
	#   * 必须是目录、不能是符号链接；
	#   * 属主必须是 root；
	#   * 若组/其他可写，则必须带 sticky 位（/tmp 这种标准写法）。
	# 最后一条是为了不把 /tmp 判死 —— 它是 1777，但有 sticky 位时非 root
	# 无法删除/重命名别人的条目，链仍然成立。
	local d="$1" owner mode perm special tmp g o writable
	# 拒绝含 .. 的输入：dirname 会把它规范化，校验对象与实际写入对象不一致。
	case "$d" in *..*) msg "路径含 .. 段（$d），拒绝继续"; return 1 ;; esac
	while [ -n "$d" ] && [ "$d" != "/" ]; do
		[ -d "$d" ] || { msg "路径组件 $d 不存在，拒绝继续"; return 1; }
		[ -L "$d" ] && { msg "路径组件 $d 是符号链接，拒绝继续"; return 1; }
		owner="$(stat -c %u "$d" 2>/dev/null)"
		mode="$(stat -c %a "$d" 2>/dev/null)"
		# 解析 mode 为八进制三位（ugo）+ 可选首位特殊位。
		# `%a` 对 0700 通常输出 "700"，对 /tmp 的 01777 输出 "1777"。
		# 首位特殊位中，sticky 是位 1（八进制值 1/3/5/7），不能只匹配
		# 字符 `1`；否则合法的 3777 会被误判成"无 sticky"。
		case "$mode" in *[!0-7]*|'') msg "无法读取 $d 的权限位，拒绝继续"; return 1 ;; esac
		case "${#mode}" in
			3) perm="$mode"; special=0 ;;
			4) special="${mode%???}"; perm="${mode#?}" ;;
			*) msg "权限位格式异常（$d mode=$mode），拒绝继续"; return 1 ;;
		esac
		# 提取 u/g/o 三位（纯字符串操作，不依赖 shell 八进制算术）。
		tmp="${perm#?}"
		g="${tmp%?}"
		o="${tmp#?}"
		writable=0
		case "$g" in 2|3|6|7) writable=1 ;; esac
		case "$o" in 2|3|6|7) writable=1 ;; esac
		if [ "$writable" -eq 1 ]; then
			case "$special" in 1|3|5|7) : ;; *)
				msg "路径组件 $d 可被非 root 写入且无 sticky 位（mode=$mode），拒绝继续"
				return 1
			;; esac
		fi
		d="$(dirname "$d" 2>/dev/null)"
	done
	return 0
}

_under_rundir() {
	# _under_rundir <path> <label> -> 0 表示该路径是本插件私有根下的安全子路径
	#
	# 判据（三层，缺一不可）：
	#   1) 必须以 "$OC_RUNDIR/" 开头 —— 否则它根本不是本插件的目录；
	#   2) 相对部分不得含 '.' 或 '..' 段 —— 否则 "$OC_RUNDIR/.." 这种写法
	#      会通过前缀检查却实际指向父目录，随后 chmod/chown 会作用到
	#      预期之外的目录（这是真实漏洞，不是理论风险）；
	#   3) 相对部分不得出现空段（连续斜杠）。
	# 注意**允许**多级（如 $OC_RUNDIR/github-update/rollback），
	# 因为 ROLLBACK_DIR 本来就是 WORK 的子目录；只禁特殊段与空段。
	local p="$1" label="$2" rest seg
	case "$p" in
		"$OC_RUNDIR"/*) rest="${p#"$OC_RUNDIR"/}" ;;
		*) msg "$label 不在 OC_RUNDIR 私有根下（$p），拒绝继续"; return 1 ;;
	esac
	case "$rest" in ''|/*) msg "$label 路径非法（$p），拒绝继续"; return 1 ;; esac
	# 逐段拆分，避免 `for x in $rest` 的 pathname glob 展开。
	while :; do
		case "$rest" in
			*/*) seg="${rest%%/*}"; rest="${rest#*/}" ;;
			*) seg="$rest"; rest="" ;;
		esac
		case "$seg" in
			'') msg "$label 路径含空段（$p），拒绝继续"; return 1 ;;
			.|..) msg "$label 路径含 . 或 .. 段（$p），拒绝继续"; return 1 ;;
			# 通配符不该出现在目录名里；出现就说明变量被人为拼接过，
			# 后续 glob 展开会作用到一批意料之外的路径。
			*'*'*|*'?'*|*'['*) msg "$label 路径含通配符（$p），拒绝继续"; return 1 ;;
		esac
		[ -n "$rest" ] || break
	done
	return 0
}

init_dirs() {
	# 顺序很重要：**先断言路径拓扑与父链，再动目录**。
	# 若先 mkdir/chmod/chown 再检查归属，那么"路径异常"的情况也已经
	# 对错误的目录执行过 chown 0:0 / chmod 700 —— 那是不可接受的副作用。
	[ -n "$OC_RUNDIR" ] || return 1
	[ -L "$OC_RUNDIR" ] && return 1

	_under_rundir "$WORK" "更新工作目录" || return 1
	_under_rundir "$ROLLBACK_DIR" "回滚目录" || return 1
	# 回滚目录必须在自己那份工作目录之下：它们是同一批产物，
	# 不能出现"归档在一处、包副本在另一处"还能通过校验的情况。
	case "$ROLLBACK_DIR" in
		"$WORK"/*) : ;;
		*) msg "回滚目录必须在更新工作目录之下（$ROLLBACK_DIR），拒绝继续"; return 1 ;;
	esac

	# 此时 OC_RUNDIR 已存在（lib.sh 建好），先校验它到 / 的整条链。
	_chain_ok "$OC_RUNDIR" || return 1

	mkdir -p "$WORK" 2>/dev/null || return 1
	[ -L "$WORK" ] && return 1
	mkdir -p "$ROLLBACK_DIR" 2>/dev/null || return 1
	[ -L "$ROLLBACK_DIR" ] && return 1
	# chmod 与 chown 都必须成功：更新器要装包，本身就必须以 root 运行，
	# 所以这里不存在"以普通用户合法运行"的场景。任何一步失败都直接拒绝，
	# 不写"失败也继续"的分支 —— 那种分支等于把私有性降级成口头承诺。
	chmod 700 "$WORK" "$ROLLBACK_DIR" 2>/dev/null || {
		msg '无法把私有目录收紧到 700，拒绝继续'
		return 1
	}
	chown 0:0 "$WORK" "$ROLLBACK_DIR" 2>/dev/null || {
		msg '无法把私有目录属主改为 root，拒绝继续（更新器必须以 root 运行）'
		return 1
	}
	_perm_ok "$WORK" || return 1
	_perm_ok "$ROLLBACK_DIR" || return 1
	: >>"$LOG" 2>/dev/null || return 1
	return 0
}

# ---------------------------------------------------------------- version
ver_norm() { printf '%s' "${1#v}"; }

version_ok() {
	# 1..3 段十进制数字
	local v
	v="$(ver_norm "${1:-}")"
	case "$v" in
		''|.*|*.|*..*|*[!0-9.]*) return 1 ;;
	esac
	[ "$(printf '%s' "$v" | awk -F. '{print NF}')" -le 3 ] || return 1
	return 0
}

ver_cmp() {
	# ver_cmp <a> <b> -> "-1" | "0" | "1"（逐段数字比较，缺失段按 0）
	printf '%s\n%s\n' "$(ver_norm "$1")" "$(ver_norm "$2")" | awk -F. '
		NR == 1 { for (i = 1; i <= 3; i++) a[i] = ($i == "" ? 0 : $i) + 0 }
		NR == 2 {
			for (i = 1; i <= 3; i++) {
				b = ($i == "" ? 0 : $i) + 0
				if (a[i] < b) { print "-1"; exit }
				if (a[i] > b) { print "1"; exit }
			}
			print "0"
		}'
}

current_version() {
	# 已安装版本：成功输出版本号；未安装输出 0.0.0；解析失败输出空串。
	# 解析失败绝不能拿兜底值顶上 —— 那会把"不知道"说成某个具体版本，
	# 从而把降级误判成升级。
	local v="" found=0
	if command -v apk >/dev/null 2>&1; then
		# 直接读已安装数据库，而不是 `apk info -e` 的输出：后者在 apk v2
		# （只打印包名）与 v3（打印 name-version）之间格式不一致，靠它解析
		# 版本号会在一类设备上永远得到空串，前端随之停在「检查中」。
		# /lib/apk/db/installed 的 P:/V: 段落格式在两个大版本间是稳定的。
		v="$(awk -v p="$PKG_NAME" '
			$0 == "P:" p { f = 1; next }
			/^$/ { f = 0 }
			f && /^V:/ { print substr($0, 3); exit }
		' /lib/apk/db/installed 2>/dev/null)"
		[ -n "$v" ] && found=1
	else
		v="$(opkg status "$PKG_NAME" 2>/dev/null | sed -n 's/^Version: //p' | head -n1)"
		[ -n "$v" ] && found=1
	fi
	if [ "$found" -eq 0 ]; then printf '0.0.0'; return 0; fi
	# 只取开头的数字版本段，丢掉 -r1 / -1 之类的包修订号
	v="$(printf '%s' "$v" | sed -n 's/^\([0-9][0-9.]*\).*/\1/p')"
	version_ok "$v" || { printf ''; return 1; }
	printf '%s' "$v"
}

asset_hint() {
	# 仅用于错误提示；真正匹配由 asset_name_ok 完成。
	if command -v apk >/dev/null 2>&1; then
		printf '%s-%s-r<数字>.apk' "$PKG_NAME" "$1"
	else
		printf '%s_%s_all.ipk' "$PKG_NAME" "$1"
	fi
}

asset_name_ok() {
	# asset_name_ok <name> <ver>
	# APK 只接受 luci-app-openclaw-<ver>-r<纯数字>.apk：
	# 带 -v2 / -signed 等后缀的变体一律拒绝。
	local name="$1" ver="$2" rel
	if command -v apk >/dev/null 2>&1; then
		case "$name" in "$PKG_NAME-$ver-r"*.apk) : ;; *) return 1 ;; esac
		rel="${name#"$PKG_NAME-$ver-r"}"
		rel="${rel%.apk}"
		case "$rel" in ''|*[!0-9]*) return 1 ;; esac
	else
		# ⚠️ 必须用 ${PKG_NAME} 形式。写成 "$PKG_NAME\_$ver\_all.ipk" 时，
		# 双引号内的反斜杠不会转义下划线，模式里会带上**字面反斜杠**，
		# 于是永远匹配不到真实资产名（实测：匹配失败）。
		[ "$name" = "${PKG_NAME}_${ver}_all.ipk" ] || return 1
	fi
	return 0
}

# ---------------------------------------------------------------- github
need_tools() {
	command -v curl >/dev/null 2>&1 || { fail '缺少 curl，无法访问 GitHub Release'; return 1; }
	command -v jsonfilter >/dev/null 2>&1 || { fail '缺少 jsonfilter，无法解析 Release'; return 1; }
	return 0
}

# curl 退出码 -> 可读原因。只映射有把握的值，其余原样带回（"未知"比猜错好）。
_curl_rc_text() {
	case "$1" in
		5|6)  printf '域名解析失败（DNS 无法解析 github.com）' ;;
		7)    printf '无法建立连接（对端不可达或被拦截）' ;;
		28)   printf '连接或传输超时' ;;
		35)   printf 'TLS 握手失败' ;;
		51|60) printf 'TLS 证书校验失败（设备可能未安装 CA 证书，试试 opkg 安装 ca-certificates）' ;;
		63)   printf '响应超过大小上限' ;;
		*)    printf 'curl 错误（rc=%s）' "$1" ;;
	esac
}

api_get() {
	# api_get <url> <dest> <max-time>   —— 固定 https、限大小
	#
	# 失败时把真实原因放进 API_GET_ERR 供调用方回显：
	# 以前一律报「网络或仓库不可达」，DNS 失败 / 403 频率超限 / 证书缺失
	# 三种完全不同的故障只能看到同一句话，根本无从排查。
	local url="$1" dest="$2" mt="$3" proxy out rc code
	API_GET_ERR=""
	case "$url" in
		https://api.github.com/repos/*|"$GH_DL_PREFIX"*) : ;;
		*) msg "拒绝非白名单地址：$url"; return 1 ;;
	esac
	# 遵循插件设置页已配置的代理（main.http_proxy）。GitHub 在很多网络下
	# 直连不可达，不配代理时检查永远失败；代理地址仍要过安全校验。
	proxy="$(uci_get main.http_proxy '')"
	if [ -n "$proxy" ]; then
		if oc_safe_url "$proxy"; then
			msg "访问 GitHub 使用已配置代理"
		else
			msg "UCI 中的代理地址不合法，已忽略"
			proxy=""
		fi
	fi
	# 不用 -f：它把 HTTP 403 / 404 与网络故障混成同一个 rc=22。
	# 改为读取 %{http_code} 自行判定，再按 curl 退出码映射真实原因。
	set -- -sSL --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time "$mt" \
		--max-filesize "$MAX_BYTES" \
		-H 'User-Agent: luci-app-openclaw-updater' \
		-H 'Accept: application/vnd.github+json' \
		-o "$dest" -w 'OC_HTTP_CODE:%{http_code}'
	[ -n "$proxy" ] && set -- "$@" -x "$proxy"
	out="$(curl "$@" "$url" 2>&1)"; rc=$?
	if [ "$rc" -ne 0 ]; then
		API_GET_ERR="$(_curl_rc_text "$rc")"
		msg "下载失败：$url（$API_GET_ERR）"
		rm -f "$dest" 2>/dev/null
		return 1
	fi
	code="$(printf '%s\n' "$out" | sed -n 's/^OC_HTTP_CODE://p' | tail -n 1)"
	case "$code" in
		2*)  return 0 ;;
		403) API_GET_ERR='GitHub 拒绝访问（HTTP 403：API 请求频率超限或地区限制，请稍后再试或配置代理）' ;;
		404) API_GET_ERR='Release 不存在（HTTP 404）' ;;
		'')  API_GET_ERR='服务器未返回有效的 HTTP 状态' ;;
		*)   API_GET_ERR="GitHub 返回 HTTP $code" ;;
	esac
	msg "下载失败：$url（$API_GET_ERR）"
	rm -f "$dest" 2>/dev/null
	return 1
}

a_field() { jsonfilter -i "$1" -e "@.assets[$2].$3" 2>/dev/null | head -n1; }

find_asset() {
	# find_asset <meta> <release-version> -> 设置 ASSET_NAME / ASSET_URL / ASSET_DIGEST
	local meta="$1" ver="$2" i=0 name url dig dig_hex
	ASSET_NAME=""; ASSET_URL=""; ASSET_DIGEST=""
	while [ "$i" -lt "$MAX_ASSET_SCAN" ]; do
		name="$(a_field "$meta" "$i" name)"
		[ -n "$name" ] || break
		if asset_name_ok "$name" "$ver"; then
			url="$(a_field "$meta" "$i" browser_download_url)"
			dig="$(a_field "$meta" "$i" digest)"
			case "$url" in
				"$GH_DL_PREFIX"*) : ;;
				*) msg "资产下载地址不在固定仓库：$url"; return 1 ;;
			esac
			case "$dig" in
				sha256:*)
					dig_hex="${dig#sha256:}"
					case "$dig_hex" in *[!0-9A-Fa-f]*|'') dig="" ;; esac
					[ "${#dig_hex}" -eq 64 ] || dig=""
					dig="$(printf '%s' "$dig" | tr 'A-F' 'a-f')"
					;;
				*) dig="" ;;
			esac
			ASSET_NAME="$name"; ASSET_URL="$url"; ASSET_DIGEST="$dig"
			return 0
		fi
		i=$((i + 1))
	done
	return 1
}

digest_from_checksums() {
	# 返回 0 = 提取到；1 = 没有校验和资产；2 = 有校验和文件但没有本资产的记录。
	# 2 必须让检查失败：Release 明确提供了校验和却不含本资产，不能当作
	# "上游未提供校验"放行。
	local meta="$1" i=0 name url f line
	f="$WORK/checksums.txt"
	while [ "$i" -lt "$MAX_ASSET_SCAN" ]; do
		name="$(a_field "$meta" "$i" name)"
		[ -n "$name" ] || break
		case "$name" in
			sha256sums.txt|SHA256SUMS|sha256sum.txt)
				url="$(a_field "$meta" "$i" browser_download_url)"
				case "$url" in "$GH_DL_PREFIX"*) : ;; *) i=$((i + 1)); continue ;; esac
				api_get "$url" "$f" "$FETCH_TIMEOUT" 2>/dev/null || return 2
				line="$(awk -v n="$ASSET_NAME" 'tolower($2) == tolower(n) { print $1; exit }' "$f")"
				line="$(printf '%s' "$line" | tr 'A-F' 'a-f')"
				case "$line" in
					'') return 2 ;;
					*[!0-9a-f]*) return 2 ;;
				esac
				[ "${#line}" -eq 64 ] || return 2
				ASSET_DIGEST="sha256:$line"
				return 0
			;;
		esac
		i=$((i + 1))
	done
	return 1
}

# ---------------------------------------------------------------- check
cmd_check() {
	local meta="$WORK/release.json" tag cur pat cmp state digest drc
	digest=''
	need_tools || return 1
	init_dirs || { fail '私有临时目录不可用'; return 1; }

	api_get "$GH_API" "$meta" "$FETCH_TIMEOUT" || { fail "GitHub Release 检查失败：${API_GET_ERR:-网络或仓库不可达}"; return 1; }
	# 只认 latest release 对象：结构不符就不要继续解释字段
	jsonfilter -i "$meta" -e '@.tag_name' >/dev/null 2>&1 || { fail 'Release 元数据结构不符合预期'; return 1; }

	tag="$(jsonfilter -i "$meta" -e '@.tag_name' 2>/dev/null | head -n1)"
	version_ok "$tag" || { fail 'Release tag 不是严格的数字版本号，已忽略'; return 1; }
	RELEASE_VERSION="$(ver_norm "$tag")"
	cur="$(current_version)" || cur=""
	pat="$(asset_hint "$RELEASE_VERSION")"

	find_asset "$meta" "$RELEASE_VERSION" || { fail "Release $RELEASE_VERSION 缺少受支持的平台资产（$pat）"; return 1; }
	if [ -z "$ASSET_DIGEST" ]; then
		digest_from_checksums "$meta"
		drc=$?
		if [ "$drc" -eq 2 ]; then
			fail 'Release 提供了校验和文件，但没有本资产的 SHA256，已拒绝'
			return 1
		fi
	fi
	digest="${ASSET_DIGEST#sha256:}"
	# 没有有效 SHA256 就**拒绝**：远端未提供校验和时，"来源是固定仓库 + https"
	# 不足以保证包没被替换（发版流程出错、凭据泄露都能改变资产内容）。
	# 要求上游每个 Release 都带 digest（GitHub 对资产自动提供 sha256）。
	[ "${#digest}" -eq 64 ] || { fail 'Release 未提供有效 SHA256，已拒绝安装（请为该 Release 补上校验和）'; return 1; }
	case "$digest" in
		*[!0-9a-fA-F]*) fail 'Release SHA256 含非十六进制字符，已拒绝安装'; return 1 ;;
	esac

	if [ -z "$cur" ]; then
		state="unknown"
	elif [ "$(ver_cmp "$cur" "$RELEASE_VERSION")" = "-1" ]; then
		state="available"
	else
		state="none"
	fi

	# 结果落盘：install 只安装"刚刚检查过的那一份"，不接受前端传版本/URL。
	# ⚠️ 落盘路径必须用独立的 *_FILE 变量：RELEASE_VERSION 此时已经是版本号
	# 本身，拿它当路径会把文件写到 CWD 下、以版本号命名的文件里去，
	# 随后 do_install 读 $RELEASE_VERSION_FILE 得到空值，安装被莫名拒绝。
	#
	# 第 5 列是候选标识，安装请求必须带回同一个值，用来证明
	# "装的就是用户在页面上看到并确认的那一份"。
	# 只靠原子 rename 不够：并发 check 可以在 install 读取前把快照换成
	# 另一次检查的完整结果（组合是自洽的，但版本可能已经不同了），
	# 于是用户点"安装 1.8.48"却装上了 1.8.49 —— 那是静默升级，必须禁止。
	#
	# 这个标识必须是**不可预测**的：可预测的值（pid、时间戳）能被另一个
	# 页面猜出来，绑定就形同虚设。所以随机源不可用时直接让本次检查失败，
	# 不用可预测值兜底。
	CANDIDATE_ID="$(oc_rand_hex 2>/dev/null)"
	case "$CANDIDATE_ID" in
		'')
			fail '无法生成候选标识（随机源不可用），已中止本次检查'
			return 1
			;;
		*[!0-9a-f]*)
			fail '候选标识格式异常，已中止本次检查'
			return 1
			;;
	esac
	[ "${#CANDIDATE_ID}" -ge 32 ] || {
		fail '候选标识长度不足（随机源输出异常），已中止本次检查'
		return 1
	}
	if ! {
		umask 077
		printf '%s\t%s\t%s\t%s\t%s\n' "$RELEASE_VERSION" "$ASSET_URL" "$ASSET_DIGEST" "$ASSET_NAME" "$CANDIDATE_ID" >"$CANDIDATE_TMP" &&
		mv -f "$CANDIDATE_TMP" "$CANDIDATE_FILE"
	}; then
		rm -f "$CANDIDATE_TMP" 2>/dev/null
		fail '无法保存检查结果（私有目录不可写）'
		return 1
	fi
	chmod 600 "$CANDIDATE_FILE" 2>/dev/null || true

	json "{\"ok\":true,\"state\":\"$state\",\"current\":\"$(jstr "$cur")\",\"release\":\"$(jstr "$RELEASE_VERSION")\",\"asset\":\"$(jstr "$ASSET_NAME")\",\"sha256\":\"$(jstr "$digest")\",\"verified\":$([ -n "$digest" ] && echo true || echo false),\"id\":\"$(jstr "$CANDIDATE_ID")\"}"
}

# ---------------------------------------------------------------- backup
backup_current() {
	# 把当前已安装的包文件打成回滚包 -> 打印路径
	local list="$WORK/files.list" keep="$WORK/files.keep" out f missing=0
	out="$ROLLBACK_DIR/rollback-$(date +%Y%m%d-%H%M%S)-$$.tar.gz"
	if command -v apk >/dev/null 2>&1; then
		apk info -L "$PKG_NAME" 2>/dev/null | awk '/^\//{ sub(/^\//, ""); print }' >"$list"
	else
		opkg files "$PKG_NAME" 2>/dev/null | awk '/^\//{ sub(/^\//, ""); print }' >"$list"
	fi
	[ -s "$list" ] || { msg '无法获取当前安装文件列表，已停止安装'; return 1; }
	: >"$keep"
	while IFS= read -r f; do
		case "$f" in
			''|/*|*..*) msg "安装清单含可疑路径（$f），已停止安装"; return 1 ;;
		esac
		if [ -e "/$f" ] || [ -L "/$f" ]; then
			printf '%s\n' "$f" >>"$keep"
		else
			missing=$((missing + 1))
		fi
	done <"$list"
	[ "$missing" -eq 0 ] || msg "回滚清单跳过 $missing 个已不存在的文件"
	[ -s "$keep" ] || { msg '当前安装文件均不存在，已停止安装'; return 1; }
	# 相对 / 打包，回滚时按同一份清单还原。
	if ! tar -czf "$out" -C / -T "$keep" 2>>"$LOG"; then
		rm -f "$out"; msg '创建回滚包失败，已停止安装'; return 1
	fi
	chmod 600 "$out" 2>/dev/null || true
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$out" | awk '{print $1}' >"$out.sha256"
		chmod 600 "$out.sha256" 2>/dev/null || true
	else
		msg '缺少 sha256sum，无法为回滚包建立完整性校验，已停止安装'
		rm -f "$out"; return 1
	fi
	printf '%s' "$out"
}

trim_rollbacks() {
	# 只保留最近 2 份（归档 + 与之配套的包副本各 2 份）。
	# 文件名受控（生成时用固定前缀 + 时间戳 + pid），但仍按行读取。
	local n=0 f m=0 p
	ls -1t "$ROLLBACK_DIR"/rollback-*.tar.gz 2>/dev/null | while IFS= read -r f; do
		n=$((n + 1))
		if [ "$n" -gt 2 ]; then
			rm -f "$f" "$f.sha256" 2>/dev/null || true
		fi
	done
	ls -1t "$ROLLBACK_DIR"/pkg-*.apk "$ROLLBACK_DIR"/pkg-*.ipk 2>/dev/null | while IFS= read -r p; do
		m=$((m + 1))
		[ "$m" -le 2 ] || rm -f "$p" 2>/dev/null || true
	done
}

# ---------------------------------------------------------------- install
verify_sha256() {
	# verify_sha256 <file> <sha256>  -> 0 ok / 1 mismatch / 2 no tool
	local f="$1" want="$2" got
	case "$want" in
		[0-9a-f][0-9a-f]*) : ;;
		*) return 1 ;;
	esac
	[ "${#want}" -eq 64 ] || return 1
	if command -v sha256sum >/dev/null 2>&1; then
		got="$(sha256sum "$f" 2>/dev/null | awk '{ print $1 }')"
	elif command -v openssl >/dev/null 2>&1; then
		got="$(openssl dgst -sha256 "$f" 2>/dev/null | awk '{ print $NF }')"
	else
		return 2
	fi
	got="$(printf '%s' "$got" | tr 'A-F' 'a-f')"
	[ -n "$got" ] || return 2
	[ "$got" = "$want" ] && return 0
	return 1
}

do_install() {
	local url name digest ver pkg old backup rc size vrc line want_id got_id
	# 候选结果是一份原子快照（check 用 rename 覆盖写入），这里只读一次，
	# 保证版本 / URL / digest / 资产名来自同一次检查。
	line="$(cat "$CANDIDATE_FILE" 2>/dev/null)"
	IFS='	' read -r ver url digest name got_id <<EOF
$line
EOF
	if [ -z "$url" ] || [ -z "$ver" ] || [ -z "$name" ]; then
		msg '没有可安装的检查结果，请先「检查更新」'
		return 1
	fi
	# 候选指纹必须与用户在页面上确认的那一份一致。
	# 为什么不能只靠原子快照：check 不需要持锁（它是只读查询），所以
	# 拿到锁之后、真正读取之前，另一个页面仍可能完成一次 check 并把快照
	# 换成更新的版本 —— 组合本身自洽，SHA256 也匹配，但用户点的
	# "安装 1.8.48" 会变成装上 1.8.49，这就是静默升级。
	want_id="$CONFIRM_ID"
	if [ -n "$want_id" ] && [ "$want_id" != "$got_id" ]; then
		msg '候选版本已变化（可能是另一次检查更新），已拒绝安装；请重新检查后确认'
		return 1
	fi
	# 落盘的值来自上一次 check，仍然复核一遍形状（文件可能陈旧或被改动）
	version_ok "$ver" || { msg "版本号不合法：$ver"; return 1; }
	case "$url" in "$GH_DL_PREFIX"*) : ;; *) msg '下载地址不在固定仓库，已拒绝'; return 1 ;; esac
	asset_name_ok "$name" "$ver" || { msg "资产名不匹配当前平台：$name"; return 1; }

	pkg="$WORK/package.download"
	rm -f "$pkg" 2>/dev/null
	old="$(current_version 2>/dev/null)"

	# 1) 先备份：备份失败就不下载、不安装
	backup="$(backup_current)" || return 1
	[ -n "$backup" ] || { msg '创建回滚包失败，已停止安装'; return 1; }
	trim_rollbacks
	msg "已创建回滚备份：$backup"

	# 2) 下载（https、限时、限大小、私有目录）
	msg "开始下载：$name"
	api_get "$url" "$pkg" "$PKG_TIMEOUT" || { msg "插件包下载失败：${API_GET_ERR:-未知原因}"; rm -f "$pkg"; return 1; }
	size="$(wc -c <"$pkg" 2>/dev/null | tr -d ' ')"
	case "$size" in ''|*[!0-9]*) size=0 ;; esac
	if [ "$size" -le 0 ] || [ "$size" -gt "$MAX_BYTES" ]; then
		msg "插件包大小异常（${size}B，上限 ${MAX_BYTES}B）"
		rm -f "$pkg"
		return 1
	fi
	msg "下载完成（${size}B）"

	# 3) 校验（check 阶段已强制要求 digest；安装阶段再拒绝一次，防止状态文件
	# 被删/被替换后绕过校验）。
	case "$digest" in
		sha256:*)
			verify_sha256 "$pkg" "${digest#sha256:}"
			rc=$?
			if [ "$rc" -ne 0 ]; then
				msg 'SHA256 校验失败，已拒绝安装（回滚包保留）'
				rm -f "$pkg"
				return 1
			fi
			msg 'SHA256 校验通过'
			;;
		*)
			msg '没有 SHA256 校验值，已拒绝安装（回滚包保留）'
			rm -f "$pkg"
			return 1
			;;
	esac

	# 4) 交给包管理器安装（不直接执行下载物）
	# 安装前把包另存一份"可再次安装的包文件"到回滚目录。
	# 为什么：回滚时若只有 tar 归档，恢复出来的文件**不在包数据库里** ——
	# 版本查询为空、`apk del` 删不掉它、下次升级会当成全新安装。
	# 有这个包文件，回滚就能走包管理器（数据库一致）；没有才退化成
	# 文件级恢复，并且明确告警，不假装是包级回滚。
	case "$name" in
		*.apk|*.ipk)
			if ! cp -p "$pkg" "$ROLLBACK_DIR/pkg-$name" 2>/dev/null; then
				msg '无法保存可安装包副本，已停止安装（回滚将无法保持包数据库一致）'
				rm -f "$pkg"
				return 1
			fi
			chmod 600 "$ROLLBACK_DIR/pkg-$name" 2>/dev/null || true
			;;
	esac
	if command -v apk >/dev/null 2>&1; then
		apk add --allow-untrusted --no-network "$pkg" >>"$LOG" 2>&1
	else
		opkg install "$pkg" >>"$LOG" 2>&1
	fi
	rc=$?
	if [ "$rc" -ne 0 ]; then
		msg "安装失败（rc=$rc）：回滚包已保留，可点「回滚」恢复"
		rm -f "$pkg"
		return 1
	fi
	rm -f "$pkg" 2>/dev/null

	# 5) 成功：刷新 rpcd / LuCI 缓存
	if [ -x /etc/init.d/rpcd ]; then
		/etc/init.d/rpcd reload >/dev/null 2>&1 || true
	fi
	rm -f /tmp/luci-indexcache /tmp/luci-modulecache 2>/dev/null
	msg "更新完成：${old:-未知} -> $ver"
	return 0
}

lock_take() {
	# 抢占更新锁。0 = 拿到；1 = 别的更新正在跑；2 = 无法获得。
	local lpid lpid2 steal
	if mkdir "$LOCK" 2>/dev/null; then
		return 0
	fi
	lpid="$(cat "$LOCK/pid" 2>/dev/null)"
	if [ -z "$lpid" ]; then
		# 关键竞态：mkdir 已成功但 worker 尚未写 pid 的窗口。
		# 旧逻辑 sleep 1 后直接把无 pid 锁当陈旧锁抢走；如果 worker 因调度/IO
		# 延迟超过 1 秒，就会出现两个更新并行。无 pid 意味着"无法证明已死"，
		# 必须保守地报 busy；下一次请求等 owner 自己清理，不能回收未知锁。
		msg '已有更新锁但尚未记录 owner，暂不抢占；请稍后重试'
		return 1
	fi
	if oc_pid_alive "$lpid"; then
		msg "已有更新在进行中（pid $lpid）"
		return 1
	fi
	# 已有 pid 且确认已死，先把锁目录原子移走，再复查被移走目录里的 pid。
	# 如果 owner 在这段窗口复活/替换，放回并放弃。
	steal="$WORK/lock.stale.$$"
	rm -rf "$steal" 2>/dev/null
	if ! mv "$LOCK" "$steal" 2>/dev/null; then
		msg '更新锁正在变化，未抢占；请稍后重试'
		return 1
	fi
	lpid2="$(cat "$steal/pid" 2>/dev/null)"
	if [ -z "$lpid2" ] || oc_pid_alive "$lpid2"; then
		mv "$steal" "$LOCK" 2>/dev/null || true
		msg '更新锁 owner 无法确认，未抢占；请稍后重试'
		return 1
	fi
	rm -rf "$steal" 2>/dev/null
	mkdir "$LOCK" 2>/dev/null || { msg '无法获取更新锁'; return 2; }
	msg "已回收陈旧更新锁（pid $lpid2 已退出）"
	return 0
}

cmd_install() {
	local confirm="" cid="" lrc worker a
	# 参数顺序无关：install --confirm 1 --id <hex>
	#
	# 不用 `shift 2 || shift`：POSIX 对 `shift n` 且 n > $# 的行为未定义，
	# 部分 ash/dash 会让非交互 shell 直接退出 —— 那时锁已经拿到但没写 pid，
	# 下一次安装会撞上无 pid 的残留锁。这里显式判断参数个数。
	while [ $# -gt 0 ]; do
		case "$1" in
			--confirm)
				[ $# -ge 2 ] || { fail '--confirm 缺少取值'; return 1; }
				confirm="$2"; shift 2
				;;
			--id)
				[ $# -ge 2 ] || { fail '--id 缺少取值'; return 1; }
				cid="$2"; shift 2
				;;
			-*)
				fail "未知选项：$1"
				return 1
				;;
			*) shift ;;
		esac
	done
	[ "$confirm" = "1" ] || { fail '缺少用户确认（--confirm 1）'; return 1; }
	# 指纹只允许十六进制/字母数字：它会被拼进锁内校验，不能带任何分隔符。
	case "$cid" in
		''|*[!0-9A-Za-z]*) fail '缺少有效的候选版本标识，请重新检查更新'; return 1 ;;
	esac
	# 长度上限：随机源异常时可能返回超长串，写进快照后会被 grep 逐次比对。
	[ "${#cid}" -le 128 ] || { fail '候选标识异常（过长），请重新检查更新'; return 1; }
	CONFIRM_ID="$cid"
	need_tools || return 1
	init_dirs || { fail '私有临时目录不可用'; return 1; }
	lock_take
	lrc=$?
	if [ "$lrc" -eq 1 ]; then
		fail '已有更新在进行中'
		return 1
	elif [ "$lrc" -ne 0 ]; then
		fail '无法获取更新锁'
		return 1
	fi
	# 拿到锁后立刻核对候选指纹：把"检查过的那一份"固定下来再交给 worker。
	# worker 在后台跑，中间还有一次 fork，越早固定越好。
	if ! grep -q -- "$(printf '\t')$cid\$" "$CANDIDATE_FILE" 2>/dev/null; then
		rmdir "$LOCK" 2>/dev/null || true
		fail '候选版本已失效，请重新检查更新'
		return 1
	fi
	printf '%s\n' running >"$STATE"
	# 后台执行：请求立刻返回，前端轮询 status；stdio 全部离开请求管道。
	# 锁里必须记后台 worker 的 pid（$$ 是即将退出的请求进程，记它会让锁
	# 看起来永远是陈旧的）。
	(
		if do_install; then
			printf '%s\n' success >"$STATE"
		else
			printf '%s\n' failed >"$STATE"
		fi
		rm -f "$LOCK/pid" 2>/dev/null
		rmdir "$LOCK" 2>/dev/null
	) </dev/null >>"$LOG" 2>&1 &
	worker=$!
	printf '%s\n' "$worker" >"$LOCK/pid" 2>/dev/null || true
	json '{"ok":true,"state":"running"}'
}

# ---------------------------------------------------------------- status
cmd_status() {
	local s='idle' tail_txt nrb lpid
	init_dirs || { fail '私有临时目录不可用'; return 1; }
	if [ -d "$LOCK" ]; then
		lpid="$(cat "$LOCK/pid" 2>/dev/null)"
		if [ -n "$lpid" ] && oc_pid_alive "$lpid"; then
			s='running'
		else
			# 锁在、进程已不在：要么刚建锁还没写 pid，要么 worker 被 SIGKILL。
			# 后者若继续报 running，前端会永远转圈。
			s='failed'
		fi
	elif [ -f "$STATE" ]; then
		s="$(head -n1 "$STATE" 2>/dev/null)"
		case "$s" in
			running|success|failed) : ;;
			*) s='idle' ;;
		esac
	fi
	# 只报回滚包数量，不回传路径：前端据此决定回滚按钮是否可用。
	nrb="$(ls -1 "$ROLLBACK_DIR"/rollback-*.tar.gz 2>/dev/null | wc -l | tr -d ' ')"
	case "$nrb" in ''|*[!0-9]*) nrb=0 ;; esac
	tail_txt="$(tail -n 40 "$LOG" 2>/dev/null)"
	json "{\"ok\":true,\"state\":\"$s\",\"rollbacks\":$nrb,\"log\":\"$(jstr "$tail_txt")\"}"
}

# ---------------------------------------------------------------- rollback
archive_paths_ok() {
	# 拒绝绝对路径、.. 段，以及符号链接 / 硬链接 / 设备等非普通文件条目。
	# 只看 -tzf 的名字不够：符号链接条目名本身可以是干净的相对路径。
	local f="$1" names types
	names="$(tar -tzf "$f" 2>/dev/null)" || return 1
	[ -n "$names" ] || return 1
	printf '%s\n' "$names" | awk '
		/^\// { bad = 1 }
		/(^|\/)\.\.(\/|$)/ { bad = 1 }
		END { exit bad ? 1 : 0 }' || return 1
	# 类型检查必须单独判 rc 并判空：如果某个 tar 实现 -tvzf 失败（返回非零、
	# 输出为空），直接管道给 awk 会因为"没有输入"而判定 0 个坏条目 →
	# 静默通过。这里显式拦住。
	types="$(tar -tvzf "$f" 2>/dev/null)" || return 1
	[ -n "$types" ] || return 1
	printf '%s\n' "$types" | awk '
		$1 !~ /^[-d]/ { bad = 1 }
		END { exit bad ? 1 : 0 }'
}

_stage_only_files() {
	# _stage_only_files <dir> —— 递归确认只有普通文件与目录
	#
	# 为什么不能只靠 archive_paths_ok：那个函数看的是 tar 条目类型字符串，
	# 而落盘的是解压后的实际文件系统对象。两者之间还有 tar 实现的差异。
	# 这里直接对解压结果做一次独立判据，落盘前再确认一遍。
	local d="$1" p
	[ -d "$d" ] || return 1
	for p in "$d"/* "$d"/.[!.]* "$d"/..?*; do
		[ -e "$p" ] || [ -L "$p" ] || continue
		if [ -L "$p" ]; then
			msg "回滚内容含符号链接：${p#"$d"/}"
			return 1
		fi
		if [ -d "$p" ]; then
			_stage_only_files "$p" || return 1
		elif [ -f "$p" ]; then
			:
		else
			msg "回滚内容含非普通文件：${p#"$d"/}"
			return 1
		fi
	done
	return 0
}

cmd_rollback_worker() {
	local f="$1" rc snap want got pkg oldpkg cur vpv best stage
	msg "开始回滚：$(basename "$f")"
	# 优先走**包级回滚**：安装时把下载到的包另存为 pkg-<文件名>。
	# 为什么必须优先：文件级 tar 恢复虽然能把文件放回去，但恢复出来的文件
	# **不在包数据库里** —— 版本查询为空、`apk del` 删不掉、下次升级会被当成
	# 全新安装。那种"看起来回滚了"的状态比不回滚更危险。
	#
	# ⚠️ 候选必须**严格低于当前已装版本**：pkg-* 里存的是"当初装上去的那一版"，
	# 最新那份正是现在跑着的版本；拿它去装等于把新版又装一遍，什么都没回滚。
	# 所以按版本号挑"低于当前版本里最高的那一份"。
	cur="$(current_version 2>/dev/null)"
	oldpkg=""
	best=""
	if [ -d "$ROLLBACK_DIR" ]; then
		for pkg in "$ROLLBACK_DIR"/pkg-*.apk "$ROLLBACK_DIR"/pkg-*.ipk; do
			[ -f "$pkg" ] || continue
			# 只认当前包管理器能吃下的扩展名
			case "$pkg" in
				*.apk) command -v apk >/dev/null 2>&1 || continue ;;
				*.ipk) command -v apk >/dev/null 2>&1 && continue ;;
			esac
			# 从文件名取版本：pkg-luci-app-openclaw-1.8.48-r1.apk
			#                     pkg-luci-app-openclaw_1.8.48_all.ipk
			# PKG_NAME 必须经 sed 元字符转义：它含 '.' 等正则元字符，
			# 直接拼进模式会把点当通配，可能匹配到别的 pkg-* 文件。
			# 用 awk 的 index/substr 做字面前缀匹配，彻底避开正则。
			vpv="$(basename "$pkg" | awk -v p="pkg-$PKG_NAME" '
				index($0, p) == 1 {
					rest = substr($0, length(p) + 1)
					sub(/^[-_]/, "", rest)
					if (match(rest, /^[0-9][0-9.]*/)) print substr(rest, 1, RLENGTH)
				}')"
			version_ok "$vpv" || continue
			# 当前版本未知时无法判断"更低"，宁可不用包级回滚（走文件级并告警），
			# 也不能瞎猜把同一版重装一遍。
			[ -n "$cur" ] || continue
			[ "$(ver_cmp "$vpv" "$cur")" = "-1" ] || continue
			if [ -z "$best" ] || [ "$(ver_cmp "$vpv" "$best")" = "1" ]; then
				best="$vpv"
				oldpkg="$pkg"
			fi
		done
	fi
	if [ -n "$oldpkg" ]; then
		msg "使用包管理器回滚到 $best：$(basename "$oldpkg")"
		if command -v apk >/dev/null 2>&1; then
			# 本地包 + 旧版本：apk 要求允许未签名；降级选项各版本支持不一，
			# 官方 OpenWrt apk 速查表只明确记录 --allow-untrusted 与
			# --repositories-file，未记录 --force-downgrade（那是 opkg 的选项）。
			# 所以先带它尝试，不支持就回落到不带该选项的安装，两者都失败才
			# 判定包级回滚不可行。
			apk add --allow-untrusted --no-network --force-downgrade "$oldpkg" >>"$LOG" 2>&1 ||
				apk add --allow-untrusted --no-network "$oldpkg" >>"$LOG" 2>&1
			rc=$?
		else
			# opkg 的 --force-downgrade 是官方文档明确列出的选项。
			opkg install --force-downgrade "$oldpkg" >>"$LOG" 2>&1
			rc=$?
		fi
		if [ "$rc" -eq 0 ]; then
			[ -x /etc/init.d/rpcd ] && /etc/init.d/rpcd reload >/dev/null 2>&1 || true
			rm -f /tmp/luci-indexcache /tmp/luci-modulecache 2>/dev/null
			msg "包级回滚完成（$cur -> $best，包数据库一致）；请刷新页面确认版本"
			return 0
		fi
		msg "包级回滚失败（rc=$rc），尝试文件级恢复（版本列表可能不反映实际文件）"
	fi

	# 回滚包必须仍然是创建时的那一份。sha256 sidecar 与 0700 目录共同提供
	# 完整性/来源约束；比对后复制到同一私有目录的新快照，再从快照解压，
	# 避免校验与使用之间被替换（TOCTOU）。
	msg '注意：本次为文件级恢复，包数据库不会更新；如需完全一致请重装对应版本包'
	[ -f "$f.sha256" ] || { msg '回滚包缺少 SHA256 sidecar，已拒绝'; return 1; }
	want="$(cat "$f.sha256" 2>/dev/null)"
	# sidecar 只接受 64 位十六进制：它本身也在可写目录里，格式校验能挡住
	# "同目录写入者把 sidecar 换成任意内容"这类最粗糙的替换。
	case "$want" in
		''|*[!0-9a-fA-F]*) msg '回滚包 SHA256 格式异常，已拒绝'; return 1 ;;
	esac
	[ "${#want}" -eq 64 ] || { msg '回滚包 SHA256 长度异常，已拒绝'; return 1; }
	want="$(printf '%s' "$want" | tr 'A-F' 'a-f')"
	got="$(sha256sum "$f" 2>/dev/null | awk '{print $1}')"
	[ -n "$got" ] && [ "$got" = "$want" ] || { msg '回滚包 SHA256 不匹配，已拒绝'; return 1; }
	snap="$WORK/rollback.snapshot.$$"
	cp -p "$f" "$snap" 2>/dev/null || { msg '无法建立回滚包私有快照，已拒绝'; return 1; }
	chmod 600 "$snap" 2>/dev/null || true
	got="$(sha256sum "$snap" 2>/dev/null | awk '{print $1}')"
	[ "$got" = "$want" ] || { rm -f "$snap"; msg '回滚包快照校验失败，已拒绝'; return 1; }
	archive_paths_ok "$snap" || { rm -f "$snap"; msg '回滚包路径/类型校验失败，已保留原包'; return 1; }
	# 不用 tar -x 直接覆盖：那样不会移除新版本独有文件，造成新旧混杂。
	#
	# 先解压到私有 staging 再落盘：以前是"先 apk del 再 tar -xzf /"，
	# 一旦解压失败，系统就停在"插件已卸载、旧文件没回来"的中间态，
	# 用户还得手工救。现在先在 staging 里解开并校验，成功后才卸载+复制，
	# 失败则原包保留、当前安装保持不动。
	stage=""
	# $WORK 必须非空且是绝对路径：下面有无条件的 rm -rf "$stage"，
	# 一旦 $WORK 为空，stage 会退化成根下路径。init_dirs 已校验过，
	# 但这里再判一次 —— 这条 rm -rf 的代价太大，不能只靠调用方自觉。
	case "$WORK" in
		/*) : ;;
		*) msg '内部错误：私有目录路径异常，已拒绝回滚'; return 1 ;;
	esac
	stage="$WORK/rollback.stage.$$"
	rm -rf "$stage" 2>/dev/null
	mkdir -p "$stage" 2>/dev/null || { rm -f "$snap"; msg '无法创建回滚暂存目录，已拒绝'; return 1; }
	if ! tar -xzf "$snap" -C "$stage" >>"$LOG" 2>&1; then
		rm -rf "$stage" 2>/dev/null; rm -f "$snap"
		msg '回滚归档解压失败（当前安装未改动，回滚包已保留）'
		return 1
	fi
	[ -n "$(ls -A "$stage" 2>/dev/null)" ] || {
		rm -rf "$stage" 2>/dev/null; rm -f "$snap"
		msg '回滚归档解压后为空（当前安装未改动，回滚包已保留）'
		return 1
	}
	# 解压后必须**再校验一次**：archive_paths_ok 校验的是 tar 包本身，
	# 而真正落盘的是解压结果。若只信包校验，符号链接/设备条目一旦漏过，
	# `cp -a "$stage"/. /` 就会把它们铺到根上。这里直接对 stage 内容做
	# 独立判据：只允许普通文件与目录，出现链接/设备/FIFO 一律拒绝。
	if ! _stage_only_files "$stage"; then
		rm -rf "$stage" 2>/dev/null; rm -f "$snap"
		msg '回滚归档解压后含符号链接/设备等非普通条目，已拒绝（当前安装未改动）'
		return 1
	fi
	# 落盘：**先不卸载**，直接覆盖。
	#
	# 以前的顺序是「apk del → tar -xzf /」，一旦写入失败，系统就停在
	# "插件已卸载、旧文件没回来"的中间态 —— 用户必须手工救，而且此时连
	# LuCI 页面都可能已经没了。相比之下，覆盖式写入失败时旧文件大多还在，
	# 系统至少保持可运行。
	#
	# 代价是可能残留"新版本独有、旧版本没有"的孤立文件。它们不影响运行，
	# 且会在下次正常安装时被包管理器重新接管。所以日志里必须说清楚：
	# 这是文件级回滚，包数据库仍记着新版本，要完全一致请重装对应版本包。
	if ! cp -a "$stage"/. / >>"$LOG" 2>&1; then
		rm -rf "$stage" 2>/dev/null
		# 不要说"仍可运行"：cp -a 失败时可能已经写进去一部分文件，
		# 变成 init 脚本/二进制半新半旧的混合状态，未必还能跑。
		# 如实告知"可能已部分覆盖"，并给出唯一可靠出路。
		msg '回滚文件覆盖失败，当前安装可能已处于部分覆盖状态（未必仍可运行）；请立即用包管理器重装对应版本，回滚包已保留'
		return 1
	fi
	rm -rf "$stage" 2>/dev/null
	rm -f "$snap"
	[ -x /etc/init.d/rpcd ] && /etc/init.d/rpcd reload >/dev/null 2>&1 || true
	rm -f /tmp/luci-indexcache /tmp/luci-modulecache 2>/dev/null
	msg '回滚文件恢复完成（文件级，非包级）；请刷新页面并确认插件版本'
	return 0
}

cmd_rollback() {
	local f lrc worker
	init_dirs || { fail '私有临时目录不可用'; return 1; }
	lock_take
	lrc=$?
	if [ "$lrc" -eq 1 ]; then
		fail '已有更新或回滚正在进行'
		return 1
	elif [ "$lrc" -ne 0 ]; then
		fail '无法获取更新锁'
		return 1
	fi
	f="$(ls -1t "$ROLLBACK_DIR"/rollback-*.tar.gz 2>/dev/null | head -n1)"
	if [ -z "$f" ] || [ ! -s "$f" ]; then
		rmdir "$LOCK" 2>/dev/null || true
		fail '没有可用回滚包'
		return 1
	fi
	archive_paths_ok "$f" || {
		rmdir "$LOCK" 2>/dev/null || true
		fail '回滚包路径校验失败，已保留待人工检查'
		return 1
	}
	printf '%s\n' running >"$STATE"
	(
		cmd_rollback_worker "$f"
		rc=$?
		if [ "$rc" -eq 0 ]; then printf '%s\n' success >"$STATE"; else printf '%s\n' failed >"$STATE"; fi
		rm -f "$LOCK/pid" 2>/dev/null
		rmdir "$LOCK" 2>/dev/null
		exit "$rc"
	) </dev/null >>"$LOG" 2>&1 &
	worker=$!
	printf '%s\n' "$worker" >"$LOCK/pid" 2>/dev/null || true
	json '{"ok":true,"state":"running"}'
}

# ---------------------------------------------------------------- dispatch
# 参数解析：第一个非选项参数是子命令，其余原样交给子命令。
# 注意不能先把 $@ 整体 shift 掉再把 "$@" 传给 cmd_install —— 那样
# `install --confirm 1 --id abc` 的选项全丢了，安装会被判成"缺少确认"。
cmd=""
while [ $# -gt 0 ]; do
	case "$1" in
		-*) shift ;;          # 子命令之前的意外选项，忽略
		*)  cmd="$1"; shift; break ;;
	esac
done
case "$cmd" in
	check)    cmd_check ;;
	install)  cmd_install "$@" ;;
	status)   cmd_status ;;
	rollback) cmd_rollback ;;
	*)
		fail '未知操作（支持 check / install / status / rollback）'
		exit 2
		;;
esac