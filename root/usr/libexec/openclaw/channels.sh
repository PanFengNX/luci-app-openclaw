#!/bin/sh
# openclaw - messaging channel helpers
#
# Supported channels (canonical id -> OpenClaw channel id):
#   telegram -> telegram
#   feishu   -> feishu        (飞书)
#   discord  -> discord
#   slack    -> slack
#   wechat   -> openclaw-weixin  (微信; alias: weixin)
#   dingtalk -> dingtalk      (钉钉)
#   qq       -> qq
#
# Unified actions per channel:
#   install   enable the channel (channels.<id>.enabled = true)
#   login     openclaw channels login --channel <id>
#   status    query connection status (CLI first, config summary as fallback)
#   config    write credentials / parameters
#
# Read-only:
#   channels-list   JSON array describing every channel (stdout is JSON only)
#   list            legacy text view of the channels config (redacted)
#
# Credentials never travel through argv. The only accepted credential input is
# a 0600 file passed with --key-file (same convention as models.sh):
#
#   channels.sh telegram config --key-file /tmp/.openclaw/cred
#
# The file contains one "name=value" per line. "name" is either a channel
# parameter (botToken, appSecret, ...) or a full config key
# (channels.feishu.appSecret). A single line without "=" is treated as the
# channel's primary secret, which keeps the old models.sh one-line convention.
#
# Values read from --key-file are written to <state>/.env (mode 600) and the
# config key is pointed at an environment SecretRef. If the installed OpenClaw
# does not support SecretRef the action fails instead of writing plaintext.
# Values are never printed and never appended to the task log.
#
# POSIX sh (busybox ash) compatible.

OC_LIB="/usr/libexec/openclaw/lib.sh"
. "$OC_LIB"

oc_env() {
	export HOME="$(oc_home_dir)"
	export PATH="$(oc_node_dir)/bin:$(oc_oc_dir)/bin:$PATH"
	OC_BIN="$(oc_oc_bin)"
	NPM_BIN="$(oc_node_dir)/bin/npm"
	[ -x "$NPM_BIN" ] || NPM_BIN="$(command -v npm 2>/dev/null)"
}

# ---------------------------------------------------------------- channel registry

channel_ids() {
	printf '%s\n' telegram feishu discord slack wechat dingtalk qq
}

channel_canon() {
	# channel_canon <id|alias> -> canonical id; rc 1 when unknown
	case "${1:-}" in
		telegram|tg|Telegram|电报) printf 'telegram' ;;
		feishu|lark|Feishu|Lark|飞书) printf 'feishu' ;;
		discord|Discord) printf 'discord' ;;
		slack|Slack) printf 'slack' ;;
		wechat|weixin|WeChat|Weixin|微信) printf 'wechat' ;;
		dingtalk|ding|DingTalk|钉钉) printf 'dingtalk' ;;
		qq|QQ|Qq) printf 'qq' ;;
		*) return 1 ;;
	esac
}

channel_ckey() {
	# channel_ckey <canonical id> -> key segment under channels.*
	# 微信是唯一有代码证据的键名：channels.openclaw-weixin（见改造前的 install）。
	case "${1:-}" in
		wechat) printf 'openclaw-weixin' ;;
		telegram|feishu|discord|slack|dingtalk|qq) printf '%s' "$1" ;;
		*) return 1 ;;
	esac
}

channel_name() {
	case "${1:-}" in
		telegram) printf 'Telegram' ;;
		feishu)   printf '飞书' ;;
		discord)  printf 'Discord' ;;
		slack)    printf 'Slack' ;;
		wechat)   printf '微信' ;;
		dingtalk) printf '钉钉' ;;
		qq)       printf 'QQ' ;;
		*)        printf '%s' "${1:-}" ;;
	esac
}

channel_actions() {
	printf '%s\n' install login status config
}

channel_params() {
	# <name>|<label>|<secret 0/1>|<required 0/1>|<config key or empty>
	#
	# 空 config key = 本仓库没有证据，不猜。调用方必须传完整键名
	# （channels.<id>.<key>）给 config，见 usage 与 review-report.md。
	case "${1:-}" in
		telegram)
			printf '%s\n' 'botToken|Bot Token|1|1|channels.telegram.botToken'
			;;
		feishu)
			printf '%s\n' \
				'appId|App ID|0|1|' \
				'appSecret|App Secret|1|1|'
			;;
		discord)
			printf '%s\n' 'token|Bot Token|1|1|channels.discord.token'
			;;
		slack)
			printf '%s\n' \
				'botToken|Bot Token|1|1|channels.slack.botToken' \
				'appToken|App Token|1|0|channels.slack.appToken'
			;;
		wechat)
			# 凭据由 login 流程保存，没有可写的参数
			:
			;;
		dingtalk)
			printf '%s\n' \
				'clientId|Client ID|0|1|' \
				'clientSecret|Client Secret|1|1|'
			;;
		qq)
			printf '%s\n' \
				'appId|App ID|0|1|' \
				'token|Token|1|1|'
			;;
	esac
}

channel_param_key() {
	# channel_param_key <channel> <param-name> -> config key (may be empty)
	local name label secret required key
	while IFS='|' read -r name label secret required key; do
		[ -n "$name" ] || continue
		if [ "$name" = "${2:-}" ]; then
			printf '%s' "$key"
			return 0
		fi
	done <<EOF
$(channel_params "$1")
EOF
	return 1
}

channel_primary_secret_key() {
	# 第一个“敏感且键名已知”的参数；用于单行密钥文件
	local name label secret required key
	while IFS='|' read -r name label secret required key; do
		[ -n "$name" ] || continue
		[ "$secret" = "1" ] || continue
		[ -n "$key" ] || continue
		printf '%s' "$key"
		return 0
	done <<EOF
$(channel_params "$1")
EOF
	return 1
}

channel_configured_known() {
	# 关键凭据的键名是否全部已知（wechat 例外：凭据由 login 保存，无法判断）
	local name label secret required key
	[ "${1:-}" = "wechat" ] && return 1
	while IFS='|' read -r name label secret required key; do
		[ -n "$name" ] || continue
		[ "$required" = "1" ] || continue
		[ -n "$key" ] || return 1
	done <<EOF
$(channel_params "$1")
EOF
	return 0
}

# ---------------------------------------------------------------- config state

oc_key_path() {
	# channels.telegram.botToken -> $["channels"]["telegram"]["botToken"]
	# 只接受安全字符，避免把引号/反斜杠带进 jsonfilter 表达式。
	case "${1:-}" in
		''|.*|*.|*..*) return 1 ;;
		*[!A-Za-z0-9_.-]*) return 1 ;;
	esac
	printf '$'
	printf '%s' "$1" | awk -F. '{ for (i = 1; i <= NF; i++) printf "[\"%s\"]", $i }'
	printf '\n'
}

conf_channel_block() {
	# conf_channel_block <ck> -> 该渠道在 openclaw.json 中的对象（文本切片）
	# 先尝试 jsonfilter（处理带 "-" 的键用 bracket 语法），失败时按大括号配对
	# 截取。只用于展示与启发式判断，不参与写入。
	local ck="${1:-}" conf out
	conf="$(oc_conf)"
	[ -f "$conf" ] || return 1
	if command -v jsonfilter >/dev/null 2>&1; then
		out="$(jsonfilter -i "$conf" -e "$(oc_key_path "channels.${ck}")" 2>/dev/null)"
		[ -n "$out" ] && { printf '%s\n' "$out"; return 0; }
	fi
	awk -v ck="$ck" '
		$0 ~ ("\"" ck "\"[[:space:]]*:") { inb = 1; depth = 0; started = 0 }
		inb {
			print
			depth += gsub(/\{/, "{")
			depth -= gsub(/\}/, "}")
			if (index($0, "{") > 0) started = 1
			if (started && depth <= 0) exit
		}
	' "$conf"
}

conf_channel_exists() {
	local ck="${1:-}" conf
	conf="$(oc_conf)"
	[ -f "$conf" ] || return 1
	grep -q "\"$ck\"[[:space:]]*:" "$conf" 2>/dev/null
}

conf_key_present() {
	# conf_key_present <channel> <dotted key>
	local ch="$1" key="$2" conf v path last block
	conf="$(oc_conf)"
	[ -f "$conf" ] || return 1
	if command -v jsonfilter >/dev/null 2>&1; then
		path="$(oc_key_path "$key")" || path=""
		if [ -n "$path" ]; then
			v="$(jsonfilter -i "$conf" -e "$path" 2>/dev/null | head -n1)"
			[ -n "$v" ] && return 0
		fi
	fi
	# 退化路径：只看该渠道对象内部是否出现这个叶子键。
	# 这是启发式判断（只用于 channels-list 的 configured 提示），不用于写入。
	last="${key##*.}"
	block="$(conf_channel_block "$(channel_ckey "$ch")")"
	[ -n "$block" ] || return 1
	printf '%s\n' "$block" | grep -q "\"$last\"[[:space:]]*:" 2>/dev/null
}

channel_enabled() {
	local ch="$1" ck conf v block
	ck="$(channel_ckey "$ch")" || return 1
	conf="$(oc_conf)"
	[ -f "$conf" ] || return 1
	if command -v jsonfilter >/dev/null 2>&1; then
		v="$(jsonfilter -i "$conf" -e "$(oc_key_path "channels.${ck}.enabled")" 2>/dev/null | head -n1)"
		case "$v" in
			true)  return 0 ;;
			false) return 1 ;;
		esac
	fi
	block="$(conf_channel_block "$ck")"
	[ -n "$block" ] || return 1
	printf '%s\n' "$block" | grep -q '"enabled"[[:space:]]*:[[:space:]]*true' 2>/dev/null
}

channel_configured() {
	# 所有“必填”参数都有对应配置键时返回 0。
	# 键名未知的渠道无法判断 -> 返回 1（channels-list 会同时给出 configuredKnown=false）。
	local ch="$1" name label secret required key any=0
	while IFS='|' read -r name label secret required key; do
		[ -n "$name" ] || continue
		[ "$required" = "1" ] || continue
		any=1
		[ -n "$key" ] || return 1
		conf_key_present "$ch" "$key" || return 1
	done <<EOF
$(channel_params "$ch")
EOF
	if [ "$any" = "1" ]; then
		return 0
	fi
	# 没有必填参数（微信）：渠道配置块存在即视为已配置；
	# 真正的凭据由 login 流程保存，无法从 openclaw.json 判断。
	conf_channel_exists "$(channel_ckey "$ch")"
}

# ---------------------------------------------------------------- output safety

oc_redact() {
	# 把疑似凭据的整行替换掉。宁可少显示一行，也不把 token 回显到页面/日志。
	# 只用于展示类输出（list / status / CLI 输出），不用于 JSON 文档。
	awk '
		/[Tt][Oo][Kk][Ee][Nn]|[Ss][Ee][Cc][Rr][Ee][Tt]|[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]|[Pp][Aa][Ss][Ss][Ww][Dd]|[Aa][Pp][Ii][_-]?[Kk][Ee][Yy]/ {
			print "[已隐藏：输出包含疑似凭据]"
			next
		}
		{ print }
	'
}

# ---------------------------------------------------------------- CLI helpers

oc_msg() {
	# stderr 上的进度信息：channels-list / config 的 stdout 必须保持干净
	oc_log INFO "$@" >&2
}

oc_run_capture() {
	# oc_run_capture <timeout> <cmd> [args...]
	# 运行命令，stdout+stderr 经脱敏后同时写终端和任务日志，返回命令本身的退出码。
	local t="$1"; shift
	local tmp rc
	tmp="$(mktemp "$OC_RUNDIR/channel-out.XXXXXX" 2>/dev/null)" || tmp="$OC_RUNDIR/channel-out.$$"
	if command -v timeout >/dev/null 2>&1; then
		timeout "$t" "$@" >"$tmp" 2>&1
	else
		"$@" >"$tmp" 2>&1
	fi
	rc=$?
	if [ -f "$tmp" ]; then
		oc_redact <"$tmp" | tee -a "$OC_TASKLOG" 2>/dev/null
		rm -f "$tmp"
	fi
	return "$rc"
}

oc_cli() {
	# oc_cli <timeout> <openclaw args...>
	local t="$1"; shift
	HOME="$(oc_home_dir)" PATH="$(oc_node_dir)/bin:$(oc_oc_dir)/bin:$PATH" \
		oc_run_capture "$t" "$(oc_oc_bin)" "$@"
}

oc_svc_restart() {
	[ -x /etc/init.d/openclaw ] || return 0
	# oc_timeout 在没有 timeout applet 的 busybox 上会退化为直接执行；
	# 告警走 stderr，这里按原有约定连同 stdout 一起丢弃（重启是静默步骤）。
	oc_timeout 60 /etc/init.d/openclaw restart >/dev/null 2>&1
}

# ---------------------------------------------------------------- install

wechat_precheck() {
	oc_msg "== 微信插件前置检查 =="
	command -v python3 >/dev/null 2>&1 || oc_warn "未安装 python3，插件可能需要：$(oc_pkg_install_hint) python3-light"
	local d code
	for d in "$(oc_home_dir)" "$(oc_base_dir)" /tmp; do
		mkdir -p "$d" 2>/dev/null
		[ -w "$d" ] || oc_warn "目录不可写: $d"
	done
	if command -v curl >/dev/null 2>&1; then
		code="$(curl -s -m 10 -o /dev/null -w '%{http_code}' https://ilinkai.weixin.qq.com 2>/dev/null)"
		oc_msg "ilinkai 连通性检查：HTTP ${code:-unknown}"
	fi
}

# 兼容旧函数名
weixin_precheck() { wechat_precheck; }

channel_install() {
	local ch="$1" ck rc
	ck="$(channel_ckey "$ch")" || { oc_err "未知渠道：$ch"; return 2; }
	oc_env
	[ -x "$OC_BIN" ] || { oc_err "OpenClaw 未安装"; return 1; }

	if [ "$ch" = "wechat" ]; then
		wechat_precheck
		if [ -z "$NPM_BIN" ] || [ ! -x "$NPM_BIN" ]; then
			oc_err "未找到 npm，无法安装微信插件"
			return 1
		fi
		oc_info "安装微信插件（官方 CLI）"
		oc_run_capture 600 "$NPM_BIN" exec -y @tencent-weixin/openclaw-weixin-cli@latest -- install
		rc=$?
		if [ "$rc" -ne 0 ]; then
			oc_err "微信插件安装失败（rc=$rc），未修改渠道配置"
			return "$rc"
		fi
		# 插件注册失败不致命：下面还会写 channels.<id>.enabled，最终以配置写入结果为准。
		oc_cli 60 config set plugins.entries.openclaw-weixin.enabled true >/dev/null 2>&1
	fi

	if ! oc_cli 60 config set "channels.${ck}.enabled" true >/dev/null 2>&1; then
		oc_err "启用渠道失败：channels.${ck}.enabled"
		return 1
	fi
	if [ "$ch" = "wechat" ] && conf_channel_exists weixin; then
		oc_warn "检测到旧渠道键 channels.weixin；当前插件使用 channels.openclaw-weixin，旧键不会自动删除"
	fi
	oc_fix_perms
	oc_info "已启用渠道：$(channel_name "$ch")"
	oc_info "重启网关以加载渠道配置"
	oc_svc_restart || oc_warn "网关重启失败，请手动重启"
	return 0
}

# ---------------------------------------------------------------- login

channel_login() {
	local ch="$1" ck rc
	ck="$(channel_ckey "$ch")" || { oc_err "未知渠道：$ch"; return 2; }
	oc_env
	[ -x "$OC_BIN" ] || { oc_err "OpenClaw 未安装"; return 1; }
	oc_info "登录渠道：$(channel_name "$ch")（--channel $ck）"
	oc_cli 150 channels login --channel "$ck"
	rc=$?
	if [ "$rc" -ne 0 ]; then
		oc_warn "渠道 $(channel_name "$ch") 登录未成功（rc=$rc）。该渠道可能不支持 login；请改用 config 设置 Token/凭据。"
		return "$rc"
	fi
	return 0
}

# ---------------------------------------------------------------- status

list_channel() {
	# 单个渠道的配置摘要（已脱敏）
	local ch="$1" ck out
	ck="$(channel_ckey "$ch")" || return 1
	out="$(conf_channel_block "$ck")"
	[ -n "$out" ] || out="(未找到该渠道配置)"
	printf '%s\n' "$out" | oc_redact
}

channel_status() {
	local ch="$1" ck rc
	ck="$(channel_ckey "$ch")" || { oc_err "未知渠道：$ch"; return 2; }
	oc_env
	[ -x "$OC_BIN" ] || { oc_err "OpenClaw 未安装"; return 1; }

	oc_info "查询渠道状态：$(channel_name "$ch")"
	oc_cli 30 channels status --channel "$ck"
	rc=$?
	if [ "$rc" -eq 0 ]; then
		return 0
	fi
	# 部分版本没有 `channels status --channel`，退到 `channels list`
	oc_msg "channels status 不可用（rc=$rc），尝试 channels list"
	oc_cli 30 channels list
	rc=$?
	if [ "$rc" -eq 0 ]; then
		return 0
	fi
	oc_msg "CLI 未提供渠道状态，显示配置摘要（已脱敏）"
	list_channel "$ch"
	return 0
}

# ---------------------------------------------------------------- config

oc_safe_config_key() {
	case "${1:-}" in
		channels.*) ;;
		*) return 1 ;;
	esac
	case "$1" in
		''|.*|*.|*..*) return 1 ;;
		*[!A-Za-z0-9_.-]*) return 1 ;;
	esac
	return 0
}

oc_normalize_key() {
	# oc_normalize_key <channel> <param-name|full-key> -> full config key
	local ch="$1" k="$2" pkey
	case "$k" in
		channels.*) printf '%s' "$k"; return 0 ;;
	esac
	pkey="$(channel_param_key "$ch" "$k")" || pkey=""
	[ -n "$pkey" ] || return 1
	printf '%s' "$pkey"
}

oc_secret_envname() {
	# OC_CH_<CHANNEL>_<LEAF>，只含 A-Z0-9_
	local ch="$1" key="$2" last
	last="${key##*.}"
	printf 'OC_CH_%s_%s' \
		"$(printf '%s' "$ch" | tr 'a-z' 'A-Z' | tr -c 'A-Z0-9' '_')" \
		"$(printf '%s' "$last" | tr 'a-z' 'A-Z' | tr -c 'A-Z0-9' '_')"
}

oc_write_env_secret() {
	# oc_write_env_secret <env-name> <value>
	# 值只写进 <state>/.env（600），不出现在 argv / stdout / 日志里。
	local envname="$1" value="$2" envfile tmp
	case "$envname" in
		''|*[!A-Za-z0-9_]*) return 1 ;;
	esac
	case "$value" in
		*'$'*|*'`'*|*';'*|*'|'*|*'&'*|*'<'*|*'>'*|*' '*|*'	'*)
			return 1 ;;
	esac
	value="$(printf '%s' "$value" | tr -d '\000-\010\013\014\016-\037\177' 2>/dev/null || printf '%s' "$value")"
	value="$(printf '%s' "$value" | head -n1)"
	[ -n "$value" ] || return 1

	envfile="$(oc_env_file)"
	mkdir -p "$(oc_data_dir)" 2>/dev/null
	touch "$envfile" 2>/dev/null
	chmod 600 "$envfile" 2>/dev/null
	tmp="$envfile.tmp.$$"
	grep -v "^${envname}=" "$envfile" >"$tmp" 2>/dev/null
	printf '%s=%s\n' "$envname" "$value" >>"$tmp"
	mv "$tmp" "$envfile" 2>/dev/null || { rm -f "$tmp"; return 1; }
	chmod 600 "$envfile" 2>/dev/null
	return 0
}

oc_config_set_ref() {
	# oc_config_set_ref <config-key> <env-name>
	oc_cli 60 config set "$1" \
		--ref-provider default --ref-source env --ref-id "$2" >/dev/null 2>&1
}

channel_config() {
	# channel_config <channel> [--key-file <path>] [--set <key> <value>]...
	#
	# stdout 只输出一行 JSON：{"ok":true} 或 {"ok":false,"error":"..."}
	# 进度/错误走 stderr（oc_msg / oc_err），不会污染 JSON。
	local ch="$1"; shift
	local kf="" key val rc=0 errmsg="" nline=0
	local line name_part pkey primary envname

	oc_env
	[ -x "$OC_BIN" ] || {
		printf '{"ok":false,"error":"OpenClaw 未安装"}\n'
		return 1
	}

	while [ $# -gt 0 ]; do
		case "$1" in
			--key-file)
				if [ $# -lt 2 ]; then
					printf '{"ok":false,"error":"--key-file 缺少路径"}\n'
					return 2
				fi
				kf="$2"
				shift 2
				;;
			--set)
				shift
				if [ $# -eq 0 ]; then
					printf '{"ok":false,"error":"--set 缺少参数"}\n'
					return 2
				fi
				case "$1" in
					*=*)
						key="${1%%=*}"
						val="${1#*=}"
						shift
						;;
					*)
						key="$1"
						val="${2:-}"
						shift
						[ $# -gt 0 ] && shift
						;;
				esac
				key="$(oc_normalize_key "$ch" "$key")" || key=""
				if [ -z "$key" ]; then
					oc_err "参数名未知：$1；请直接使用完整键名 channels.<id>.<key>"
					[ -n "$errmsg" ] || errmsg="参数名未知，请使用完整键名"
					rc=1
					continue
				fi
				if ! oc_safe_config_key "$key"; then
					oc_err "配置键不合法（只允许 channels.*，字符集 A-Za-z0-9_.-）：$key"
					[ -n "$errmsg" ] || errmsg="配置键不合法"
					rc=1
					continue
				fi
				# 敏感参数必须走 --key-file，绝不能进 argv
				case "$key" in
					*token*|*Token*|*secret*|*Secret*|*password*|*Password*|*apiKey*|*apikey*)
						oc_err "敏感参数不能通过 --set 传递（会进入 argv）：$key；请使用 --key-file"
						[ -n "$errmsg" ] || errmsg="敏感参数请使用 --key-file"
						rc=1
						continue
						;;
				esac
				if oc_cli 60 config set "$key" "$val" >/dev/null 2>&1; then
					oc_msg "已写入：$key"
				else
					oc_err "写入失败：$key"
					[ -n "$errmsg" ] || errmsg="写入失败：$key"
					rc=1
				fi
				;;
			*)
				printf '{"ok":false,"error":"未知参数：%s"}\n' "$(oc_json_str "$1")"
				return 2
				;;
		esac
	done

	if [ -n "$kf" ]; then
		if [ ! -f "$kf" ]; then
			printf '{"ok":false,"error":"密钥文件不存在"}\n'
			return 1
		fi
		primary="$(channel_primary_secret_key "$ch")" || primary=""
		while IFS= read -r line || [ -n "$line" ]; do
			case "$line" in
				''|'#'*) continue ;;
			esac
			nline=$((nline + 1))
			name_part="${line%%=*}"
			if [ "$name_part" = "$line" ]; then
				# 没有 "="：按“主密钥”处理（兼容 models.sh 的单行约定）
				if [ -z "$primary" ] || [ "$nline" -ne 1 ]; then
					oc_err "密钥文件第 ${nline} 行缺少 name=value：$name_part"
					[ -n "$errmsg" ] || errmsg="密钥文件格式错误"
					rc=1
					continue
				fi
				key="$primary"
				val="$line"
			else
				key="$(oc_normalize_key "$ch" "$name_part")" || key=""
				if [ -z "$key" ]; then
					oc_err "密钥文件里的参数名未知：$name_part；请写成完整键名 channels.<id>.<key>=<value>"
					[ -n "$errmsg" ] || errmsg="参数名未知，请使用完整键名"
					rc=1
					continue
				fi
				val="${line#*=}"
			fi
			if ! oc_safe_config_key "$key"; then
				oc_err "配置键不合法：$key"
				[ -n "$errmsg" ] || errmsg="配置键不合法"
				rc=1
				continue
			fi
			envname="$(oc_secret_envname "$ch" "$key")"
			if ! oc_write_env_secret "$envname" "$val"; then
				oc_err "凭据值不合法或写入 .env 失败：$key"
				[ -n "$errmsg" ] || errmsg="凭据写入失败：$key"
				rc=1
				continue
			fi
			if oc_config_set_ref "$key" "$envname"; then
				oc_msg "已写入凭据：$key（SecretRef: $envname）"
			else
				oc_err "写入凭据失败：$key（当前 OpenClaw 可能不支持 SecretRef；未回退明文）"
				[ -n "$errmsg" ] || errmsg="SecretRef 写入失败：$key"
				rc=1
			fi
		done <"$kf"
		if [ "$nline" -eq 0 ]; then
			printf '{"ok":false,"error":"密钥文件为空"}\n'
			return 1
		fi
	fi

	if [ "$rc" -eq 0 ]; then
		printf '{"ok":true}\n'
	else
		printf '{"ok":false,"error":"%s"}\n' "$(oc_json_str "$errmsg")"
	fi
	return "$rc"
}

# ---------------------------------------------------------------- read-only views

list() {
	# 旧版文本视图：整棵 channels 配置树，已脱敏
	local conf out
	conf="$(oc_conf)"
	[ -f "$conf" ] || { printf '(未配置渠道)\n'; return 0; }
	out=""
	if command -v jsonfilter >/dev/null 2>&1; then
		out="$(jsonfilter -i "$conf" -e '$.channels' 2>/dev/null)"
	fi
	if [ -z "$out" ]; then
		out="$(sed -n '/"channels"[[:space:]]*:/,/^[[:space:]]*}/p' "$conf" 2>/dev/null | head -c 4000)"
	fi
	[ -n "$out" ] || out="(未配置渠道)"
	printf '%s\n' "$out" | oc_redact
}

channels_list() {
	# stdout 只有 JSON 数组。任何日志都必须走 stderr（oc_msg/oc_warn/oc_err）。
	local id name ck enabled configured known actions actions_json params_json paramnames
	local name2 label secret required key knownp note first=1 pfirst
	printf '['
	for id in $(channel_ids); do
		name="$(channel_name "$id")"
		ck="$(channel_ckey "$id")"
		enabled=false
		channel_enabled "$id" && enabled=true
		configured=false
		channel_configured "$id" && configured=true
		known=false
		channel_configured_known "$id" && known=true

		actions_json=""
		for actions in $(channel_actions); do
			[ -n "$actions_json" ] && actions_json="$actions_json,"
			actions_json="$actions_json\"$actions\""
		done

		params_json=""
		paramnames=""
		pfirst=1
		while IFS='|' read -r name2 label secret required key; do
			[ -n "$name2" ] || continue
			if [ -n "$key" ]; then knownp=true; else knownp=false; fi
			[ "$pfirst" = "1" ] || params_json="$params_json,"
			pfirst=0
			params_json="$params_json{\"name\":\"$(oc_json_str "$name2")\",\"label\":\"$(oc_json_str "$label")\",\"secret\":$([ "$secret" = "1" ] && echo true || echo false),\"required\":$([ "$required" = "1" ] && echo true || echo false),\"configKey\":\"$(oc_json_str "$key")\",\"configKeyKnown\":$knownp}"
			[ -n "$paramnames" ] && paramnames="$paramnames,"
			paramnames="$paramnames\"$(oc_json_str "$name2")\""
		done <<EOF
$(channel_params "$id")
EOF

		note=""
		case "$id" in
			wechat)
				note="凭据由 login 流程保存，无法从配置判断是否齐全"
				;;
			feishu|dingtalk|qq)
				note="凭据配置键名未在本仓库证实；config 请传完整键名 channels.<id>.<key>"
				;;
		esac

		[ "$first" = "1" ] || printf ','
		first=0
		printf '{"id":"%s","name":"%s","channelId":"%s","enabled":%s,"configured":%s,"configuredKnown":%s,"configKey":"channels.%s","enabledKey":"channels.%s.enabled","actions":[%s],"params":[%s],"paramNames":[%s],"note":"%s"}' \
			"$(oc_json_str "$id")" "$(oc_json_str "$name")" "$(oc_json_str "$ck")" \
			"$enabled" "$configured" "$known" \
			"$(oc_json_str "$ck")" "$(oc_json_str "$ck")" \
			"$actions_json" "$params_json" "$paramnames" "$(oc_json_str "$note")"
	done
	printf ']\n'
}

# ---------------------------------------------------------------- usage

usage() {
	cat <<EOF
Usage: channels.sh <channel> {install|login|status|config ...}
       channels.sh channels-list
       channels.sh list

Channels:
  telegram, feishu (飞书), discord, slack, wechat (微信; alias weixin),
  dingtalk (钉钉), qq

Actions:
  install                 enable the channel (channels.<id>.enabled=true)
  login                   openclaw channels login --channel <id>
  status                  connection status (CLI first, config summary fallback)
  config --key-file <f>   write credentials from a 0600 file
  config --set <key> <v>  write a NON-secret parameter (raw passthrough)

Credential file format (one per line):
  name=value              name is a channel parameter (e.g. botToken) or a
                          full config key (e.g. channels.feishu.appSecret)
  <line without "=">      treated as the channel's primary secret
                          (same one-line convention as models.sh)

Secrets never travel through argv: values from --key-file are written to
<state>/.env (0600) and the config key is pointed at an env SecretRef. If the
installed OpenClaw does not support SecretRef the action fails; it does NOT
fall back to plaintext.

  channels-list           JSON array for the UI (stdout is JSON only)
  list                    legacy text view of the channels config (redacted)
EOF
}

# ---------------------------------------------------------------- dispatch

case "${1:-}" in
	channels-list|list-json)
		channels_list
		;;
	list)
		list
		;;
	''|-h|--help|help)
		usage
		;;
	*)
		ch="$(channel_canon "$1")" || {
			oc_err "未知渠道：$1"
			usage
			exit 2
		}
		action="${2:-}"
		if [ $# -ge 2 ]; then
			shift 2
		else
			shift $#
		fi
		case "$action" in
			install) channel_install "$ch" ;;
			login)   channel_login "$ch" ;;
			status)  channel_status "$ch" ;;
			config)  channel_config "$ch" "$@" ;;
			'')
				usage
				exit 2
				;;
			*)
				oc_err "未知动作：$action"
				usage
				exit 2
				;;
		esac
		;;
esac
