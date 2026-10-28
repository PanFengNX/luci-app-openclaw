#!/bin/sh
# openclaw - 网关凭据判定（全项目唯一实现）
# POSIX sh (busybox ash) compatible. 载入无副作用：不建目录、不装 trap、不写日志。
#
# 谁在用：
#   * /usr/libexec/openclaw/lib.sh  —— repair / install / cli 等管理命令
#   * /etc/init.d/openclaw          —— 启动前的凭据门
# init.d 刻意**不** source lib.sh（lib.sh 载入期会建私有 rundir、装 trap，
# 对 rc.common 太重），所以判定逻辑放进这个独立文件，两边 source 同一份。
# 这是"唯一实现"能同时服务两边、又不把 lib.sh 塞进 init 的唯一干净办法。
#
# 为什么必须收敛成一处：同一个配置形状以前在 init / repair / install / cli
# 各写一遍，用了三种解析器（jsonfilter、case 匹配大括号、grep），结论互相打架：
#   * case '{'*'}' 把 `{}`、`{"source":"store"}`（缺 id/name）当成有效引用放行；
#   * grep '"token"[[:space:]]*:' 被 `"mode": "token"` 命中，把没有凭据的
#     配置判成已配置 —— init 拒绝启动而 repair 说一切正常。
# 还有一个更隐蔽的：init 曾用**同一个变量**同时表示
#   (a) 凭据是否已配置（引用式也算）
#   (b) 凭据能否导出成环境变量（引用式必须排除）
# 为满足 (b) 清空变量，顺手破坏了 (a) 的判断依据，于是 SecretRef 必然被判成
# "未生成 token"。所以这里把两件事彻底拆开，用两个变量回传。
#
# 输出（busybox ash 没有 local -n，用全局变量回传）：
#   OC_CRED_STATE = PLAIN | REF | BADREF | MISSING | UNREAD
#   OC_CRED_ENV   = 可安全导出的明文凭据；只有 PLAIN 且无空白时非空
#   OC_CRED_DESC  = 一句话描述，用于日志；**只含 source 名与结论，绝不含凭据值**
#
# 语义（与 OpenClaw 2026.10 的 SecretRef 形状对齐）：
#   raw = gateway.auth.token
#     src = gateway.auth.token.source ; id/name = gateway.auth.token.id|name
#   src + id/name        -> REF     允许启动；**不**导出环境变量
#   src 无 id/name       -> BADREF  拒绝
#   raw 是对象但无 src   -> BADREF  拒绝（`{}`、`{"foo":1}` 都不是引用）
#   raw 为 null/空/缺失  -> MISSING 拒绝（token 模式）
#   raw 其余非空字符串   -> PLAIN   允许启动；无空白才导出，有空白只允许配置读取
#   jsonfilter 缺失/配置不可读 -> UNREAD 拒绝（fail-closed）
#   source 是未知 provider 但有 src+id/name -> 仍按 REF 放行 + 警告
#     （"能不能解析这个 provider"是上游职责；在这里抢先拒绝会把将来新增的
#      provider 全挡在门外）

# 日志通道：管理命令里有 oc_warn；init.d 里没有，退回 logger。
# 两条路径都只接收**已构造好的描述**，本文件不把 raw 传进任何日志。
oc_cred_log() {
	if command -v oc_warn >/dev/null 2>&1; then
		oc_warn "$1"
	else
		logger -t openclaw "$1" 2>/dev/null || true
	fi
	return 0
}

# 读一个配置字段。刻意不复用 oc_json_get：那个函数jsonfilter 缺失时静默返回
# 空串，与"字段不存在"无法区分 —— 这里必须把"读不了"和"没配置"分开。
_oc_cred_json() {
	# _oc_cred_json <file> <expr>
	command -v jsonfilter >/dev/null 2>&1 || return 127
	[ -r "$1" ] || return 127
	# **不要**接 head -n1。
	# 值里含换行时 jsonfilter 会输出多行，head -n1 会把它静默截成第一行；
	# 截断后的“半截凭据”看起来仍是非空合法明文，于是会被导出到环境变量，
	# 网关拿它认证必然失败，而现场只看到“认证不通过”——查不到是这里截的。
	# 完整取回后交给上层判断：含任何空白（含 LF/CR）就不导 env。
	# 命令替换会去掉结尾换行，内部换行保留，正是我们要检测的。
	jsonfilter -i "$1" -e "$2" 2>/dev/null
}

oc_credential_state() {
	# oc_credential_state <config-path>
	local cfg="$1" raw src idref rc compact
	OC_CRED_STATE=MISSING
	OC_CRED_ENV=""
	OC_CRED_DESC=""

	# fail-closed 的第一层：连读都读不了，就不要假装"没配置"。
	# 这两种情况现场处置完全不同（装 jsonfilter vs 修配置权限），文案必须分开。
	if [ -z "$cfg" ] || [ ! -e "$cfg" ]; then
		OC_CRED_STATE=UNREAD
		OC_CRED_DESC="配置文件不存在（$cfg）"
		return 0
	fi
	if [ ! -r "$cfg" ]; then
		OC_CRED_STATE=UNREAD
		OC_CRED_DESC="配置文件不可读（$cfg）"
		return 0
	fi
	command -v jsonfilter >/dev/null 2>&1 || {
		OC_CRED_STATE=UNREAD
		OC_CRED_DESC="缺少 jsonfilter，无法解析 $cfg"
		return 0
	}
	# 先验证整个文档可解析。否则 jsonfilter 对不存在路径可能只返回空串，
	# malformed JSON 会被误报成 MISSING，无法区分"没配置"和"配置不可读"。
	if ! jsonfilter -i "$cfg" -e '$' >/dev/null 2>&1; then
		OC_CRED_STATE=UNREAD
		OC_CRED_DESC="配置文件格式不可解析（$cfg）"
		return 0
	fi

	raw="$(_oc_cred_json "$cfg" '@.gateway.auth.token')"; rc=$?
	if [ "$rc" = "127" ]; then
		OC_CRED_STATE=UNREAD
		OC_CRED_DESC="无法解析 $cfg（jsonfilter 不可用或文件不可读）"
		return 0
	fi
	src="$(_oc_cred_json "$cfg" '@.gateway.auth.token.source')"
	idref="$(_oc_cred_json "$cfg" '@.gateway.auth.token.id')"
	[ -n "$idref" ] || idref="$(_oc_cred_json "$cfg" '@.gateway.auth.token.name')"

	if [ -n "$src" ] && [ -n "$idref" ]; then
		OC_CRED_STATE=REF
		OC_CRED_DESC="引用式凭据（source=$src）"
		# 未知 provider 不拒绝，但要让现场知道"能不能用"由上游决定。
		case "$src" in
			store|env|file|exec|keychain|keyring|vault|1password|op) ;;
			*) oc_cred_log "提示：网关凭据使用未知 source '$src'，按引用放行；能否解析取决于 OpenClaw 版本" ;;
		esac
		return 0
	fi
	if [ -n "$src" ]; then
		OC_CRED_STATE=BADREF
		OC_CRED_DESC="引用式凭据缺少 id/name（source=$src）"
		return 0
	fi
	case "$raw" in
		''|null|NULL|undefined)
			OC_CRED_STATE=MISSING
			OC_CRED_DESC="gateway.auth.token 缺失或为空"
			return 0
			;;
		'{'*|'['*)
			# 结构化值却没有 source：不认识的形状。既不是有效引用，也绝不能
			# 当明文导出（那会把一段 JSON 塞进 OPENCLAW_GATEWAY_TOKEN）。
			OC_CRED_STATE=BADREF
			OC_CRED_DESC="凭据是结构化值但缺少 source/id，无法识别"
			return 0
			;;
	esac
	OC_CRED_STATE=PLAIN
	# 只有**不含任何 ASCII 空白**的明文才允许导出到 procd env。
	# 判据在 oc_cred_env_safe()：token 与 password 必须共用同一份，
	# 否则两处会各自漂移（实测出现过：password 只查了空格和 Tab，
	# 漏了 CR/LF，含换行的密码被导出成截断后的半截值）。
	if oc_cred_env_safe "$raw"; then
		OC_CRED_ENV="$raw"
	else
		OC_CRED_DESC="明文凭据含空白/换行控制字符，未导出到环境变量（网关仍读配置文件）"
	fi
	return 0
}

oc_cred_env_safe() {
	# oc_cred_env_safe <value> -> 0 当且仅当可安全放进 procd 的 env 扁平列表
	#
	# procd_set_param env 是"空白分隔的一串 KEY=value"。值里只要出现空格、
	# Tab、CR 或 LF，就会把后面的内容拆成另一个环境项（或被截断），
	# 所以这四类一律禁止导出。**token 与 password 都必须走这里。**
	#
	# 三个实测坑：
	#   1) `grep '[[:space:]]'` 检测不到 LF —— grep 按行匹配，行分隔符本身
	#      永远不在被匹配的内容里。实测含 LF 的值返回 rc=1（"没匹配"）。
	#      所以 LF 必须用 `wc -l` 数行来判断。
	#   2) 不能用 `case` 把 CR/LF 作为字面字符写进源码：任何一次行尾转换
	#      （CRLF）都会把它变成真正的换行，直接破坏脚本语法，而且看不见。
	#      CR 用 `$(printf '\r')` 在运行时构造，避免源码里出现裸控制字符。
	#   3) 空格与 Tab 是行内字符，`case` 检测是可靠的。
	local raw="$1" nl cr tab
	case "$raw" in
		*' '*) return 1 ;;
	esac
	# Tab 与 CR 都用运行时构造，**不要**把控制字符写成源码字面量：
	# 编辑器"Tab 转空格"或任何一次 CRLF 往返都会把它变成普通空格，
	# 检测静默失效，含 Tab 的凭据就会被导出并截断 procd env。
	tab="$(printf '\t')"
	case "$raw" in
		*"$tab"*) return 1 ;;
	esac
	cr="$(printf '\r')"
	case "$raw" in
		*"$cr"*) return 1 ;;
	esac
	# printf 不加尾换行：无换行的值 -> 0 行；含 N 个内部换行 -> N 行。
	nl="$(printf '%s' "$raw" | wc -l 2>/dev/null | tr -d ' ')"
	case "$nl" in ''|*[!0-9]*) return 1 ;; esac
	[ "$nl" -eq 0 ] || return 1
	return 0
}

oc_gateway_auth_mode() {
	# oc_gateway_auth_mode <config-path> -> token | password | none | trusted-proxy | unknown
	#
	# 缺省（字段不存在）按 token —— 历史行为，也是唯一安全默认。
	# 但"字段存在却是垃圾值"必须和"字段不存在"分开：前者要明确拒绝，
	# 静默回落到 token 会让 password 配置被钉死成 token，表面能起、实际认证不通。
	local cfg="$1" m
	m="$(_oc_cred_json "$cfg" '@.gateway.auth.mode')"
	case "$m" in
		'') printf 'token' ;;
		token|password|none|trusted-proxy) printf '%s' "$m" ;;
		*) printf 'unknown' ;;
	esac
}

oc_cred_state_starts() {
	# oc_cred_state_starts <state> -> 0 当且仅当该状态允许启动
	case "$1" in
		PLAIN|REF) return 0 ;;
		*) return 1 ;;
	esac
}