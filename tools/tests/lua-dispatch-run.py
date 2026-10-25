#!/usr/bin/env python3
"""Dispatch every API route in the real controller, using a real Lua runtime.

Why this exists
---------------
Static checks missed a bug that took three releases to find. LuCI's `call()`
resolves its target through the environment:

    local func = getfenv()[self.name]
    assert(func ~= nil, 'Cannot resolve function "' .. self.name .. '"...')

so `call("api_info")` works and `call(guarded("info", api_info))` does not --
`getfenv()` is indexed with a function object, finds nothing, and the assert
throws inside the dispatch path. Every endpoint returned 500 while the pages
still rendered normally, which looked exactly like "the UI is broken".

lua-syntax.py passed (the syntax is fine). lua-scope.py passed (no forward
reference). The unit tests passed (they call helpers directly, never through
call()). Only actually dispatching a route exposes it.

This test loads the controller with a minimal LuCI stand-in (module, entry,
call, _call, template, firstchild) and dispatches every registered api/* route,
reporting each failure with the route name.

Requirements: `lupa` (bundled Lua 5.1, matching OpenWrt). Without it the test
skips rather than fails -- it must not block builds on an optional dependency.

Usage: lua-dispatch-run.py <project-dir>
Exit:  0 pass/skip, 1 failures, 2 usage error
"""
import re
import sys
from pathlib import Path

SKIP = 3

HARNESS = r'''
local CONTROLLER = [[__CONTROLLER__]]

-- ---- minimal LuCI stand-ins -------------------------------------------
package.loaded["luci.sys"]  = { exec = function() return "" end,
                                call = function() return 0 end }
package.loaded["luci.util"] = { trim = function(s) return s end,
                                split = function() return {} end }
package.loaded["luci.http"] = {
  getenv = function() return "GET" end,
  formvalue = function() return nil end,
  prepare_content = function() end,
  write = function() end, status = function() end, header = function() end,
  redirect = function() end, close = function() end,
  content = function() return nil end,
  urldecode = function(s) return s end,
  build_url = function() return "/" end,
  getcookie = function() return nil end, setcookie = function() end,
}
package.loaded["luci.jsonc"] = {
  stringify = function() return "{}" end,
  parse = function() return {} end,
  new = function() return {} end,
}
package.loaded["luci.fs"] = { readfile = function() return nil end,
  writefile = function() return true end, stat = function() return nil end,
  isdirectory = function() return false end, opendir = function() return {} end }
package.loaded["luci.model.uci"] = { cursor = function()
  return { get = function() return nil end, set = function() return true end,
           commit = function() return true end, foreach = function() end,
           delete = function() return true end } end }

-- ---- dispatcher semantics (copied from luci/dispatcher.lua) ------------
local ROUTES = {}
local function _call(self, ...)
  local func = getfenv()[self.name]
  assert(func ~= nil,
    'Cannot resolve function "' .. tostring(self.name) ..
    '". Is it misspelled or local?')
  assert(type(func) == "function",
    'The symbol "' .. tostring(self.name) .. '" does not refer to a function')
  return func(...)
end
function call(name, ...) return {type="call", argv={...}, name=name, target=_call} end
function entry(path, target, title, order)
  ROUTES[table.concat(path, "/")] = {target=target, title=title}
  return {leaf=false, dependent=true}
end
function template(name) return {type="template", view=name} end
function firstchild() return {type="firstchild"} end
function node() return {} end
function _(s) return s end
function translate(s) return s end

-- ---- load the controller ----------------------------------------------
local chunk, err = loadfile(CONTROLLER)
if not chunk then print("LOADFAIL\t" .. tostring(err)); os.exit(1) end
local ok, err2 = pcall(chunk)
if not ok then print("LOADFAIL\t" .. tostring(err2)); os.exit(1) end

local mod = package.loaded["luci.controller.openclaw"]
if not mod then print("LOADFAIL\tmodule table missing"); os.exit(1) end

if type(mod.index) ~= "function" then
  print("LOADFAIL\tindex() is not a function"); os.exit(1)
end
local ok3, err3 = pcall(mod.index)
if not ok3 then print("INDEXFAIL\t" .. tostring(err3)); os.exit(1) end

-- ---- dispatch every api route, GET and POST ---------------------------
-- 每条路由跑两次：
--   GET  ：只读端点应通过；写端点应被拒（返回 {"ok":false,...}）
--   POST ：都应通过
-- 只测 GET 会漏掉"守卫把写端点全拒了"这类错误。
local total, bad = 0, 0
local out = {}
local method = "GET"
local httpstub = package.loaded["luci.http"]
httpstub.getenv = function(k)
  if k == "REQUEST_METHOD" then return method end
  return nil
end
httpstub.formvalue = function() return nil end

local function run_route(nd)
  local t = nd.target
  local oldenv = getfenv(t.target)
  local env = setmetatable({}, {__index = function(_, k)
    return rawget(_, k) or mod[k] or oldenv[k]
  end})
  setfenv(t.target, env)
  local okd, res = pcall(t.target, t)
  setfenv(t.target, oldenv)
  return okd, res
end

for route, nd in pairs(ROUTES) do
  if route:find("/api/", 1, true) and nd.target and nd.target.type == "call" then
    total = total + 1
    local name = route:match("/api/([a-z_]+)$") or route

    method = "GET"
    local okg, resg = run_route(nd)
    if not okg then
      bad = bad + 1
      out[#out + 1] = route .. "\tGET 抛异常: " ..
        tostring(resg):gsub("\n", " "):sub(1, 120)
    end

    method = "POST"
    local okp, resp = run_route(nd)
    if not okp then
      bad = bad + 1
      out[#out + 1] = route .. "\tPOST 抛异常: " ..
        tostring(resp):gsub("\n", " "):sub(1, 120)
    end
  end
end

print("TOTAL\t" .. total)
print("BAD\t" .. bad)
for _, l in ipairs(out) do print("FAILED\t" .. l) end
'''


def find_controller(proj):
    for p in sorted((proj / 'luasrc' / 'controller').glob('*.lua')):
        return p
    return None


def main(argv):
    if len(argv) != 2:
        print('用法: lua-dispatch-run.py <项目目录>', file=sys.stderr)
        return 2
    proj = Path(argv[1])
    ctrl = find_controller(proj)
    if ctrl is None:
        print('    跳过：找不到 luasrc/controller/*.lua')
        return SKIP

    try:
        from lupa import lua51
    except ImportError:
        print('    跳过：未安装 lupa（pip install lupa 后生效）')
        return SKIP

    # Lua 的 loadfile 需要系统路径；Windows 风格对 lupa 也适用。
    script = HARNESS.replace('__CONTROLLER__', ctrl.resolve().as_posix())

    rt = lua51.LuaRuntime(unpack_returned_tuples=True)
    lines = []

    def capture(s):
        lines.append(str(s))

    rt.globals()['print'] = capture
    try:
        rt.execute(script)
    except Exception as e:                       # noqa: BLE001 - report verbatim
        print('    FAIL  Lua 执行异常：%s' % str(e).replace('\n', ' ')[:200])
        return 1

    if not lines:
        print('    FAIL  harness 没有任何输出（脚本未执行？）')
        return 1

    total = bad = None
    failures = []
    for ln in lines:
        parts = ln.split('\t')
        kind = parts[0]
        if kind == 'LOADFAIL':
            print('    FAIL  controller 加载失败：%s' % (parts[1] if len(parts) > 1 else ''))
            return 1
        if kind == 'INDEXFAIL':
            print('    FAIL  index() 抛异常：%s' % (parts[1] if len(parts) > 1 else ''))
            return 1
        if kind == 'TOTAL':
            total = int(parts[1])
        elif kind == 'BAD':
            bad = int(parts[1])
        elif kind == 'FAILED':
            failures.append(parts[1] if len(parts) > 1 else '')

    if total is None or bad is None:
        print('    FAIL  harness 输出不完整：%s' % ' / '.join(lines[:3]))
        return 1

    print('    API 路由 %d 条，dispatch 成功 %d 条' % (total, total - bad))
    if bad == 0:
        print('    全部接口能被 LuCI 正确调度')
        return 0

    print('    FAIL  %d 条路由 dispatch 失败（该接口在设备上会 500）：' % bad)
    for f in failures[:8]:
        route, _, err = f.partition('\t')
        print('        %s' % route)
        if err:
            print('            %s' % err)
    return 1


if __name__ == '__main__':
    sys.exit(main(sys.argv))
