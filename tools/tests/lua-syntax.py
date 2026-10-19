#!/usr/bin/env python3
"""lua-syntax.py — 控制器 Lua 语法检查

LuCI 的控制器是整个应用的入口：`luasrc/controller/openclaw.lua` 里只要有一个
语法错误，所有页面都会 500，而且浏览器里看不到任何有用信息（错误只在
/var/log/luci.log 或 uhttpd 的 stderr 里）。

本机没有 lua/luac，所以用 Python 的 luaparser 做纯语法解析。它不能替代在
路由器上跑一遍，但能挡住"少一个 end""引号没闭合"这类最致命也最常见的错误。

退出码：
  0 = 全部通过
  1 = 有语法错误
  3 = 没装 luaparser（调用方应视为 skip，而不是失败）
"""

import pathlib
import sys

try:
    from luaparser import ast
except ImportError:
    print("    跳过：未安装 luaparser（pip install luaparser）")
    sys.exit(3)

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
files = sorted(root.glob("luasrc/**/*.lua"))
if not files:
    print("    跳过：没有找到 .lua 文件")
    sys.exit(3)

failed = 0
for f in files:
    src = f.read_text(encoding="utf-8", errors="replace")
    try:
        ast.parse(src)
    except Exception as exc:  # luaparser 抛的异常类型不统一
        failed += 1
        msg = str(exc).replace("\n", " ")[:200]
        print("    FAIL  %s：%s" % (f.relative_to(root), msg))

if failed:
    print("    共 %s 个文件，%s 个语法错误" % (len(files), failed))
    sys.exit(1)

print("    共 %s 个文件，语法全部通过" % len(files))
sys.exit(0)
