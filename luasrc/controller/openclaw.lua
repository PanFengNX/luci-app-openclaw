-- Copyright (C) openclaw - LuCI controller
-- OpenClaw 助手 (OpenClaw Assistant) for OpenWrt
-- package: luci-app-openclaw

module("luci.controller.openclaw", package.seeall)

local sys   = require "luci.sys"
local util  = require "luci.util"
local http  = require "luci.http"
local jsonc = require "luci.jsonc"

local SH     = "/usr/libexec/istorec/openclaw.sh"
local MODELS = "/usr/libexec/openclaw/models.sh"

function index()
	entry({"admin", "services", "openclaw"}, firstchild(), _("OpenClaw 助手"), 60).dependent = false
	entry({"admin", "services", "openclaw", "status"},   template("openclaw/status"),   _("状态 / 安装"), 10)
	entry({"admin", "services", "openclaw", "model"},    template("openclaw/model"),    _("模型"),      20)
	entry({"admin", "services", "openclaw", "channels"}, template("openclaw/channels"), _("渠道"),      30)
	entry({"admin", "services", "openclaw", "terminal"}, template("openclaw/terminal"), _("命令行"),    40)
	entry({"admin", "services", "openclaw", "log"},      template("openclaw/log"),      _("日志"),      50)

	-- JSON API
	entry({"admin", "services", "openclaw", "api", "info"},      call("api_info")).leaf = true
	entry({"admin", "services", "openclaw", "api", "versions"},  call("api_versions")).leaf = true
	entry({"admin", "services", "openclaw", "api", "check"},     call("api_check")).leaf = true
	entry({"admin", "services", "openclaw", "api", "install"},   call("api_install")).leaf = true
	entry({"admin", "services", "openclaw", "api", "istatus"},   call("api_istatus")).leaf = true
	entry({"admin", "services", "openclaw", "api", "ilog"},      call("api_ilog")).leaf = true
	entry({"admin", "services", "openclaw", "api", "service"},   call("api_service")).leaf = true
	entry({"admin", "services", "openclaw", "api", "save"},      call("api_save")).leaf = true
	entry({"admin", "services", "openclaw", "api", "presets"},   call("api_presets")).leaf = true
	entry({"admin", "services", "openclaw", "api", "models"},    call("api_models")).leaf = true
	entry({"admin", "services", "openclaw", "api", "apply"},     call("api_apply")).leaf = true
	entry({"admin", "services", "openclaw", "api", "run"},       call("api_run")).leaf = true
	entry({"admin", "services", "openclaw", "api", "channels"},  call("api_channels")).leaf = true
	entry({"admin", "services", "openclaw", "api", "log"},       call("api_log")).leaf = true
	entry({"admin", "services", "openclaw", "api", "mounts"},    call("api_mounts")).leaf = true
	entry({"admin", "services", "openclaw", "api", "doctor"},    call("api_doctor")).leaf = true
	entry({"admin", "services", "openclaw", "api", "providers"}, call("api_providers")).leaf = true
	entry({"admin", "services", "openclaw", "api", "repair"},    call("api_repair")).leaf = true
	-- async diagnostics: start in background, poll for output (no request timeout)
	entry({"admin", "services", "openclaw", "api", "diag_run"},  call("api_diag_run")).leaf = true
	entry({"admin", "services", "openclaw", "api", "diag_poll"}, call("api_diag_poll")).leaf = true
	entry({"admin", "services", "openclaw", "api", "backups"},   call("api_backups")).leaf = true
	entry({"admin", "services", "openclaw", "api", "backup_create"}, call("api_backup_create")).leaf = true
	entry({"admin", "services", "openclaw", "api", "backup_verify"}, call("api_backup_verify")).leaf = true
	entry({"admin", "services", "openclaw", "api", "backup_delete"}, call("api_backup_delete")).leaf = true
	entry({"admin", "services", "openclaw", "api", "backup_upload"}, call("api_backup_upload")).leaf = true
	entry({"admin", "services", "openclaw", "api", "backup_download"}, call("api_backup_download")).leaf = true
	entry({"admin", "services", "openclaw", "api", "restore"}, call("api_restore")).leaf = true
end

local function sh(args)
	-- stdout only. stderr is deliberately NOT merged in: oc_warn/oc_err write
	-- to stderr precisely so that a stray log line cannot corrupt the JSON
	-- payload of info / diag-poll / install-status.
	return util.trim(sys.exec(args))
end

local function run_rc(args)
	-- Fire-and-forget helper that reports whether the script actually
	-- succeeded. sys.exec() drops the exit status, which is why every write
	-- action used to answer ok=true even when the helper failed.
	-- Output is discarded so it cannot leak into the HTTP response body.
	return sys.call(args .. " >/dev/null 2>&1") == 0
end

local function out(tbl)
	http.prepare_content("application/json")
	-- stringify() returns nil when a value cannot be encoded (e.g. invalid
	-- UTF-8 straight from a helper script); writing nil produced an empty
	-- body and the browser then failed on JSON.parse.
	http.write(jsonc.stringify(tbl) or '{"ok":false,"error":"serialize-failed"}')
end

local function q(s)
	if not s then return "''" end
	s = tostring(s)
	s = s:gsub("'", "'\\''")
	return "'" .. s .. "'"
end

function api_info()
	local r = sh(SH .. " info")
	out({ ok = true, data = r })
end

function api_versions()
	local refresh = http.formvalue("refresh")
	local arg = refresh == "1" and " refresh" or ""
	local ocv = sh("/usr/libexec/openclaw/versions.sh oc-versions" .. arg)
	local nv  = sh("/usr/libexec/openclaw/versions.sh node-versions" .. arg)
	local urls = sh("/usr/libexec/openclaw/versions.sh urls")
	out({ ok = true, openclaw = ocv, node = nv, sources = urls })
end

function api_check()
	local ocv = http.formvalue("oc") or "latest"
	local nv  = http.formvalue("node") or ""
	local r = sh("/usr/libexec/openclaw/versions.sh check " .. q(ocv) .. " " .. q(nv))
	local ok = r:find('"ok":true') ~= nil
	out({ ok = ok, data = r })
end

function api_install()
	local ocv  = http.formvalue("oc_version") or "latest"
	local ndv  = http.formvalue("node_version") or "auto"
	local dir  = http.formvalue("base_dir") or ""
	local odir = http.formvalue("openclaw_dir") or ""
	local args = " install-bg --oc-version " .. q(ocv) .. " --node-version " .. q(ndv)
	if dir ~= "" then args = args .. " --base-dir " .. q(dir) end
	if odir ~= "" then args = args .. " --openclaw-dir " .. q(odir) end
	sh(SH .. args)
	out({ ok = true })
end

function api_istatus()
	local r = sh(SH .. " install-status")
	out({ ok = true, data = r })
end

-- install.log grows for the whole (long) install; cap what we ship to the
-- browser so a big log cannot blow up memory or the response body
local MAX_ILOG = 262144   -- 256 KiB

function api_ilog()
	local r = ""
	local f = io.open("/var/log/openclaw-install.log", "r")
	if f then
		-- 只读尾部：read("*a") 会把几十 MB 的安装日志整份读进内存，
		-- 之后才截断，正好和上面"限制内存"的初衷相反。
		local size = f:seek("end") or 0
		if size > MAX_ILOG then
			f:seek("set", size - MAX_ILOG)
			r = "…（日志过长，仅显示最后 256KB）\n" .. (f:read("*a") or "")
		else
			f:seek("set", 0)
			r = f:read("*a") or ""
		end
		f:close()
	end
	out({ ok = true, log = r })
end

function api_service()
	local act = http.formvalue("action") or "restart"
	if act == "start" or act == "stop" or act == "restart" then
		out({ ok = run_rc(SH .. " " .. act) })
		return
	end
	out({ ok = false, error = "unsupported action" })
end

function api_save()
	local keys = {
		"base_dir", "port", "bind", "oc_version", "node_version",
		"npm_registry", "node_mirror", "http_proxy", "enabled"
	}
	local args = ""
	for _, k in ipairs(keys) do
		local v = http.formvalue(k)
		if v and v ~= "" then
			args = args .. " --" .. k:gsub("_", "-") .. " " .. q(v)
		end
	end
	-- openclaw_dir 允许为空：空值表示"恢复默认（<安装目录>/openclaw）"，
	-- 所以必须显式传递，不能像上面那样把空值跳过。
	local od = http.formvalue("openclaw_dir")
	if od ~= nil then
		args = args .. " --openclaw-dir " .. q(od)
	end
	out({ ok = run_rc(SH .. " save" .. args) })
end

function api_presets()
	local r = sh("/usr/libexec/openclaw/models.sh presets")
	out({ ok = true, data = r })
end

function api_models()
	local p = http.formvalue("provider") or ""
	local r = sh("/usr/libexec/openclaw/models.sh discover " .. q(p))
	out({ ok = true, data = r })
end

function api_apply()
	local p    = http.formvalue("provider") or ""
	local key  = http.formvalue("apikey") or ""
	local mdl  = http.formvalue("model") or ""
	local base = http.formvalue("baseurl") or ""
	-- 不把 Key 放进 argv 或环境变量：sys.call() 经过 /bin/sh -c，
	-- 即使写成 env OC_APPLY_KEY=...，密钥也会出现在 sh/env 的 cmdline。
	-- 改为私有 rundir 下的 0600 临时文件，models.sh 读取后立即删除。
	if key ~= "" then
		if not need_dir() then
			out({ ok = false, error = "临时目录不可用" })
			return
		end
		local keyfile = RUNDIR .. "/apply-key-" .. os.date("%Y%m%d%H%M%S") .. "-" .. tostring(math.random(100000, 999999))
		local fh = io.open(keyfile, "wb")
		if not fh then
			out({ ok = false, error = "无法创建临时密钥文件" })
			return
		end
		local wrote = fh:write(key)
		local closed = fh:close()
		os.execute("chmod 600 " .. q(keyfile) .. " 2>/dev/null")
		if not wrote or not closed then
			os.remove(keyfile)
			out({ ok = false, error = "无法写入临时密钥文件" })
			return
		end
		local cmd = MODELS .. " apply " .. q(p) .. " --key-file " .. q(keyfile) .. " " .. q(mdl) .. " " .. q(base)
		local ok = run_rc(cmd)
		os.remove(keyfile)
		out({ ok = ok })
		return
	end
	-- 空 Key 仍然允许沿用已有配置；不需要创建临时文件。
	out({ ok = run_rc(MODELS .. " apply " .. q(p) .. " - " .. q(mdl) .. " " .. q(base)) })
end

-- Sub-commands the terminal box is allowed to reach. The command line is free
-- text posted from the browser and used to be spliced into a shell string
-- unquoted, so `cmd=status; reboot` ran as root. Two gates now: the first
-- token has to be in this list, and every token is single quoted by q().
local RUN_CMDS = {
	status = true, version = true, help = true, doctor = true, health = true,
	update = true, models = true, plugins = true, channels = true,
	gateway = true, config = true, agents = true, sessions = true,
	cron = true, skills = true, logs = true, onboard = true,
	message = true, memory = true, workspace = true
}

function api_run()
	local cmd = tostring(http.formvalue("cmd") or "status")
	local argv = {}
	for tok in cmd:gmatch("%S+") do argv[#argv + 1] = tok end
	local sub = argv[1] or ""
	if not RUN_CMDS[sub] then
		out({ ok = false, output = "不支持的命令：" .. sub })
		return
	end
	local args = ""
	for i = 2, #argv do args = args .. " " .. q(argv[i]) end
	local r = sh(SH .. " run " .. q(sub) .. args)
	out({ ok = true, output = r })
end

function api_channels()
	local act = http.formvalue("action") or "list"
	local r
	if act == "weixin_install" then
		r = sh("/usr/libexec/openclaw/channels.sh weixin install")
	elseif act == "weixin_login" then
		r = sh("/usr/libexec/openclaw/channels.sh weixin login")
	else
		r = sh("/usr/libexec/openclaw/channels.sh list")
	end
	out({ ok = true, output = r })
end

function api_log()
	local n = tonumber(http.formvalue("lines") or "300") or 300
	if n < 1 then n = 1 elseif n > 5000 then n = 5000 end
	local r = sh(SH .. " log " .. q(tostring(n)))
	out({ ok = true, log = r })
end

function api_mounts()
	local r = sh(SH .. " mounts")
	out({ ok = true, data = r })
end

function api_doctor()
	local fix = http.formvalue("fix")
	local arg = fix == "1" and " doctor --fix" or " doctor"
	local r = sh(SH .. arg)
	out({ ok = true, output = r })
end

function api_providers()
	local r = sh("/usr/libexec/openclaw/models.sh catalog")
	out({ ok = true, data = r })
end

function api_repair()
	local j = http.formvalue("json")
	local arg = " repair"
	if j == "1" then arg = arg .. " --json" end
	local r = sh(SH .. arg)
	if j == "1" then
		out({ ok = true, data = r })
	else
		out({ ok = true, output = r })
	end
end

-- Background diagnostics. doctor / repair can run for minutes; running them
-- inline makes the HTTP request time out and the UI looks frozen.
function api_diag_run()
	local name = http.formvalue("name") or "doctor"
	if name ~= "doctor" and name ~= "doctor-fix" and name ~= "repair" then
		name = "doctor"
	end
	local r = sh(SH .. " diag-run " .. q(name))
	out({ ok = true, data = r })
end

function api_diag_poll()
	local name = http.formvalue("name") or "doctor"
	if name ~= "doctor" and name ~= "doctor-fix" and name ~= "repair" then
		name = "doctor"
	end
	local r = sh(SH .. " diag-poll " .. q(name))
	out({ ok = true, data = r })
end

-- ---------------------------------------------------------------- backup
-- 备份文件里含 API Key，所以：
--   * 只允许按"文件名"引用备份，不允许任意路径
--   * 上传的归档先落到私有 rundir，再由 backup.sh 校验后才允许还原
--   * 下载强制 attachment，避免浏览器直接渲染内容

local RUNDIR = "/tmp/.openclaw"
-- 首字符必须是字母数字：排除 "." / ".."（会被拼成路径穿越）与前导 "-"
-- （会被 helper 的 getopts 当成选项）。这些名字会原样下传给 openclaw.sh。
local SAFE_NAME = "^[A-Za-z0-9][A-Za-z0-9._-]*$"
local MAX_UPLOAD = 64 * 1024 * 1024   -- 64 MiB

-- RUNDIR 在全局可写的 /tmp 下：mkdir -p 会照单全收预先存在的同名条目，包括
-- 本地用户预置的符号链接，root 随后就会把上传内容写进链接指向的文件。
-- 所以先确认它不是符号链接，失败时由调用者拒绝本次上传。
local function need_dir()
	if sh("test -L " .. q(RUNDIR) .. " && echo symlink") == "symlink" then
		return false
	end
	os.execute("mkdir -p " .. q(RUNDIR) .. " && chmod 700 " .. q(RUNDIR) .. " 2>/dev/null")
	return true
end

function api_backups()
	local r = sh(SH .. " backups")
	out({ ok = true, data = r })
end

function api_backup_create()
	local name = http.formvalue("name") or ""
	local ws   = http.formvalue("workspace")
	local args = ""
	if name ~= "" then
		if not name:match(SAFE_NAME) then
			out({ ok = false, error = "备份名只能包含字母数字与 . _ -" })
			return
		end
		args = args .. " --name " .. q(name)
	end
	if ws == "0" then args = args .. " --no-workspace" end
	local r = sh(SH .. " backup" .. args)
	out({ ok = r:find('"ok":true') ~= nil, data = r })
end

function api_backup_verify()
	local f = http.formvalue("file") or ""
	if not f:match(SAFE_NAME) then
		out({ ok = false, error = "非法的备份文件名" })
		return
	end
	local r = sh(SH .. " backup-verify " .. q(f))
	out({ ok = r:find('"ok":true') ~= nil, data = r })
end

function api_backup_delete()
	local f = http.formvalue("file") or ""
	if not f:match(SAFE_NAME) then
		out({ ok = false, error = "非法的备份文件名" })
		return
	end
	local r = sh(SH .. " backup-delete " .. q(f))
	out({ ok = r:find('"ok":true') ~= nil, data = r })
end

-- 上传归档：只写进私有 rundir，返回一个受约束的文件名
function api_backup_upload()
	local data = http.formvalue("archive")
	if not data or #data == 0 then
		out({ ok = false, error = "没有收到文件" })
		return
	end
	if #data > MAX_UPLOAD then
		out({ ok = false, error = "文件过大（上限 64MB）" })
		return
	end
	-- gzip magic = 1f 8b。这里必须用数字比较，不能写成 "\x1f\x8b"：
	-- \xXX 转义是 Lua 5.2 才引入的，Lua 5.1（OpenWrt 的 LuCI 运行时）遇到它会
	-- 直接报语法错误 —— 那会让**整个控制器**加载失败，整个页面 500。
	local b1, b2 = data:byte(1), data:byte(2)
	if b1 ~= 0x1f or b2 ~= 0x8b then
		out({ ok = false, error = "不是 .tar.gz 归档（缺少 gzip 头）" })
		return
	end
	if not need_dir() then
		out({ ok = false, error = "临时目录不可用" })
		return
	end
	-- 时间戳只精确到秒：同一秒内的第二次上传会静默覆盖第一次，而被覆盖的
	-- 文件可能正被并发的 restore 读取。冲突时追加序号避让。
	local base = "uploaded-" .. os.date("%Y%m%d-%H%M%S")
	local name, fh
	for i = 0, 100 do
		name = i == 0 and (base .. ".tar.gz") or (base .. "-" .. i .. ".tar.gz")
		fh = io.open(RUNDIR .. "/" .. name, "rb")
		if fh then
			fh:close()
		else
			fh = io.open(RUNDIR .. "/" .. name, "wb")
			break
		end
	end
	if not fh then
		out({ ok = false, error = "无法写入临时文件" })
		return
	end
	-- write/close 都可能失败（tmpfs 写满、超配额）。不检查的话会返回一个
	-- 残缺的归档，UI 拿着它去 restore，失败被推迟到解包时才暴露。
	local ok = fh:write(data) and fh:close()
	if not ok then
		os.remove(RUNDIR .. "/" .. name)
		out({ ok = false, error = "写入临时文件失败（磁盘已满？）" })
		return
	end
	out({ ok = true, file = name })
end

function api_restore()
	local f  = http.formvalue("file") or ""
	local up = http.formvalue("uploaded") or ""
	local arg
	if f ~= "" and f:match(SAFE_NAME) then
		arg = q(f)
	elseif up ~= "" and up:match(SAFE_NAME) then
		arg = q(RUNDIR .. "/" .. up)
	else
		out({ ok = false, error = "未指定备份文件" })
		return
	end
	local r = sh(SH .. " restore " .. arg)
	out({ ok = r:find('"ok":true') ~= nil, data = r })
end

-- 下载归档（强制附件，避免浏览器渲染内容）
function api_backup_download()
	local f = http.formvalue("file") or ""
	if not f:match(SAFE_NAME) then
		http.status(400, "Bad Request")
		http.write("bad file name")
		return
	end
	local dir = sh(SH .. " backup-path")
	-- f 已由 SAFE_NAME 限死（不含 "/"），这里不存在实际穿越；但仍要求 dir 是
	-- 绝对路径且不含 ".."，避免 helper 返回值被污染时直接拼出目录穿越。
	if dir == "" or dir:find("%s") or dir:sub(1, 1) ~= "/" or dir:find("%.%.") then
		http.status(500, "Internal Error")
		http.write("backup directory unavailable")
		return
	end
	local fh = io.open(dir .. "/" .. f, "rb")
	if not fh then
		http.status(404, "Not Found")
		http.write("backup not found")
		return
	end
	local data = fh:read("*a") or ""
	fh:close()
	http.prepare_content("application/octet-stream")
	http.header("Content-Disposition", 'attachment; filename="' .. f .. '"')
	http.header("X-Content-Type-Options", "nosniff")
	http.write(data)
end
