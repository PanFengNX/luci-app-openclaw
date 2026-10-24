#!/usr/bin/env python3
"""Detect Lua 5.1 forward references to file-local declarations.

Lua 5.1 is lexically scoped: a `local` name is visible only *after* its
declaration. When a function defined earlier refers to a local declared later
in the same file, the compiler emits GETGLOBAL instead, and the reference is
nil at runtime.

This is not a syntax error, so `luac -p` and any parser-only check pass. It is
also invisible to unit tests that only exercise helpers. It only shows up when
the request actually runs -- and because it hits a shared code path, it takes
the whole application down.

Real instance (1.8.28): `guarded()` was declared at line 51 and called `out()`,
which was declared at line 156. Every API request goes through guarded, so
every endpoint raised "attempt to call a nil value (global 'out')" and returned
500. The UI still rendered (templates do not go through guarded), so it looked
like "the page works but nothing loads": empty mount list, "读取中…" forever,
"服务无响应" for versions, empty model dropdowns.

Usage: python3 tools/tests/lua-scope.py <dir>
Exit:  0 clean, 1 findings, 2 usage error
"""
import re
import sys
from pathlib import Path

DECL_FUNC = re.compile(r'local\s+function\s+([A-Za-z_]\w*)')
DECL_VAR = re.compile(r'local\s+([A-Za-z_]\w*)\s*=')


def top_level_decls(lines):
    """name -> line number, for declarations at column 0."""
    decls = {}
    for i, line in enumerate(lines, 1):
        if line.startswith((' ', '\t')):
            continue
        m = DECL_FUNC.match(line) or DECL_VAR.match(line)
        if m:
            decls.setdefault(m.group(1), i)
    return decls


def top_level_functions(lines):
    """(name, start_line, end_line) for functions starting at column 0.

    The end is the first line that is exactly `end` at column 0 -- every
    function in this codebase is formatted that way. Counting block keywords
    instead is unreliable: `end` appears inside strings and long comments.
    """
    starts = []
    for i, line in enumerate(lines, 1):
        if line.startswith((' ', '\t')):
            continue
        m = re.match(r'(?:local\s+)?function\s+([A-Za-z_]\w*)', line)
        if m:
            starts.append((i, m.group(1)))

    out = []
    for k, (start, name) in enumerate(starts):
        limit = starts[k + 1][0] if k + 1 < len(starts) else len(lines) + 1
        end = limit - 1
        for j in range(start, limit):
            if lines[j - 1].strip() == 'end':
                end = j
                break
        out.append((name, start, end))
    return out


def strip_comments(text):
    text = re.sub(r'--\[\[.*?\]\]', '', text, flags=re.S)
    return re.sub(r'--[^\n]*', '', text)


def check_file(path):
    lines = path.read_text(encoding='utf-8').splitlines()
    decls = top_level_decls(lines)
    findings = []
    for name, start, end in top_level_functions(lines):
        body = strip_comments('\n'.join(lines[start - 1:end]))
        for var, decl_line in decls.items():
            if decl_line <= start:
                continue
            # `(?<![\w.:])` keeps `t.out` and `obj:out()` out of the match.
            if re.search(r'(?<![\w.:])' + re.escape(var) + r'(?![\w])', body):
                findings.append((name, start, var, decl_line))
    return findings


def main(argv):
    if len(argv) != 2:
        print('用法: lua-scope.py <目录>', file=sys.stderr)
        return 2
    root = Path(argv[1])
    if not root.exists():
        print('目录不存在: %s' % root, file=sys.stderr)
        return 2

    files = sorted(root.rglob('*.lua'))
    total = 0
    for f in files:
        try:
            hits = check_file(f)
        except UnicodeDecodeError as e:
            print('  跳过（无法按 UTF-8 解码）: %s (%s)' % (f, e))
            continue
        if not hits:
            continue
        total += len(hits)
        rel = f.relative_to(root) if f.is_relative_to(root) else f
        print('%s:' % rel)
        for func, start, var, decl in hits:
            print('  行%-5d %s() 引用了 %s，但它在行 %d 才声明'
                  % (start, func, var, decl))
            print('           Lua 5.1 只在声明之后可见 → 运行时是 nil')

    print('\n扫描 %d 个 .lua 文件，前向引用 %d 处' % (len(files), total))
    return 0 if total == 0 else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv))
