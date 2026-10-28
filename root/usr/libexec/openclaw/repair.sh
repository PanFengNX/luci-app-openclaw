#!/bin/sh
# openclaw - one click repair
#
# Fixes the things that most commonly break a native OpenClaw deployment on
# OpenWrt: ownership/permissions, missing directories, a corrupted
# openclaw.json, a lost executable bit, a stale init script, a port conflict
# and a missing CA bundle.
#
# Usage: repair.sh [--json] [--no-restart]

OC_LIB="/usr/libexec/openclaw/lib.sh"
. "$OC_LIB"

INITD="/etc/init.d/openclaw"
JSON=0
RESTART=1
FIXED=0
WARNS=0
FAILS=0
OUT=""

[ "${1:-}" = "--json" ] && JSON=1
OWNER_FIX=0
for a in "$@"; do
	case "$a" in
		--json) JSON=1 ;;
		--no-restart) RESTART=0 ;;
		# owner-fix：只修属主，不做其它检查。init 的断言失败时会提示这条命令，
		# 所以它必须存在 —— 提示里给一条不存在的命令等于没给。
		owner-fix) OWNER_FIX=1 ;;
	esac
done

if [ "$OWNER_FIX" = "1" ]; then
	# 显式维护路径：允许递归修正（这是 I4 的例外）。
	# 启动路径只断言不修，修只能由用户显式触发 —— 这样"改错了"永远是
	# 用户主动选择的结果，而不是启动时静默发生的副作用。
	_fix_owner_tree() {
		local d="$1"
		[ -d "$d" ] || return 0
		if grep -q "^${OC_USER}:" /etc/passwd 2>/dev/null; then
			chown -R "$OC_USER:$OC_USER" "$d" 2>/dev/null || \
				printf '警告：%s 属主修正未完全成功\n' "$d" >&2
		fi
		chmod -R u+rwX "$d" 2>/dev/null || true
		printf '已修正属主：%s\n' "$d"
	}
	_fix_owner_tree "$HOME_DIR"
	_fix_owner_tree "$DATA"
	_fix_owner_tree "$BASE/logs"
	_fix_owner_tree "$BASE/tmp"
	# 顺手清掉别的身份留下的临时根（只匹配 openclaw-<数字>）
	if command -v oc_sweep_stale_tmp >/dev/null 2>&1; then
		oc_sweep_stale_tmp
	fi
	if command -v oc_pin_system_tmp_root >/dev/null 2>&1; then
		oc_pin_system_tmp_root
	fi
	printf '属主修正完成。请重启服务：/etc/init.d/openclaw restart\n'
	exit 0
fi

finish() {
	if [ "$JSON" = "1" ]; then
		printf '{"ok":%s,"fixed":%s,"warn":%s,"fail":%s,"items":[%s]}\n' \
			"$([ "$FAILS" = "0" ] && echo true || echo false)" \
			"$FIXED" "$WARNS" "$FAILS" "$(printf '%s' "$OUT" | sed 's/,$//')"
	else
		printf '\n修复完成：已修复 %s 项，警告 %s 项，错误 %s 项\n' "$FIXED" "$WARNS" "$FAILS"
	fi
	# exit non-zero when something actually failed, so callers (and the async
	# diag poll) can tell "repair ran" from "repair ran and did not succeed"
	[ "$FAILS" = "0" ] || exit 1
	exit 0
}

say() {
	# say <OK|FIX|WARN|FAIL> <message>
	local lvl="$1"; shift
	case "$lvl" in
		FIX) FIXED=$((FIXED + 1)) ;;
		WARN) WARNS=$((WARNS + 1)) ;;
		FAIL) FAILS=$((FAILS + 1)) ;;
	esac
	if [ "$JSON" = "1" ]; then
		# oc_json_str escapes quotes/backslashes and strips control chars;
		# the previous sed pass left backslashes raw, which breaks JSON.parse
		OUT="$OUT{\"level\":\"$lvl\",\"msg\":\"$(oc_json_str "$*")\"},"
	else
		printf '[%s] %s\n' "$lvl" "$*"
	fi
}

if ! oc_validate_base_dir "$(oc_base_dir)"; then
	say FAIL "安装目录不安全：$(oc_base_dir)（请先在状态页改为 /mnt/.../OpenClaw）"
	# Do not fall through: the steps below create directories inside BASE and
	# then run `chown -R` / `chmod -R` on it, so on a system path (/etc, /tmp,
	# ...) "repair" would recursively take ownership of the system tree. The
	# check above only helps if we actually stop here.
	finish
fi

BASE="$(oc_base_dir)"
NODE_DIR="$(oc_node_dir)"
OC_DIR="$(oc_oc_dir)"
HOME_DIR="$(oc_home_dir)"
DATA="$HOME_DIR/.openclaw"
CONF="$DATA/openclaw.json"

# 1 ------------------------------------------------------------- base dir
if [ ! -d "$BASE" ]; then
	mkdir -p "$BASE" 2>/dev/null && say FIX "已重建安装目录 $BASE" \
		|| { say FAIL "无法创建安装目录 $BASE"; finish; }
else
	say OK "安装目录存在 $BASE"
fi
if ! : >"$BASE/.oc-write-probe" 2>/dev/null; then
	say FAIL "安装目录不可写：$BASE"
else
	rm -f "$BASE/.oc-write-probe"
	say OK "安装目录可写"
fi

# 2 ------------------------------------------------------------- system user
if grep -q "^${OC_USER}:" /etc/passwd 2>/dev/null; then
	say OK "运行用户 $OC_USER 已存在"
else
	if oc_ensure_user; then
		say FIX "已创建运行用户 $OC_USER"
	else
		say WARN "无法创建用户 $OC_USER（将以 root 运行）"
	fi
fi

# 3 ------------------------------------------------------------- directories
for d in "$HOME_DIR" "$DATA" "$BASE/workspace" "$BASE/logs"; do
	if [ ! -d "$d" ]; then
		mkdir -p "$d" 2>/dev/null && say FIX "已重建目录 $d" || say WARN "无法创建目录 $d"
	fi
done
[ -d "$DATA" ] && say OK "数据目录就绪 $DATA"

# 4 ------------------------------------------------------------- node runtime
NB="$(oc_node_bin)"
if [ ! -x "$NB" ]; then
	say FAIL "Node.js 运行时缺失：$NB（请重新安装）"
else
	if "$NB" -v >/dev/null 2>&1; then
		say OK "Node.js 可运行：$("$NB" -v 2>/dev/null)"
	else
		say FAIL "Node.js 无法执行（架构或 libc 不匹配？）：$NB"
	fi
fi

# 5 ------------------------------------------------------------- openclaw
OB="$(oc_oc_bin)"
if [ ! -e "$OB" ]; then
	# try to recreate the shim from the npm layout
	mkdir -p "$OC_DIR/bin"
	target="$(find "$OC_DIR/lib/node_modules/openclaw" -name 'openclaw.mjs' -o -name 'openclaw.js' 2>/dev/null | head -n1)"
	if [ -n "$target" ]; then
		# 解释器必须跟随 oc_node_bin()：global 模式下是 /usr/bin/node，
		# 写死 $NODE_DIR/bin/node 会与 init 脚本启动用的解释器不一致。
		cat >"$OB" <<EOF
#!/bin/sh
exec "$NB" "$target" "\$@"
EOF
		chmod +x "$OB"
		say FIX "已重建 openclaw 启动脚本"
	else
		say FAIL "OpenClaw 未安装：$OB"
	fi
elif [ ! -x "$OB" ]; then
	chmod +x "$OB" 2>/dev/null && say FIX "已修复可执行权限：$OB" || say WARN "无法 chmod $OB"
else
	say OK "OpenClaw 可执行文件就绪"
fi
# all helper scripts executable
for f in "$OC_DIR"/bin/* /usr/libexec/openclaw/*.sh; do
	[ -f "$f" ] || continue
	[ -x "$f" ] || { chmod +x "$f" 2>/dev/null && say FIX "已修复可执行权限：$f"; }
done

# 6 ------------------------------------------------------------- config json
if [ -f "$CONF" ]; then
	if command -v jsonfilter >/dev/null 2>&1; then
		if jsonfilter -i "$CONF" -e '$' >/dev/null 2>&1; then
			say OK "配置文件格式正确"
		else
		cp "$CONF" "$CONF.bak.$(date +%s)" 2>/dev/null
		port="$(uci_get main.port 18789)"
		oc_safe_port "$port" || port=18789
		bind="$(uci_get main.bind lan)"
		case "$bind" in *[!A-Za-z0-9_.:-]* ) bind="lan" ;; esac
		token="$(oc_rand_hex)"
			cat >"$CONF" <<EOF
{
  "gateway": {
    "port": $port,
    "bind": "$bind",
    "auth": { "mode": "token", "token": "$token" },
    "controlUi": { "enabled": true, "allowedOrigins": [] }
  }
}
EOF
			# 重建用的是最小可用配置：provider / channel / 模型选择都不在里面。
			# 这一点必须说清，否则用户以为"修复"是无损的，回头发现模型和渠道全没了。
			say FIX "配置文件损坏，已备份并重建为最小可用配置（旧文件 $CONF.bak.*）"
			say WARN "重建后需要重新配置模型与渠道（原文件已备份，可从中提取 apiKey/baseUrl）"
		fi
	else
		say WARN "缺少 jsonfilter，跳过配置文件格式校验"
	fi
	# `"token"` alone also matches `"mode": "token"`, which made a config with
	# no real token look fine - and the init script then refuses to start.
	if ! grep -q '"token"[[:space:]]*:' "$CONF" 2>/dev/null; then
		[ -x "$OB" ] && HOME="$HOME_DIR" PATH="$NODE_DIR/bin:$OC_DIR/bin:$PATH" \
			"$OB" config set gateway.auth.token "$(oc_rand_hex)" >/dev/null 2>&1 \
			&& say FIX "已补齐网关 token"
	fi
else
	say WARN "配置文件不存在 $CONF（将在下次安装/启动时生成）"
fi

# 7 ------------------------------------------------------------- legacy config keys
# 2026.10 删除了 gateway.controlUi 下的三个认证键，配置里残留任意一个都会让
# 整份 openclaw.json 判为无效（Unrecognized key），网关直接拒绝启动。
# 旧版管理程序每次启动/停止/打开管理页都会把它们写回来，
# 所以这里每次修复都检查一遍。版本门禁在 oc_purge_legacy_controlui 内部：
# 2026.10 之前的版本里这些键仍然合法，不删。
# 配置文件不存在时第 6 步已经报过 WARN，这里无事可做。
if [ -f "$CONF" ]; then
	oc_purge_legacy_controlui "$CONF"
	if [ "${OC_LEGACY_CONTROLUI_FOUND:-0}" -gt 0 ] 2>/dev/null; then
		if [ "${OC_LEGACY_CONTROLUI_REMOVED:-0}" -gt 0 ] 2>/dev/null; then
			say FIX "已移除 ${OC_LEGACY_CONTROLUI_REMOVED} 个 2026.10 不再支持的配置键"
		else
			say FAIL "检测到 ${OC_LEGACY_CONTROLUI_FOUND} 个 2026.10 不再支持的配置键，但移除失败（配置未改动，详见日志）"
		fi
	elif [ "${OC_LEGACY_CONTROLUI_APPLICABLE:-0}" = "1" ]; then
		say OK "无 2026.10 已废弃的配置键"
	else
		say OK "无 2026.10 已废弃的配置键（版本低于 2026.10 或未安装，按旧版语义跳过清理）"
	fi
fi

# 8 ------------------------------------------------------------- env file
ENVF="$DATA/.env"
if [ -f "$ENVF" ]; then
	# only claim a fix when the mode actually changes, so the summary
	# "已修复 N 项" reflects reality on a healthy installation
	cur_mode="$(stat -c %a "$ENVF" 2>/dev/null)"
	if [ "$cur_mode" != "600" ]; then
		chmod 600 "$ENVF" 2>/dev/null && say FIX "已收紧 .env 权限为 600" || say WARN "无法收紧 .env 权限"
	else
		say OK ".env 权限已是 600"
	fi
else
	say OK "无 .env 文件（可稍后在模型页填写 Key）"
fi

# 9 ------------------------------------------------------------- ownership
if [ -d "$BASE" ]; then
	if grep -q "^${OC_USER}:" /etc/passwd 2>/dev/null; then
		if [ "$(stat -c %U "$BASE" 2>/dev/null)" = "$OC_USER" ]; then
			say OK "属主正确：$OC_USER"
		else
			chown -R "$OC_USER":"$OC_GROUP" "$BASE" 2>/dev/null || chown -R "$OC_USER" "$BASE" 2>/dev/null
			say FIX "已修复 $BASE 属主为 $OC_USER"
		fi
	fi
	chmod -R u+rwX "$BASE" 2>/dev/null
fi

# 10 ------------------------------------------------------------ init script
if [ -f "$INITD" ]; then
	[ -x "$INITD" ] || { chmod +x "$INITD" 2>/dev/null && say FIX "已修复 init 脚本执行权限"; }
	if "$INITD" enabled 2>/dev/null; then
		say OK "服务已设置开机自启"
	else
		"$INITD" enable >/dev/null 2>&1 && say FIX "已启用开机自启" || say WARN "无法启用开机自启"
	fi
else
	say FAIL "缺少 init 脚本 $INITD（请重新安装软件包）"
fi

# 11 ------------------------------------------------------------ port / bind
port="$(uci_get main.port 18789)"
if ! oc_safe_port "$port"; then
	uci_set main.port 18789
	uci_commit
	port=18789
	say FIX "端口不安全（必须 1025-65535），已重置为 18789"
fi
if command -v netstat >/dev/null 2>&1; then
	who="$(netstat -lnt 2>/dev/null | awk -v p=":$port" '$4 ~ p"$" {print $0; exit}')"
elif [ -r /proc/net/tcp ]; then
	hexport="$(printf '%04X' "$port")"
	who="$(awk -v h="$hexport" 'NR>1{split($2,a,":"); if (a[2]==h && $4=="0A") print $2; exit}' /proc/net/tcp)"
else
	who=""
fi
if [ -n "$who" ]; then
	# oc_gateway_pids matches the private node binary by argv[0]; a plain
	# `pgrep -f openclaw` here also matched `tail -f openclaw.log` and made
	# the repair report "已在运行" for a dead gateway
	if [ -n "$(oc_gateway_pids)" ]; then
		say OK "端口 $port 已被 OpenClaw 占用（正常）"
	else
		say WARN "端口 $port 被其他进程占用（$who），网关可能无法启动"
	fi
else
	say OK "端口 $port 空闲"
fi

# 12 ------------------------------------------------------------ CA certs
if oc_ca_ok; then
	say OK "CA 证书已安装"
else
	say WARN "未找到 CA 证书，HTTPS 下载可能失败：$(oc_pkg_install_hint) ca-certificates"
fi

# 12b ----------------------------------------------------------- xz
# Node.js 官方包是 .tar.xz。没有 xz 时 install.sh 会退化成 `tar -xf`，而
# busybox tar 多半没编进 -J，最后只报"解压失败（tar）"—— 看不出根因。
# 这里点名检查，让"一键修复"能直接告诉用户该装什么。
if command -v xz >/dev/null 2>&1 || command -v unxz >/dev/null 2>&1; then
	say OK "xz 已安装（可解压 Node.js 的 .tar.xz）"
elif tar --help 2>/dev/null | grep -q -- '-J'; then
	say OK "tar 自带 xz 支持"
else
	say WARN "缺少 xz，安装 Node.js 时会解压失败：$(oc_pkg_install_hint) xz-utils"
fi

# 13 ------------------------------------------------------------ luci cache
if [ -e /tmp/luci-indexcache ] || [ -e /tmp/luci-modulecache ]; then
	rm -f /tmp/luci-indexcache /tmp/luci-modulecache 2>/dev/null
	say FIX "已清理 LuCI 缓存"
else
	say OK "LuCI 缓存为空"
fi

# 14 ------------------------------------------------------------ openclaw self-check
# 先修环境，再让 OpenClaw 修它自己的配置，最后重启 —— 这样 doctor --fix 的
# 修改能随最后一次重启生效。doctor --fix 可能因个别问题修不了而返回非零，
# 因此只记 WARN，不让整次 repair 判失败。
# 等价于 openclaw/cli.sh 的 installed()：程序与 Node 都可执行才算已安装。
if [ -x "$OB" ] && [ -x "$NB" ]; then
	# 先清陈旧的状态所有权锁：OpenClaw 10.x 的 doctor / 网关 / sqlite 维护
	# 共用一把锁，维护进程被打断后数据库里会留下指向死 pid 的租约，
	# 于是两边都报 "undergoing offline maintenance"，修复也修不动。
	# 只有确认持有者已死才删，活锁一律不动。
	if command -v oc_clear_stale_state_lock >/dev/null 2>&1; then
		if oc_clear_stale_state_lock "$(oc_state_dir)"; then
			say OK "状态锁检查通过（无活锁占用）"
		else
			say WARN "状态仍被活动进程占用，若持续失败请先停止网关再重试"
		fi
	fi

	doc_out="$(HOME="$HOME_DIR" PATH="$NODE_DIR/bin:$OC_DIR/bin:$PATH" \
		oc_timeout 300 "$OB" doctor --fix 2>&1)"
	doc_rc=$?
	if [ "$doc_rc" = "0" ]; then
		say FIX "OpenClaw 自检修复完成"
	else
		# 维护锁是 doctor 唯一「等一等就好」的失败原因，单独说清楚，
		# 否则用户只会看到一行退出码。
		case "$doc_out" in
			*"offline maintenance"*|*"sqlite-maintenance"*)
				say WARN "状态库正在做离线维护，需等维护进程结束再试：
$(printf '%s\n' "$doc_out" | grep -iE 'maintenance|retry' | head -n 3)" ;;
			*)
				say WARN "OpenClaw 自检修复未完全成功（退出码 $doc_rc）" ;;
		esac
	fi
	# 保留最后若干行，便于定位 doctor 修不了的问题。--json 下不能直接
	# printf 到 stdout（会破坏 finish 输出的 JSON），统一交给 say 收集。
	doc_tail="$(printf '%s\n' "$doc_out" | tail -n 40)"
	[ -n "$doc_tail" ] && say OK "$doc_tail"
else
	say OK "未安装，跳过 doctor --fix"
fi

# 15 ------------------------------------------------------------ restart
if [ "$RESTART" = "1" ] && [ -x "$OB" ] && [ -x "$NB" ]; then
	"$INITD" restart >/dev/null 2>&1 && say FIX "已重启服务" || say WARN "服务重启失败（见日志）"
	sleep 1
	if [ -n "$(oc_gateway_pids)" ]; then
		say OK "网关进程已在运行"
	else
		say WARN "网关进程未在运行，请查看日志"
	fi
fi

finish
