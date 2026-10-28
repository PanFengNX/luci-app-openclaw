#!/bin/sh
# cred-matrix.sh — 网关凭据判定矩阵（credential.sh 的行为回归）
#
# 为什么需要运行时测试而不是字符串断言：同一个配置形状在四种解析器里出现过
# 三种不同结论（对象被当引用放行、`mode:"token"` 被当凭据、CR 绕过空白检查）。
# 静态搜索 "REF" 字样证明不了这些分支真的按预期分流。
#
# 做法：把 jsonfilter 换成桩，逐条喂形状，断言
#   1) OC_CRED_STATE 分类
#   2) 是否允许启动（PLAIN/REF）
#   3) OC_CRED_ENV 是否导出，以及导出的值是否原样
#
# 退出码：0 = 全部通过；1 = 有失败

PROJ="$(dirname "$0")/../.."
CRED="$PROJ/root/usr/libexec/openclaw/credential.sh"
[ -f "$CRED" ] || { echo "找不到 $CRED"; exit 2; }

RC=0
N=0
chk() { # chk <desc> <got> <want>
	N=$((N + 1))
	if [ "$2" = "$3" ]; then
		printf '    ok    %s\n' "$1"
	else
		printf '    FAIL  %s got=[%s] want=[%s]\n' "$1" "$2" "$3"
		RC=1
	fi
}

# ---------------- 桩：替换 jsonfilter 与配置可读性探测
# credential.sh 用 `command -v jsonfilter` 与 jsonfilter 本体；这里把两者
# 都换成受控桩：环境变量 _S_RAW / _S_SRC / _S_ID / _S_NOFILTER / _S_MALFORMED
jsonfilter_stub() {
	# jsonfilter_stub -i <file> -e <expr>
	if [ "${_S_MALFORMED:-0}" = "1" ]; then return 1; fi
	case "$2" in
		'@.gateway.auth.token')        printf '%s\n' "$_S_RAW" ;;
		'@.gateway.auth.token.source') printf '%s\n' "$_S_SRC" ;;
		'@.gateway.auth.token.id')     printf '%s\n' "$_S_ID" ;;
		'@.gateway.auth.token.name')   printf '%s\n' "$_S_ID" ;;
		'@.gateway.auth.mode')         printf '%s\n' "${_S_MODE:-}" ;;
		'$')                           printf '{}\n' ;;
		*) printf '\n' ;;
	esac
}

CFG="$(dirname "$0")/.cred-matrix-config.json"
: > "$CFG"

# 用 PATH 里的假 jsonfilter 覆盖真实命令。
# 注意：不要试图覆盖 `command`（POSIX 特殊内建，同名函数无效）。
STUBDIR="$(dirname "$0")/.cred-matrix-bin"
mkdir -p "$STUBDIR" 2>/dev/null
cat > "$STUBDIR/jsonfilter" <<'STUB'
#!/bin/sh
# 真实调用形态：jsonfilter -i <file> -e <expr>
# 参数位：$1=-i $2=<file> $3=-e $4=<expr>
if [ "${_S_MALFORMED:-0}" = "1" ]; then exit 1; fi
expr="$4"
case "$expr" in
	'@.gateway.auth.token')        printf '%s\n' "$_S_RAW" ;;
	'@.gateway.auth.token.source') printf '%s\n' "$_S_SRC" ;;
	'@.gateway.auth.token.id')     printf '%s\n' "$_S_ID" ;;
	'@.gateway.auth.token.name')   printf '%s\n' "$_S_ID" ;;
	'@.gateway.auth.mode')         printf '%s\n' "${_S_MODE:-}" ;;
	'$')                           printf '{}\n' ;;
	*) printf '\n' ;;
esac
exit 0
STUB
chmod +x "$STUBDIR/jsonfilter" 2>/dev/null

# 以子 shell 载入 credential.sh 并跑一次判定；输出 "STATE|ENV|STARTS"
run_one() {
	(
		set +e
		# 桩脚本是**独立子进程**，必须 export 才能看到这些变量。
		export _S_RAW _S_SRC _S_ID _S_MODE _S_MALFORMED _S_NOFILTER
		PATH="$STUBDIR:$PATH"
		export PATH
		# 载入被测实现（无副作用：不建目录、不装 trap）
		. "$CRED" 2>/dev/null
		if [ "${_S_NOFILTER:-0}" = "1" ]; then
			PATH="/usr/bin:/bin"
			command -v jsonfilter >/dev/null 2>&1 && exit 90
		fi
		oc_credential_state "$CFG"
		starts=no
		oc_cred_state_starts "$OC_CRED_STATE" && starts=yes
		printf '%s|%s|%s' "$OC_CRED_STATE" "$OC_CRED_ENV" "$starts"
	)
}

check_case() { # check_case <desc> <want_state> <want_env> <want_starts>
	got="$(run_one)"
	want="$2|$3|$4"
	chk "$1" "$got" "$want"
}

echo '  凭据判定矩阵：'

_S_NOFILTER=0; _S_MALFORMED=0; _S_MODE=token
_S_RAW=""; _S_SRC=""; _S_ID=""
check_case 'token 字段缺失'      MISSING ''  no
_S_RAW="null"
check_case 'token = null'        MISSING ''  no
_S_RAW=""
check_case 'token = 空串'        MISSING ''  no
_S_RAW="0123456789abcdef0123456789abcdef"
check_case '明文（无空白）'      PLAIN '0123456789abcdef0123456789abcdef' yes
_S_RAW="abc def"
check_case '明文（含空格）'      PLAIN ''  yes
_S_RAW="abc	def"
check_case '明文（含 Tab）'      PLAIN ''  yes
_S_RAW="$(printf 'abc\rdef')"
check_case '明文（含 CR）'       PLAIN ''  yes
_S_RAW="$(printf 'abc\ndef')"
check_case '明文（含 LF）'       PLAIN ''  yes
_S_RAW='{"source":"store","id":"K"}'; _S_SRC="store"; _S_ID="K"
check_case '有效 SecretRef'      REF   ''  yes
_S_RAW='{"source":"env","name":"N"}'; _S_SRC="env"; _S_ID="N"
check_case 'env 型 SecretRef'    REF   ''  yes
_S_RAW='{}'; _S_SRC=""; _S_ID=""
check_case '空对象 {}'           BADREF '' no
_S_RAW='{"source":"store"}'; _S_SRC="store"; _S_ID=""
check_case 'SecretRef 缺 id'     BADREF '' no
_S_RAW='[1,2]'; _S_SRC=""; _S_ID=""
check_case '数组值'              BADREF '' no
_S_RAW='{"source":"future","id":"X"}'; _S_SRC="future"; _S_ID="X"
check_case '未知 source 带 id'   REF   ''  yes
_S_MALFORMED=1; _S_RAW=""; _S_SRC=""; _S_ID=""
check_case '整份 JSON 不可解析'  UNREAD '' no
_S_MALFORMED=0
_S_NOFILTER=1
check_case 'jsonfilter 不可用'   UNREAD '' no
_S_NOFILTER=0

# oc_cred_env_safe：token 与 password **共用**的"能否进 procd env"判据。
# 这条以前只写在 token 分支里，password 自己又抄了一份（只查空格和 Tab），
# 结果含换行的密码被 head -n1 截成半截后当成干净明文导出。现在必须有
# 独立断言锁住这个函数本身。
echo '  env 导出判据（token/password 共用）：'
_safe() {
	(
		set +e
		. "$CRED" 2>/dev/null
		oc_cred_env_safe "$1" && printf 'yes' || printf 'no'
	)
}
chk '普通十六进制可导出'      "$(_safe '0123456789abcdef')" 'yes'
chk '含空格不可导出'          "$(_safe 'abc def')" 'no'
chk '含 Tab 不可导出'         "$(_safe "$(printf 'abc\tdef')")" 'no'
chk '含 CR 不可导出'          "$(_safe "$(printf 'abc\rdef')")" 'no'
chk '含内部 LF 不可导出'      "$(_safe "$(printf 'abc\ndef')")" 'no'
# 「值只以 LF 结尾」这条用例**不可达**，因此不写断言：
# shell 的命令替换会剥掉所有结尾换行，`v="$(...)"` 拿到的永远不含结尾 LF。
# 写一个期望 no 的断言只会假失败（实测过）。真正危险的是内部 LF，已覆盖。
chk '纯字母数字可导出'        "$(_safe 'aZ09')" 'yes'

# auth.mode 解析：缺省按 token，显式未知值返回 unknown（由 init 拒绝）
_S_MODE=""
got="$( (
	export _S_RAW _S_SRC _S_ID _S_MODE _S_MALFORMED _S_NOFILTER
	PATH="$STUBDIR:$PATH"; export PATH
	. "$CRED" 2>/dev/null
	oc_gateway_auth_mode "$CFG"
) )"
chk 'auth.mode 缺省 -> token' "$got" 'token'
_S_MODE="password"
got="$( (
	export _S_RAW _S_SRC _S_ID _S_MODE _S_MALFORMED _S_NOFILTER
	PATH="$STUBDIR:$PATH"; export PATH
	. "$CRED" 2>/dev/null
	oc_gateway_auth_mode "$CFG"
) )"
chk 'auth.mode=password 被保留' "$got" 'password'
_S_MODE="bogus"
got="$( (
	export _S_RAW _S_SRC _S_ID _S_MODE _S_MALFORMED _S_NOFILTER
	PATH="$STUBDIR:$PATH"; export PATH
	. "$CRED" 2>/dev/null
	oc_gateway_auth_mode "$CFG"
) )"
chk 'auth.mode 未知值 -> unknown' "$got" 'unknown'

rm -rf "$STUBDIR" "$CFG" 2>/dev/null
printf '    共 %d 项，%d 项失败\n' "$N" "$( [ "$RC" -eq 0 ] && echo 0 || echo 1 )"
exit "$RC"