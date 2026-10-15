#!/usr/bin/env bash
# audit-suite.sh — 全项目深度审计（拆批执行）
#
# 为什么要拆批：AI CLI 的 -p 模式有后台子代理 10 分钟上限，加上会话配额，
# 一次性"审计整个项目"必然中途失败。这里按模块拆成若干小批次，
# 每批独立走一遍隔离流程（副本 → 补丁 → 闸门），互不阻塞。
#
# 用法：
#   tools/audit-suite.sh              # 跑全部批次
#   tools/audit-suite.sh 1 3          # 只跑第 1 和第 3 批
#
# 产物：每批一个 .review/<时间戳>/artifacts/ 目录；
#       最后在 .review/<套件时间戳>/SUITE-SUMMARY.md 汇总。

set -u

PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ" || exit 1

TIMEOUT_PER_BATCH="${TIMEOUT_PER_BATCH:-720}"

# 批次定义：<批次名>|<目标文件>|<审计要点>
#
# 粒度原则（实测结论）：AI 网关每轮 5–30 秒，任务必须小到 10 轮左右能完成。
# 一个 700 行的文件整体审计是跑不完的 —— 要按函数组拆开。
BATCHES=(
	"backup-core|root/usr/libexec/openclawmgr/backup.sh|新建的备份实现，只看 create / list / delete 三个命令与 oc_backup_resolve 的路径约束。重点：文件名注入、路径越界、空间检查、暂存目录清理、权限收紧失败是否告警、JSON 输出是否被日志污染"

	"backup-restore|root/usr/libexec/openclawmgr/backup.sh|只看 verify / restore 与 oc_archive_inspect / oc_archive_ok_size。重点：恶意归档（绝对路径/../符号链接/硬链接/设备/FIFO/缺清单）是否被完整拒绝、解压体积上限、安全快照与回滚路径、还原中断后的残留"

	"lib-ver|root/usr/libexec/openclawmgr/lib.sh|只看版本相关函数：_ver_field / _ver_raw / _cmp_one / _caret_ok / _tilde_ok / engines_match / engines_min_version / ver_ge 等。重点：semver 边界（预发布号、位数不足、x-range）、运算符优先级、变量作用域泄漏"

	"lib-net|root/usr/libexec/openclawmgr/lib.sh|只看网络与解析函数：oc_fetch / oc_fetch_body / oc_json_get / oc_json_has / oc_json_str / oc_safe_url / oc_need / oc_ca_ok / oc_arch / oc_sys_version。重点：URL 校验绕过、控制字符、awk/tr 可移植性、错误码被管道吞掉"

	"lib-safe|root/usr/libexec/openclawmgr/lib.sh|只看安全与进程函数：oc_rundir / oc_dir_uid / oc_lock_acquire / oc_lock_release / oc_locked / oc_pid_in_ancestry / oc_kill_tree / oc_gateway_pids / oc_ensure_user / oc_fix_perms / oc_validate_base_dir / oc_validate_base_dir_shape / oc_canonical_dir。重点：锁的竞态与自愈、误杀进程、符号链接绕过、路径形状过滤"

	"install|root/usr/libexec/openclawmgr/install.sh|安装流程。重点：参数解析、错误码传播、管道吞错、下载校验与断点、npm 源/代理注入、.env 写入、幂等性与失败回滚、--force 语义"

	"versions|root/usr/libexec/openclawmgr/versions.sh|在线版本发现。重点：缓存读写一致性、并发刷新、engines 解析、网络失败降级、JSON 转义、oc-tags.tsv 与 oc-versions.tsv 的同步"

	"models-channels|root/usr/libexec/openclawmgr/models.sh root/usr/libexec/openclawmgr/channels.sh|模型与渠道。重点：插件安装与缓存失效、API Key 传递路径（argv vs 环境变量）、preset 解析、jsonfilter 使用、渠道命令的错误处理"

	"repair|root/usr/libexec/openclawmgr/repair.sh|一键修复。重点：13 项检查的幂等性与顺序、FAIL 后是否真的停止、chown/chmod 的作用范围、JSON 模式输出、退出码语义"

	"luci-ctrl|luasrc/controller/openclaw.lua|LuCI 控制器（含新增的备份/恢复端点）。重点：命令注入（q() 转义是否覆盖所有 formvalue）、白名单粒度、上传/下载端点的路径约束、错误处理与 JSON 输出"

	"luci-view-status|luasrc/view/openclaw/status.htm|状态页（含新增备份 UI）。重点：XSS（服务端数据是否只进 textContent）、上传/下载/恢复的交互与失败提示、轮询逻辑、DOM 构建"

	"packaging|scripts/apk3.py scripts/build_apk.py scripts/verify_apk.py|打包器。重点：APK v3 目录完整性与哈希公式、块对齐、v2/ipk 生成、自检脚本能否真正发现损坏、路径处理"
)

want() {
	# want <批次号> [用户指定的批次号...]
	# 调用方是 want "$i" "$@"，所以 $# 至少为 1；未指定时 $# == 1 表示"跑全部"
	local n="$1"
	shift
	[ "$#" -eq 0 ] && return 0
	local i
	for i in "$@"; do [ "$i" = "$n" ] && return 0; done
	return 1
}

STAMP="$(date +%Y%m%d-%H%M%S)"
SUITE="$PROJ/../.review/suite-$STAMP"
mkdir -p "$SUITE" || exit 2

printf '\n\033[1m全项目深度审计\033[0m\n'
printf '  项目      : %s\n' "$PROJ"
printf '  批次总数  : %s\n' "${#BATCHES[@]}"
printf '  单批超时  : %ss\n' "$TIMEOUT_PER_BATCH"
printf '  汇总目录  : %s\n\n' "$SUITE"

i=0
for entry in "${BATCHES[@]}"; do
	i=$((i + 1))
	name="${entry%%|*}"
	rest="${entry#*|}"
	files="${rest%%|*}"
	focus="${rest#*|}"

	if ! want "$i" "$@"; then
		printf '\033[33m[%s/%s] 跳过批次 %s\033[0m\n\n' "$i" "${#BATCHES[@]}" "$name"
		continue
	fi

	printf '\033[1m[%s/%s] 批次 %s\033[0m\n' "$i" "${#BATCHES[@]}" "$name"
	printf '  目标：%s\n' "$files"

	TASK="对本项目的以下文件做一次深度审计：$files

审计要点：$focus

【执行预算 —— 最重要，务必遵守】
本环境的模型网关很慢（每轮 5–30 秒），超过预算会被强制中断且报告全部丢失。
- 最多使用 12 次工具调用（读文件、跑命令都算一次）。
- 第 10 次调用之前，必须已经把 review-report.md 写好。
- 剩余调用只用于修复代码，不要再做新的探索。
- 不要创建临时脚本或草稿目录。

要求：
1. 只审计上述文件，不要改动其他文件。
2. 逐个函数/分支检查真实缺陷：逻辑错误、边界条件、错误码被吞、资源泄漏、
   竞态、幂等性、busybox ash 兼容性、注入与转义。
3. 对**明确**的缺陷直接修复；对不确定或有争议的，只在报告中说明，不要改代码。
4. 不要为了"看起来更好"而重构无关代码，不要改动文件格式与既有功能。
5. 把结论写入 review-report.md：按 严重/中等/轻微 分级列出发现的问题、
   每项的位置与原因、你改了什么、没改什么及原因、以及建议的后续验证。"

	LOG="$SUITE/$name.log"
	# 外层超时必须给后处理留足余量（沙箱自检 + git diff + 闸门）。
	# 上一版只留 120s，结果 AI 超时后整个脚本也被杀，连闸门结论都没写出来。
	OUTER=$((TIMEOUT_PER_BATCH + 300))
	if timeout "$OUTER" bash tools/isolated-review.sh "$TASK" \
		--timeout "$TIMEOUT_PER_BATCH" >"$LOG" 2>&1; then
		:
	fi

	# 取出这一批的产物目录（头部用半角冒号、尾部用全角冒号，两种都要认）
	art="$(grep -oE '产物目录[：:][^ ]+' "$LOG" 2>/dev/null | tail -1 | sed 's/^产物目录[：:]//')"
	verdict="$(grep -E '^[[:space:]]+状态[[:space:]]+:' "$LOG" 2>/dev/null | tail -1 | sed 's/.*: *//')"
	guard="$(grep -E '^[[:space:]]+安全闸门[[:space:]]+:' "$LOG" 2>/dev/null | tail -1 | sed 's/.*: *//')"
	lines="$(grep -E '^[[:space:]]+补丁行数[[:space:]]+:' "$LOG" 2>/dev/null | tail -1 | sed 's/.*: *//')"

	# 报告才是审计的主要产出：AI 超时被中断时报告为空，这一批等于白跑
	rep=0
	if [ -n "$art" ] && [ -d "$art" ]; then
		for rf in ai-self-report.md ai-report.md; do
			if [ -f "$art/$rf" ]; then rep="$(wc -c <"$art/$rf" 2>/dev/null | tr -d ' ')"; break; fi
		done
	fi
	case "$rep" in ''|*[!0-9]*) rep=0 ;; esac
	if [ "$rep" -gt 200 ]; then
		repstate="有报告（${rep} 字节）"
	else
		repstate="\033[33m无有效报告\033[0m"
	fi

	printf '  补丁 %s 行 | 报告 %b | 闸门 %s | 状态 %s\n' "${lines:-?}" "$repstate" "${guard:-?}" "${verdict:-?}"
	if [ -n "$art" ] && [ -d "$art" ]; then
		printf '  产物：%s\n' "$art"
	fi
	printf '\n'

	# 记录到汇总
	{
		printf '## 批次 %s — %s\n\n' "$i" "$name"
		printf -- '- 目标：`%s`\n' "$files"
		printf -- '- 补丁行数：%s\n' "${lines:-?}"
		printf -- '- 报告：%s\n' "$repstate"
		printf -- '- 安全闸门：%s\n' "${guard:-?}"
		printf -- '- 状态：%s\n' "${verdict:-?}"
		[ -n "$art" ] && printf -- '- 产物：`%s`\n' "$art"
		printf '\n'
	} >>"$SUITE/SUITE-SUMMARY.md"
done

printf '\033[1m套件结束\033[0m\n'
printf '  汇总：%s/SUITE-SUMMARY.md\n' "$SUITE"
[ -f "$SUITE/SUITE-SUMMARY.md" ] && cat "$SUITE/SUITE-SUMMARY.md"
exit 0
