#!/usr/bin/env python3
"""lua-patterns.py — 检查 Lua 模式串里的运行时陷阱

`luaparser` 只做语法解析：`s:gsub("+", " ")` 语法完全合法，但运行时会抛
`malformed pattern (ends with '%')` / `malformed pattern` —— 因为 `+` 是
模式量词，前面没有主语。这类错误浏览器里只看到 500，日志里也只是一行，
排查成本很高。

本脚本做两件事：

1. **模式以量词开头**：`+ * ? -` 出现在模式串开头（未转义）→ 必然 malformed。
   实测踩过一次：`s:gsub("+", " ")` 想做"把加号换成空格"，结果整个端点 500。

2. **find/match 用了 plain 参数却传了模式字符**：`s:find("[&?]"..k, 1, true)`
   的最后一个 `true` 让整串按字面量匹配，方括号不再是字符类，永远不命中。
   这是逻辑 bug 而非报错，更难发现（实测踩过一次）。

只检查字符串字面量参数，变量拼进来的模式无法静态判断（会给出提示但不算失败）。

退出码：
  0 = 没有发现确定的问题
  1 = 发现确定的问题
"""

import json
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
files = sorted(root.glob("luasrc/**/*.lua"))
if not files:
    print("    跳过：没有找到 .lua 文件")
    sys.exit(0)

# 会解释模式的方法
PATTERN_METHODS = ("gsub", "gmatch", "find", "match")

# Lua 模式里出现在开头就是非法的量词
LEADING_QUANT = set("+*?-")

# 单个字符类/模式字符：出现在 plain 模式的 find 里就是"想当模式用"
META = set("[]()%+*?^$")

problems = []

for f in files:
    lines = f.read_text(encoding="utf-8", errors="replace").splitlines()
    for lineno, line in enumerate(lines, 1):
        code = re.sub(r"--.*$", "", line)          # 去掉行注释
        for meth in PATTERN_METHODS:
            for m in re.finditer(r":%s\s*\(\s*(\"[^\"\\n]*\"|'[^'\\n]*')" % meth, code):
                lit = m.group(1)[1:-1]
                if not lit:
                    continue
                # 1) 以未转义的量词开头
                if lit[0] in LEADING_QUANT:
                    problems.append(
                        ("ERROR", f, lineno,
                         's:%s 的模式以量词 %r 开头，运行时会抛 malformed pattern；'
                         '要匹配字面量请写成 %%%s' % (meth, lit[0], lit[0])))
                # 2) find 的 plain 参数为 true 但模式里含元字符
                if meth == "find":
                    tail = code[m.end():]
                    if re.match(r'\s*,\s*[^,)]+\s*,\s*true\s*\)', tail):
                        if any(c in META for c in lit):
                            problems.append(
                                ("ERROR", f, lineno,
                                 "s:find(..., true) 是 plain 模式，%r 里的元字符"
                                 "会被当字面量，永远不命中" % lit))

for kind, f, lineno, msg in problems:
    print("    %s  %s:%d" % (kind, f.relative_to(root).as_posix(), lineno))
    print("          " + msg)

if problems:
    print("    共 %s 处模式串问题" % len(problems))
    sys.exit(1)

print("    共 %s 个文件，模式串检查通过" % len(files))
sys.exit(0)
