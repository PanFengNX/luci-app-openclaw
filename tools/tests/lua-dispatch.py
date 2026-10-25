#!/usr/bin/env python3
"""Check that call() registrations in LuCI controllers are valid.

LuCI's `call()` takes a **string** function name and resolves it at dispatch
time through the environment:

    local function _call(self, ...)
        local func = getfenv()[self.name]
        assert(func ~= nil,
               'Cannot resolve function "' .. self.name .. '". Is it misspelled or local?')
        ...
    end

Passing a function object instead of a name therefore fails: `getfenv()[函数]`
looks the function up *as a key* in the environment table, finds nothing, and
the assert throws. Because the assert is inside the dispatch path, the whole
response becomes a 500 -- and if the bad registration is in a helper shared by
every endpoint, **every** endpoint returns 500 while the pages themselves still
render (templates do not go through call()).

That is exactly what shipped in 1.8.28-1.8.30:

    entry({..., "api", "info"}, call(guarded("info", api_info))).leaf = true

The UI looked completely broken -- empty mount list, "读取中…" forever,
"服务无响应" for versions -- but the cause was one wrong argument type here.

This checker enforces two things:

  1. every call(...) argument is a string literal (or a value that is obviously
     a string at that point), never a function call or a bare identifier;
  2. no call() is registered with a local function, since _call resolves
     through the *environment*, not the lexical scope -- `call("local_fn")`
     fails too, just with a different message.

Usage: lua-dispatch.py <dir>
Exit:  0 clean, 1 findings, 2 usage error
"""
import re
import sys
from pathlib import Path

# call("name") -- the only valid form. `(?<![\w.:])` excludes sys.call( and
# obj:call(, which are ordinary function/method calls, not registrations.
CALL_STRING = re.compile(r'(?<![\w.:])call\(\s*(["\'])([A-Za-z_][\w.]*)\1')
# call(<anything else>)
CALL_ANY = re.compile(r'(?<![\w.:])call\s*\(')


def strip_comments_and_strings(text):
    """Blank out comments and the *contents* of strings, keeping positions."""
    out = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == '-' and text[i:i + 2] == '--':
            m = re.match(r'--\[(=*)\[', text[i:])
            if m:
                close = ']' + m.group(1) + ']'
                j = text.find(close, i + m.end())
                j = n if j < 0 else j + len(close)
                out.append(re.sub(r'[^\n]', ' ', text[i:j]))
                i = j
                continue
            j = text.find('\n', i)
            j = n if j < 0 else j
            out.append(' ' * (j - i))
            i = j
            continue
        if c in '"\'':
            q = c
            j = i + 1
            while j < n:
                if text[j] == '\\':
                    j += 2
                    continue
                if text[j] == q:
                    j += 1
                    break
                j += 1
            out.append(q + ' ' * max(0, j - i - 2) + (q if j - 1 > i else ''))
            i = j
            continue
        if c == '[' and text[i:i + 2] == '[[':
            j = text.find(']]', i + 2)
            j = n if j < 0 else j + 2
            out.append('[[' + re.sub(r'[^\n]', ' ', text[i + 2:j - 2]) + ']]')
            i = j
            continue
        out.append(c)
        i += 1
    return ''.join(out)


def find_call_args(code):
    """Yield (line_number, argument_text) for each call(...)."""
    for m in CALL_ANY.finditer(code):
        start = m.end()
        depth, i = 1, start
        while i < len(code) and depth:
            if code[i] == '(':
                depth += 1
            elif code[i] == ')':
                depth -= 1
            i += 1
        arg = code[start:i - 1].strip()
        line = code.count('\n', 0, m.start()) + 1
        yield line, arg


def local_function_names(text):
    """Names declared as `local function X` -- unreachable through getfenv()."""
    return set(re.findall(r'(?m)^\s*local\s+function\s+([A-Za-z_]\w*)', text))


def check_file(path):
    raw = path.read_text(encoding='utf-8')
    code = strip_comments_and_strings(raw)
    locals_ = local_function_names(raw)

    problems = []
    for line, arg in find_call_args(code):
        # `call` used as a plain identifier (e.g. `.call(` / `:call(`) is not
        # a dispatcher registration.
        if not arg:
            continue
        if re.fullmatch(r'[A-Za-z_][\w.]*', arg) or arg.startswith(('function', '{')):
            problems.append((line, arg, '参数是函数对象而不是函数名'))
            continue
        if arg.startswith(('"', "'")):
            # string form handled below via the raw text
            continue
        # something more complex: call(guarded(...)), call(f(x))
        problems.append((line, arg[:60], '参数不是字符串字面量'))

    # call("local_fn") -- resolves through the environment, so a file-local
    # function is invisible to it.
    for m in CALL_STRING.finditer(code):
        name = m.group(2)
        if name.split('.')[0] in locals_:
            line = code.count('\n', 0, m.start()) + 1
            problems.append((line, 'call("%s")' % name,
                             '目标是文件局部函数，getfenv() 看不到'))

    return problems


def main(argv):
    if len(argv) != 2:
        print('用法: lua-dispatch.py <目录>', file=sys.stderr)
        return 2
    root = Path(argv[1])
    if not root.exists():
        print('目录不存在: %s' % root, file=sys.stderr)
        return 2

    files = sorted(root.rglob('*.lua'))
    controllers = [f for f in files if 'controller' in f.parts]
    total = 0
    for f in controllers:
        try:
            problems = check_file(f)
        except UnicodeDecodeError:
            continue
        if not problems:
            continue
        total += len(problems)
        print('%s:' % f)
        for line, arg, why in problems:
            print('  行%-5d call(%s)  —  %s' % (line, arg, why))
            print('            LuCI 的 _call 用 getfenv()[name] 解析，'
                  '传函数对象会 assert 失败 → 该接口 500')

    print('\n扫描 %d 个 controller，非法 call() 注册 %d 处'
          % (len(controllers), total))
    return 0 if total == 0 else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv))
