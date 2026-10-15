#!/usr/bin/env bash
# isolated-review.sh — 让 AI 在隔离副本里改造代码，产出可审核的补丁
#
# 设计原则（安全合规）：
#   1. 绝不直接修改正式项目。AI 只在一份临时副本里工作。
#   2. 副本内先建 git 基线，AI 的改动以 unified diff 形式产出。
#   3. 补丁必须通过 patch-guard 检查才能应用。
#   4. 应用前后都要跑 verify-project.sh。
#   5. 默认只产出产物、不应用；加 --apply 才落地。
#   6. 任务拆小：单文件/单主题。长任务会被中断（见文档）。
#
# 用法：
#   tools/isolated-review.sh "只审计并优化 install.sh 的管道吞错与幂等性"
#   tools/isolated-review.sh "检查 scripts/apk3.py 的目录收集逻辑" --no-apply
#   tools/isolated-review.sh "重构 repair.sh" --apply
#
# 选项：
#   --model <name>     模型（默认 glm-5.3）
#   --timeout <sec>    单次执行上限（默认 900）
#   --apply            补丁通过检查后自动应用到正式项目
#   --keep-sandbox     保留隔离副本（默认保留，便于复查）
#   --no-guard         跳过补丁安全闸门（不推荐，仅调试用）

set -u

PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REVIEW_ROOT="$(cd "$PROJ/.." && pwd)/.review"

MODEL="glm-5.3"
TIMEOUT_SEC=900
DO_APPLY=0
DO_GUARD=1

# --------------------------------------------------------------------------
# 参数解析
TASK=""
while [ $# -gt 0 ]; do
	case "$1" in
		--model)   MODEL="${2:-}"; shift 2 ;;
		--timeout) TIMEOUT_SEC="${2:-900}"; shift 2 ;;
		--apply)   DO_APPLY=1; shift ;;
		--no-guard) DO_GUARD=0; shift ;;
		--keep-sandbox) shift ;;
		-h|--help)
			sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
			exit 0 ;;
		-*)
			printf '未知参数：%s\n' "$1" >&2; exit 2 ;;
		*)
			if [ -z "$TASK" ]; then TASK="$1"; else TASK="$TASK $1"; fi
			shift ;;
	esac
done

if [ -z "$TASK" ]; then
	printf '错误：必须给出任务描述。\n\n用法：%s "任务描述" [--model glm-5.3] [--timeout 900] [--apply]\n' \
		"$(basename "$0")" >&2
	exit 2
fi

# --------------------------------------------------------------------------
# 定位工具
PY=""
for cand in python3 python "$HOME/.workbuddy/binaries/python/versions/3.13.12/python.exe"; do
	if command -v "$cand" >/dev/null 2>&1 || [ -x "$cand" ]; then PY="$cand"; break; fi
done
[ -n "$PY" ] || { printf '错误：找不到 python\n' >&2; exit 2; }

CLAUDE_BIN="${CLAUDE_BIN:-}"
if [ -z "$CLAUDE_BIN" ]; then
	for cand in \
		"$HOME/.claude/local/claude.cmd" \
		"$HOME/.claude/local/claude" \
		"$(command -v claude 2>/dev/null)"
	do
		[ -n "$cand" ] || continue
		if [ -x "$cand" ] || command -v "$cand" >/dev/null 2>&1; then CLAUDE_BIN="$cand"; break; fi
	done
fi
[ -n "$CLAUDE_BIN" ] || { printf '错误：找不到 claude CLI（可设 CLAUDE_BIN 指定）\n' >&2; exit 2; }

STAMP="$(date +%Y%m%d-%H%M%S)"
SB="$REVIEW_ROOT/$STAMP/sandbox"
ART="$REVIEW_ROOT/$STAMP/artifacts"
mkdir -p "$SB" "$ART" || exit 2

printf '\n\033[1m隔离审查任务\033[0m\n'
printf '  项目    : %s\n' "$PROJ"
printf '  隔离副本: %s\n' "$SB"
printf '  产物目录: %s\n' "$ART"
printf '  模型    : %s\n' "$MODEL"
printf '  超时    : %ss\n' "$TIMEOUT_SEC"
printf '  任务    : %s\n\n' "$TASK"

# --------------------------------------------------------------------------
printf '\033[1m[1/6] 复制项目到隔离副本\033[0m\n'
( cd "$PROJ" && tar cf - \
	--exclude='./dist' \
	--exclude='./.tmp' \
	--exclude='./.workbuddy' \
	--exclude='./.review' \
	--exclude='./.git' \
	--exclude='__pycache__' \
	--exclude='*/__pycache__/*' \
	--exclude='*.pyc' \
	. ) | ( cd "$SB" && tar xf - ) || { printf '复制失败\n' >&2; exit 2; }

n_files="$(find "$SB" -type f 2>/dev/null | wc -l | tr -d ' ')"
printf '  已复制 %s 个文件\n' "$n_files"

# 沙箱内的 git 只用来产出补丁，所以把"构建产物/缓存"排除掉。
# 不排除的话：沙箱自检跑 py_compile 会生成 __pycache__/*.pyc，
# 它们会被 git add -A 收进补丁，然后被安全闸门当成"新增二进制"拦下。
cat >"$SB/.gitignore" <<'GITIGNORE'
__pycache__/
*.pyc
dist/
.audit-scratch/
*.bak
*.tmp
GITIGNORE

# --------------------------------------------------------------------------
printf '\033[1m[2/6] 建立 git 基线（用于生成补丁）\033[0m\n'
( cd "$SB" \
	&& git init -q \
	&& git config core.autocrlf false \
	&& git config core.safecrlf false \
	&& git config core.fileMode false \
	&& git add -A \
	&& git -c user.email=review@local -c user.name=review commit -q -m baseline ) \
	|| { printf 'git 基线建立失败\n' >&2; exit 2; }
printf '  基线提交完成\n'

# --------------------------------------------------------------------------
printf '\033[1m[3/6] 在隔离副本中执行 AI 改造\033[0m\n'

SYSTEM_EXTRA="你正在一个一次性的隔离副本中工作，当前工作目录就是项目根目录。

硬性约束（必须全部遵守）：
1. 只能修改当前目录内的文件。禁止访问或修改上级目录、用户主目录、系统目录、以及任何 .git 内部文件。
2. 禁止联网：不要执行 npm install / pip install / curl 下载 / wget 下载等任何安装或下载动作。
3. 禁止使用子代理、后台任务、Task 工具。本环境的长任务与后台任务会被强制中断。
4. 禁止在代码、注释、补丁或报告中写入任何真实密钥（API Key、Token、密码）。需要举例时一律写 <REDACTED>。
5. 只做被要求的范围，不要顺手重构无关文件；保持现有功能与文件格式兼容。
6. 不要创建临时脚本、草稿目录或任何非交付文件（例如 .audit-scratch/、test-*.sh）。
   需要验证时用行内命令（sh -c '...'），不要落地成文件。

【最重要的执行顺序 —— 本环境会在任意时刻强制中断，所以】
  第一步：先完成审计，把发现的问题按 严重/中等/轻微 分级**立即写入 review-report.md**。
          不要等到最后才写报告，否则中断后什么都留不下来。
  第二步：再动手修复其中明确的缺陷；每修完一项，就把该项在报告里标注为「已修复」。
  第三步：若还有余力，运行 sh -n / node --check / python -m py_compile 做语法自检，结果追加进报告。

review-report.md 必须包含：发现的问题（分级 + 位置 + 原因）、已修复项、未修复项及原因、
执行过的检查命令与结果、以及建议的后续验证。"

PROMPT="$TASK"

export CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
export DISABLE_TELEMETRY=1
export DISABLE_ERROR_REPORTING=1
export DISABLE_AUTOUPDATER=1

# 工具策略（实测调优）：
# 最初用「白名单只放开几个 Bash 动词」，结果 AI 反复尝试白名单外的命令，
# 实测一次 240s 运行里 16 次 Bash 调用有 8 次被拒 —— 一半轮次白白浪费。
# 现在改为「放开 Bash，只显式禁用真正危险的动作」：
#   网络（curl/wget/npm/pip）、提权（sudo/ssh/scp）、递归删除。
# 主要隔离手段是"一次性沙箱副本 + 补丁安全闸门"，而不是工具白名单。
ALLOWED_TOOLS="Read Write Edit Glob Grep Bash"
DISALLOWED_TOOLS="Bash(curl:*) Bash(wget:*) Bash(npm:*) Bash(pip:*) Bash(pip3:*) Bash(sudo:*) Bash(su:*) Bash(ssh:*) Bash(scp:*) Bash(rm -rf:*)"

set +e
( cd "$SB" && timeout "$TIMEOUT_SEC" "$CLAUDE_BIN" \
	-p "$PROMPT" \
	--model "$MODEL" \
	--permission-mode acceptEdits \
	--allowedTools "$ALLOWED_TOOLS" \
	--disallowedTools "$DISALLOWED_TOOLS" \
	--append-system-prompt "$SYSTEM_EXTRA" \
	--output-format text \
	< /dev/null ) >"$ART/ai-report.md" 2>"$ART/ai-stderr.log"
CLAUDE_RC=$?
set -e 2>/dev/null || true
set +e

printf '  AI 退出码：%s\n' "$CLAUDE_RC"
case "$CLAUDE_RC" in
	0)   printf '  执行完成\n' ;;
	124) printf '  \033[33m超时被终止（%ss）\033[0m\n' "$TIMEOUT_SEC" ;;
	*)   printf '  \033[33m非零退出，详见 ai-stderr.log\033[0m\n' ;;
esac

# --------------------------------------------------------------------------
printf '\033[1m[4/6] 生成补丁与清单\033[0m\n'

# AI 的自述报告是"产物"，不是"代码改动"。它必须从补丁里剥离出来，
# 否则会被安全闸门当成越界路径拦下（review-report.md 不在允许改动范围内）。
for rf in review-report.md REVIEW-REPORT.md review_report.md ai-report.md REPORT.md; do
	if [ -f "$SB/$rf" ]; then
		cp "$SB/$rf" "$ART/ai-self-report.md" 2>/dev/null
		rm -f "$SB/$rf"
		printf '  已剥离报告文件：%s -> artifacts/ai-self-report.md\n' "$rf"
	fi
done

( cd "$SB" && git add -A && git diff --cached >"$ART/changes.patch" ) || true
( cd "$SB" && git diff --cached --stat >"$ART/changed-files.txt" ) || true
( cd "$SB" && git status --porcelain >>"$ART/changed-files.txt" ) || true

patch_lines="$(wc -l <"$ART/changes.patch" 2>/dev/null | tr -d ' ')"
printf '  补丁行数：%s\n' "${patch_lines:-0}"

if [ "${patch_lines:-0}" -eq 0 ]; then
	printf '  \033[33m注意：补丁为空，AI 可能没有做出任何修改\033[0m\n'
fi

# 隔离副本里的自检（在副本内跑，用于评估 AI 改动是否可用）
# 用 --no-build：打包验证放到补丁应用之后在正式项目里做，沙箱里只做语法与结构检查，
# 既省时间，也避免沙箱里生成 dist/ 与 __pycache__ 污染补丁。
if [ -x "$SB/tools/verify-project.sh" ]; then
	( cd "$SB" && bash tools/verify-project.sh --no-build ) >"$ART/sandbox-verify.log" 2>&1
	printf '  副本内自检：%s\n' \
		"$(grep -q '结论：通过' "$ART/sandbox-verify.log" && echo '通过' || echo '未通过（见 sandbox-verify.log）')"
fi

# --------------------------------------------------------------------------
printf '\033[1m[5/6] 补丁安全闸门\033[0m\n'
GUARD_RC=0
if [ "$DO_GUARD" -eq 1 ] && [ -f "$ART/changes.patch" ]; then
	"$PY" "$PROJ/tools/patch-guard.py" "$ART/changes.patch" >"$ART/guard-report.txt" 2>&1
	GUARD_RC=$?
	cat "$ART/guard-report.txt" | sed 's/^/  /'
else
	printf '  已跳过\n'
fi

# --------------------------------------------------------------------------
printf '\033[1m[6/6] 结论\033[0m\n'

VERDICT="待人工确认"
if [ "${patch_lines:-0}" -eq 0 ]; then
	VERDICT="无改动"
elif [ "$GUARD_RC" -ne 0 ]; then
	VERDICT="禁止应用（安全闸门拦截）"
fi

APPLIED="否"
if [ "$DO_APPLY" -eq 1 ] && [ "$VERDICT" = "待人工确认" ]; then
	if ( cd "$PROJ" && git apply --check "$ART/changes.patch" 2>"$ART/apply.log" ); then
		if ( cd "$PROJ" && git apply "$ART/changes.patch" 2>>"$ART/apply.log" ); then
			APPLIED="是"
			VERDICT="已应用"
		else
			VERDICT="应用失败（见 apply.log）"
		fi
	else
		VERDICT="补丁无法干净应用（可能上下文不匹配，见 apply.log）"
	fi
fi

{
	printf '# 隔离审查报告\n\n'
	printf -- '- 时间：%s\n' "$STAMP"
	printf -- '- 模型：%s\n' "$MODEL"
	printf -- '- 任务：%s\n' "$TASK"
	printf -- '- 隔离副本：`%s`\n' "$SB"
	printf -- '- 产物目录：`%s`\n\n' "$ART"
	printf '## 结论\n\n'
	printf -- '- AI 退出码：%s\n' "$CLAUDE_RC"
	printf -- '- 补丁行数：%s\n' "${patch_lines:-0}"
	printf -- '- 安全闸门：%s\n' "$([ "$GUARD_RC" -eq 0 ] && echo 通过 || echo 拦截)"
	printf -- '- 是否已应用：%s\n' "$APPLIED"
	printf -- '- 状态：%s\n\n' "$VERDICT"
	printf '## 产物\n\n'
	printf -- '- `ai-report.md`      AI 的说明与自检结果\n'
	printf -- '- `changes.patch`     待审核的补丁\n'
	printf -- '- `changed-files.txt` 变更文件清单\n'
	printf -- '- `guard-report.txt`  安全闸门结论\n'
	printf -- '- `sandbox-verify.log` 副本内自检日志\n'
	printf -- '- `ai-stderr.log`     AI 运行日志\n\n'
	printf '## 下一步\n\n'
	printf '1. 人工阅读 `changes.patch` 与 `guard-report.txt`\n'
	printf '2. 确认无误后在项目根目录执行：`git apply %s/changes.patch`\n' "$ART"
	printf '3. 执行 `tools/verify-project.sh` 做全量回归\n'
} >"$ART/SUMMARY.md"

printf '  AI 退出码 : %s\n' "$CLAUDE_RC"
printf '  补丁行数  : %s\n' "${patch_lines:-0}"
printf '  安全闸门  : %s\n' "$([ "$GUARD_RC" -eq 0 ] && echo 通过 || echo 拦截)"
printf '  已应用    : %s\n' "$APPLIED"
printf '  状态      : %s\n' "$VERDICT"
printf '\n  产物目录：%s\n\n' "$ART"

# 应用后回归
if [ "$APPLIED" = "是" ]; then
	printf '\033[1m应用后回归验证\033[0m\n'
	( cd "$PROJ" && bash tools/verify-project.sh ) 2>&1 | tail -8
fi

exit 0
