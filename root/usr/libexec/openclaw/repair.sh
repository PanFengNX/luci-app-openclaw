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
for a in "$@"; do
	case "$a" in
		--json) JSON=1 ;;
		--no-restart) RESTART=0 ;;
	esac
done

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
for f in "$OC_DIR"/bin/* /usr/libexec/openclaw/*.sh /usr/libexec/istorec/openclaw.sh; do
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
			say FIX "配置文件损坏，已备份并重建（旧文件 $CONF.bak.*）"
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

# 7 ------------------------------------------------------------- env file
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

# 8 ------------------------------------------------------------- ownership
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

# 9 ------------------------------------------------------------- init script
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

# 10 ------------------------------------------------------------ port / bind
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

# 11 ------------------------------------------------------------ CA certs
if oc_ca_ok; then
	say OK "CA 证书已安装"
else
	say WARN "未找到 CA 证书，HTTPS 下载可能失败：$(oc_pkg_install_hint) ca-certificates"
fi

# 12 ------------------------------------------------------------ luci cache
if [ -e /tmp/luci-indexcache ] || [ -e /tmp/luci-modulecache ]; then
	rm -f /tmp/luci-indexcache /tmp/luci-modulecache 2>/dev/null
	say FIX "已清理 LuCI 缓存"
else
	say OK "LuCI 缓存为空"
fi

# 13 ------------------------------------------------------------ restart
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
