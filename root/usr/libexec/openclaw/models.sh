#!/bin/sh
# openclaw - model provider configuration
#
# The model catalogue is built from what OpenClaw itself supports:
#   1. curated presets shipped with this package (offline fallback)
#   2. live discovery from the installed OpenClaw (`openclaw models list --all`)
#   3. manual model id input
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
	# oc_run <timeout> <args...>
	local t="$1"; shift
	HOME="$(oc_home_dir)" PATH="$(oc_node_dir)/bin:$(oc_oc_dir)/bin:$PATH" \
		timeout "$t" "$(oc_oc_bin)" "$@" 2>&1
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

# ---------------------------------------------------------------- live discovery
live_providers() {
	# provider ids OpenClaw currently knows about
	[ -x "$(oc_oc_bin)" ] || return 0
	{
		oc_run 20 models list --all
		oc_run 20 providers list
	} 2>/dev/null | grep -o '[A-Za-z0-9._-]*/[A-Za-z0-9._:/-]*' | \
		awk -F/ '$1!="" && $2!="" {print $1}' | sort -u
}

live_models() {
	# live_models <provider>
	[ -x "$(oc_oc_bin)" ] || return 0
	local out
	out="$(oc_run 20 models list --all --provider "$1")"
	[ -n "$out" ] || out="$(oc_run 20 models list --provider "$1")"
	[ -n "$out" ] || return 0
	printf '%s' "$out" | grep -o '[A-Za-z0-9._:/-]*' | \
		awk 'length($0) < 3 { next } /^(id|name|model|provider|models|all|list)$/ { next } { print }' | \
		sort -u
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
		if [ "$first" = "1" ]; then printf '"%s"' "$m"; first=0
		else printf ',"%s"' "$m"; fi
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
	npmcli="$(oc_node_dir)/lib/node_modules/npm/bin/npm-cli.js"
	[ -f "$npmcli" ] || npmcli="$(find "$(oc_node_dir)" -name npm-cli.js 2>/dev/null | head -n1)"
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
catalog() {
	# JSON array describing every provider OpenClaw supports here
	local all id first=1 name plugin defm base keyurl m mfirst
	all="$(preset_ids)"
	if [ -x "$(oc_oc_bin)" ]; then
		all="$(printf '%s\n%s\n' "$all" "$(live_providers)" | grep -v '^$' | awk '!seen[$0]++')"
	fi
	printf '['
	for id in $all; do
		[ -n "$id" ] || continue
		name="$(preset_field "$id" name)"; [ -n "$name" ] || name="$id"
		plugin="$(preset_field "$id" plugin)"
		defm="$(preset_field "$id" defaultModel)"
		base="$(preset_field "$id" baseUrl)"
		keyurl="$(preset_field "$id" keyUrl)"
		[ "$first" = "1" ] || printf ','
		first=0
		printf '{"id":"%s","name":"%s","plugin":"%s","bundled":%s,"installed":%s,"configured":%s,"hasKey":%s,"defaultModel":"%s","baseUrl":"%s","keyUrl":"%s","models":[' \
			"$id" "$name" "${plugin:-}" \
			"$([ -n "$plugin" ] && echo false || echo true)" \
			"$(plugin_installed "$id" && echo true || echo false)" \
			"$(provider_configured "$id" && echo true || echo false)" \
			"$(provider_has_key "$id" && echo true || echo false)" \
			"${defm:-}" "${base:-}" "${keyurl:-}"
		mfirst=1
		for m in $(models_of "$id"); do
			[ "$mfirst" = "1" ] || printf ','
			mfirst=0
			printf '{"id":"%s","name":"%s"}' "$m" "$m"
		done
		printf ']}'
	done
	printf ']'
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
	local provider="$1" key="" kf="" model="" base=""
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
		local envname envfile
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

		envfile="$HOME/.openclaw/.env"
		mkdir -p "$HOME/.openclaw"
		touch "$envfile"
		chmod 600 "$envfile" 2>/dev/null
		grep -v "^${envname}=" "$envfile" >"$envfile.tmp" 2>/dev/null
		printf '%s=%s\n' "$envname" "$key" >>"$envfile.tmp"
		mv "$envfile.tmp" "$envfile"
		chmod 600 "$envfile" 2>/dev/null
	fi

	# 3) explicit provider config
	[ -n "$key" ] && oc_run 60 config set "models.providers.${provider}.apiKey" "$key" >/dev/null 2>&1
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
	local v=""
	if [ -f "$HOME/.openclaw/openclaw.json" ]; then
		v="$(oc_json_get "$HOME/.openclaw/openclaw.json" '$.agents.defaults.model.primary' 2>/dev/null)"
		[ -n "$v" ] || v="$(grep -o '"primary"[^,]*' "$HOME/.openclaw/openclaw.json" 2>/dev/null | head -n1 | sed 's/.*: *"//; s/"//')"
	fi
	printf '%s' "$v"
}

case "${1:-}" in
	presets)   presets ;;
	catalog)   catalog ;;
	providers) catalog ;;
	models)    discover "$2" ;;
	discover)  discover "$2" ;;
	apply)     shift; apply "$@" ;;
	setkey)    shift; setkey "$@" ;;
	plugin)    require_plugin "$2" ;;
	install)   require_plugin "$2" ;;
	current)   current && printf '\n' ;;
	field)     preset_field "$2" "$3" ;;
	*)
		cat <<EOF
Usage: models.sh {catalog|models <provider>|apply <provider> <key> [model] [base]|plugin <provider>|current}

  catalog                 every provider OpenClaw supports (JSON, with state)
  models <provider>       model ids (live from OpenClaw, presets as fallback)
  apply <provider> <key> [model] [base]
                          install plugin + store key + set default model
  plugin <provider>       install only the provider plugin
  current                 current default model
EOF
		;;
esac
