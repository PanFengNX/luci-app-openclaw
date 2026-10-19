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
	entry({"admin", "services", "openclaw", "status"},   template("openclaw/status"),   _("状态"),      10)
	-- 「设置」是父节点：点击直接落到「基础」（alias 目标必须真实存在，见下一行）。
	entry({"admin", "services", "openclaw", "setup"},    firstchild(), _("设置"), 15)
	entry({"admin", "services", "openclaw", "setup", "general"}, template("openclaw/setup"), _("基础"), 10)
	entry({"admin", "services", "openclaw", "setup", "install"}, template("openclaw/install"), _("安装"), 15)
	entry({"admin", "services", "openclaw", "setup", "adopt"},   template("openclaw/adopt"), _("迁移"), 20)
	entry({"admin", "services", "openclaw", "setup", "model"},    template("openclaw/model"),    _("模型"), 30)
	entry({"admin", "services", "openclaw", "setup", "channels"}, template("openclaw/channels"), _("渠道"), 40)
	entry({"admin", "services", "openclaw", "setup", "changelog"}, template("openclaw/changelog"), _("更新说明"), 50)
	-- 「备份与恢复」独立成顶层页面（不放在「设置」子菜单里）。
	entry({"admin", "services", "openclaw", "backup"},    template("openclaw/backup"),   _("备份与恢复"), 20)
	entry({"admin", "services", "openclaw", "terminal"}, template("openclaw/terminal"), _("命令行"),    40)
	entry({"admin", "services", "openclaw", "log"},      template("openclaw/log"),      _("日志"),      50)

	-- JSON API
	entry({"admin", "services", "openclaw", "api", "info"},      call("api_info")).leaf = true
	entry({"admin", "services", "openclaw", "api", "versions"},  call("api_versions")).leaf = true
	entry({"admin", "services", "openclaw", "api", "check"},     call("api_check")).leaf = true
	entry({"admin", "services", "openclaw", "api", "install"},   call("api_install")).leaf = true
	entry({"admin", "services", "openclaw", "api", "istatus"},   call("api_istatus")).leaf = true
	entry({"admin", "services", "openclaw", "api", "ilog"},      call("api_ilog")).leaf = true
	entry({"admin", "services", "openclaw", "api", "changelog"}, call("api_changelog")).leaf = true
	entry({"admin", "services", "openclaw", "api", "service"},   call("api_service")).leaf = true
	entry({"admin", "services", "openclaw", "api", "save"},      call("api_save")).leaf = true
	entry({"admin", "services", "openclaw", "api", "presets"},   call("api_presets")).leaf = true
	entry({"admin", "services", "openclaw", "api", "models"},    call("api_models")).leaf = true
	entry({"admin", "services", "openclaw", "api", "models_url"}, call("api_models_url")).leaf = true
	entry({"admin", "services", "openclaw", "api", "apply"},     call("api_apply")).leaf = true
	entry({"admin", "services", "openclaw", "api", "run"},       call("api_run")).leaf = true
	entry({"admin", "services", "openclaw", "api", "channels"},  call("api_channels")).leaf = true
	entry({"admin", "services", "openclaw", "api", "log"},       call("api_log")).leaf = true
	entry({"admin", "services", "openclaw", "api", "mounts"},    call("api_mounts")).leaf = true
	entry({"admin", "services", "openclaw", "api", "discover"},  call("api_discover")).leaf = true
	entry({"admin", "services", "openclaw", "api", "node_existing"}, call("api_node_existing")).leaf = true
	entry({"admin", "services", "openclaw", "api", "devices_pending"}, call("api_devices_pending")).leaf = true
	entry({"admin", "services", "openclaw", "api", "devices_approve"}, call("api_devices_approve")).leaf = true
	entry({"admin", "services", "openclaw", "api", "migrate"},   call("api_migrate")).leaf = true
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
	entry({"admin", "services", "openclaw", "api", "backup_log"}, call("api_backup_log")).leaf = true
	entry({"admin", "services", "openclaw", "api", "backup_upload"}, call("api_backup_upload")).leaf = true
	entry({"admin", "services", "openclaw", "api", "backup_download"}, call("api_backup_download")).leaf = true
	entry({"admin", "services", "openclaw", "api", "restore"}, call("api_restore")).leaf = true
	-- 诊断包下载（openclaw.sh export）：生成后立刻作为附件回传
	entry({"admin", "services", "openclaw", "api", "export"}, call("api_export")).leaf = true
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

-- 私有临时目录。必须在这里声明：api_apply() 也要用 RUNDIR / need_dir()，
-- 而 Lua 5.1 是词法作用域 —— 声明放在文件后半段时，前面的引用会解析成全局
-- 查找（模块表与 _G 里都没有），填写 API Key 保存时直接报 nil 调用。
local RUNDIR = "/tmp/.openclaw"

-- RUNDIR 在全局可写的 /tmp 下：mkdir -p 会照单全收预先存在的同名条目，包括
-- 本地用户预置的符号链接，root 随后就会把上传内容写进链接指向的文件。
-- 所以先确认它不是符号链接，失败时由调用者拒绝本次写入。
local function need_dir()
	if sh("test -L " .. q(RUNDIR) .. " && echo symlink") == "symlink" then
		return false
	end
	os.execute("mkdir -p " .. q(RUNDIR) .. " && chmod 700 " .. q(RUNDIR) .. " 2>/dev/null")
	return true
end

-- sys.exec() 只返回 stdout 且丢掉退出码，写操作会因此一律回报成功。这里把
-- 合并后的输出落到私有 rundir 的临时文件，退出码与文本都能拿到；调用方负责
-- 在动作结束后删除临时文件（run_capture 自己删）。
local MAX_CAPTURE = 262144   -- 256 KiB
local function run_capture(args)
	if not need_dir() then return false, "" end
	local tmp = RUNDIR .. "/out-" .. os.date("%Y%m%d%H%M%S") .. "-" .. tostring(math.random(100000, 999999))
	local rc = sys.call(args .. " >" .. q(tmp) .. " 2>&1")
	local fh = io.open(tmp, "rb")
	local txt = ""
	if fh then
		txt = fh:read("*a") or ""
		fh:close()
	end
	os.remove(tmp)
	if #txt > MAX_CAPTURE then
		txt = "…（输出过长，仅显示最后 256KB）\n" .. txt:sub(-MAX_CAPTURE)
	end
	return rc == 0, txt
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

-- ---------------------------------------------------------------- changelog
-- 只读端点：把安装包内的 CHANGELOG.md 原样交给前端渲染。
-- 版本号取自文件首行的构建期标记 `<!-- version: X.Y.Z -->`。LuCI 没有暴露
-- 本包版本的纯 Lua 接口；opkg 的 /usr/lib/opkg/info/*.control 在 APK 系统上
-- 不存在，APK 的 /lib/apk/db/installed 格式又随 apk-tools 版本变化，调用
-- opkg / apk 则是外部命令。标记与正文在同一次读取里拿到，不会出现版本号与
-- 说明内容不一致的情况；标记缺失时退回正文第一个 "## X.Y.Z" 标题。
local CHANGELOG_PATH = "/usr/share/openclaw/CHANGELOG.md"
local MAX_CHANGELOG  = 262144   -- 256 KiB

-- 截断点落在 UTF-8 字符中间会让 jsonc.stringify() 返回 nil（非法 UTF-8），
-- 整个响应随即退化成 serialize-failed。这里先跳过尾部续字节找到最后一个
-- 字符的起始字节，再按它的长度判断该字符是否完整：不完整就整段丢弃。
-- 只删续字节是不够的 —— 那会留下一个孤立的起始字节，仍然不是合法 UTF-8。
local function utf8_safe_cut(s, n)
	if #s <= n then return s end
	local cut = s:sub(1, n)
	local i = #cut
	while i > 0 do
		local b = cut:byte(i)
		if b < 0x80 or b > 0xBF then break end
		i = i - 1
	end
	if i == 0 then return "" end
	local lead = cut:byte(i)
	local need = 1
	if lead >= 0xF0 and lead <= 0xF7 then need = 4
	elseif lead >= 0xE0 and lead <= 0xEF then need = 3
	elseif lead >= 0xC2 and lead <= 0xDF then need = 2
	end
	if #cut - i + 1 < need then
		cut = cut:sub(1, i - 1)
	end
	return cut
end

function api_changelog()
	local fh = io.open(CHANGELOG_PATH, "rb")
	if not fh then
		-- 文件不存在或打不开：前端显示一句提示，不当作错误弹窗。
		out({ ok = false, data = "" })
		return
	end
	-- 只读前 256KB：异常大的文件不能把响应体撑爆，也不能整份读进内存。
	local data = fh:read(MAX_CHANGELOG) or ""
	local more = fh:read(1)   -- 多探一个字节，区分"刚好 256KB"与"被截断"
	fh:close()
	if more then
		data = utf8_safe_cut(data, MAX_CHANGELOG) ..
			"\n\n…（更新说明过长，仅显示前 256KB）\n"
	end
	local version = data:match("<!%-%-%s*version:%s*([%w%.%-]+)%s*%-%->")
	if not version then
		version = data:match("\n##%s+([%w%.%-]+)")
	end
	out({ ok = true, data = data, version = version or "" })
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
	-- node_mirror 需要能显式清空（设置页选「自动」）：上面按空值跳过，
	-- 旧镜像源会一直留在 UCI 里。只有带 node_mirror_clear=1 且没有给出
	-- 具体地址时才清空，避免「保存基本设置」误清镜像源。
	local nm = http.formvalue("node_mirror") or ""
	if nm == "" and http.formvalue("node_mirror_clear") == "1" then
		args = args .. " --node-mirror " .. q("")
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

-- 上游模型列表：models.sh models-url <provider> 自己解析 Base URL 与 .env 里的
-- Key（Key 只经 curl --config - 的 stdin 传递），stdout 只有一行 JSON。
-- provider 会被拼进 shell 命令，也会被 helper 用来拼 .env 变量名，所以先按
-- 形状白名单校验，再交给 q() 转义；helper 侧还有一道同样的校验。
local PROVIDER_ID = "^[A-Za-z0-9][A-Za-z0-9_.-]*$"

function api_models_url()
	local p = http.formvalue("provider") or ""
	if #p == 0 or #p > 64 or not p:match(PROVIDER_ID) then
		out({ ok = false, error = "Provider 参数无效" })
		return
	end
	local r = sh(MODELS .. " models-url " .. q(p))
	local j = jsonc.parse(r)
	if type(j) ~= "table" then
		out({ ok = false, error = "上游模型列表无法解析" })
		return
	end
	out(j)
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

-- ---------------------------------------------------------------- channels
-- 渠道动作全部转给 channels.sh（渠道注册表、参数表、凭据规则都只在那一处维护，
-- 控制器不复制一份）。约定：
--   * channels.sh channels-list 的 stdout 只有 JSON 数组，日志走 stderr。
--   * 凭据只接受 --key-file：本控制器把浏览器 POST 上来的值写成 0600 临时文件，
--     调用后立刻删除。值绝不进 argv，也绝不进 URL —— uhttpd 会把查询串写进
--     访问日志，凭据一旦出现在 query 里就等于落盘。
local CHANNELS = "/usr/libexec/openclaw/channels.sh"

-- 渠道 id 先做形状校验，再经 q() 单引号转义后交给 shell。真正的合法集合在
-- channels.sh 的 channel_canon 里；这里只挡住空串、前导 "-"（会被当成选项）
-- 与任何可能改变命令结构的字符。
local CH_ID = "^[a-z][a-z0-9_]*$"
local CH_MAX_PARAMS = 32
local CH_MAX_VALUE  = 8192

local function ch_id(v)
	if type(v) ~= "string" or #v == 0 or #v > 32 then return nil end
	if not v:match(CH_ID) then return nil end
	return v
end

-- channels.sh 的 config 动作把结果写成一行 JSON，进度日志走 stderr；
-- run_capture 把两者合并了，所以按行找那条 JSON，取出脚本自己的错误文案。
local function ch_json_error(txt)
	for line in tostring(txt or ""):gmatch("[^\r\n]+") do
		local t = line:match("^%s*(%b{})%s*$")
		if t then
			local j = jsonc.parse(t)
			if type(j) == "table" and j.ok == false then
				return tostring(j.error or "操作失败")
			end
		end
	end
	return nil
end

-- 私有临时文件：目录本身是 0700，文件创建后立刻收紧到 0600。
-- 同名文件已存在时换一个后缀，避免同一秒内的两次请求互相覆盖
-- （上一次的文件可能正被 channels.sh 读取）。
local function ch_tmpfile(prefix)
	if not need_dir() then return nil end
	local base = prefix .. "-" .. os.date("%Y%m%d%H%M%S")
	for i = 0, 100 do
		local path = RUNDIR .. "/" .. (i == 0 and base or (base .. "-" .. i))
		local probe = io.open(path, "rb")
		if probe then
			probe:close()
		else
			local fh = io.open(path, "wb")
			if not fh then return nil end
			fh:close()
			os.execute("chmod 600 " .. q(path) .. " 2>/dev/null")
			return path
		end
	end
	return nil
end

-- 该渠道允许写入的键名：channels-list 里的 params[].name，或该渠道自己的
-- 完整键（顶层 configKey 形如 "channels.<channelId>"）。这样前端不可能借
-- config 动作改别的渠道，也改不到 channels 之外的键。
local function ch_allowed_keys(ch)
	local list = jsonc.parse(sh(CHANNELS .. " channels-list"))
	if type(list) ~= "table" then return nil end
	for _, c in ipairs(list) do
		if type(c) == "table" and c.id == ch then
			local names = {}
			for _, p in ipairs(c.params or {}) do
				if type(p) == "table" and type(p.name) == "string" then
					names[p.name] = true
				end
			end
			return names, tostring(c.configKey or "")
		end
	end
	return nil
end

local function ch_key_ok(key, names, prefix)
	if names[key] then return true end
	if prefix == "" or key:sub(1, #prefix + 1) ~= prefix .. "." then return false end
	local rest = key:sub(#prefix + 2)
	return rest ~= ""
		and rest:match("^[A-Za-z0-9_.-]+$") ~= nil
		and rest:sub(1, 1) ~= "."
		and rest:sub(-1) ~= "."
		and not rest:find("%.%.")
end

-- 把 values 写成 --key-file 要求的 "name=value" 行。
-- 值里的控制字符必须拒绝：换行会往文件里注入额外的一行 name=value，
-- 等于让一次请求写入任意键。留空表示"不修改"（密码框永不回填）。
local function ch_write_cred(path, values, names, prefix)
	local lines, n, err = {}, 0, nil
	for k, v in pairs(values) do
		if type(k) ~= "string" or type(v) ~= "string" then
			err = "参数格式无效"
			break
		elseif v ~= "" then
			n = n + 1
			if n > CH_MAX_PARAMS then
				err = "一次提交的参数过多"
				break
			elseif not ch_key_ok(k, names, prefix) then
				err = "参数名不在该渠道的配置项内：" .. k
				break
			elseif #v > CH_MAX_VALUE then
				err = "参数值过长：" .. k
				break
			elseif v:find("%c") then
				err = "参数值不能包含控制字符：" .. k
				break
			else
				lines[#lines + 1] = k .. "=" .. v
			end
		end
	end
	if err then return false, err end
	if n == 0 then return false, "没有填写任何配置项" end

	local fh = io.open(path, "wb")
	if not fh then return false, "无法创建临时密钥文件" end
	local wrote = fh:write(table.concat(lines, "\n") .. "\n")
	local closed = fh:close()
	if not wrote or not closed then return false, "写入临时密钥文件失败" end
	return true
end

function api_channels()
	local act = http.formvalue("action") or "list"

	-- 只读：给前端渲染卡片用。data 是原样 JSON 字符串，前端自己 parse。
	if act == "channels_list" then
		local r = sh(CHANNELS .. " channels-list")
		local list = jsonc.parse(r)
		if type(list) ~= "table" then
			out({ ok = false, error = "无法读取渠道列表（OpenClaw 可能未安装）" })
			return
		end
		out({ ok = true, data = r })
		return
	end

	if act == "list" then
		out({ ok = true, output = sh(CHANNELS .. " list") })
		return
	end

	-- 兼容旧页面的动作名；实现走下面同一套（微信的 canonical id 是 wechat）
	local ch = ch_id(http.formvalue("channel"))
	if act == "weixin_install" or act == "weixin_login" then
		ch = "wechat"
		act = (act == "weixin_install") and "install" or "login"
	end

	if act ~= "install" and act ~= "login" and act ~= "status" and act ~= "config" then
		out({ ok = false, error = "不支持的动作：" .. act })
		return
	end
	if not ch then
		out({ ok = false, error = "渠道参数无效" })
		return
	end

	if act == "install" or act == "login" or act == "status" then
		local ok, txt = run_capture(CHANNELS .. " " .. q(ch) .. " " .. act)
		out({ ok = ok, output = txt })
		return
	end

	-- config：值来自 POST body（http.formvalue 同时读 POST 与 query，但前端
	-- 只会 POST；这里绝不把它们拼进命令行）。
	local raw = http.formvalue("values")
	local values = type(raw) == "string" and jsonc.parse(raw) or nil
	if type(values) ~= "table" then
		out({ ok = false, error = "配置内容无法解析" })
		return
	end
	local names, prefix = ch_allowed_keys(ch)
	if not names then
		out({ ok = false, error = "未知渠道：" .. ch })
		return
	end
	local path = ch_tmpfile("cred")
	if not path then
		out({ ok = false, error = "临时目录不可用" })
		return
	end
	local okw, werr = ch_write_cred(path, values, names, prefix)
	if not okw then
		os.remove(path)
		out({ ok = false, error = werr })
		return
	end
	local ok, txt = run_capture(CHANNELS .. " " .. q(ch) .. " config --key-file " .. q(path))
	-- 凭据文件用完即删：/tmp 是 tmpfs，留着只会把明文多留一会儿
	os.remove(path)
	local err = ch_json_error(txt)
	if err then ok = false end
	out({ ok = ok, output = txt, error = err })
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

-- ------------------------------------------------- 已有安装：发现 / 迁移
-- 这两条走 openclaw.sh 自己的子命令（discover / migrate），不是 openclaw
-- CLI，所以 api_run 的白名单帮不上忙，必须单独开端点。
--   discover 只读；migrate 会复制文件（重操作，前端二次确认）。
-- 两者的 stdout 都是 JSON（helper 的日志一律走 stderr），控制器原样透传给前端。

local function oc_dir_arg(s)
	-- 目录参数形状校验。真正的安全判断在 shell 侧（oc_probe_openclaw_dir /
	-- oc_validate_base_dir），这里只挡掉三类明显无意义或有害的输入：
	--   * 空值与相对路径 —— helper 只接受绝对路径
	--   * 非 "/" 开头 —— 前导 "-" 会被 helper 的 case 当成选项而不是参数
	--   * 控制字符（换行等）—— 即使 q() 会转义，也不该出现在路径里
	-- 注意：q() 仍然必须使用，因为路径里的空格 / 引号 / $ 都要靠它隔离。
	if not s or s == "" or #s > 4096 then return nil end
	if s:sub(1, 1) ~= "/" then return nil end
	if s:find("%c") then return nil end
	return s
end

function api_discover()
	-- 只读探测。可能较慢（每个候选目录一次 du，helper 内部有 timeout 封顶），
	-- 所以前端必须异步调用、失败或空结果时安静隐藏卡片。
	local r = sh(SH .. " discover")
	out({ ok = true, data = r })
end

function api_node_existing()
	-- 只读探测：列出本机已有的 node 运行时（JSON 数组，每项 path/version/source/usable）。
	-- 与 api_discover 同一条约定：helper 只往 stdout 写 JSON、日志走 stderr，
	-- 这里原样透传，前端拿到 data 后自己 JSON.parse。
	-- 同样可能较慢（逐候选跑 node -v，helper 用 timeout 封顶），前端必须异步调用、
	-- 失败或空结果时安静隐藏提示，不弹错误。
	local r = sh(SH .. " node-existing")
	out({ ok = true, data = r })
end

-- ---------------------------------------------------------------- devices
-- 局域网 / Tailnet 访问 Control UI 时 OpenClaw 要求一次性配对批准
-- （127.0.0.1 自动批准）。两个端点都只是 openclaw.sh 的薄封装：
--   * helper 的 stdout 只有 JSON，日志走 stderr；这里把整段 JSON 作为 data
--     原样透传，前端自己 parse（与 discover / node_existing 一致）。
--     不在这里 jsonc.parse 后再 stringify：LuCI 的 jsonc 会把空数组重新编码成
--     {}，前端 Array.isArray() 就失效了。
--   * requestId 只从 POST body 读取（前端 post() 以表单编码提交），绝不拼进
--     URL —— uhttpd 会把查询串写进访问日志。
--   * 控制器侧先做一次白名单校验；shell 侧还有第二道（id 会进入 argv）。
--     批准是逐条动作，不提供 approve-all。
local DEVICE_ID = "^[A-Za-z0-9._-]+$"

function api_devices_pending()
	local r = sh(SH .. " devices-pending")
	if r == "" then
		out({ ok = false, error = "设备列表为空（OpenClaw 可能未安装）" })
		return
	end
	out({ ok = true, data = r })
end

function api_devices_approve()
	local id = http.formvalue("requestId")
	if type(id) ~= "string" or id == "" then
		out({ ok = false, error = "缺少 requestId" })
		return
	end
	-- 与 shell 侧保持同一条白名单：长度 <= 128、只允许 [A-Za-z0-9._-]，
	-- 且拒绝前导 "-"（会被 CLI 当成选项而不是设备 id）。
	if #id > 128 or not id:match(DEVICE_ID) or id:sub(1, 1) == "-" then
		out({ ok = false, error = "requestId 非法" })
		return
	end
	local r = sh(SH .. " devices-approve " .. q(id))
	if r == "" then
		out({ ok = false, error = "批准失败（无返回内容）" })
		return
	end
	out({ ok = true, data = r })
end

function api_migrate()
	local dir = oc_dir_arg(http.formvalue("dir"))
	if not dir then
		out({ ok = false, error = "目录参数无效" })
		return
	end
	-- 同步执行：migrate 自己取锁、自己校验目标，失败时返回 {"ok":false,"error":..}。
	-- 前端在请求期间显示"进行中"，完成后按 data 里的结果提示。
	local r = sh(SH .. " migrate " .. q(dir))
	out({ ok = r:find('"ok":true') ~= nil, data = r })
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

-- 首字符必须是字母数字：排除 "." / ".."（会被拼成路径穿越）与前导 "-"
-- （会被 helper 的 getopts 当成选项）。这些名字会原样下传给 openclaw.sh。
local SAFE_NAME = "^[A-Za-z0-9][A-Za-z0-9._-]*$"
local MAX_UPLOAD = 64 * 1024 * 1024   -- 64 MiB

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

-- 备份操作审计（只读）：backup-log [N] 返回按时间正序的 JSON 数组。
-- N 的合法性由 openclaw.sh 统一兜底（非数字/0 -> 50，上限 500）。
function api_backup_log()
	local n = http.formvalue("n") or ""
	local r = sh(SH .. " backup-log" .. (n ~= "" and (" " .. q(n)) or ""))
	out({ ok = true, data = r })
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
	-- 顺序不能反：prepare_content() 会立刻把响应头刷出并置 sent，
	-- 之后再调用 header() 是空操作，附件名会丢。
	http.header("Content-Disposition", 'attachment; filename="' .. f .. '"')
	http.header("X-Content-Type-Options", "nosniff")
	http.prepare_content("application/octet-stream")
	http.write(data)
end

-- ---------------------------------------------------------------- export
-- 诊断包下载。openclaw.sh export 会把脱敏后的 tar.gz 写到
-- /tmp/luci-app-openclaw-diag-<ts>.tar.gz，stdout 只有一行 JSON：
--   {"ok":true,"path":"...","size":N} / {"ok":false,"error":"..."}
-- 这里只负责调用、解析路径、回传文件；export 子命令本身不改。
local EXPORT_CHUNK  = 65536   -- 64 KiB

local function export_fail(msg)
	-- status() 会立刻把响应头刷出，所以 Content-Type 必须先写进头表；
	-- 反过来调用（先 status 再 prepare_content）时后者不会再生效。
	http.header("Content-Type", "application/json")
	http.status(500, "Internal Error")
	http.write(jsonc.stringify({ ok = false, error = tostring(msg) })
		or '{"ok":false,"error":"export-failed"}')
end

function api_export()
	local r = sh(SH .. " export")
	local j = jsonc.parse(r)
	if type(j) ~= "table" then
		export_fail("导出结果无法解析")
		return
	end
	if j.ok ~= true then
		export_fail(j.error or "导出失败")
		return
	end

	local path = j.path
	-- 只接受 helper 默认输出位置的精确形状：
	--   /tmp/luci-app-openclaw-diag-YYYYmmdd-HHMMSS.tar.gz
	-- 路径由 helper 生成、不来自浏览器；这条白名单保证即使 helper 返回值
	-- 被污染，本端点也不会变成任意文件读取 / 任意文件删除。
	if type(path) ~= "string"
		or not path:match("^/tmp/luci%-app%-openclaw%-diag%-%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d%.tar%.gz$")
	then
		export_fail("导出路径不合法")
		return
	end

	local fh = io.open(path, "rb")
	if not fh then
		export_fail("无法读取诊断包")
		return
	end
	local size = fh:seek("end") or 0
	fh:seek("set", 0)

	-- 浏览器端文件名固定格式、带时间戳，不暴露 /tmp 路径，也不拼接请求参数。
	local name = "openclaw-diag-" .. os.date("%Y%m%d-%H%M") .. ".tar.gz"

	-- 先 header() 再 prepare_content()（理由同 api_backup_download）。
	http.header("Content-Disposition", 'attachment; filename="' .. name .. '"')
	http.header("X-Content-Type-Options", "nosniff")
	http.header("Cache-Control", "no-store")
	if size > 0 then
		http.header("Content-Length", tostring(size))
	end
	http.prepare_content("application/octet-stream")

	-- 分块写出：诊断包含完整日志，整份 read("*a") 会把包同时压在 Lua 与
	-- uhttpd 的内存里；分块读只占一个 chunk。
	while true do
		local chunk = fh:read(EXPORT_CHUNK)
		if not chunk then break end
		http.write(chunk)
	end
	fh:close()
	-- 每次导出都会生成新包，临时文件没有保留价值；/tmp 是 tmpfs，留着占内存。
	os.remove(path)
end
