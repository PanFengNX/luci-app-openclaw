#!/bin/sh
# openclaw - messaging channel helpers (WeChat / Feishu / Telegram / Discord)

OC_LIB="/usr/libexec/openclaw/lib.sh"
. "$OC_LIB"

oc_env() {
	export HOME="$(oc_home_dir)"
	export PATH="$(oc_node_dir)/bin:$(oc_oc_dir)/bin:$PATH"
	OC_BIN="$(oc_oc_bin)"
	NPM_BIN="$(oc_node_dir)/bin/npm"
	[ -x "$NPM_BIN" ] || NPM_BIN="$(command -v npm)"
}

weixin_precheck() {
	oc_info "== 微信插件前置检查 =="
	grep -q "^$(id -un 2>/dev/null):" /etc/passwd 2>/dev/null
	command -v python3 >/dev/null 2>&1 || oc_warn "未安装 python3，插件可能需要：$(oc_pkg_install_hint) python3-light"
	local d
	for d in "$(oc_home_dir)" "$(oc_base_dir)" /tmp; do
		mkdir -p "$d" 2>/dev/null
		[ -w "$d" ] || oc_warn "目录不可写: $d"
	done
	# connectivity
	if command -v curl >/dev/null 2>&1; then
		curl -s -m 10 -o /dev/null -w "ilinkai: %{http_code}\n" https://ilinkai.weixin.qq.com 2>/dev/null | tee -a "$OC_TASKLOG"
	fi
}

weixin_install() {
	oc_env
	[ -x "$OC_BIN" ] || { oc_err "OpenClaw 未安装"; return 1; }
	weixin_precheck
	oc_info "安装微信插件（官方 CLI）"
	HOME="$HOME" PATH="$PATH" timeout 600 "$NPM_BIN" exec -y \
		@tencent-weixin/openclaw-weixin-cli@latest -- install 2>&1 | tee -a "$OC_TASKLOG"

	# make sure the plugin is registered even if the CLI is silent
	HOME="$HOME" PATH="$PATH" "$OC_BIN" config set plugins.entries.openclaw-weixin.enabled true >/dev/null 2>&1
	HOME="$HOME" PATH="$PATH" "$OC_BIN" config set channels.openclaw-weixin.enabled true >/dev/null 2>&1
	# migrate legacy channel name
	if grep -q '"weixin"' "$HOME/.openclaw/openclaw.json" 2>/dev/null; then
		HOME="$HOME" PATH="$PATH" "$OC_BIN" config set channels.openclaw-weixin.enabled true >/dev/null 2>&1
	fi
	oc_fix_perms
	oc_info "重启网关以加载插件"
	/etc/init.d/openclaw restart
}

weixin_login() {
	oc_env
	[ -x "$OC_BIN" ] || { oc_err "OpenClaw 未安装"; return 1; }
	HOME="$HOME" PATH="$PATH" timeout 150 "$OC_BIN" channels login --channel openclaw-weixin 2>&1 | tee -a "$OC_TASKLOG"
}

list() {
	local conf
	conf="$(oc_conf)"
	[ -f "$conf" ] || { printf '(未配置渠道)\n'; return 0; }
	if command -v jsonfilter >/dev/null 2>&1; then
		# `$.channels` is an object, and jsonfilter prints one leaf per line for
		# a non-scalar expression - a `head -n1` here returned a fragment of
		# invalid JSON. Print the whole subtree and let the UI show it as text.
		if ! jsonfilter -i "$conf" -e '$.channels' 2>/dev/null; then
			printf '(未配置渠道)\n'
		fi
	else
		# no jsonfilter: fall back to a bounded slice of the raw section
		sed -n '/"channels"[[:space:]]*:/,/^[[:space:]]*}/p' "$conf" 2>/dev/null | head -c 4000
	fi
}

case "${1:-}" in
	weixin)
		case "${2:-}" in
			install) weixin_install ;;
			login)   weixin_login ;;
			status)  list ;;
			*) echo "Usage: channels.sh weixin {install|login|status}" ;;
		esac
		;;
	list) list ;;
	*) echo "Usage: channels.sh {weixin {install|login|status}|list}" ;;
esac
