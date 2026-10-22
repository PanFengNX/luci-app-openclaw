#!/usr/bin/env python3
"""audit-static.py — 确定性静态审计（不调用任何模型，不联网）

为什么要有这个：AI 审计每批要十几分钟、结论还可能漂。这里把**能用规则判断**
的东西固定下来，跑一次几秒钟，结果可复现。它覆盖的是"机械错误"那一层：
重复定义、死代码、未引用 id、未转义拼接、固定名临时文件等。

用法：
    python tools/audit-static.py [项目根目录]

退出码：0 = 无高严重级别问题；1 = 有高严重级别问题
"""

import json
import pathlib
import re
import sys
from collections import Counter, defaultdict

ROOT = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
SHELL_DIRS = [ROOT / "root", ROOT / "tools"]
VIEW_DIR = ROOT / "luasrc" / "view" / "openclaw"
CTRL = ROOT / "luasrc" / "controller" / "openclaw.lua"

findings = []  # (severity, file, line, message)


def add(sev, path, line, msg):
    findings.append((sev, str(pathlib.Path(path).relative_to(ROOT)), line, msg))


def shell_files():
    out = []
    for d in SHELL_DIRS:
        if d.is_dir():
            out.extend(sorted(d.rglob("*.sh")))
    return out


# ---------------------------------------------------------------- shell
FUNC_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\s*\(\)\s*\{", re.M)


def check_shell():
    for f in shell_files():
        text = f.read_text(encoding="utf-8", errors="replace")
        lines = text.splitlines()

        # 1) 重复函数定义：后一份静默覆盖前一份，是真实事故过的那种
        names = FUNC_RE.findall(text)
        for name, cnt in Counter(names).items():
            if cnt > 1:
                first = next(i for i, l in enumerate(lines, 1)
                             if re.match(r"^%s\s*\(\)\s*\{" % re.escape(name), l))
                add("high", f, first, "函数重复定义 %s（%d 次），后者会覆盖前者" % (name, cnt))

        # 2) eval
        for i, l in enumerate(lines, 1):
            if re.search(r"(?<![A-Za-z0-9_])eval\s+", l) and not l.lstrip().startswith("#"):
                add("high", f, i, "使用了 eval，参数一旦可被影响就是命令注入")

        # 3) 下载即执行
        for i, l in enumerate(lines, 1):
            if re.search(r"(curl|wget|uclient-fetch)[^|]*\|\s*(sh|bash)\b", l):
                add("high", f, i, "把下载内容直接管道给 shell 执行")

        # 4) /tmp 下的固定名临时文件（并发会互相覆盖）
        #    只看随包脚本：tools/ 里的 /tmp/... 多半是测试夹具或扫描正则。
        for i, l in enumerate(lines, 1):
            if f.parent.name != "openclaw":
                break
            if l.lstrip().startswith("#"):
                continue
            for m in re.finditer(r"/tmp/[A-Za-z0-9._-]+", l):
                p = m.group(0)
                # 已知的安全路径：本插件自己的私有 rundir、LuCI 的缓存目录
                if p.startswith("/tmp/.openclaw") or p.startswith("/tmp/luci-"):
                    continue
                if re.search(r"\$\$|mktemp", l):
                    continue
                add("medium", f, i, "固定名临时文件 %s（并发/重启会互相覆盖，应放私有目录或用 $$）" % p)

        # 5) shebang
        # 只有随包发布到路由器的脚本才要求 #!/bin/sh；tools/ 下的开发者脚本
        # 用 bash 是刻意的。
        if f.parent.name == "openclaw":
            if lines and not lines[0].startswith("#!"):
                add("medium", f, 1, "缺少 shebang")
            elif lines and not re.match(r"^#!/bin/sh\b", lines[0]):
                add("high", f, 1, "随包脚本的 shebang 不是 #!/bin/sh：%s" % lines[0][:40])

        # 6) 定义了但从未被调用的函数（死代码 / 拼写错误的调用）
        called = set(re.findall(r"(?<![A-Za-z0-9_-])([a-z_][a-z0-9_]*)\s*[\s(]", text))
        for name in sorted(set(names)):
            if name.startswith("_") or name in ("main",):
                continue
            # 出现在自身定义行之外、且从未以调用形式出现
            uses = len(re.findall(r"(?<![A-Za-z0-9_-])%s(?![A-Za-z0-9_-])" % re.escape(name), text))
            if uses <= 1 and name not in called:
                add("low", f, 0, "函数 %s 定义了但似乎从未被调用" % name)


# ---------------------------------------------------------------- lua
def check_lua():
    if not CTRL.is_file():
        return
    text = CTRL.read_text(encoding="utf-8", errors="replace")
    lines = text.splitlines()

    for i, l in enumerate(lines, 1):
        if l.lstrip().startswith("--"):
            continue
        # 5.1 不支持 \xXX
        if re.search(r'"[^"]*\\x[0-9A-Fa-f]{2}', l):
            add("high", CTRL, i, "Lua 5.1 不支持 \\xXX 转义，整个控制器会加载失败")
        if re.search(r"\bgoto\b", l):
            add("high", CTRL, i, "Lua 5.1 没有 goto")
        if re.search(r"\btable\.unpack\b", l):
            add("medium", CTRL, i, "table.unpack 是 5.2+，5.1 用 unpack")
        if re.search(r"os\.execute\s*\(", l):
            if "q(" in l:
                add("low", CTRL, i, "os.execute 执行字符串（本行已用 q() 转义；能改成 sys.call 更好）")
            else:
                add("high", CTRL, i, "os.execute 执行未转义的字符串")
        # sh() 拼接：把当前行与后两行拼起来看，只有确实把 formvalue 拼进去
        # 且整段没有 q() 时才报 —— 单纯 sh(A .. " 常量") 是正常的。
        window = " ".join(lines[i - 1:i + 2])
        constant_derived = ('and "' in window and 'or "' in window)
        if (not constant_derived) and re.search(r"sh\(\s*[A-Za-z_]+\s*\.\.", window) \
                and "formvalue" in window and "q(" not in window:
            add("high", CTRL, i, "sh() 把表单值拼进命令但没有 q() 转义")


# ---------------------------------------------------------------- views
def view_files():
    return sorted(VIEW_DIR.glob("*.htm")) if VIEW_DIR.is_dir() else []


def check_views():
    style_hashes = {}
    for f in view_files():
        text = f.read_text(encoding="utf-8", errors="replace")
        lines = text.splitlines()

        # 样式块一致性
        m = re.search(r"<style>(.*?)</style>", text, re.S)
        if m:
            import hashlib
            style_hashes[f.name] = hashlib.sha1(m.group(1).encode()).hexdigest()[:12]
        else:
            add("medium", f, 0, "没有 <style> 块")

        for i, l in enumerate(lines, 1):
            if l.lstrip().startswith("//") or l.lstrip().startswith("/*"):
                continue
            # innerHTML 拼接变量
            if re.search(r"innerHTML\s*=\s*[^;]*\+", l):
                add("high", f, i, "innerHTML 拼接了变量（XSS 面），应改 textContent/createElement")
            if re.search(r"insertAdjacentHTML|document\.write", l):
                add("high", f, i, "使用 insertAdjacentHTML / document.write")

        # id 引用一致性：$('x') / getElementById('x') 与 HTML 里的 id
        html_ids = set(re.findall(r'\bid\s*=\s*"([^"]+)"', text))
        js_ids = set(re.findall(r"\$\('([^']+)'\)", text)) | \
            set(re.findall(r"getElementById\('([^']+)'\)", text))
        missing = sorted(js_ids - html_ids)
        for mid in missing:
            add("medium", f, 0, "JS 引用了不存在的 id：%s" % mid)

    if len(set(style_hashes.values())) > 1:
        add("high", VIEW_DIR / "*.htm", 0,
            "十个视图的 <style> 块不一致：%s" % json.dumps(style_hashes, ensure_ascii=False))

    # 控制器 entry 与前端 API 映射的交叉检查
    if CTRL.is_file():
        ctrl = CTRL.read_text(encoding="utf-8", errors="replace")
        entries = set(re.findall(r'entry\(\{[^}]*"api",\s*"([a-z0-9_]+)"\}', ctrl))
        used = set()
        for f in view_files():
            t = f.read_text(encoding="utf-8", errors="replace")
            used |= set(re.findall(r'build_url\("admin","services","openclaw","api","([a-z0-9_]+)"\)', t))
        for e in sorted(entries - used):
            add("low", CTRL, 0, "控制器端点 api/%s 前端从未调用（死端点？）" % e)
        for u in sorted(used - entries):
            add("high", CTRL, 0, "前端调用了不存在的端点 api/%s" % u)


# ---------------------------------------------------------------- 杂项
def check_misc():
    for f in sorted(ROOT.rglob("*.json")):
        if ".review" in f.parts or "dist" in f.parts:
            continue
        try:
            json.loads(f.read_text(encoding="utf-8"))
        except Exception as exc:
            add("high", f, 0, "JSON 解析失败：%s" % str(exc)[:120])

    for f in sorted(list(ROOT.rglob("*.sh")) + list(ROOT.rglob("*.lua")) + list(ROOT.rglob("*.htm"))):
        if ".review" in f.parts or "dist" in f.parts:
            continue
        if b"\r" in f.read_bytes():
            add("high", f, 0, "含 CRLF 行尾")


def main():
    check_shell()
    check_lua()
    check_views()
    check_misc()

    order = {"high": 0, "medium": 1, "low": 2}
    findings.sort(key=lambda x: (order.get(x[0], 9), x[1], x[2]))

    if not findings:
        print("静态审计：未发现问题")
        return 0

    counts = Counter(s for s, _, _, _ in findings)
    cur = None
    for sev, path, line, msg in findings:
        if sev != cur:
            print("\n=== %s ===" % {"high": "高", "medium": "中", "low": "低"}[sev])
            cur = sev
        loc = "%s:%s" % (path, line) if line else path
        print("  %-52s %s" % (loc, msg))

    print("\n共 %d 项：高 %d / 中 %d / 低 %d"
          % (len(findings), counts["high"], counts["medium"], counts["low"]))
    return 1 if counts["high"] else 0


if __name__ == "__main__":
    sys.exit(main())
