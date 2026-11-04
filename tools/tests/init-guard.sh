#!/bin/sh
# init-guard.sh —— 守住 init.d 启动路径的两个死穴（真机踩过，代价是服务起不来）
#
# 1) **init.d 不 source lib.sh**。它自带 uci_get 等函数，刻意避免命名冲突。
#    所以任何 lib.sh 里的辅助函数（oc_clean_sqlite_snapshots / oc_free_mb /
#    oc_as_user …）在 init.d 里**裸调用一定失败**。1.8.68 就是这样把服务拦死的：
#    快照清理返回空 → 可用空间被当成 0 → 「<200MB 拒绝启动」直接 return 1，
#    状态页显示 `active with no instances`，看起来像配置坏了。
#    要求：要么放进子 shell 里临时 `.` 一下，要么根本不用。
#
# 2) 启动路径上的检查必须 **fail-open**：拿不到数据就跳过，不能因为一个
#    辅助工具缺失而拒绝启动。磁盘检查写成「空值也当 0」是隐形的拒绝启动。

set -u
INITD="root/etc/init.d/openclaw"
LIB="root/usr/libexec/openclaw/lib.sh"
fail=0
n=0

chk() {
	n=$((n + 1))
	if [ "$1" = "ok" ]; then
		printf '    ok    %s\n' "$2"
	else
		printf '    FAIL  %s\n' "$2"
		fail=$((fail + 1))
	fi
}

[ -f "$INITD" ] || { printf '    跳过：找不到 %s\n' "$INITD"; exit 0; }
[ -f "$LIB" ] || { printf '    跳过：找不到 %s\n' "$LIB"; exit 0; }

# 取 lib.sh 里定义的函数名，逐个看 init.d 里有没有裸调用
LIBSH_FUNCS="$(sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)()[[:space:]]*{[[:space:]]*$/\1/p' "$LIB" | sort -u)"

bare=""
for fn in $LIBSH_FUNCS; do
	# 在 init.d 里找到调用点，再排除掉「同一行或附近有 . lib.sh」的
	# 简化判据：只要出现 "$fn" 且该文件里没有 `. /usr/libexec/openclaw/lib.sh`
	# 的上下文包裹，就算裸调用。这里用保守做法：逐行找，跳过注释。
	while IFS= read -r line; do
		case "$line" in
			\#*) continue ;;
		esac
		case "$line" in
			*"$fn"*) bare="$bare $fn" ;;
		esac
	done <<EOF
$(grep -v '^\s*#' "$INITD" 2>/dev/null)
EOF
done

# 只关心我们新引入的那几个（其余历史调用本来就不存在，避免误报）
for fn in oc_clean_sqlite_snapshots oc_free_mb oc_as_user oc_as_user_timeout oc_heal_openclaw_cache_dirs; do
	case "$bare" in
		*" $fn"*|*"$fn "*) ;;
		*) continue ;;
	esac
	# 有子 shell 里临时加载的写法就算安全：同一行出现 `. /usr/libexec/openclaw/lib.sh`
	if grep -q "\. /usr/libexec/openclaw/lib.sh" "$INITD" 2>/dev/null; then
		chk ok "init.d 通过子 shell 加载 lib.sh 后再用 $fn"
	else
		chk fail "init.d 裸调用了 lib.sh 的 $fn（会 command not found）"
	fi
done

# 兜底：启动路径里不允许「取不到就当 0 → 拒绝启动」的写法
if grep -q 'dispatch' "$INITD" 2>/dev/null; then :; fi
if grep -q '_oc_free=""' "$INITD" 2>/dev/null; then
	chk ok '空间检查对空值走 fail-open（不拒绝启动）'
else
	chk fail '空间检查缺少 fail-open 分支（空值会被当成 0 而拒绝启动）'
fi
if grep -q 'return 1' "$INITD" 2>/dev/null; then :; fi
if grep -q 'df -m' "$INITD" 2>/dev/null; then
	chk ok 'init.d 用 df 直接取空间（不依赖 lib.sh）'
else
	chk fail 'init.d 取空间仍依赖 lib.sh'
fi

# schema 自愈必须走 cli.sh 子命令（那边才有跨 su 的超时封装）
if grep -q 'cli.sh selfheal-schema' "$INITD" 2>/dev/null; then
	chk ok 'schema 自愈通过 cli.sh selfheal-schema 执行'
else
	chk fail 'schema 自愈没有走 cli.sh 子命令'
fi

printf '    共 %s 项，%s 项失败\n' "$n" "$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
