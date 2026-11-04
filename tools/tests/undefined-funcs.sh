#!/bin/sh
# undefined-funcs.sh —— 抓「调用了、但当前脚本根本看不到」的函数
#
# 真实事故：backup.sh 里有一行 `export_note "记录插件清单"`。export_note() 确实
# 存在，但定义在 **cli.sh** 里，而 backup.sh 只 source 了 lib.sh —— 于是运行时
# 报 `export_note: not found`，每次备份都往日志里写一行错误。备份本身还能成功，
# 但那行报错会让人以为备份失败了。
#
# 这类问题的关键不是"有没有定义"，而是"**在这个脚本里看不看得见**"：
# 函数在别的文件里定义、但当前脚本没 source 那个文件，一样是坏的。
# 所以判据按每个脚本各自的 source 关系计算可见函数集合：
#     可见 = 自己定义的 + 它 source 的文件（递归）里定义的
#
# 只查这次事故的确切形状：语句位置上的「含下划线的小写函数名 + 引号参数」。
# 要求含下划线是为了避开 shell 内建/外部命令（if/cat/awk/print/status…），
# 这样不需要解析 heredoc 与 awk 块（那种状态机很脆，且容易漏）。
#
# 定义/可见性来源：libexec 下所有 .sh 与 init.d。

set -u
DIR="root/usr/libexec/openclaw"
INITD="root/etc/init.d/openclaw"
PY="${PY:-python3}"
command -v "$PY" >/dev/null 2>&1 || PY="python"

"$PY" - "$DIR" "$INITD" <<'PYEOF'
import re, sys, pathlib

dirpath, initd = sys.argv[1], sys.argv[2]
files = sorted(pathlib.Path(dirpath).glob("*.sh"))
if pathlib.Path(initd).is_file():
    files.append(pathlib.Path(initd))

sources = {f.name: f.read_text(encoding="utf-8", errors="replace") for f in files}

# 每个文件自己定义的函数
own = {}
for name, text in sources.items():
    own[name] = set(re.findall(
        r'^[ \t]*([A-Za-z_][A-Za-z0-9_]*)[ \t]*\(\)[ \t]*\{', text, re.M))

# 变量名 -> 文件名（脚本里用 . "$OC_LIB" 这种形式 source）
var2file = {}
for text in sources.values():
    for m in re.finditer(r'^[ \t]*(OC_[A-Z_]+)="[^"]*/([A-Za-z0-9_.-]+\.sh)"',
                         text, re.M):
        var2file[m.group(1)] = m.group(2)

# 每个文件 source 了谁
def sourced_by(name):
    text = sources[name]
    out = set()
    for m in re.finditer(r'^[ \t]*\.[ \t]+"?\$\{?(OC_[A-Z_]+)\}?"?', text, re.M):
        tgt = var2file.get(m.group(1))
        if tgt and tgt in sources:
            out.add(tgt)
    for m in re.finditer(r'^[ \t]*\.[ \t]+/usr/libexec/openclaw/([A-Za-z0-9_.-]+\.sh)',
                         text, re.M):
        if m.group(1) in sources:
            out.add(m.group(1))
    return out


def visible(name, seen=None):
    """该脚本能看到的全部函数名（含 source 链上的）"""
    if seen is None:
        seen = set()
    if name in seen:
        return set()
    seen.add(name)
    got = set(own.get(name, ()))
    for dep in sourced_by(name):
        got |= visible(dep, seen)
    return got


# rc.common 提供的函数（init.d 里可见，但项目里不定义）
RCC = {
    "procd_open_instance", "procd_close_instance", "procd_set_param",
    "procd_add_reload_trigger", "procd_add_raw_trigger", "procd_kill",
    "procd_running", "config_load", "config_get", "config_get_bool",
    "config_set", "config_foreach", "config_list_foreach",
    "start_stop_daemon", "start-stop-daemon",
}

# 语句位置 / 命令替换位置上的「含下划线的小写名字 + 空白 + 引号」
CALL = re.compile(r'(?:^|[;|&(]|&&|\|\|)[ \t]*([a-z][a-z0-9_]*_[a-z0-9_]*)[ \t]+(?=["\'])')
SUB = re.compile(r'\$\([ \t]*([a-z][a-z0-9_]*_[a-z0-9_]*)[ \t]+(?=["\'])')

bad = {}
for name, text in sources.items():
    vis = visible(name)
    # 「可选依赖」：先用 `command -v <fn>` 探测再调用，缺失时有回退路径。
    # 典型例子是 credential.sh：它既被 lib.sh 载入（有 oc_warn），又被
    # init.d 载入（没有），于是它刻意写成
    #     if command -v oc_warn >/dev/null 2>&1; then oc_warn "$1"; else logger …; fi
    # 这不是 bug，是本文件的核心设计，必须放行。
    guarded = set(re.findall(r'command[ \\t]+-v[ \\t]+([A-Za-z_][A-Za-z0-9_]*)',
                             text))
    for ln, line in enumerate(text.splitlines(), 1):
        code = line.split("#", 1)[0]
        stripped = code.strip()
        if not stripped:
            continue
        if re.match(r'^[A-Za-z_][A-Za-z0-9_]*[ \t]*\(\)[ \t]*\{', stripped):
            continue
        for rx in (CALL, SUB):
            for m in rx.finditer(code):
                fn = m.group(1)
                if fn in vis or fn in RCC or fn in guarded:
                    continue
                bad.setdefault(fn, []).append("%s:%d" % (name, ln))

if bad:
    for fn in sorted(bad):
        print("    FAIL  %s 调用了看不见的函数（%s）"
              % (fn, ", ".join(bad[fn][:4])))
    print("    共 %d 项，%d 项失败" % (len(bad) + 1, len(bad)))
    sys.exit(1)

print('    ok    每个脚本调用的函数都在自己的 source 可见范围内')
print("    共 1 项，0 项失败")
PYEOF
