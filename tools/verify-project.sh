#!/usr/bin/env bash
# verify-project.sh — luci-app-openclaw 全量回归验证
#
# 任何代码改动（无论人写还是 AI 写）在交付前都必须跑通本脚本。
# 它只做检查，不修改任何文件。
#
# 用法：
#   tools/verify-project.sh            # 全部检查
#   tools/verify-project.sh --no-build # 跳过打包（只做语法与结构检查）
#
# 退出码：0 = 全部通过；1 = 有失败项

set -u

PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ" || exit 1

DO_BUILD=1
[ "${1:-}" = "--no-build" ] && DO_BUILD=0

PASS=0
FAIL=0
SKIP=0

ok()   { printf '  \033[32mok\033[0m    %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAIL=$((FAIL + 1)); }
skip() { printf '  \033[33mskip\033[0m  %s\n' "$1"; SKIP=$((SKIP + 1)); }
head_() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }

# --------------------------------------------------------------------------
# 解释器
PY=""
for cand in python3 python "$HOME/.workbuddy/binaries/python/versions/3.13.12/python.exe"; do
	if command -v "$cand" >/dev/null 2>&1; then PY="$cand"; break; fi
	[ -x "$cand" ] && { PY="$cand"; break; }
done

NODE=""
for cand in node "$(command -v node 2>/dev/null)" \
	"C:/Program Files/nodejs/node.exe" \
	"$HOME/.workbuddy/binaries/node/versions/22.22.2-6/node.exe"; do
	[ -n "$cand" ] || continue
	if command -v "$cand" >/dev/null 2>&1 || [ -x "$cand" ]; then NODE="$cand"; break; fi
done

# --------------------------------------------------------------------------
head_ "1. Shell 语法（sh -n）"
sh_count=0
while IFS= read -r f; do
	[ -n "$f" ] || continue
	sh_count=$((sh_count + 1))
	if err="$(sh -n "$f" 2>&1)"; then
		ok "$f"
	else
		bad "$f"
		printf '        %s\n' "$err"
	fi
done < <(find root -name '*.sh' -type f 2>/dev/null; \
	printf '%s\n' root/etc/init.d/openclaw; \
	find root/etc/uci-defaults -type f 2>/dev/null; \
	find tools -name '*.sh' -type f 2>/dev/null)
[ "$sh_count" -eq 0 ] && bad "没有找到任何 shell 脚本（路径错误？）"

# --------------------------------------------------------------------------
head_ "2. LuCI 页面内嵌 JS（node --check）"
if [ -z "$NODE" ]; then
	skip "找不到 node，跳过"
else
	js_count=0
	for f in luasrc/view/openclaw/*.htm; do
		[ -f "$f" ] || continue
		js_count=$((js_count + 1))
		# 必须带 .js 后缀：node --check 会拒绝未知扩展名的文件
		tmp="${TMPDIR:-/tmp}/ocjs-$$-$js_count.js"
		awk '/<script/{s=1;next} /<\/script>/{s=0} s' "$f" >"$tmp"
		if "$NODE" --check "$tmp" >/dev/null 2>&1; then
			ok "$f"
		else
			bad "$f"
			"$NODE" --check "$tmp" 2>&1 | head -5 | sed 's/^/        /'
		fi
		rm -f "$tmp"
	done
	[ "$js_count" -eq 0 ] && bad "没有找到 LuCI 视图文件"
fi

# --------------------------------------------------------------------------
head_ "3. Python 打包脚本（py_compile）"
if [ -z "$PY" ]; then
	skip "找不到 python，跳过"
else
	py_count=0
	for f in scripts/*.py tools/*.py; do
		[ -f "$f" ] || continue
		py_count=$((py_count + 1))
		if "$PY" -m py_compile "$f" >/dev/null 2>&1; then
			ok "$f"
		else
			bad "$f"
			"$PY" -m py_compile "$f" 2>&1 | head -5 | sed 's/^/        /'
		fi
	done
	[ "$py_count" -eq 0 ] && skip "没有找到 python 脚本"
	rm -rf scripts/__pycache__ tools/__pycache__ 2>/dev/null
fi

# --------------------------------------------------------------------------
head_ "4. JSON 合法性"
for f in root/usr/share/rpcd/acl.d/*.json; do
	[ -f "$f" ] || continue
	if [ -n "$PY" ]; then
		if "$PY" -c "import json,sys; json.load(open(sys.argv[1],encoding='utf-8'))" "$f" >/dev/null 2>&1; then
			ok "$f"
		else
			bad "$f"
		fi
	else
		skip "$f（无 python）"
	fi
done

# --------------------------------------------------------------------------
head_ "5. 必须存在的关键文件"
for f in \
	Makefile \
	root/etc/init.d/openclaw \
	root/usr/share/openclaw/config.default \
	root/etc/uci-defaults/99-openclaw \
	root/usr/libexec/openclaw/cli.sh \
	root/usr/libexec/openclaw/lib.sh \
	root/usr/libexec/openclaw/install.sh \
	root/usr/libexec/openclaw/versions.sh \
	root/usr/libexec/openclaw/models.sh \
	root/usr/libexec/openclaw/channels.sh \
	root/usr/libexec/openclaw/repair.sh \
	root/usr/libexec/openclaw/backup.sh \
	luasrc/controller/openclaw.lua \
	root/usr/share/rpcd/acl.d/luci-app-openclaw.json
do
	[ -e "$f" ] && ok "$f" || bad "缺失：$f"
done

# --------------------------------------------------------------------------
head_ "6. 危险模式残留扫描"
# 这些是历史审计中明确修掉的问题，回归时不允许复活
scan_forbid() {
	local desc="$1" pat="$2"
	local hit
	# grep 输出形如 "文件:行号:内容"，注释行必须按"内容"部分判断，
	# 直接在整行上过滤 ^# 是无效的（那会把所有命中都漏掉）。
	# .md 一律跳过：CHANGELOG / README 会引用被禁止的写法来解释
	# "为什么不能这么写"，那是文档，不是代码。
	hit="$(grep -rnE "$pat" root/ luasrc/ 2>/dev/null \
		| grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' \
		| grep -vE '^[^:]*\.(md|MD):' \
		| head -5)"
	if [ -n "$hit" ]; then
		bad "$desc"
		printf '%s\n' "$hit" | sed 's/^/        /'
	else
		ok "$desc"
	fi
}
scan_forbid "无 pgrep -f 模糊强杀"          "pgrep -f '?openclaw'?[^)]*kill|kill -9 \\\$\\(pgrep"
# 存在性判定同样不能用 pgrep -f：`pgrep -f 'openclaw.*(gateway|run)'` 会命中
# 终端页的 `cli.sh run xxx` 和用户的 `tail -f ...openclaw.log gateway`，
# 于是状态页谎报"运行中"、`--force` 不触发、后续操作全对着不存在的网关。
# 判定进程要用 /proc/<pid>/cmdline 比对 argv（见 lib.sh 的 oc_gateway_pids）。
scan_forbid "无 pgrep -f 做进程存在性判定"    "pgrep -f '[^']*openclaw[^']*\(gateway\|run\)"
# 只挡**固定名**的临时文件（可预测名字 + 写入 = 符号链接攻击面）。
# 名字里带 * 的是只读 glob（例如扫网关日志目录），不可能被预置链接，不算。
# 原来的模式 /tmp/openclaw- 会把 "$base"/tmp/openclaw-*/openclaw-*.log 这种
# 读取误判成写入（实测 1.8.21 就撞上了）。
scan_forbid "无 /tmp 固定名临时文件"        "/tmp/openclaw[a-z]*-[A-Za-z0-9._$-]+|/tmp/oc-[a-z][A-Za-z0-9._$-]+"
scan_forbid "无未引用的 run 参数拼接"        'run " \.\. cmd'
scan_forbid "无 --token 出现在命令行"        '\-\-token "\$token"'
scan_forbid "无 curl 管道执行"              '\(curl\|wget\)[^|]*\|\s*\(sh\|bash\|ash\)'

# CRLF 会让 shell 的 shebang 变成 "#!/bin/sh\r"（找不到解释器），
# 也会让 LuCI 模板解析报 "unfinished string"。全项目必须是纯 LF。
# 之前用 Python 批量改代码时踩过：Windows 上 write_text() 默认把 \n 转成 \r\n。
# 注意用 Python 而不是 `find -exec grep {} +`：后者在 MSYS 上会对干净文件误报。
crlf_hits=""
if [ -n "$PY" ]; then
	crlf_hits="$("$PY" -c '
import pathlib
bad = []
for t in ("root", "luasrc", "scripts", "tools", "Makefile", "README.md"):
    p = pathlib.Path(t)
    fs = [p] if p.is_file() else [f for f in p.rglob("*") if f.is_file()]
    for f in fs:
        if f.suffix == ".pyc" or "__pycache__" in f.parts:
            continue
        try:
            if b"\r" in f.read_bytes():
                bad.append(str(f))
        except OSError:
            pass
for b in bad[:5]:
    print(b)
' 2>/dev/null)"
fi
if [ -n "$crlf_hits" ]; then
	bad "无 CRLF 行尾（shebang / LuCI 模板会失效）"
	printf '%s\n' "$crlf_hits" | sed 's/^/        /'
else
	ok "无 CRLF 行尾"
fi

# --------------------------------------------------------------------------
head_ "7. 安全不变量回归测试（路径/端口/URL/JSON 转义）"
if [ -f tools/tests/path-validate.sh ]; then
	if out="$(sh tools/tests/path-validate.sh 2>&1)"; then
		printf '%s\n' "$out" | tail -1 | sed 's/^/    /'
		ok "path-validate.sh 全部断言通过"
	else
		bad "path-validate.sh 有失败断言"
		printf '%s\n' "$out" | grep -E 'FAIL|共 ' | sed 's/^/        /'
	fi
else
	skip "缺少 tools/tests/path-validate.sh"
fi

head_ "7b. 备份归档安全校验（拒绝越界/链接/设备条目）"
if [ -f tools/tests/backup-archive.sh ]; then
	if out="$(sh tools/tests/backup-archive.sh 2>&1)"; then
		printf '%s\n' "$out" | tail -1 | sed 's/^/    /'
		ok "backup-archive.sh 全部断言通过"
	else
		bad "backup-archive.sh 有失败断言"
		printf '%s\n' "$out" | grep -E 'FAIL|共 |项失败' | sed 's/^/        /'
	fi
else
	skip "缺少 tools/tests/backup-archive.sh"
fi

head_ "7c. 云备份定时任务（crontab 重写不得动别人的行）"
if [ -f tools/tests/cloud-cron.sh ]; then
	if out="$(sh tools/tests/cloud-cron.sh 2>&1)"; then
		printf '%s\n' "$out" | tail -1 | sed 's/^/    /'
		ok "cloud-cron.sh 全部断言通过"
	else
		bad "cloud-cron.sh 有失败断言"
		printf '%s\n' "$out" | grep -E 'FAIL|共 |项失败' | sed 's/^/        /'
	fi
else
	skip "缺少 tools/tests/cloud-cron.sh"
fi

head_ "7d. 控制器 Lua 语法（一个语法错误会让所有页面 500）"
if [ -z "$PY" ]; then
	skip "找不到 python"
elif [ ! -f tools/tests/lua-syntax.py ]; then
	skip "缺少 tools/tests/lua-syntax.py"
else
	lua_out="$("$PY" tools/tests/lua-syntax.py . 2>&1)"
	lua_rc=$?
	if [ "$lua_rc" -eq 0 ]; then
		printf '%s\n' "$lua_out" | tail -1 | sed 's/^/    /'
		ok "Lua 语法全部通过"
	elif [ "$lua_rc" -eq 3 ]; then
		printf '%s\n' "$lua_out" | tail -1 | sed 's/^ *跳过：//' | sed 's/^/    /'
		skip "未安装 luaparser（pip install luaparser 后生效）"
	else
		bad "Lua 语法有错误"
		printf '%s\n' "$lua_out" | grep -E 'FAIL|共 ' | sed 's/^/        /'
	fi
fi

head_ "7d2. 控制器 Lua 词法作用域（local 前向引用会让所有接口 500）"
if [ -z "$PY" ]; then
	skip "找不到 python"
elif [ ! -f tools/tests/lua-scope.py ]; then
	skip "缺少 tools/tests/lua-scope.py"
else
	scope_out="$("$PY" tools/tests/lua-scope.py . 2>&1)"
	if [ $? -eq 0 ]; then
		printf '%s\n' "$scope_out" | tail -1 | sed 's/^/    /'
		ok "无 local 前向引用"
	else
		bad "存在 local 前向引用（运行时 nil）"
		printf '%s\n' "$scope_out" | grep -E '★|行 |引用了' | head -6 | sed 's/^/        /'
	fi
fi

head_ "7e2. 云端列表的空状态与页面提示语"
if [ -f tools/tests/cloud-ls.sh ]; then
	if out="$(sh tools/tests/cloud-ls.sh 2>&1)"; then
		printf '%s\n' "$out" | tail -1 | sed 's/^/    /'
		ok "cloud-ls.sh 全部断言通过"
	else
		bad "cloud-ls.sh 有失败断言"
		printf '%s\n' "$out" | grep -E 'FAIL|共 |项失败' | sed 's/^/        /'
	fi
else
	skip "缺少 tools/tests/cloud-ls.sh"
fi

if [ -f tools/tests/view-messages.sh ]; then
	if out="$(sh tools/tests/view-messages.sh 2>&1)"; then
		printf '%s\n' "$out" | tail -1 | sed 's/^/    /'
		ok "view-messages.sh 全部断言通过"
	else
		bad "view-messages.sh 有失败断言"
		printf '%s\n' "$out" | grep -E 'FAIL|共 |项失败' | sed 's/^/        /'
	fi
else
	skip "缺少 tools/tests/view-messages.sh"
fi

if [ -f tools/tests/cloud-no-od.sh ]; then
	if out="$(sh tools/tests/cloud-no-od.sh 2>&1)"; then
		printf '%s\n' "$out" | tail -1 | sed 's/^/    /'
		ok "cloud-no-od.sh 全部断言通过"
	else
		bad "cloud-no-od.sh 有失败断言"
		printf '%s\n' "$out" | grep -E 'FAIL|共 |项失败' | sed 's/^/        /'
	fi
else
	skip "缺少 tools/tests/cloud-no-od.sh"
fi

if [ -f tools/tests/model-flags.sh ]; then
	if out="$(sh tools/tests/model-flags.sh 2>&1)"; then
		printf '%s\n' "$out" | tail -1 | sed 's/^/    /'
		ok "model-flags.sh 全部断言通过"
	else
		bad "model-flags.sh 有失败断言"
		printf '%s\n' "$out" | grep -E 'FAIL|共 |项失败' | sed 's/^/        /'
	fi
else
	skip "缺少 tools/tests/model-flags.sh"
fi

if [ -f tools/tests/init-recovery.sh ]; then
	if out="$(sh tools/tests/init-recovery.sh 2>&1)"; then
		printf '%s\n' "$out" | tail -1 | sed 's/^/    /'
		ok "init-recovery.sh 全部断言通过"
	else
		bad "init-recovery.sh 有失败断言"
		printf '%s\n' "$out" | grep -E 'FAIL|共 |项失败' | sed 's/^/        /'
	fi
else
	skip "缺少 tools/tests/init-recovery.sh"
fi

if [ -f tools/tests/info-json.sh ]; then
	if out="$(sh tools/tests/info-json.sh 2>&1)"; then
		printf '%s\n' "$out" | tail -1 | sed 's/^/    /'
		ok "info-json.sh 全部断言通过"
	else
		bad "info-json.sh 有失败断言"
		printf '%s\n' "$out" | grep -E 'FAIL|共 |项失败' | sed 's/^/        /'
	fi
else
	skip "缺少 tools/tests/info-json.sh"
fi

head_ "7f. 安装目录候选（/boot 等系统分区必须被剔除）"
if [ -f tools/tests/mounts.sh ]; then
	if out="$(sh tools/tests/mounts.sh 2>&1)"; then
		printf '%s\n' "$out" | tail -1 | sed 's/^/    /'
		ok "mounts.sh 全部断言通过"
	else
		bad "mounts.sh 有失败断言"
		printf '%s\n' "$out" | grep -E 'FAIL|共 |项失败' | sed 's/^/        /'
	fi
else
	skip "缺少 tools/tests/mounts.sh"
fi

head_ "7g. 升级不得覆盖用户配置（包内不能带 /etc/config/openclaw）"
if [ -f tools/tests/config-preserve.sh ]; then
	if out="$(sh tools/tests/config-preserve.sh 2>&1)"; then
		printf '%s\n' "$out" | tail -1 | sed 's/^/    /'
		ok "config-preserve.sh 全部断言通过"
	else
		bad "config-preserve.sh 有失败断言"
		printf '%s\n' "$out" | grep -E 'FAIL|共 |项失败' | sed 's/^/        /'
	fi
else
	skip "缺少 tools/tests/config-preserve.sh"
fi

# --------------------------------------------------------------------------
head_ "7h. 命令超时兜底（没有 timeout applet 时不能无限等）"
if [ -f tools/tests/oc-timeout.sh ]; then
	if out="$(sh tools/tests/oc-timeout.sh 2>&1)"; then
		printf '%s\n' "$out" | tail -1 | sed 's/^/    /'
		ok "oc-timeout.sh 全部断言通过"
	else
		bad "oc-timeout.sh 有失败断言"
		printf '%s\n' "$out" | grep -E 'FAIL|共 |项失败' | sed 's/^/        /'
	fi
else
	skip "缺少 tools/tests/oc-timeout.sh"
fi

head_ "7i. 命名不沿用 iStoreOS（本包不依赖它）"
if [ -f tools/tests/naming.sh ]; then
	if out="$(sh tools/tests/naming.sh 2>&1)"; then
		printf '%s\n' "$out" | tail -1 | sed 's/^/    /'
		ok "naming.sh 全部断言通过"
	else
		bad "naming.sh 有失败断言"
		printf '%s\n' "$out" | grep -E 'FAIL|共 |项失败' | sed 's/^/        /'
	fi
else
	skip "缺少 tools/tests/naming.sh"
fi

head_ "7i2. Lua 模式串陷阱（量词开头 / plain 模式误用元字符）"
if [ -f tools/tests/lua-patterns.py ]; then
	if out="$("$PY" tools/tests/lua-patterns.py . 2>&1)"; then
		printf '%s\n' "$out" | tail -1 | sed 's/^/    /'
		ok "lua-patterns.py 检查通过"
	else
		bad "lua-patterns.py 发现问题"
		printf '%s\n' "$out" | grep -E 'ERROR|共 ' | sed 's/^/        /'
	fi
else
	skip "缺少 tools/tests/lua-patterns.py"
fi

head_ "7j. 备份列表在含空格的安装目录下必须可用"
if [ -f tools/tests/backup-list-space.sh ]; then
	if out="$(sh tools/tests/backup-list-space.sh 2>&1)"; then
		printf '%s\n' "$out" | tail -1 | sed 's/^/    /'
		ok "backup-list-space.sh 全部断言通过"
	else
		bad "backup-list-space.sh 有失败断言"
		printf '%s\n' "$out" | grep -E 'FAIL|共 |项失败' | sed 's/^/        /'
	fi
else
	skip "缺少 tools/tests/backup-list-space.sh"
fi

head_ "7k. 读凭据的端点必须强制 POST"
if [ -f tools/tests/api-post-guard.sh ]; then
	if out="$(sh tools/tests/api-post-guard.sh 2>&1)"; then
		printf '%s\n' "$out" | tail -1 | sed 's/^/    /'
		ok "api-post-guard.sh 全部断言通过"
	else
		bad "api-post-guard.sh 有失败断言"
		printf '%s\n' "$out" | grep -E 'FAIL|共 |项失败' | sed 's/^/        /'
	fi
else
	skip "缺少 tools/tests/api-post-guard.sh"
fi

head_ "7l. shell 状态传递与 awk 模式陷阱"
if [ -f tools/tests/shell-state.sh ]; then
	if out="$(sh tools/tests/shell-state.sh 2>&1)"; then
		printf '%s\n' "$out" | tail -1 | sed 's/^/    /'
		ok "shell-state.sh 全部断言通过"
	else
		bad "shell-state.sh 有失败断言"
		printf '%s\n' "$out" | grep -E 'FAIL|共 |项失败' | sed 's/^/        /'
	fi
else
	skip "缺少 tools/tests/shell-state.sh"
fi

head_ "8. 打包与三种包格式校验"
if [ "$DO_BUILD" -eq 0 ]; then
	skip "--no-build 指定，跳过"
elif [ -z "$PY" ]; then
	skip "找不到 python，跳过"
else
	if "$PY" scripts/build_apk.py >/dev/null 2>&1; then
		ok "build_apk.py 构建成功"
		# 版本号从 Makefile 读，别在这里硬编码 —— 否则一改版本号
		# 就会出现"构建成功但找不到产物"的假失败。
		MKVER="$(sed -n 's/^PKG_VERSION:=\(.*\)$/\1/p' Makefile | head -1)"
		MKREL="$(sed -n 's/^PKG_RELEASE:=\(.*\)$/\1/p' Makefile | head -1)"
		PKGNAME="$(sed -n 's/^PKG_NAME:=\(.*\)$/\1/p' Makefile | head -1)"
		[ -n "$MKVER" ] || MKVER="1.0.0"
		[ -n "$MKREL" ] || MKREL="1"
		[ -n "$PKGNAME" ] || PKGNAME="luci-app-openclaw"
		APKS=()
		for f in \
			"dist/luci-app-openclaw-${MKVER}-r${MKREL}.apk" \
			"dist/luci-app-openclaw-${MKVER}-r${MKREL}-v2.apk" \
			"dist/luci-app-openclaw_${MKVER}_all.ipk"
		do
			[ -f "$f" ] && APKS+=("$f")
		done
		if [ "${#APKS[@]}" -eq 3 ]; then
			out="$("$PY" scripts/verify_apk.py "${APKS[@]}" 2>&1)"
			if printf '%s' "$out" | grep -q 'RESULT: PASS'; then
				ok "三种包格式 verify 全部 PASS"
			else
				bad "verify 未通过"
				printf '%s\n' "$out" | tail -20 | sed 's/^/        /'
			fi
		else
			bad "缺少构建产物（找到 ${#APKS[@]}/3）"
		fi

		# 产物也要查行尾：.run 是文本脚本，CRLF 会让它的 shebang 失效。
		# （源码树的行尾由第 7 节的检查覆盖，但 dist/ 是构建产物，需要单独查。）
		run_file="dist/${PKGNAME}-${MKVER}.run"
		if [ -f "$run_file" ]; then
			if head -c 10 "$run_file" | grep -q $'\r'; then
				bad "产物行尾：$run_file 含 CR（shebang 会失效）"
			else
				ok "产物行尾：.run 为纯 LF"
			fi
		fi
	else
		bad "build_apk.py 构建失败"
		"$PY" scripts/build_apk.py 2>&1 | tail -15 | sed 's/^/        /'
	fi
fi

# --------------------------------------------------------------------------
printf '\n\033[1m== 汇总 ==\033[0m\n'
printf '  通过 %d  失败 %d  跳过 %d\n' "$PASS" "$FAIL" "$SKIP"
if [ "$FAIL" -gt 0 ]; then
	printf '  \033[31m结论：不通过\033[0m\n'
	exit 1
fi
printf '  \033[32m结论：通过\033[0m\n'
exit 0
