#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
patch-guard.py — 补丁安全闸门

用途：在把 AI 产出的补丁应用到正式项目之前，先做一次机械化的安全检查。
它不判断"改得好不好"，只判断"改得危不危险"。

用法：
    python3 tools/patch-guard.py changes.patch
    python3 tools/patch-guard.py changes.patch --json

退出码：
    0 = 通过（可能有 WARN）
    1 = 存在 BLOCK 项，禁止应用
    2 = 参数/文件错误
"""

import argparse
import json
import re
import sys
from pathlib import Path

# ---------------------------------------------------------------------------
# 允许改动的路径前缀。补丁里出现任何此前缀之外的文件，一律 BLOCK。
ALLOWED_PREFIXES = (
    "root/",
    "luasrc/",
    "htdocs/",
    "scripts/",
    "tools/",
    "Makefile",
    "README.md",
)

# 绝不允许出现在补丁里的路径（即使是新增）
FORBIDDEN_PATH_PATTERNS = (
    r"^\.\./",
    r"^/",
    r"^[A-Za-z]:",
    r"^\.git/",
    r"^\.workbuddy/",
    r"^\.review/",
    r"^dist/",
    r"\.ssh/",
    r"authorized_keys",
    r"/etc/passwd",
    r"/etc/shadow",
    r"\.bashrc$",
    r"\.profile$",
    r"\.claude",
    r"settings\.json$",
)

# 关键文件：不允许被补丁删除
CRITICAL_FILES = (
    "root/etc/init.d/openclawmgr",
    "root/etc/config/openclawmgr",
    "root/etc/uci-defaults/99-openclawmgr",
    "root/usr/libexec/istorec/openclawmgr.sh",
    "root/usr/libexec/openclawmgr/lib.sh",
    "root/usr/libexec/openclawmgr/install.sh",
    "root/usr/libexec/openclawmgr/versions.sh",
    "root/usr/libexec/openclawmgr/models.sh",
    "root/usr/libexec/openclawmgr/channels.sh",
    "root/usr/libexec/openclawmgr/repair.sh",
    "luasrc/controller/openclaw.lua",
    "root/usr/share/rpcd/acl.d/luci-app-openclaw.json",
    "Makefile",
)

# 新增文件里不允许出现的扩展名（二进制/可执行载荷）
FORBIDDEN_NEW_SUFFIXES = (
    ".exe", ".dll", ".so", ".node", ".bin", ".msi", ".dmg",
    ".apk", ".ipk", ".deb", ".rpm", ".jar", ".pyc",
)

# ---------------------------------------------------------------------------
# 行级规则：(严重级别, 名称, 正则, 说明)
LINE_RULES = [
    ("BLOCK", "递归删除",
     r"\brm\s+(-[a-zA-Z]*\s+)*-[a-zA-Z]*[rR][a-zA-Z]*f|rm\s+-[a-zA-Z]*f[a-zA-Z]*\s+.*\s-[a-zA-Z]*[rR]",
     "出现 rm -rf 类递归强制删除"),

    ("BLOCK", "管道执行远程脚本",
     r"(curl|wget|uclient-fetch)\b[^\n|]*\|\s*(sudo\s+)?(sh|bash|ash|zsh)\b",
     "把网络内容直接管道给 shell 执行"),

    ("BLOCK", "eval 执行",
     r"(^|[;&|(]\s*)eval\s",
     "eval 会把数据当代码执行，审计无法覆盖"),

    ("BLOCK", "写入系统账户文件",
     r"(>>?|tee\s+)\s*[^|]*\b(/etc/(passwd|shadow|sudoers)|authorized_keys)",
     "试图写系统账户/授权文件"),

    ("BLOCK", "反弹 shell",
     r"\bnc\s+(-[a-zA-Z]+\s+)*.*\s-e\s|/dev/tcp/|bash\s+-i\s+>&",
     "反弹 shell 特征"),

    ("BLOCK", "fork 炸弹",
     r":\(\)\s*\{.*\};\s*:",
     "fork 炸弹"),

    ("BLOCK", "明文密钥",
     r"\bsk-[A-Za-z0-9_\-]{16,}",
     "补丁里出现了疑似 API Key 明文"),

    ("BLOCK", "私钥",
     r"-----BEGIN [A-Z ]*PRIVATE KEY-----",
     "补丁里出现了私钥"),

    ("WARN", "宽权限",
     r"\bchmod\s+(-[a-zA-Z]+\s+)*0?777\b",
     "chmod 777 会放开所有权限"),

    ("WARN", "强制杀进程",
     r"\bkill\s+-9\b",
     "kill -9 无优雅退出机会（本项目仅 oc_kill_tree 场景允许，需人工确认）"),

    ("WARN", "关闭校验",
     r"--no-check-certificate|--insecure\b|verify\s*=\s*False|ssl_verify\s*=\s*false",
     "关闭 TLS 证书校验"),

    ("WARN", "追加 crontab",
     r"\bcrontab\b|\bcron\.d\b",
     "改动计划任务"),

    ("WARN", "修改启动脚本",
     r"init\.d/|rc\.d/|rc\.local",
     "改动系统启动逻辑，需重点人工确认"),

    ("WARN", "环境变量外传",
     r"\b(env|printenv|set)\b\s*\|\s*(curl|wget|nc)\b",
     "把环境变量（可能含密钥）外发"),

    ("WARN", "无校验下载",
     r"(curl|wget)\b[^\n]*\s-o\s|(curl|wget)\b[^\n]*--output\s",
     "新增下载动作，确认有校验与来源可信"),
]


# 受限于名称与深度的删除（find <dir> -maxdepth N -name '<pat>' ... -exec rm -rf {} \;）
# 是常见的安全写法：它只删匹配到的那几个条目。命中它时把"递归删除"从 BLOCK
# 降为 WARN —— 仍然让人看一眼，但不至于把整份补丁拦死。
SCOPED_RM_RX = re.compile(
    r"\bfind\b[^\n]*\s-maxdepth\s+\d+[^\n]*\s-name\s+['\"][^'\"]+['\"]"
    r"[^\n]*\s-exec\s+rm\s+-[a-zA-Z]*r[a-zA-Z]*f?\s+\{\}",
    re.IGNORECASE,
)


def parse_patch(text: str):
    """把 unified diff 解析成每个文件的 dict。

    注意：diff 里 "--- a/x" 在 "+++ b/x" 之前。上一版按 +++ 建条目、
    再回头用 --- 判断 is_new，结果把"新增文件"标记到了前一个文件上，
    新增的 .exe 因此逃过检查。这里改成成对识别：
    只有 "--- " 且紧邻下一行是 "+++ " 时，才当成文件头。
    """
    lines = text.splitlines()
    files = []
    cur = None
    i = 0
    n = len(lines)
    while i < n:
        line = lines[i]
        if (line.startswith("--- ")
                and i + 1 < n and lines[i + 1].startswith("+++ ")):
            old = line[4:].strip().split("\t")[0]
            new = lines[i + 1][4:].strip().split("\t")[0]
            if cur:
                files.append(cur)
            if new == "/dev/null":
                path = re.sub(r"^[ab]/", "", old)
                is_del = True
            else:
                path = re.sub(r"^[ab]/", "", new)
                is_del = False
            cur = {
                "path": path,
                "added": [],
                "removed": [],
                "is_new": (old == "/dev/null"),
                "is_del": is_del,
            }
            i += 2
            continue
        if cur is not None:
            if line.startswith("+"):
                cur["added"].append(line[1:])
            elif line.startswith("-"):
                cur["removed"].append(line[1:])
        i += 1
    if cur:
        files.append(cur)
    return files


def check(patch_path: Path):
    findings = []          # (level, category, detail)
    text = patch_path.read_text(encoding="utf-8", errors="replace")

    if not text.strip():
        findings.append(("WARN", "空补丁", "补丁文件没有任何内容"))
        return findings

    files = parse_patch(text)

    if not files:
        findings.append(("BLOCK", "解析失败", "无法从补丁中解析出任何文件，格式可能不合法"))
        return findings

    for f in files:
        path = f["path"]
        # 路径白名单
        if not path.startswith(ALLOWED_PREFIXES):
            findings.append(
                ("BLOCK", "越界路径", f"{path} 不在允许改动的目录范围内"))
        for pat in FORBIDDEN_PATH_PATTERNS:
            if re.search(pat, path):
                findings.append(
                    ("BLOCK", "危险路径", f"{path} 命中禁止模式 {pat}"))

        # 删除文件：关键文件一律拦截，其余提醒
        if f.get("is_del"):
            if path in CRITICAL_FILES:
                findings.append(
                    ("BLOCK", "删除关键文件", f"{path} 是关键文件，不允许删除"))
            else:
                findings.append(("WARN", "删除文件", f"{path} 被删除"))

        # 新增文件
        if f["is_new"]:
            low = path.lower()
            for suf in FORBIDDEN_NEW_SUFFIXES:
                if low.endswith(suf):
                    findings.append(
                        ("BLOCK", "新增二进制", f"{path} 是新增的 {suf} 文件"))
            if low.startswith("root/") and "/bin/" in low and not low.endswith((".sh", ".py")):
                findings.append(
                    ("WARN", "新增可执行文件", f"{path} 位于 bin 目录"))

        # 行级规则
        for level, name, pat, desc in LINE_RULES:
            rx = re.compile(pat, re.IGNORECASE)
            for ln in f["added"]:
                body = ln.strip()
                # 注释不可能被执行。早期版本会把注释里提到的 `rm -rf` 当成真代码，
                # 于是一句解释性注释就把整份补丁拦死了。
                if body.startswith("#") or body.startswith("--"):
                    continue
                if not rx.search(ln):
                    continue
                snippet = ln.strip()[:120]
                if name == "递归删除" and SCOPED_RM_RX.search(ln):
                    findings.append(
                        ("WARN", "受限递归删除",
                         f"{path}: find 已限定 -maxdepth/-name，仍需人工确认 → {snippet}"))
                    continue
                findings.append((level, name, f"{path}: {desc} → {snippet}"))

    # 统计信息
    total_add = sum(len(f["added"]) for f in files)
    total_del = sum(len(f["removed"]) for f in files)
    findings.append(
        ("INFO", "统计", f"{len(files)} 个文件，+{total_add} / -{total_del} 行"))
    return findings


def main():
    ap = argparse.ArgumentParser(description="补丁安全闸门")
    ap.add_argument("patch", help="unified diff 文件路径")
    ap.add_argument("--json", action="store_true", help="以 JSON 输出")
    args = ap.parse_args()

    p = Path(args.patch)
    if not p.is_file():
        print(f"错误：找不到补丁文件 {p}", file=sys.stderr)
        return 2

    findings = check(p)
    blocked = [f for f in findings if f[0] == "BLOCK"]
    warned = [f for f in findings if f[0] == "WARN"]
    infos = [f for f in findings if f[0] == "INFO"]

    if args.json:
        print(json.dumps({
            "blocked": [{"category": c, "detail": d} for _, c, d in blocked],
            "warned": [{"category": c, "detail": d} for _, c, d in warned],
            "info": [{"category": c, "detail": d} for _, c, d in infos],
            "verdict": "BLOCK" if blocked else "PASS",
        }, ensure_ascii=False, indent=2))
        return 1 if blocked else 0

    for lvl, cat, det in blocked:
        print(f"[BLOCK] {cat}: {det}")
    for lvl, cat, det in warned:
        print(f"[WARN ] {cat}: {det}")
    for lvl, cat, det in infos:
        print(f"[INFO ] {cat}: {det}")

    print()
    if blocked:
        print(f"结论：禁止应用（{len(blocked)} 项 BLOCK，{len(warned)} 项 WARN）")
        return 1
    print(f"结论：通过（{len(warned)} 项 WARN 需人工确认）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
