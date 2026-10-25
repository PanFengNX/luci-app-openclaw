-- Copyright (C) openclaw - LuCI controller
-- OpenClaw 助手 (OpenClaw Assistant) for OpenWrt
-- package: luci-app-openclaw

module("luci.controller.openclaw", package.seeall)

local sys   = require "luci.sys"
local util  = require "luci.util"
local http  = require "luci.http"
local jsonc = require "luci.jsonc"

local SH     = "/usr/libexec/openclaw/cli.sh"
local MODELS = "/usr/libexec/openclaw/models.sh"

local function is_post()
	-- http.getenv 在 luci-compat 里一直存在，但取不到时按「不是 POST」处理，
	-- 宁可拒绝也不要把敏感参数当成查询串接受。
	local m = nil
	if http.getenv then m = http.getenv("REQUEST_METHOD") end
	return (m or ""):upper() == "POST"
end

-- JSON 响应出口。**必须声明在 guarded() 之前**：Lua 5.1 是词法作用域，
-- 局部变量只在声明之后可见；guarded 定义在前、out 声明在后时，guarded 体内
-- 的 out 会被编译成全局查找，运行时是 nil。
--
-- 这个错误在 1.8.28 里真实发生过：所有 API 请求都经过 guarded，于是
-- 每个接口都抛 "attempt to call a nil value (global 'out')" 并返回 500 ——
-- 表现为页面能打开、但挂载点为空、程序位置一直「读取中」、版本列表「服务
-- 无响应」、模型下拉为空、网盘状态读取失败。tools/tests/lua-scope.py 现在
-- 专门检查这类前向引用。
local function out(tbl)
	http.prepare_content("application/json")
	-- stringify() returns nil when a value cannot be encoded (e.g. invalid
	-- UTF-8 straight from a helper script); writing nil produced an empty
	-- body and the browser then failed on JSON.parse.
	http.write(jsonc.stringify(tbl) or '{"ok":false,"error":"serialize-failed"}')
end

-- ---------------------------------------------------------------- CSRF
-- 写操作必须 POST。此前 56 个端点里只有 13 个自己调 is_post()，其余
-- （install / service / save / run / restore / backup_* / diag_run …）
-- 用 GET 就能触发：管理员登录着 LuCI 时，任意第三方页面一个 <img src> 或
-- 表单就能让设备还原备份、装任意 npm 包。
--
-- 这里在**入口层**一次性做，而不是逐个函数补 —— 逐个补必然漏。
-- 白名单只列真正只读的端点；新增端点若忘记登记，会被默认要求 POST。
-- 漏登记的**安全方向**是安全的（不会静默放行写操作），但**功能会坏**：
-- 前端用 GET 调的只读端点会直接报「请使用 POST」。所以新增端点时：
--   * 前端用 post() 调的 → 不必登记；
--   * 前端用 get() / window.open() 调的 → 必须登记进 READ_ONLY，
--     否则该功能立刻失效（历史上 backup_download 就踩过）。
-- 改前端调用方式时也要回来核对这张表。
local READ_ONLY = {
	info = true, versions = true, check = true, istatus = true, ilog = true,
	-- backup_download 前端用 window.open 触发（浏览器下载只能 GET），
	-- 且它只是把已有归档回传，不修改任何状态 —— 属于只读。
	backup_download = true,
	changelog = true, presets = true, models = true, model_current = true,
	models_url = true, log = true, mounts = true, node_existing = true,
	providers = true, backups = true, backup_log = true,
	devices_pending = true,
	cloud_status = true, cloud_install_poll = true, cloud_ls = true,
	cloud_pass_status = true, cloud_encrypt_status = true,
	cloud_schedule_status = true, cloud_cli_check = true, export = true,
}

local function guarded(name, fn)
	return function()
		if not READ_ONLY[name] and not is_post() then
			out({ ok = false, error = "请使用 POST 提交（" .. name .. "）" })
			return
		end
		return fn()
	end
end

function index()
	entry({"admin", "services", "openclaw"}, firstchild(), _("OpenClaw 助手"), 60).dependent = false
	entry({"admin", "services", "openclaw", "status"},   template("openclaw/status"),   _("状态"),      10)
	-- 「设置」是父节点：点击直接落到「基础」（alias 目标必须真实存在，见下一行）。
	entry({"admin", "services", "openclaw", "setup"},    firstchild(), _("设置"), 15)
	entry({"admin", "services", "openclaw", "setup", "general"}, template("openclaw/setup"), _("基础"), 10)
	entry({"admin", "services", "openclaw", "setup", "install"}, template("openclaw/install"), _("安装"), 15)
	entry({"admin", "services", "openclaw", "setup", "model"},    template("openclaw/model"),    _("模型"), 30)
	entry({"admin", "services", "openclaw", "setup", "channels"}, template("openclaw/channels"), _("渠道"), 40)
	entry({"admin", "services", "openclaw", "setup", "changelog"}, template("openclaw/changelog"), _("更新说明"), 50)
	-- 「备份与恢复」独立成顶层页面（不放在「设置」子菜单里）。
	entry({"admin", "services", "openclaw", "backup"},    template("openclaw/backup"),   _("备份与恢复"), 20)
	entry({"admin", "services", "openclaw", "terminal"}, template("openclaw/terminal"), _("命令行"),    40)
	entry({"admin", "services", "openclaw", "log"},      template("openclaw/log"),      _("日志"),      50)

	-- JSON API
	entry({"admin", "services", "openclaw", "api", "info"},      call("api_info")).leaf = true
	-- 完整网关 token 只走这个端点（POST）；info 里只有掩码。
	entry({"admin", "services", "openclaw", "api", "token"},     call("api_token")).leaf = true
	entry({"admin", "services", "openclaw", "api", "versions"},  call("api_versions")).leaf = true
	entry({"admin", "services", "openclaw", "api", "check"},     call("api_check")).leaf = true
	entry({"admin", "services", "openclaw", "api", "install"},   call("api_install")).leaf = true
	entry({"admin", "services", "openclaw", "api", "uninstall"}, call("api_uninstall")).leaf = true
	entry({"admin", "services", "openclaw", "api", "istatus"},   call("api_istatus")).leaf = true
	entry({"admin", "services", "openclaw", "api", "ilog"},      call("api_ilog")).leaf = true
	entry({"admin", "services", "openclaw", "api", "changelog"}, call("api_changelog")).leaf = true
	entry({"admin", "services", "openclaw", "api", "service"},   call("api_service")).leaf = true
	entry({"admin", "services", "openclaw", "api", "save"},      call("api_save")).leaf = true
	entry({"admin", "services", "openclaw", "api", "presets"},   call("api_presets")).leaf = true
	entry({"admin", "services", "openclaw", "api", "models"},    call("api_models")).leaf = true
	entry({"admin", "services", "openclaw", "api", "model_current"}, call("api_model_current")).leaf = true
	entry({"admin", "services", "openclaw", "api", "models_url"}, call("api_models_url")).leaf = true
	entry({"admin", "services", "openclaw", "api", "apply"},     call("api_apply")).leaf = true
	entry({"admin", "services", "openclaw", "api", "run"},       call("api_run")).leaf = true
	entry({"admin", "services", "openclaw", "api", "channels"},  call("api_channels")).leaf = true
	entry({"admin", "services", "openclaw", "api", "log"},       call("api_log")).leaf = true
	entry({"admin", "services", "openclaw", "api", "mounts"},    call("api_mounts")).leaf = true
	entry({"admin", "services", "openclaw", "api", "diag_export"}, call("api_diag_export")).leaf = true
	entry({"admin", "services", "openclaw", "api", "node_existing"}, call("api_node_existing")).leaf = true
	entry({"admin", "services", "openclaw", "api", "devices_pending"}, call("api_devices_pending")).leaf = true
	entry({"admin", "services", "openclaw", "api", "devices_approve"}, call("api_devices_approve")).leaf = true
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
	-- 百度网盘云备份：业务全部在 cloud.sh 里，这里只做参数校验与透传
	entry({"admin", "services", "openclaw", "api", "cloud_status"},  call("api_cloud_status")).leaf = true
	entry({"admin", "services", "openclaw", "api", "cloud_install"}, call("api_cloud_install")).leaf = true
	-- 后台安装 + 轮询：请求只负责启动 worker，进度从 cloud.sh 的日志文件读
	entry({"admin", "services", "openclaw", "api", "cloud_install_bg"}, call("api_cloud_install_bg")).leaf = true
	entry({"admin", "services", "openclaw", "api", "cloud_install_poll"}, call("api_cloud_install_poll")).leaf = true
	entry({"admin", "services", "openclaw", "api", "cloud_login_url"},  call("api_cloud_login_url")).leaf = true
	entry({"admin", "services", "openclaw", "api", "cloud_login_code"}, call("api_cloud_login_code")).leaf = true
	entry({"admin", "services", "openclaw", "api", "cloud_logout"}, call("api_cloud_logout")).leaf = true
	entry({"admin", "services", "openclaw", "api", "cloud_upload"}, call("api_cloud_upload")).leaf = true
	entry({"admin", "services", "openclaw", "api", "cloud_ls"},     call("api_cloud_ls")).leaf = true
	entry({"admin", "services", "openclaw", "api", "cloud_download"}, call("api_cloud_download")).leaf = true
	entry({"admin", "services", "openclaw", "api", "cloud_rm"},     call("api_cloud_rm")).leaf = true
	entry({"admin", "services", "openclaw", "api", "cloud_pass_status"}, call("api_cloud_pass_status")).leaf = true
	entry({"admin", "services", "openclaw", "api", "cloud_pass_set"},    call("api_cloud_pass_set")).leaf = true
	entry({"admin", "services", "openclaw", "api", "cloud_pass_clear"},  call("api_cloud_pass_clear")).leaf = true
	entry({"admin", "services", "openclaw", "api", "cloud_encrypt_status"}, call("api_cloud_encrypt_status")).leaf = true
	entry({"admin", "services", "openclaw", "api", "cloud_encrypt_set"},    call("api_cloud_encrypt_set")).leaf = true
	entry({"admin", "services", "openclaw", "api", "cloud_schedule_status"}, call("api_cloud_schedule_status")).leaf = true
	entry({"admin", "services", "openclaw", "api", "cloud_schedule_set"},    call("api_cloud_schedule_set")).leaf = true
	entry({"admin", "services", "openclaw", "api", "cloud_cli_check"},      call("api_cloud_cli_check")).leaf = true
	entry({"admin", "services", "openclaw", "api", "cloud_cli_update"},     call("api_cloud_cli_update")).leaf = true
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

-- 请求方法 / 查询串的检查放在这里（文件前部），**必须在使用之前**声明：
-- Lua 5.1 是词法作用域，声明写在文件后半段时，前面 api_apply 里的调用会
-- 解析成全局查找（nil），一调就 "attempt to call a nil value"，整个端点 500。
-- 这个坑本项目已经踩过一次（RUNDIR 声明晚于 api_apply 的使用）。
--

-- 光强制 POST 还不够：http.formvalue() 同时查 POST body 与 URL query，
-- 所以 `POST /api/apply?apikey=...` 依然能生效，而 uhttpd 记录的是完整 URL。
-- 这里直接检查查询串里有没有敏感键名，有就拒绝 —— 让它连"能生效"都做不到，
-- 用户只能改用 body 提交，凭据也就不会进访问日志。
local SECRET_QS = { "apikey", "pass", "password", "code", "secret", "token" }

-- URL 解码（%XX）。只处理百分号编码，'+' 按 query 惯例还原成空格。
local function url_decode(s)
	-- '+' 是 Lua 的模式量词，必须转义成 %+ 才是字面量加号。
	-- 写成 gsub("+", " ") 会在运行时抛 malformed pattern（量词缺主语）。
	s = s:gsub("%+", " ")
	return (s:gsub("%%(%x%x)", function(h)
		return string.char(tonumber(h, 16))
	end))
end

local SECRET_SET = {}
for _, k in ipairs(SECRET_QS) do SECRET_SET[k] = true end

local function query_has_secret()
	local qs = nil
	if http.getenv then qs = http.getenv("QUERY_STRING") end
	if not qs or qs == "" then return false end
	-- 按键值对逐个比对键名，而不是在整串里找子串：
	--   * 子串匹配会误伤 apikey_hint=1（它只是个开关，不是凭据）；
	--   * 也不能用 find(s, 1, true) 去匹配 "[&?]" —— plain 模式会把方括号
	--     当字面量，永远不命中，等于漏掉 & 之后的键。
	for pair in (qs .. "&"):gmatch("([^&]*)&") do
		local k = pair:match("^([^=]*)=")
		if k then
			k = url_decode(k)
			if SECRET_SET[k] then return true end
		end
	end
	return false
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

-- 网关 token 掩码：只留后 4 位；短于 8 位全掩码。空值仍给空串，
-- 前端据此区分「没有 token」与「有 token 但被遮住」。
local function mask_token(t)
	t = tostring(t or "")
	if t == "" then return "" end
	if #t < 8 then return "****" end
	return "****" .. t:sub(-4)
end

function api_info()
	local r = sh(SH .. " info")
	-- info 的原始 JSON 里带完整网关 token。状态页每次加载都会拉一次，
	-- 明文回传等于把 token 写进浏览器缓存 / 历史 / 任何抓包与代理日志。
	-- 这里在服务端就把 token 摘掉，只回掩码；完整值只能走 api_token（POST）。
	local j = jsonc.parse(r)
	if type(j) ~= "table" then
		-- 解析失败时绝不回退到原文：原文里就有 token。
		out({ ok = false, error = "后端返回无法解析" })
		return
	end
	local tok = j.token
	j.token = nil
	j.token_masked = mask_token(tok)
	local s = jsonc.stringify(j)
	if not s then
		out({ ok = false, error = "后端返回无法序列化" })
		return
	end
	out({ ok = true, data = s })
end

function api_versions()
	local refresh = http.formvalue("refresh")
	local arg = refresh == "1" and " refresh" or ""
	local ocv = sh("/usr/libexec/openclaw/versions.sh oc-versions" .. arg)
	local nv  = sh("/usr/libexec/openclaw/versions.sh node-versions" .. arg)
	local urls = sh("/usr/libexec/openclaw/versions.sh urls")
	-- status 原样透传（一行 JSON）：前端靠它区分「确实没有新版本」与「根本
	-- 没拉到列表」。以前后者只表现为一个空数组，升级入口整块静默消失。
	-- status 只往 stdout 写这一行 JSON，日志一律走 stderr，所以这里不会被污染。
	local st = sh("/usr/libexec/openclaw/versions.sh status")
	out({ ok = true, openclaw = ocv, node = nv, sources = urls, status = st })
end

function api_check()
	local ocv = http.formvalue("oc") or "latest"
	local nv  = http.formvalue("node") or ""
	local r = sh("/usr/libexec/openclaw/versions.sh check " .. q(ocv) .. " " .. q(nv))
	local ok = r:find('"ok":true') ~= nil
	out({ ok = ok, data = r })
end

function api_uninstall()
	-- 专用端点，而不是塞进 api/run 的白名单：
	--   * api/run 的 RUN_CMDS 语义是"openclaw CLI 的子命令"，uninstall 不是；
	--   * 卸载会 rm -rf 程序目录，必须能返回真实的退出码给前端。
	-- 同步执行：删的是程序目录与 node 运行时（不含数据），几十秒量级；
	-- 前端给了长超时。返回 run_rc 的结果，前端据此显示成功/失败。
	if not is_post() then out({ ok = false, error = "请使用 POST 提交" }); return end
	local ok = run_rc(SH .. " uninstall")
	out({ ok = ok })
end

function api_install()
	local ocv  = http.formvalue("oc_version") or "latest"
	local ndv  = http.formvalue("node_version") or "auto"
	local dir  = http.formvalue("base_dir") or ""
	local odir = http.formvalue("openclaw_dir") or ""
	local args = " install-bg --oc-version " .. q(ocv) .. " --node-version " .. q(ndv)
	if dir ~= "" then args = args .. " --base-dir " .. q(dir) end
	if odir ~= "" then args = args .. " --openclaw-dir " .. q(odir) end

	-- 这里必须看 install-bg 的退出码，不能无条件 ok=true。
	--
	-- install-bg 有三条**同步**拒绝路径（都只写 stderr + exit 2）：
	--   * require_safe 失败（base_dir 是系统路径 / 端口不安全）
	--   * 已持有操作锁（另一个操作在跑）
	--   * 已有安装进程在跑
	-- 而 sh() 只取 stdout、刻意丢弃 stderr（那是给 JSON 端点防污染用的）。
	-- 两者一叠加，拒绝原因彻底消失，前端只收到 ok=true，于是
	--   「点了升级 → 没有任何日志 → 界面像卡死」
	-- —— 因为后台进程压根没起来，install-status 永远查不到 running。
	-- 用 run_capture 同时拿退出码与输出，失败时把真实原因回给前端。
	local ok, out_txt = run_capture(SH .. args)
	if not ok then
		out({ ok = false,
			error = (out_txt ~= "" and out_txt) or "安装进程启动失败（无输出）" })
		return
	end
	out({ ok = true })
end

function api_istatus()
	local r = sh(SH .. " install-status")
	out({ ok = true, data = r })
end

-- install.log grows for the whole (long) install; cap what we ship to the
-- browser so a big log cannot blow up memory or the response body
local MAX_ILOG = 262144   -- 256 KiB

-- 读一个日志文件的尾部（最多 MAX_ILOG 字节）
local function read_tail(path)
	local f = io.open(path, "r")
	if not f then return nil end
	-- 只读尾部：read("*a") 会把几十 MB 的安装日志整份读进内存，
	-- 之后才截断，正好和"限制内存"的初衷相反。
	local size = f:seek("end") or 0
	local txt
	if size > MAX_ILOG then
		f:seek("set", size - MAX_ILOG)
		txt = "…（日志过长，仅显示最后 256KB）\n" .. (f:read("*a") or "")
	else
		f:seek("set", 0)
		txt = f:read("*a") or ""
	end
	f:close()
	return txt
end

function api_ilog()
	-- 安装日志的**真实路径由后端决定**，不能写死。
	--
	-- 两处会偏离 /var/log/openclaw-install.log：
	--   1. install.sh 在 /var/log 不可写时回退到 $OC_RUNDIR/install.log；
	--   2. install.sh 每次启动都先把上一轮日志 `mv` 成 .1 再清空主文件。
	--      如果这一轮刚启动就退出（preflight 失败、被 kill），主文件是空的，
	--      **有用内容全在 .1 里** —— 而这里原来只读主文件，于是弹窗空着，
	--      用户看到的就是"点了升级、没进度、也没有日志"。
	-- install-status 已经返回真实路径（"log" 字段），优先用它。
	local path = nil
	local st = sh(SH .. " install-status")
	if st ~= "" then
		local okj, tbl = pcall(jsonc.parse, st)
		if okj and type(tbl) == "table" and type(tbl.log) == "string" and tbl.log ~= "" then
			path = tbl.log
		end
	end
	if not path or path == "" then path = "/var/log/openclaw-install.log" end

	local r = read_tail(path)
	if not r or r == "" then
		-- 主日志空/不存在：试试上一轮留下的 .1（本轮启动时被 mv 过去的那份）。
		-- 这是"刚点完升级就失败"时唯一有内容的文件。
		local prev = read_tail(path .. ".1")
		if prev and prev ~= "" then
			r = ("（本轮安装日志为空，以下是上一轮的日志 %s.1）\n\n"):format(path) .. prev
		else
			-- 都没有：给出实际找过的路径，别让用户对着空白猜
			r = ("（暂无安装日志）\n已查找：\n  %s\n  %s.1\n"):format(path, path)
		end
	end
	out({ ok = true, log = r, path = path })
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
		"npm_registry", "node_mirror", "http_proxy", "enabled", "core_dumps"
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

function api_model_current()
	-- 当前默认模型：models.sh current 直接读 state_dir/openclaw.json 的
	-- agents.defaults.model.primary，不启动 CLI。
	-- 曾经这里是 api_run 的 `models current`，而 openclaw 的部分版本没有这个
	-- 子命令，页面上于是显示成一段报错文字（还带着 WARN 前缀）。
	out({ ok = true, current = sh("/usr/libexec/openclaw/models.sh current") })
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
	-- 必须 POST：apikey 走 GET 查询串会落进 uhttpd 的访问日志（完整 URL 都记）。
	-- 同文件另外 12 个写操作端点都有这道检查，这里是漏掉的一处。
	-- 第二道检查针对"POST 但把 key 塞进 query"：formvalue 两种来源都读，
	-- 所以只挡 GET 还不够。
	if not is_post() then
		out({ ok = false, error = "请使用 POST 提交" })
		return
	end
	if query_has_secret() then
		out({ ok = false, error = "凭据不能放在 URL 查询串里，请用表单提交" })
		return
	end
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
	message = true, memory = true, workspace = true,
	-- 2026-10-20 补充：都是"看"为主的子命令。判断标准是
	-- 「能不能通过它把任意命令塞进 shell」——这些都不能，参数仍逐 token 过 q()。
	providers = true,  -- 列出已知的模型服务商
	tools = true,      -- 列出可用工具（排查工具调用时最常用）
	mcp = true,        -- 列出 / 增删 MCP 服务器（本地配置，可回退）
	devices = true,    -- 局域网配对：list 只读，approve 与设置页的按钮等价
	["--version"] = true, ["--help"] = true   -- 不带子命令的两种常规问法
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
	-- src：gateway（网关自己的日志文件）| file（管理脚本日志）
	--      | syslog（procd 转发的摘要）| all（默认，三者合并）
	-- 白名单，不能把任意值拼进命令行。
	-- 默认 all 而不是 file：/var/log/openclaw.log 只有管理脚本写的几行，
	-- 真正的启动过程、插件加载、崩溃堆栈都在网关日志文件里。
	local src = http.formvalue("src") or "all"
	if src ~= "gateway" and src ~= "file" and src ~= "syslog" and src ~= "all" then
		src = "all"
	end
	local r = sh(SH .. " log " .. q(tostring(n)) .. " " .. q(src))
	out({ ok = true, log = r, src = src })
end

function api_diag_export()
	-- 把诊断快照落到 <state_dir>/diagnostics/，供 agent / 人工查看。
	-- 这不是"改代码"的通道，只是把已有的只读信息搬到 agent 有读权限的目录里。
	local r = sh(SH .. " diag-export")
	out({ ok = true, data = r })
end

function api_mounts()
	local r = sh(SH .. " mounts")
	out({ ok = true, data = r })
end

function api_node_existing()
	-- 只读探测：列出本机已有的 node 运行时（JSON 数组，每项 path/version/source/usable）。
	-- 与本文件其它 JSON 端点同一条约定：helper 只往 stdout 写 JSON、日志走 stderr，
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
--     原样透传，前端自己 parse（与 node_existing 一致）。
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
	-- repair.sh 里会跑 `openclaw doctor --fix`（上限 300s），远超 uhttpd 的
	-- CGI 超时。同步执行的结果是：浏览器先断，脚本还在后台跑，用户看到
	-- 「服务无响应」，然后再点一次 —— 两次修复并发。
	-- 界面上的一键修复已经走 api_diag_run 的后台范式（起任务 + 轮询），
	-- 这里不再提供同步入口，避免任何调用方踩这个坑。
	local j = http.formvalue("json")
	if j == "1" then
		out({ ok = false,
			error = "同步修复会超过 HTTP 超时，请改用 api/diag_run?name=repair 后台执行并轮询结果" })
		return
	end
	out({ ok = false,
		output = "修复耗时可能数十秒到数分钟，超出 HTTP 请求超时。\n"
			.. "请在「状态」页点「一键修复」，它会后台执行并轮询日志；\n"
			.. "或用 SSH 执行：/usr/libexec/openclaw/cli.sh diag repair" })
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
-- 分块写出/读取的块大小。备份下载与诊断包导出共用，必须**在使用之前**声明：
-- Lua 5.1 是词法作用域，声明写在文件后半段时前面的引用会解析成全局查找
-- （nil），fh:read(nil) 会退化成按行读，二进制文件直接被读坏。
local EXPORT_CHUNK = 65536   -- 64 KiB

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
	local size = fh:seek("end") or 0
	fh:seek("set", 0)
	-- 顺序不能反：prepare_content() 会立刻把响应头刷出并置 sent，
	-- 之后再调用 header() 是空操作，附件名会丢。
	http.header("Content-Disposition", 'attachment; filename="' .. f .. '"')
	http.header("X-Content-Type-Options", "nosniff")
	http.header("Cache-Control", "no-store")
	if size > 0 then
		http.header("Content-Length", tostring(size))
	end
	http.prepare_content("application/octet-stream")
	-- 分块写出，与 api_export 同一策略：备份默认含 workspace，可达数百 MB，
	-- read("*a") 会把整份同时压在 Lua 与 uhttpd 的内存里，小内存路由器直接 OOM。
	while true do
		local chunk, err = fh:read(EXPORT_CHUNK)
		if not chunk then
			-- read 返回 nil 有两种情况：正常 EOF（err 为 nil）与 I/O 错误。
			-- 后者如果不区分，客户端会收到一个 Content-Length 声明了 size
			-- 却提前断流的响应，看不出是磁盘还是网络的问题。至少留一行日志。
			if err then
				io.stderr:write("openclaw: 备份下载中途读失败（" ..
					tostring(f) .. "）：" .. tostring(err) .. "\n")
			end
			break
		end
		http.write(chunk)
	end
	fh:close()
end

-- ---------------------------------------------------------------- cloud
-- 百度网盘云备份。业务逻辑全部在 cloud.sh 里，这里只做三件事：
--   1) 参数白名单校验（远端名 / 本地备份名 / 授权码 / 口令）
--   2) 把口令经私有临时文件喂给 cloud.sh 的 stdin（绝不进 argv，ps 看不到）
--   3) 把 cloud.sh 的单行 JSON 原样透传给浏览器
--
-- 安全约定：
--   * 授权码与口令只从 POST body 取（http.formvalue），绝不拼进 URL 查询串，
--     否则会被 uhttpd 的访问日志完整记录。
--   * 远端文件名只允许 [A-Za-z0-9._-]，首字符必须是字母数字（排除 . / .. /
--     前导 -）；与 cloud.sh 的 cloud_valid_remote_name() 同口径。
--   * 本地目标永远落在 backup.sh 报告的备份目录内，文件名再过一次 SAFE_NAME。
local CLOUD      = "/usr/libexec/openclaw/cloud.sh"
local SAFE_REMOTE = "^[A-Za-z0-9][A-Za-z0-9._-]*$"


-- cloud.sh 的 stdout 契约是「只有一行 JSON」；解析失败时把原始文本带回前端，
-- 至少让用户看到真实的报错，而不是一句笼统的失败。
local function cloud_json(raw)
	local j = jsonc.parse(raw)
	if type(j) ~= "table" then return nil end
	return j
end

local function cloud_reply(raw, extra)
	local j = cloud_json(raw)
	if not j then
		out({ ok = false, error = "后端返回无法解析", data = raw })
		return
	end
	local r = { ok = j.ok == true, error = j.error, data = j }
	if j.ok == true and extra then
		for k, v in pairs(extra) do r[k] = v end
	end
	out(r)
end

local function cloud_exec(args)
	return sh(CLOUD .. " " .. args)
end

-- 完整网关 token：只在这个 POST 端点回传，且响应禁止缓存。
-- api_info 里只有掩码（token_masked），所以状态页加载不再把 token 送进
-- 浏览器缓存；用户点「打开控制台」时才现取一次。
function api_token()
	-- 响应头必须在 out() 之前设置：out() 里的 prepare_content() 会立刻
	-- 刷出响应头，之后再调 header() 是空操作。
	http.header("Cache-Control", "no-store")
	if not is_post() then
		out({ ok = false, error = "请使用 POST 提交" })
		return
	end
	local tok = sh(SH .. " token")
	if tok == "" then
		out({ ok = false, error = "未找到网关 token（服务可能未安装或尚未启动）" })
		return
	end
	out({ ok = true, token = tok })
end

-- 口令 / 授权码的 stdin 通道：0600 私有文件 + shell 重定向，调用方负责删除。
-- 文件名带时间戳 + 进程内序号 + 随机数，避免并发请求互相覆盖。
local stdin_seq = 0
local function write_private(text)
	if not need_dir() then return nil end
	stdin_seq = stdin_seq + 1
	local tmp = RUNDIR .. "/stdin-" .. os.date("%Y%m%d%H%M%S") .. "-"
		.. tostring(stdin_seq) .. "-" .. tostring(math.random(100000, 999999))
	-- 先用 umask 077 建空文件，再打开写入：避免出现「先 0644 后 chmod」的窗口。
	-- io.open("wb") 只截断、不改权限，所以建好之后模式一直是 0600。
	os.execute("( umask 077; : > " .. q(tmp) .. " ) 2>/dev/null")
	local fh = io.open(tmp, "wb")
	if not fh then return nil end
	local ok = fh:write(text) and fh:close()
	if not ok then
		os.remove(tmp)
		return nil
	end
	-- 兜底：建文件那一步失败时（目录不可写等）io.open 可能新建 0644 文件。
	os.execute("chmod 600 " .. q(tmp) .. " 2>/dev/null")
	return tmp
end

local function cloud_exec_stdin(args, text)
	local tmp = write_private(text)
	if not tmp then return '{"ok":false,"error":"临时目录不可用"}' end
	local raw = sh(CLOUD .. " " .. args .. " < " .. q(tmp))
	os.remove(tmp)
	return raw
end

-- 备份目录：与 api_backup_download() 同样的校验口径（绝对路径、无空白、无 ..）。
local function backup_dir()
	local dir = sh(SH .. " backup-path")
	if dir == "" or dir:find("%s") or dir:sub(1, 1) ~= "/" or dir:find("%.%.") then
		return nil
	end
	return dir
end

local function file_exists(p)
	return sh("if [ -e " .. q(p) .. " ] || [ -L " .. q(p) .. " ]; then echo 1; fi") == "1"
end

function api_cloud_status()
	cloud_reply(cloud_exec("status"))
end

function api_cloud_install()
	-- 会下载并执行安装器，只接受 POST（避免被 <img src> 之类的跨站 GET 触发）。
	if not is_post() then
		out({ ok = false, error = "请使用 POST 提交" })
		return
	end
	cloud_reply(cloud_exec("install-cli"))
end

-- 版本号只允许 x.y.z：它会作为参数拼进 shell 命令，虽然 q() 已经转义，
-- 这里仍然按白名单拒绝掉奇怪的值（与 cloud.sh 的校验互为两道防线）。
local CLOUD_VER_RE = "^[0-9]+%.[0-9]+%.[0-9]+$"

function api_cloud_install_bg()
	if not is_post() then
		out({ ok = false, error = "请使用 POST 提交" })
		return
	end
	local ver = http.formvalue("version") or ""
	-- formvalue 遇到 version[]=... 会返回 table；先拒掉，避免 trim 抛错变成 500。
	if type(ver) ~= "string" then
		out({ ok = false, error = "版本号格式不正确（应为 x.y.z）" })
		return
	end
	ver = util.trim(ver)
	if ver ~= "" and not ver:match(CLOUD_VER_RE) then
		out({ ok = false, error = "版本号格式不正确（应为 x.y.z）" })
		return
	end
	local args = "install-cli-bg"
	if ver ~= "" then
		args = args .. " " .. q(ver)
	end
	cloud_reply(cloud_exec(args))
end

function api_cloud_install_poll()
	cloud_reply(cloud_exec("install-cli-poll"))
end

function api_cloud_login_url()
	cloud_reply(cloud_exec("login-url"))
end

function api_cloud_login_code()
	if not is_post() then
		out({ ok = false, error = "请使用 POST 提交授权码" })
		return
	end
	local code = http.formvalue("code") or ""
	-- 前端已校验一次；这里是服务端防线（cloud.sh 里还有一次）。
	if #code < 4 or #code > 64 or not code:match("^[A-Za-z0-9_-]+$") then
		out({ ok = false, error = "授权码格式不正确（只允许字母、数字、_ 和 -，长度 4-64）" })
		return
	end
	cloud_reply(cloud_exec("login-code " .. q(code)))
end

function api_cloud_logout()
	cloud_reply(cloud_exec("logout"))
end

-- 上传：只接受「本机备份目录里的文件名」，不接受任意本地路径。
-- 这样即使前端被篡改，也无法把 /etc/shadow 之类的东西传到网盘。
function api_cloud_upload()
	if not is_post() then
		out({ ok = false, error = "请使用 POST 提交" })
		return
	end
	local file = http.formvalue("file") or ""
	if not file:match(SAFE_NAME) or not file:match("%.tar%.gz$") then
		out({ ok = false, error = "非法的备份文件名" })
		return
	end
	local dir = backup_dir()
	if not dir then
		out({ ok = false, error = "备份目录不可用" })
		return
	end
	local path = dir .. "/" .. file
	if not file_exists(path) then
		out({ ok = false, error = "本地备份不存在：" .. file })
		return
	end
	-- 远端名默认与本地同名；显式指定时同样走白名单。
	local remote = http.formvalue("remote")
	if remote == nil or remote == "" then remote = file end
	if #remote > 128 or not remote:match(SAFE_REMOTE) then
		out({ ok = false, error = "非法的云端文件名" })
		return
	end
	if remote:sub(-4) == ".enc" then
		-- 该后缀由 cloud.sh 在加密上传时自行追加，明文上传不能占用。
		out({ ok = false, error = "云端文件名不能以 .enc 结尾（该后缀保留给加密备份）" })
		return
	end
	cloud_reply(cloud_exec("upload " .. q(path) .. " " .. q(remote)))
end

function api_cloud_ls()
	cloud_reply(cloud_exec("ls"))
end

function api_cloud_rm()
	if not is_post() then
		out({ ok = false, error = "请使用 POST 提交" })
		return
	end
	local name = http.formvalue("name") or ""
	if #name > 128 or not name:match(SAFE_REMOTE) then
		out({ ok = false, error = "非法的云端文件名" })
		return
	end
	cloud_reply(cloud_exec("rm " .. q(name)))
end

-- 下载：落到本机备份目录，成功后前端可以直接复用 api_restore。
--   * 明文备份：cloud.sh download
--   * .enc 备份：cloud.sh download-dec，口令只走 stdin
-- cloud.sh 拒绝覆盖已存在的目标文件，这里先给出更明确的提示。
function api_cloud_download()
	if not is_post() then
		out({ ok = false, error = "请使用 POST 提交" })
		return
	end
	local name = http.formvalue("name") or ""
	if #name > 128 or not name:match(SAFE_REMOTE) then
		out({ ok = false, error = "非法的云端文件名" })
		return
	end
	local encrypted = name:sub(-4) == ".enc"
	local target = name
	if encrypted then target = name:sub(1, -5) end
	-- 下载后要交给 backup.sh restore，名字必须是它认得的 .tar.gz。
	if not target:match(SAFE_NAME) or not target:match("%.tar%.gz$") then
		out({ ok = false, error = "云端文件名不是 .tar.gz 备份" })
		return
	end
	local dir = backup_dir()
	if not dir then
		out({ ok = false, error = "备份目录不可用" })
		return
	end

	-- cloud.sh 拒绝覆盖已存在的目标文件。云端备份通常就是从本机传上去的，
	-- 同名文件几乎一定还在本地，所以这里主动换一个不冲突的名字：
	--   openclaw-x.tar.gz -> cloud-openclaw-x.tar.gz（仍以 .tar.gz 结尾，
	--   backup.sh restore 认得）。仍然冲突时再追加序号。
	local dest_name, dest
	local stem = target:sub(1, -8)          -- 去掉 .tar.gz
	for i = 0, 50 do
		local cand = (i == 0) and ("cloud-" .. target)
			or ("cloud-" .. stem .. "-" .. i .. ".tar.gz")
		if #cand <= 128 and cand:match(SAFE_NAME) then
			if not file_exists(dir .. "/" .. cand) then
				dest_name, dest = cand, dir .. "/" .. cand
				break
			end
		end
	end
	if not dest then
		out({ ok = false, error = "备份目录里同名文件过多，请先清理本地备份" })
		return
	end

	local pass = http.formvalue("pass") or ""
	if pass:find("[%c]") then
		out({ ok = false, error = "口令不能包含换行或控制字符" })
		return
	end
	if #pass > 128 then
		out({ ok = false, error = "口令过长" })
		return
	end

	local raw
	if encrypted then
		-- 空口令表示「使用本机已保存的口令」，由 cloud.sh 回退。
		raw = cloud_exec_stdin("download-dec " .. q(name) .. " " .. q(dest), pass .. "\n")
	else
		raw = cloud_exec("download " .. q(name) .. " " .. q(dest))
	end
	cloud_reply(raw, { file = dest_name })
end

function api_cloud_pass_status()
	cloud_reply(cloud_exec("pass-status"))
end

function api_cloud_pass_set()
	if not is_post() then
		out({ ok = false, error = "请使用 POST 提交" })
		return
	end
	local pass = http.formvalue("pass") or ""
	if #pass < 8 or #pass > 128 then
		out({ ok = false, error = "口令长度必须为 8-128 个字符" })
		return
	end
	if pass:find("[%c]") then
		out({ ok = false, error = "口令不能包含换行或控制字符" })
		return
	end
	if pass:match("^%s*$") then
		out({ ok = false, error = "口令不能全是空格" })
		return
	end
	cloud_reply(cloud_exec_stdin("set-pass", pass .. "\n"))
end

function api_cloud_pass_clear()
	if not is_post() then
		out({ ok = false, error = "请使用 POST 提交" })
		return
	end
	cloud_reply(cloud_exec("clear-pass"))
end

-- 上传前加密开关：是否加密由 UCI 的 main.cloud_encrypt 决定，口令只是必要条件。
-- 这里只读/写开关本身，绝不读取或回传口令。
function api_cloud_encrypt_status()
	cloud_reply(cloud_exec("encrypt-status"))
end

function api_cloud_encrypt_set()
	if not is_post() then
		out({ ok = false, error = "请使用 POST 提交" })
		return
	end
	local v = http.formvalue("enabled") or ""
	-- 只接受 "0"/"1"：其它值一律拒绝，不做"看起来像真值"的宽松解释。
	if v ~= "0" and v ~= "1" then
		out({ ok = false, error = "enabled 只能是 0 或 1" })
		return
	end
	-- 与 schedule-set 同一套 stdin 写法：0600 私有临时文件 + shell 重定向，
	-- 值不进 argv / URL。
	cloud_reply(cloud_exec_stdin("set-encrypt", v .. "\n"))
end

-- 只读：给界面回填当前定时设置。写入口在下面的 api_cloud_schedule_set。
function api_cloud_schedule_status()
	cloud_reply(cloud_exec("schedule-status"))
end

-- ------------------------------------------------- 组件检查更新 / 更新组件
-- cli-check 只探测官方 CDN 上的可用版本（不下载、不安装），因此允许 GET；
-- cli-update 会下载并执行安装器，必须 POST。
function api_cloud_cli_check()
	cloud_reply(cloud_exec("cli-check"))
end

-- 版本号先按形状白名单校验，再经 q() 单引号转义交给 shell。
-- Lua 模式里 % 是转义符：%% 表示字面量 %，%- 表示字面量 -。
-- 与需求给定的 ^[0-9A-Za-z._%-]+$ 等价（字母、数字、. _ % -，长度 1-32）；
-- cloud.sh 的 cloud_version_valid() 还会再收一次（它不接受 %），非法值
-- 最终由后端拒绝，且始终经过 q() 转义，不会改变命令结构。
local CLI_VER = "^[0-9A-Za-z._%%%-]+$"

function api_cloud_cli_update()
	if not is_post() then
		out({ ok = false, error = "请使用 POST 提交" })
		return
	end
	local ver = http.formvalue("version") or ""
	local args = "cli-update"
	if ver ~= "" then
		if #ver > 32 or not ver:match(CLI_VER) then
			out({ ok = false, error = "版本号不合法（只允许字母、数字与 . _ -，长度 1-32）" })
			return
		end
		args = args .. " " .. q(ver)
	end
	-- 下载 + 安装约 14 MB，可能超过 uhttpd 的请求超时；前端按长任务处理。
	cloud_reply(cloud_exec(args))
end

-- ---------------------------------------------------------------- 定时备份
-- schedule-set 从 stdin 读 "key=value" 行。六个字段在控制器侧逐个校验，
-- 与 cloud.sh 的 cloud_sched_check() 保持同一口径（严格十进制整数 + 区间），
-- 任一不合法就直接返回，绝不把半套参数交给后端。
--
-- 数值字段先过 ^%d+$ 再做 tonumber()：Lua 5.1 的 tonumber 会接受 "0x1F"、
-- " 5 "、"5.0" 这类写法，只靠区间判断会把它们放过去。
local SCH_NUM = {
	weekday = { 0, 6 },
	hour    = { 0, 23 },
	minute  = { 0, 59 },
	keep    = { 1, 30 },
}

local function sch_int(key, v)
	if type(v) ~= "string" or #v == 0 or #v > 3 or not v:match("^%d+$") then
		return nil
	end
	local n = tonumber(v)
	local lo, hi = SCH_NUM[key][1], SCH_NUM[key][2]
	if not n or n < lo or n > hi then return nil end
	return n
end

function api_cloud_schedule_set()
	if not is_post() then
		out({ ok = false, error = "请使用 POST 提交" })
		return
	end

	local enabled = http.formvalue("enabled") or ""
	if enabled ~= "0" and enabled ~= "1" then
		out({ ok = false, error = "参数不合法：enabled" })
		return
	end

	local period = http.formvalue("period") or ""
	if period ~= "daily" and period ~= "weekly" then
		out({ ok = false, error = "参数不合法：period" })
		return
	end

	local nums = {}
	for _, key in ipairs({ "weekday", "hour", "minute", "keep" }) do
		local n = sch_int(key, http.formvalue(key))
		if n == nil then
			out({ ok = false, error = "参数不合法：" .. key })
			return
		end
		nums[key] = n
	end

	-- 逐行 key=value，与 cloud.sh 的解析格式一致；值全部来自上面的白名单，
	-- 不含换行 / 控制字符，因此不可能注入额外的键。
	local text = table.concat({
		"enabled=" .. enabled,
		"period=" .. period,
		"weekday=" .. nums.weekday,
		"hour=" .. nums.hour,
		"minute=" .. nums.minute,
		"keep=" .. nums.keep,
	}, "\n") .. "\n"

	-- 复用已有的 stdin 通道：私有 rundir 下 0600 临时文件 + shell 重定向，
	-- 用完立刻删除（cloud_exec_stdin 内部负责）。
	cloud_reply(cloud_exec_stdin("schedule-set", text))
end

-- ---------------------------------------------------------------- export
-- 诊断包下载。openclaw.sh export 会把脱敏后的 tar.gz 写到
-- /tmp/luci-app-openclaw-diag-<ts>.tar.gz，stdout 只有一行 JSON：
--   {"ok":true,"path":"...","size":N} / {"ok":false,"error":"..."}
-- 这里只负责调用、解析路径、回传文件；export 子命令本身不改。
-- EXPORT_CHUNK 在文件前部的常量区声明（下载与导出共用），
-- 这里不再重复 local：重复声明会让前面的使用点拿到另一份 nil。

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

-- ---------------------------------------------------------------- 入口守卫
-- 写操作必须 POST。此前 56 个端点里只有 13 个自己调 is_post()，其余
-- （install / service / save / run / restore / backup_* / diag_run …）用 GET
-- 就能触发：管理员登录着 LuCI 时，任意第三方页面一个 <img src> 就能让设备
-- 还原备份、装任意 npm 包。
--
-- 为什么不在 index() 里写 call(guarded(...))：**call() 只接受字符串函数名**。
-- LuCI 的实现是 `local func = getfenv()[self.name]`，传函数对象会得到 nil，
-- assert 直接抛异常 —— 那样每个接口都 500（1.8.28~1.8.30 的真实故障）。
-- 正确做法是注册仍用 call("api_xxx")，在这里把环境里的同名函数换成守卫版。
local function _install_guards()
	local env = getfenv(1)
	local names = {}
	for k, v in pairs(env) do
		if type(k) == "string" and type(v) == "function" then
			local short = k:match("^api_([a-z_]+)$")
			if short then names[#names + 1] = { k, short, v } end
		end
	end
	-- 先收集再替换：pairs 迭代期间修改表是未定义的。
	for _, e in ipairs(names) do
		env[e[1]] = guarded(e[2], e[3])
	end
	return #names
end

API_GUARDED_COUNT = _install_guards()
