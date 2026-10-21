#!/bin/sh
# openclaw - model provider configuration
#
# The model catalogue is built from three layers, highest priority first:
#   1. providers the user already configured in openclaw.json
#   2. live discovery from the installed OpenClaw (`openclaw models list --all`)
#   3. curated presets shipped with this package (offline fallback)
# plus manual model id input.
# Selecting a provider installs its official plugin (if any), stores the API
# key and sets the chosen model as the default - all in one step.
# DeepSeek and Z.AI (zai/GLM) are part of the default preset set.

OC_LIB="/usr/libexec/openclaw/lib.sh"
. "$OC_LIB"

PRESETS="/usr/share/openclaw/model-presets.json"

oc_env() {
	export HOME="$(oc_home_dir)"
	export PATH="$(oc_node_dir)/bin:$(oc_oc_dir)/bin:$PATH"
	OC_BIN="$(oc_oc_bin)"
}

oc_run() {
	# oc_run <timeout> <args...> —— 合并 stderr（给人看的场景用）
	#
	# 用 oc_timeout 而不是裸 timeout：部分 busybox 没有 timeout 命令，
	# 裸调会把 "timeout: not found" 打进输出 —— 而被 2>&1 合并后，这行错误
	# 会被下游当成"模型 id"（真机上出现过 /usr/libexec/openclaw/models.sh: 27:
	# found 这种下拉项）。oc_timeout 缺失时会告警到 stderr 并直接执行。
	local t="$1"; shift
	HOME="$(oc_home_dir)" PATH="$(oc_node_dir)/bin:$(oc_oc_dir)/bin:$PATH" \
		oc_timeout "$t" "$(oc_oc_bin)" "$@" 2>&1
}

oc_run_q() {
	# oc_run_q <timeout> <args...> —— **丢弃 stderr**，只留 stdout。
	# 凡是"解析输出"的地方都必须用它：CLI 的报错、本插件的 WARN 都不是数据。
	local t="$1"; shift
	HOME="$(oc_home_dir)" PATH="$(oc_node_dir)/bin:$(oc_oc_dir)/bin:$PATH" \
		oc_timeout "$t" "$(oc_oc_bin)" "$@" 2>/dev/null
}

preset_ids() {
	# Only the provider objects: their "id" is the first token on the line.
	# Model entries look like `{ "id": ...` and must NOT be listed here.
	[ -f "$PRESETS" ] || return 0
	awk '
		/^[ \t]*"providers"[ \t]*:/ { inp = 1; next }
		inp && /^[ \t]*"id"[ \t]*:[ \t]*"[^"]*"/ {
			line = $0
			sub(/^[^:]*: *"/, "", line)
			sub(/".*$/, "", line)
			if (line != "") print line
		}
	' "$PRESETS"
}

# Both parsers below walk a single provider object. A provider block starts at a
# line whose first token is "id":   ->   ^[ \t]*"id"[ \t]*:
# Model entries instead look like   ->   { "id": "xxx", ...
# so the two can never be confused, and we stop at the next provider block.

preset_field() {
	# preset_field <provider-id> <field>
	[ -f "$PRESETS" ] || return 1
	awk -v p="$1" -v f="$2" '
		/^[ \t]*"id"[ \t]*:/ {
			if (inb) exit                       # next provider block -> done
			if (index($0, "\"id\": \"" p "\"")) inb = 1
			next
		}
		inb && /^[ \t]*\{/ { next }              # array items, not provider fields
		inb && index($0, "\"" f "\"") {
			line = $0
			sub(/^[^:]*: */, "", line)
			gsub(/[",]/, "", line)
			gsub(/^[ \t]+|[ \t]+$/, "", line)
			print line
			exit
		}
	' "$PRESETS"
}

presets() {
	if [ -f "$PRESETS" ]; then cat "$PRESETS"; else printf '{"providers":[]}'; fi
}

models_of() {
	# models_of <provider> -> preset model ids
	[ -f "$PRESETS" ] || return 0
	awk -v p="$1" '
		/^[ \t]*"id"[ \t]*:/ {
			if (inb) exit                       # next provider block -> done
			if (index($0, "\"id\": \"" p "\"")) inb = 1
			next
		}
		inb && /^[ \t]*"models"[ \t]*:/ {
			if (index($0, "[]")) exit           # no curated models -> empty
			inm = 1; next
		}
		inm && /^[ \t]*\]/ { exit }             # end of the models array
		inm && /^[ \t]*\{[ \t]*"id"/ {
			line = $0
			sub(/^[^{]*\{[ \t]*"id"[ \t]*:[ \t]*"/, "", line)
			sub(/".*$/, "", line)
			gsub(/^[ \t]+|[ \t]+$/, "", line)
			if (line != "") print line
		}
	' "$PRESETS"
}

# ---------------------------------------------------------------- configured
# openclaw.json is the source of truth for providers the user already set up
# under models.providers.<id>. The CLI is not always runnable (fresh install,
# npm install in progress, broken upgrade), and live discovery then returns
# nothing - the catalogue must still show what is in the config file.
#
# The helpers below only read the file. jsonfilter (an OpenWrt base package,
# already a dependency of this package) is used when present; the awk scanners
# are a fallback that also cope with compact (single-line) JSON.

json_slice() {
	# json_slice <key>  (stdin: JSON text) -> the object/array value of "key"
	# String- and escape-aware, so braces/brackets inside strings do not
	# confuse it. Handles both pretty-printed and compact JSON.
	awk -v key="$1" '
		BEGIN { instr = 0; esc = 0; str = ""; last = ""; want = 0; cap = 0; depth = 0 }
		{
			s = $0 "\n"
			for (i = 1; i <= length(s); i++) {
				c = substr(s, i, 1)
				if (cap) {
					printf "%s", c
					if (instr) {
						if (esc) esc = 0
						else if (c == "\\") esc = 1
						else if (c == "\"") instr = 0
					} else {
						if (c == "\"") instr = 1
						else if (c == "{" || c == "[") depth++
						else if (c == "}" || c == "]") { depth--; if (depth == 0) exit }
					}
					continue
				}
				if (instr) {
					if (esc) { str = str c; esc = 0 }
					else if (c == "\\") esc = 1
					else if (c == "\"") { instr = 0; last = str }
					else str = str c
					continue
				}
				if (c == "\"") { instr = 1; str = ""; continue }
				if (c == ":" && last == key) want = 1
				else if (want && (c == "{" || c == "[")) {
					cap = 1; depth = 1; printf "%s", c; want = 0
				}
				else if (want && c != " " && c != "\t" && c != "\n" && c != "\r") want = 0
			}
		}
	'
}

json_keys() {
	# stdin: JSON object -> its direct member keys, one per line
	awk '
		BEGIN { depth = 0; instr = 0; esc = 0; expect = 0; buf = "" }
		{
			s = $0 "\n"
			for (i = 1; i <= length(s); i++) {
				c = substr(s, i, 1)
				if (instr) {
					if (esc) { buf = buf c; esc = 0 }
					else if (c == "\\") esc = 1
					else if (c == "\"") {
						instr = 0
						if (depth == 1 && expect) { print buf; expect = 0 }
					} else buf = buf c
					continue
				}
				if (c == "\"") { instr = 1; buf = ""; continue }
				if (c == "{") { depth++; if (depth == 1) expect = 1; continue }
				if (c == "}") { depth--; continue }
				if (c == "," && depth == 1) { expect = 1; continue }
				if (c == ":" && depth == 1) { expect = 0; continue }
			}
		}
	'
}

json_scalar() {
	# json_scalar <key>  (stdin: JSON object) -> scalar value of a direct member
	awk -v key="$1" '
		BEGIN { depth = 0; instr = 0; esc = 0; buf = ""; last = ""; want = 0; val = "" }
		{
			s = $0 "\n"
			for (i = 1; i <= length(s); i++) {
				c = substr(s, i, 1)
				if (instr) {
					if (esc) { buf = buf c; esc = 0 }
					else if (c == "\\") esc = 1
					else if (c == "\"") {
						instr = 0
						if (want) { print buf; exit }
						last = buf
					} else buf = buf c
					continue
				}
				if (want) {
					if (c == "\"") { instr = 1; buf = ""; continue }
					if (c == " " || c == "\t" || c == "\n" || c == "\r") continue
					if (c == "," || c == "}" || c == "]") { print val; exit }
					val = val c
					continue
				}
				if (c == "\"") { instr = 1; buf = ""; continue }
				if (c == "{" || c == "[") { depth++; continue }
				if (c == "}" || c == "]") { depth--; continue }
				if (c == ":" && depth == 1 && last == key) { want = 1; val = "" }
			}
		}
	'
}

json_model_ids() {
	# stdin: a models array -> model ids, one per line.
	# Accepts both [{"id":"x"},...] and ["x",...].
	awk '
		BEGIN { depth = 0; instr = 0; esc = 0; buf = ""; last = ""; want = 0 }
		{
			s = $0 "\n"
			for (i = 1; i <= length(s); i++) {
				c = substr(s, i, 1)
				if (instr) {
					if (esc) { buf = buf c; esc = 0 }
					else if (c == "\\") esc = 1
					else if (c == "\"") {
						instr = 0
						if (want) { if (buf != "") print buf; want = 0 }
						else if (depth == 1 && buf != "") print buf
						last = buf
					} else buf = buf c
					continue
				}
				if (c == "\"") { instr = 1; buf = ""; continue }
				if (c == "{" || c == "[") { if (want) want = 0; depth++; continue }
				if (c == "}" || c == "]") { depth--; continue }
				if (c == ":" && depth == 2 && last == "id") want = 1
				else if (c == ",") want = 0
			}
		}
	'
}

configured_providers() {
	# provider ids found under models.providers in openclaw.json
	local conf blk
	conf="$(oc_conf)"
	[ -f "$conf" ] || return 0
	blk=""
	if command -v jsonfilter >/dev/null 2>&1; then
		blk="$(jsonfilter -i "$conf" -e '$["models"]["providers"]' 2>/dev/null)"
	fi
	[ -n "$blk" ] || blk="$(json_slice providers <"$conf")"
	[ -n "$blk" ] || return 0
	printf '%s\n' "$blk" | json_keys
}

configured_field() {
	# configured_field <provider-id> <field> -> scalar from openclaw.json
	local p="$1" f="$2" conf v
	case "$p" in ''|*[!A-Za-z0-9_.-]*) return 1 ;; esac
	case "$f" in ''|*[!A-Za-z0-9_.-]*) return 1 ;; esac
	conf="$(oc_conf)"
	[ -f "$conf" ] || return 1
	v=""
	if command -v jsonfilter >/dev/null 2>&1; then
		v="$(jsonfilter -i "$conf" -e "\$[\"models\"][\"providers\"][\"$p\"][\"$f\"]" 2>/dev/null | head -n1)"
	fi
	[ -n "$v" ] || v="$(json_slice providers <"$conf" | json_slice "$p" | json_scalar "$f")"
	[ -n "$v" ] || return 1
	printf '%s\n' "$v"
}

configured_models() {
	# configured_models <provider-id> -> model ids from openclaw.json
	local p="$1" conf arr
	case "$p" in ''|*[!A-Za-z0-9_.-]*) return 0 ;; esac
	conf="$(oc_conf)"
	[ -f "$conf" ] || return 0
	arr=""
	if command -v jsonfilter >/dev/null 2>&1; then
		arr="$(jsonfilter -i "$conf" -e "\$[\"models\"][\"providers\"][\"$p\"][\"models\"]" 2>/dev/null)"
	fi
	[ -n "$arr" ] || arr="$(json_slice providers <"$conf" | json_slice "$p" | json_slice models)"
	[ -n "$arr" ] || return 0
	printf '%s\n' "$arr" | json_model_ids
}

# Parsing the config once per provider would mean one jsonfilter run each;
# catalog() needs the id list and a membership test per provider, so cache it.
OC_CONF_PROVIDERS=""
OC_CONF_PROVIDERS_READY=0
configured_list() {
	if [ "$OC_CONF_PROVIDERS_READY" != "1" ]; then
		OC_CONF_PROVIDERS="$(configured_providers)"
		OC_CONF_PROVIDERS_READY=1
	fi
	printf '%s' "$OC_CONF_PROVIDERS"
}

configured_has() {
	[ -n "${1:-}" ] || return 1
	printf '%s\n' "$(configured_list)" | grep -qxF -- "$1"
}

# ---------------------------------------------------------------- live discovery
OC_LIVE_RAW=""
OC_LIVE_READY=0
live_raw() {
	# `models list` / `providers list` start node and are expensive. catalog()
	# needs both provider ids and per-provider model ids, so run them once.
	if [ "$OC_LIVE_READY" != "1" ]; then
		OC_LIVE_RAW=""
		if [ -x "$(oc_oc_bin)" ]; then
			OC_LIVE_RAW="$({
				oc_run 20 models list --all
				oc_run 20 providers list
			} 2>/dev/null)"
		fi
		OC_LIVE_READY=1
	fi
	printf '%s' "$OC_LIVE_RAW"
}

live_providers() {
	# provider ids OpenClaw currently knows about
	live_raw | grep -o '[A-Za-z0-9._-]*/[A-Za-z0-9._:/-]*' | \
		awk -F/ '$1!="" && $2!="" {print $1}' | sort -u
}

live_models() {
	# live_models <provider>
	[ -x "$(oc_oc_bin)" ] || return 0
	local out
	out="$(oc_run_q 20 models list --all --provider "$1")"
	[ -n "$out" ] || out="$(oc_run_q 20 models list --provider "$1")"
	[ -n "$out" ] || return 0
	# 只认"像模型 id"的 token：必须有字母、不含路径片段、不以冒号结尾。
	# 宁可少列几个，也不能把 CLI 的报错文字当成模型塞进下拉框 —— 用户会以为
	# 那是能选的模型，选中后必然失败。
	printf '%s' "$out" | \
		grep -viE 'not found|no command|Try:|Docs:|Usage:|command not found|Permission denied' | \
		grep -v '^/' | \
		grep -o '[A-Za-z0-9][A-Za-z0-9._:/-]*' | \
		awk -v prov="$1" '
			length($0) < 3 { next }
			$0 ~ /[A-Z]/ { next }          # 模型 id 全是小写，大写只可能来自报错文字
			$0 ~ /\// && $0 !~ /^[a-z0-9._-]+\/[a-z0-9._:-]+$/ { next }
			$0 ~ /\.sh$/ || $0 ~ /:$/ { next }
			$0 !~ /[a-z]/ { next }
			$0 == prov { next }
			$0 ~ /^(id|name|model|models|provider|providers|all|list|true|false|null|default|none|help|usage|error|warn|warning|command|docs|https|current|openclaw)$/ { next }
			{ print }
		' | sort -u
}

live_models_of() {
	# live_models_of <provider> -> model ids parsed from the cached
	# `models list --all` output ("provider/model" pairs). No extra CLI call:
	# catalog() asks this for every provider.
	local p="$1"
	[ -n "$p" ] || return 0
	live_raw | grep -o '[A-Za-z0-9._-]*/[A-Za-z0-9._:/-]*' | \
		awk -F/ -v p="$p" '$1 == p { m = $0; sub("^[^/]*/", "", m); if (m != "") print m }' | \
		sort -u
}

# live_providers() itself walks the cached output; keep its result too so the
# per-provider source lookup does not re-run grep/awk each time.
OC_LIVE_PROVIDERS=""
OC_LIVE_PROVIDERS_READY=0
live_list() {
	if [ "$OC_LIVE_PROVIDERS_READY" != "1" ]; then
		OC_LIVE_PROVIDERS="$(live_providers)"
		OC_LIVE_PROVIDERS_READY=1
	fi
	printf '%s' "$OC_LIVE_PROVIDERS"
}

live_has() {
	[ -n "${1:-}" ] || return 1
	printf '%s\n' "$(live_list)" | grep -qxF -- "$1"
}

discover() {
	# discover <provider> -> JSON array (live first, presets as fallback)
	local p="$1" ids out first=1
	ids="$(live_models "$p")"
	[ -n "$ids" ] || ids="$(models_of "$p")"
	out="$(printf '%s' "$ids" | grep -v '^$' | sort -u)"
	printf '['
	printf '%s\n' "$out" | while IFS= read -r m; do
		[ -n "$m" ] || continue
		if [ "$first" = "1" ]; then printf '"%s"' "$(oc_json_str "$m")"; first=0
		else printf ',"%s"' "$(oc_json_str "$m")"; fi
	done
	printf ']'
}

# ---------------------------------------------------------------- plugins
# `plugins list` is expensive; catalog() asks for every provider, so cache it.
OC_PLUGINS_CACHE=""
OC_PLUGINS_CACHED=0
plugins_list_cached() {
	if [ "$OC_PLUGINS_CACHED" != "1" ]; then
		if [ -x "$(oc_oc_bin)" ]; then
			OC_PLUGINS_CACHE="$(oc_run 20 plugins list 2>/dev/null)"
		else
			OC_PLUGINS_CACHE=""
		fi
		OC_PLUGINS_CACHED=1
	fi
	printf '%s' "$OC_PLUGINS_CACHE"
}

plugin_installed() {
	# plugin_installed <provider>
	local plugin p
	plugin="$(preset_field "$1" plugin)"
	p="$1"
	if [ -n "$plugin" ] && [ -d "$(oc_oc_dir)/lib/node_modules/openclaw/node_modules/$plugin" ]; then
		return 0
	fi
	# global prefix layout: $OC_DIR/lib/node_modules/<plugin>. Scoped names keep
	# their "@scope/" part, so the previous `lib/node_modules/*/"$plugin"` glob
	# could never match an installed `@scope/name` (it needs one extra level).
	if [ -n "$plugin" ] && [ -d "$(oc_oc_dir)/lib/node_modules/$plugin" ]; then
		return 0
	fi
	if [ -n "$plugin" ] && plugins_list_cached | grep -qiF "$plugin"; then
		return 0
	fi
	if [ -z "$plugin" ]; then
		# built-in provider: it counts as "installed" as soon as OpenClaw exists
		[ -x "$(oc_oc_bin)" ] && return 0
		return 1
	fi
	grep -q "$p" "$(oc_conf)" 2>/dev/null && return 0
	return 1
}

require_plugin() {
	# require_plugin <provider> -> install the official plugin if needed
	oc_env
	local plugin
	plugin="$(preset_field "$1" plugin)"
	[ -n "$plugin" ] || { oc_info "$1 为 OpenClaw 内置 Provider，无需插件"; return 0; }
	if plugin_installed "$1"; then
		oc_info "插件已安装: $plugin"
		return 0
	fi
	oc_info "安装官方插件: $plugin"
	oc_run 300 plugins install "$plugin" 2>&1 | tee -a "$OC_TASKLOG"
	# the check above already populated the `plugins list` cache, so it still
	# describes the pre-install state; drop it before verifying the result
	OC_PLUGINS_CACHED=0
	if plugin_installed "$1"; then
		oc_info "插件安装完成: $plugin"
		return 0
	fi
	# fallback: plain npm install into the private prefix
	oc_warn "plugins install 未生效，改用 npm 直接安装"
	local npmcli
	# oc_npm_cli() 覆盖 private（<安装目录>/node）与 global（/usr/lib/nodejs）两种布局
	npmcli="$(oc_npm_cli)"
	if [ -n "$npmcli" ]; then
		HOME="$HOME" PATH="$PATH" timeout 300 "$(oc_node_bin)" "$npmcli" install -g \
			--prefix "$(oc_oc_dir)" \
			--registry "$(uci_get main.npm_registry https://registry.npmjs.org)" \
			--no-audit --no-fund "$plugin" 2>&1 | tee -a "$OC_TASKLOG"
	fi
	plugin_installed "$1"
}

# ---------------------------------------------------------------- state
provider_has_key() {
	# provider_has_key <provider>
	local envname
	envname="$(preset_field "$1" env)"
	if [ -n "$envname" ] && [ -f "$(oc_data_dir)/.env" ]; then
		grep -q "^${envname}=" "$(oc_data_dir)/.env" 2>/dev/null && return 0
	fi
	provider_configured "$1"
}

provider_configured() {
	[ -f "$(oc_conf)" ] || return 1
	grep -q "\"$1\"" "$(oc_conf)" 2>/dev/null
}

# ---------------------------------------------------------------- catalogue
merge_models() {
	# merge_models <provider> -> "<id>\t<source>" lines, highest priority first.
	# configured wins over live, live wins over presets; duplicates are dropped
	# so a model the user configured is never overwritten by a preset entry.
	local p="$1"
	# **不合并 live 层**：live_models_of 会触发 `openclaw models list --all`，
	# 一次 20 秒上限，而 catalog 要为每个 provider 调一次 —— 页面 20 秒就超时，
	# 下拉框于是长期空着（实机就是这个现象）。实时清单由「刷新上游模型」
	# 单独请求（models_url），不在首屏渲染路径上。
	{
		configured_models "$p" | awk -v s=configured 'NF { print $0 "\t" s }'
		models_of "$p" | awk -v s=preset 'NF { print $0 "\t" s }'
	} | awk 'BEGIN { FS = "\t" } NF && !seen[$1]++ { print $1 "\t" $2 }'
}

catalog() {
	# JSON array describing every provider this box knows about: configured
	# (openclaw.json) first, then live discovery, then shipped presets.
	local all id first=1 name plugin defm base keyurl m msrc mfirst src tab
	tab="$(printf '\t')"
	# 只从「已配置」+「内置预设」建表，**不启动 CLI**：
	# live_list 要跑两次 openclaw（models list --all / providers list），
	# 每次 20 秒上限，最坏 40 秒；而页面 20 秒就超时 —— 下拉框于是长时间空着，
	# 看起来就是「读不出服务商」。实时清单只在用户点「刷新上游模型」时才用。
	all="$({
		configured_list
		preset_ids
	} | grep -v '^$' | awk '!seen[$0]++')"
	printf '['
	for id in $all; do
		[ -n "$id" ] || continue
		name="$(preset_field "$id" name)"; [ -n "$name" ] || name="$id"
		plugin="$(preset_field "$id" plugin)"
		defm="$(preset_field "$id" defaultModel)"
		base="$(preset_field "$id" baseUrl)"
		keyurl="$(preset_field "$id" keyUrl)"
		# A provider that only exists in openclaw.json has no preset metadata:
		# show its configured endpoint and its first configured model.
		[ -n "$base" ] || base="$(configured_field "$id" baseUrl)"
		[ -n "$defm" ] || defm="$(configured_models "$id" | head -n1)"
		src="preset"
		if configured_has "$id"; then
			src="configured"
		fi
		[ "$first" = "1" ] || printf ','
		first=0
		printf '{"id":"%s","name":"%s","plugin":"%s","source":"%s","bundled":%s,"installed":%s,"configured":%s,"hasKey":%s,"defaultModel":"%s","baseUrl":"%s","keyUrl":"%s","models":[' \
			"$(oc_json_str "$id")" "$(oc_json_str "$name")" "$(oc_json_str "${plugin:-}")" "$src" \
			"$([ -n "$plugin" ] && echo false || echo true)" \
			"$(plugin_installed "$id" && echo true || echo false)" \
			"$(provider_configured "$id" && echo true || echo false)" \
			"$(provider_has_key "$id" && echo true || echo false)" \
			"$(oc_json_str "${defm:-}")" "$(oc_json_str "${base:-}")" "$(oc_json_str "${keyurl:-}")"
		mfirst=1
		merge_models "$id" | while IFS="$tab" read -r m msrc; do
			[ -n "$m" ] || continue
			[ "$mfirst" = "1" ] || printf ','
			mfirst=0
			printf '{"id":"%s","name":"%s","source":"%s"}' \
				"$(oc_json_str "$m")" "$(oc_json_str "$m")" "$(oc_json_str "${msrc:-preset}")"
		done
		printf ']}'
	done
	printf ']'
}

# ---------------------------------------------------------------- upstream models
# 「刷新上游模型」：按 provider 的 Base URL 直接问上游要一份模型清单。
# 只读、无副作用；stdout 只允许出现一行 JSON，诊断信息一律走 stderr。
#
# 清单分三级，优先级从高到低：
#   1. 有 API Key  -> 问 provider 自己的 Base URL（权威、实时）
#   2. 没有 Key    -> 问公开模型目录（无需鉴权，实时；绝不携带凭据）
#   3. 都失败      -> 由前端回退到随包发布的内置清单
# 返回的 JSON 里带 "source"（upstream / public），前端据此告诉用户清单来源。
#
# 密钥绝不能进 argv（/proc/<pid>/cmdline 全局可读）：Key 从 .env 读出后通过
# curl 的 --config - 从 stdin 交给 curl，命令行里只有 URL 和固定参数。
# 不传 -k：证书校验失败就应当失败，而不是静默降级。

models_url_fail() {
	printf '{"ok":false,"error":"%s"}\n' "$(oc_json_str "$1")"
}

# 公开模型目录：GET，无需鉴权。返回 {"data":[{"id":"z-ai/glm-5.3",...}]}。
PUBLIC_MODELS_URL="https://openrouter.ai/api/v1/models"

public_prefix() {
	# public_prefix <provider> -> 公开目录里的厂商前缀；无映射时返回 1。
	# 没在表里的 provider 不做公开目录查询，直接按原来的方式报错。
	case "$1" in
		zai)       printf '%s' 'z-ai' ;;
		openai)    printf '%s' 'openai' ;;
		deepseek)  printf '%s' 'deepseek' ;;
		anthropic) printf '%s' 'anthropic' ;;
		google)    printf '%s' 'google' ;;
		moonshot)  printf '%s' 'moonshotai' ;;
		minimax)   printf '%s' 'minimax' ;;
		*)         return 1 ;;
	esac
}

models_public() {
	# models_public <provider> <base-url> <env-name> -> JSON (source=public) / 1
	# 只在「没有 API Key」时调用：请求公开目录，请求里不含任何凭据。
	# 成功时 baseUrl 仍是该 provider 自己的地址（后续 apply 会用到），
	# 不是公开目录的地址。
	local p="$1" base="$2" envname="$3" prefix body errf code rc msg ids first m
	prefix="$(public_prefix "$p")" || return 1

	if ! command -v curl >/dev/null 2>&1; then
		oc_warn "系统缺少 curl，无法访问公开模型目录"
		return 1
	fi
	if [ ! -d "$OC_RUNDIR" ] || [ ! -w "$OC_RUNDIR" ]; then
		oc_warn "临时目录不可用"
		return 1
	fi

	body="$OC_RUNDIR/models-public.$$.json"
	errf="$OC_RUNDIR/models-public.$$.err"
	# 公开目录不需要 Authorization：这里刻意不写任何 header 文件。
	code="$(oc_timeout 20 curl -sS --max-time 20 --connect-timeout 10 \
		-H 'Accept: application/json' -o "$body" -w '%{http_code}' \
		"$PUBLIC_MODELS_URL" 2>"$errf")"
	rc=$?

	if [ "$rc" -ne 0 ]; then
		msg="$(head -n1 "$errf" 2>/dev/null)"
		rm -f "$body" "$errf"
		[ -n "$msg" ] || msg="curl 退出码 $rc"
		oc_warn "公开模型目录不可用：$msg"
		return 1
	fi
	if [ "$code" != "200" ]; then
		rm -f "$body" "$errf"
		oc_warn "公开模型目录返回 HTTP ${code:-未知}"
		return 1
	fi

	# jsonfilter 是 OpenWrt 基础包且比逐字符 awk 快得多；缺失时回退到
	# json_slice + json_model_ids（与上游解析共用同一套解析器）。
	ids=""
	if command -v jsonfilter >/dev/null 2>&1; then
		ids="$(jsonfilter -i "$body" -e '$["data"][*]["id"]' 2>/dev/null)"
	fi
	[ -n "$ids" ] || ids="$(json_slice data <"$body" 2>/dev/null | json_model_ids)"
	rm -f "$body" "$errf"

	# 只留 "<prefix>/" 开头的条目，去掉前缀；丢弃 ~ 别名与 :batch 变体。
	ids="$(printf '%s\n' "$ids" | while IFS= read -r m; do
		case "$m" in
			"$prefix"/*) ;;
			*) continue ;;
		esac
		m="${m#*/}"
		case "$m" in
			''|'~'*|*:batch) continue ;;
		esac
		printf '%s\n' "$m"
	done | sort -u)"
	if [ -z "$ids" ]; then
		oc_warn "公开模型目录中没有 ${prefix}/* 的可用条目（${envname} 未配置）"
		return 1
	fi

	printf '{"ok":true,"source":"public","baseUrl":"%s","models":[' "$(oc_json_str "$base")"
	first=1
	printf '%s\n' "$ids" | while IFS= read -r m; do
		[ -n "$m" ] || continue
		if [ "$first" = "1" ]; then
			printf '"%s"' "$(oc_json_str "$m")"
			first=0
		else
			printf ',"%s"' "$(oc_json_str "$m")"
		fi
	done
	printf ']}\n'
	return 0
}

env_key() {
	# env_key <VAR_NAME> -> value from the OpenClaw .env, empty when absent.
	# 唯一权威位置是 oc_env_file()（= state_dir/.env）；apply() 也只写这里。
	# 旧位置 $HOME/.openclaw/.env 只作向后兼容：升级前写下的 key 可能还留在
	# 那里。state_dir 被覆盖后旧位置可能存在过期值，所以必须放在后面读，
	# 不能让它盖过新值。
	local name="$1" f v
	for f in "$(oc_env_file)" "$HOME/.openclaw/.env"; do
		[ -f "$f" ] || continue
		v="$(grep "^${name}=" "$f" 2>/dev/null | tail -n1 | sed 's/^[^=]*=//')"
		[ -n "$v" ] || continue
		# tolerate a hand-edited NAME="value" / NAME='value'
		case "$v" in
			\"*\") v="${v#\"}"; v="${v%\"}" ;;
			\'*\') v="${v#\'}"; v="${v%\'}" ;;
		esac
		printf '%s' "$v"
		return 0
	done
	return 0
}

models_url() {
	# models_url <provider-id> -> {"ok":true,"source":"...","baseUrl":"...","models":[...]}
	local p="${1:-}" base url envname key esc code rc body errf ids first m msg
	case "$p" in
		''|*[!A-Za-z0-9_.-]*|-*) models_url_fail "Provider 名称无效"; return 1 ;;
	esac

	oc_env
	base="$(configured_field "$p" baseUrl)"
	[ -n "$base" ] || base="$(preset_field "$p" baseUrl)"
	if [ -z "$base" ]; then
		models_url_fail "该 provider 没有 Base URL"
		return 1
	fi
	if ! oc_safe_url "$base"; then
		models_url_fail "Base URL 不合法（只支持 http/https）：$base"
		return 1
	fi

	# Variable name mirrors apply(): the preset's env field, otherwise
	# <UPPER(provider)>_API_KEY.
	envname="$(preset_field "$p" env)"
	[ -n "$envname" ] || envname="$(printf '%s' "$p" | tr 'a-z' 'A-Z')_API_KEY"
	case "$envname" in
		''|*[!A-Za-z0-9_]*) models_url_fail "无法确定该 provider 的 API Key 变量名"; return 1 ;;
	esac
	key="$(env_key "$envname" | head -n1)"
	if [ -z "$key" ]; then
		# 没有 Key 不等于没有实时清单：先问公开目录（无需鉴权、不带凭据）。
		# 取不到（无映射 / 网络失败 / 一条都没有）才走原来的报错路径。
		models_public "$p" "$base" "$envname" && return 0
		models_url_fail "未找到 ${envname}，请先在模型页填写并保存 API Key"
		return 1
	fi

	if ! command -v curl >/dev/null 2>&1; then
		models_url_fail "系统缺少 curl，无法访问上游"
		return 1
	fi
	if [ ! -d "$OC_RUNDIR" ] || [ ! -w "$OC_RUNDIR" ]; then
		models_url_fail "临时目录不可用"
		return 1
	fi

	# strip trailing slashes, then append the OpenAI-compatible path
	url="$base"
	while [ "${url%/}" != "$url" ]; do url="${url%/}"; done
	url="$url/models"

	# curl config syntax: backslash first, then the double quote
	esc="$(printf '%s' "$key" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
	body="$OC_RUNDIR/models-url.$$.json"
	errf="$OC_RUNDIR/models-url.$$.err"
	code="$(printf 'header = "Authorization: Bearer %s"\n' "$esc" | \
		oc_timeout 20 curl -sS --max-time 20 --connect-timeout 10 \
			-H 'Accept: application/json' -o "$body" -w '%{http_code}' \
			--config - "$url" 2>"$errf")"
	rc=$?

	if [ "$rc" -ne 0 ]; then
		msg="$(head -n1 "$errf" 2>/dev/null)"
		rm -f "$body" "$errf"
		[ -n "$msg" ] || msg="curl 退出码 $rc"
		models_url_fail "无法连接上游：$msg"
		return 1
	fi

	case "$code" in
		200) ;;
		401|403)
			rm -f "$body" "$errf"
			models_url_fail "上游拒绝访问（HTTP $code），API Key 可能无效或无权限"
			return 1 ;;
		404)
			rm -f "$body" "$errf"
			models_url_fail "上游没有 /models 接口（HTTP 404）"
			return 1 ;;
		''|*[!0-9]*)
			rm -f "$body" "$errf"
			models_url_fail "未取得 HTTP 状态码"
			return 1 ;;
		*)
			rm -f "$body" "$errf"
			models_url_fail "上游返回 HTTP $code"
			return 1 ;;
	esac

	# {"data":[{"id":"..."}]} (and, for good measure, ["..."])
	ids="$(json_slice data <"$body" 2>/dev/null | json_model_ids)"
	rm -f "$body" "$errf"
	ids="$(printf '%s\n' "$ids" | grep -v '^[[:space:]]*$' | sort -u)"
	if [ -z "$ids" ]; then
		models_url_fail "上游返回的内容中没有可识别的模型列表（HTTP 200）"
		return 1
	fi

	printf '{"ok":true,"source":"upstream","baseUrl":"%s","models":[' "$(oc_json_str "$base")"
	first=1
	printf '%s\n' "$ids" | while IFS= read -r m; do
		[ -n "$m" ] || continue
		if [ "$first" = "1" ]; then
			printf '"%s"' "$(oc_json_str "$m")"
			first=0
		else
			printf ',"%s"' "$(oc_json_str "$m")"
		fi
	done
	printf ']}\n'
}

# ---------------------------------------------------------------- apply
apply() {
	# apply <provider> <apikey|-> [model] [baseurl]
	# apply <provider> --key-file <path> [model] [baseurl]
	#
	# 密钥绝不能出现在 argv 里：/proc/<pid>/cmdline 是全局可读的，任何本地用户
	# 都能在 helper 运行期间读到它。所以支持两种"不进 argv"的传法：
	#   --key-file <path>  从 600 的临时文件读（LuCI 控制器用这个）
	#   -                  从 $OC_APPLY_KEY 环境变量读（命令行用法）
	local provider="$1" key="" kf="" model="" base="" envname=""
	shift
	case "${1:-}" in
		--key-file) kf="${2:-}"; shift 2 ;;
		-)          key="${OC_APPLY_KEY:-}"; shift ;;
		'')         shift ;;
		*)          key="$1"; shift ;;
	esac
	model="${1:-}"; base="${2:-}"
	if [ -n "$kf" ]; then
		[ -f "$kf" ] || { oc_err "密钥文件不存在：$kf"; return 1; }
		key="$(head -n1 "$kf" 2>/dev/null)"
	fi
	oc_env
	[ -x "$OC_BIN" ] || { oc_err "OpenClaw 未安装"; return 1; }
	[ -n "$provider" ] || { oc_err "未指定 Provider"; return 1; }

	# provider id is interpolated into config keys and into a .env variable
	# name. Anything outside [A-Za-z0-9_-] could escape either one.
	case "$provider" in
		*[!A-Za-z0-9_-]* ) oc_err "Provider 名称含非法字符：$provider"; return 1 ;;
	esac

	if [ "$provider" = "custom" ] && [ -z "$base" ]; then
		oc_err "自定义 Provider 需要 Base URL"; return 1
	fi
	if [ -n "$base" ]; then
		oc_safe_url "$base" || { oc_err "Base URL 不合法：$base"; return 1; }
	fi
	[ -n "$model" ] || model="$(preset_field "$provider" defaultModel)"
	case "$model" in
		*'$'*|*'`'*|*';'*|*'|'*|*'&'*|*'<'*|*'>'* )
			oc_err "模型名含非法字符（\$ \` ; | & < >）"; return 1 ;;
	esac

	# 1) provider plugin (DeepSeek etc.)
	# A failed plugin install must not be swallowed: the key is still stored
	# below (that part is independent), but the user has to know the provider
	# is not usable yet.
	if ! require_plugin "$provider"; then
		oc_warn "插件未安装成功：$provider（Key 仍会写入，可稍后在模型页重试安装）"
	fi

	# 2) credential into .env so the gateway process sees it
	if [ -n "$key" ]; then
		local envfile
		envname="$(preset_field "$provider" env)"
		[ -n "$envname" ] || envname="$(printf '%s' "$provider" | tr 'a-z' 'A-Z')_API_KEY"

		# An API key is pasted into a LuCI text box and written straight into
		# .env. A key containing a newline would append extra variable lines
		# (and the gateway reads them), so the value is checked and flattened.
		case "$envname" in
			*[!A-Za-z0-9_]* ) oc_err "环境变量名不合法：$envname"; return 1 ;;
		esac
		case "$key" in
			*'$'*|*'`'*|*';'*|*'|'*|*'&'*|*'<'*|*'>'* )
				oc_err "API Key 含不允许的字符（\$ \` ; | & < >）"; return 1 ;;
		esac
		key="$(printf '%s' "$key" | tr -d '\000-\010\013\014\016-\037\177' 2>/dev/null || printf '%s' "$key")"
		# keep only the first line: a pasted key must never span lines
		key="$(printf '%s' "$key" | head -n1)"
		[ -n "$key" ] || { oc_err "API Key 为空"; return 1; }

		# 统一走 oc_env_file()（= state_dir/.env）：provider_has_key() 与
		# env_key() 读的是同一份，CLI/网关（OPENCLAW_STATE_DIR 已由 lib.sh 导出）
		# 也看这里。state_dir 被 main.state_dir 覆盖时不能再写 $HOME/.openclaw，
		# 否则写进去的 key 页面看不见、网关也读不到。
		envfile="$(oc_env_file)"
		mkdir -p "$(dirname "$envfile")"
		touch "$envfile"
		chmod 600 "$envfile" 2>/dev/null
		grep -v "^${envname}=" "$envfile" >"$envfile.tmp" 2>/dev/null
		printf '%s=%s\n' "$envname" "$key" >>"$envfile.tmp"
		mv "$envfile.tmp" "$envfile"
		chmod 600 "$envfile" 2>/dev/null
	fi

	# 3) explicit provider config
	# The key must never travel through argv: oc_run execs the CLI, so a plaintext
	# key would sit in /proc/<pid>/cmdline (world readable) for as long as the
	# command runs. OpenClaw wants credentials as SecretRefs anyway, so point the
	# config at the variable we just wrote to .env. Old versions do not know the
	# --ref-* flags; for those we fall back to the legacy plaintext form, loudly.
	if [ -n "$key" ]; then
		if ! oc_run 60 config set "models.providers.${provider}.apiKey" \
			--ref-provider default --ref-source env --ref-id "$envname" >/dev/null 2>&1
		then
			oc_warn "当前 OpenClaw 版本不支持 SecretRef，密钥只能以明文写入配置（已写入 .env，建议升级 OpenClaw 后重跑本步）"
			oc_run 60 config set "models.providers.${provider}.apiKey" "$key" >/dev/null 2>&1 \
				|| oc_warn "API Key 写入配置失败：$provider（已写入 .env，可稍后重试）"
		fi
	fi
	if [ -n "$base" ]; then
		oc_run 60 config set "models.providers.${provider}.baseUrl" "$base" >/dev/null 2>&1
	else
		base="$(preset_field "$provider" baseUrl)"
		[ -n "$base" ] && oc_run 60 config set "models.providers.${provider}.baseUrl" "$base" >/dev/null 2>&1
	fi
	local api
	api="$(preset_field "$provider" api)"
	[ -n "$api" ] && oc_run 60 config set "models.providers.${provider}.api" "$api" >/dev/null 2>&1

	# 4) default model
	if [ -n "$model" ]; then
		oc_run 60 config set agents.defaults.model.primary "${provider}/${model}" 2>&1 | tee -a "$OC_TASKLOG"
	fi

	oc_fix_perms
	oc_info "已应用：${provider}/${model}"
	return 0
}

setkey() {
	# setkey <provider> <apikey>
	apply "$1" "$2" "" ""
}

current() {
	oc_env
	# 直接读 oc_conf()（= state_dir/openclaw.json）：state_dir 被 main.state_dir
	# 覆盖时，$HOME/.openclaw/openclaw.json 可能根本不存在或已过期。
	local v="" conf
	conf="$(oc_conf)"
	if [ -f "$conf" ]; then
		v="$(oc_json_get "$conf" '$.agents.defaults.model.primary' 2>/dev/null)"
		[ -n "$v" ] || v="$(grep -o '"primary"[^,]*' "$conf" 2>/dev/null | head -n1 | sed 's/.*: *"//; s/"//')"
	fi
	printf '%s' "$v"
}

case "${1:-}" in
	presets)   presets ;;
	catalog)   catalog ;;
	providers) catalog ;;
	models)    discover "$2" ;;
	models-url) models_url "$2" ;;
	discover)  discover "$2" ;;
	apply)     shift; apply "$@" ;;
	setkey)    shift; setkey "$@" ;;
	plugin)    require_plugin "$2" ;;
	install)   require_plugin "$2" ;;
	current)   current && printf '\n' ;;
	field)     preset_field "$2" "$3" ;;
	*)
		cat <<EOF
Usage: models.sh {catalog|models <provider>|models-url <provider>|apply <provider> <key> [model] [base]|plugin <provider>|current}

  catalog                 every provider OpenClaw supports (JSON, with state)
  models <provider>       model ids (live from OpenClaw, presets as fallback)
  models-url <provider>   ask the provider's Base URL for its model list (JSON)
  apply <provider> <key> [model] [base]
                          install plugin + store key + set default model
  plugin <provider>       install only the provider plugin
  current                 current default model
EOF
		;;
esac
