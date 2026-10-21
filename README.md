# luci-app-openclaw — OpenClaw 助手 for OpenWrt

在 OpenWrt 上原生安装、启动并管理 **官方 OpenClaw**（npm 包 `openclaw`，非魔改版），
内置 **DeepSeek** 与 **Z.AI（GLM / 智谱）** 默认模型。

LuCI 入口：**服务 → OpenClaw 助手**（`/cgi-bin/luci/admin/services/openclaw`）。

## 与 iStoreOS 自带的 luci-app-openclawmgr 完全独立

本包**不复用** iStoreOS 应用商店里 `luci-app-openclawmgr` 的任何标识或路径，
两者可以同时安装、互不干扰：

| 项目 | iStoreOS luci-app-openclawmgr | 本包 |
| --- | --- | --- |
| 包名 | `luci-app-openclawmgr` | `luci-app-openclaw` |
| UCI 配置 | `/etc/config/openclawmgr`（段 `openclawmgr`） | `/etc/config/openclaw`（段 `openclaw`） |
| procd 服务 | `/etc/init.d/openclawmgr` | `/etc/init.d/openclaw` |
| 主脚本 | `/usr/libexec/istorec/openclawmgr.sh` | `/usr/libexec/istorec/openclaw.sh` |
| 脚本目录 | `/usr/libexec/openclawmgr/` | `/usr/libexec/openclaw/` |
| 运行用户 | `openclawmgr` | `openclaw` |
| 运行目录 | `/tmp/.openclaw` | `/tmp/.openclaw` |
| 日志 | `/var/log/openclawmgr*.log` | `/var/log/openclaw*.log` |
| 默认数据目录 | `/mnt/data/OpenClawMgr` | `/mnt/data/OpenClaw` |

因此**不需要** `replaces` / `conflicts` 声明，也不会出现
`trying to overwrite ... owned by` 之类的文件冲突。两者的 Node 运行时、
OpenClaw 程序与数据各自独立，**默认不共享任何文件**。

> 例外：若两者指向同一个安装目录，会共用该目录下的 `openclaw.json`。
> 此时需要留意旧包写回的废弃配置键，详见下文
> [「与 iStoreOS 自带的 OpenClawMgr 共存」](#与-istoreos-自带的-openclawmgr-共存)。

> `usr/libexec/istorec/openclaw.sh` 只是为了让 iStore 能显示/控制本包而实现的
> **可选**接口；不装 iStore 也完全可用。

## 兼容性

| OpenWrt / iStoreOS | 包管理器 | 该装哪个产物 |
| --- | --- | --- |
| **25.12 及更新**（含 iStoreOS 25.12.x） | apk-tools **3.x** | `luci-app-openclaw-<ver>-r<rel>.apk`（**APK v3 / ADB 容器**） |
| 24.10 及更早（含 iStoreOS ≤ 24.10） | opkg | `luci-app-openclaw_<ver>_all.ipk` |
| Alpine 类 | apk-tools 2.x | `luci-app-openclaw-<ver>-r<rel>-v2.apk`（OpenWrt 用不到） |
| 任意 | — | `luci-app-openclaw-<ver>.run`（自解压，不需要包管理器） |

> **选错格式会直接装不上**：OpenWrt 正式版**从未**使用过 apk 2.x —— 24.10 及更早是 opkg，
> 25.12 起直接换到 apk-tools 3.x。所以 `-v2.apk` 对 OpenWrt 没有目标平台，
> 装它会报 `unexpected end of file`。

### OpenWrt 25.12 的三处关键适配

1. **APK v3 包格式**：25.12 起 OpenWrt 换成 apk-tools 3.x，包体从「三段 gzip」改为
   **ADB 容器**（magic `ADB`，内含 `pckg` schema）。`scripts/apk3.py` 是纯 Python 的 APK v3
   写出器，无需 `apk mkpkg`；产物已用 `adumpk` 与实际官方 25.12 包做过结构对齐
   （根目录 `""`、所有中间目录逐一列出、`PKGINFO HASHES = SHA256(payload|hashes=0)[:20]`）。
2. **Lua 运行时依赖**：25.12 的 LuCI 全面 ucode 化，`luci-base` 不再自带 Lua 桥接。
   因此依赖显式加上 **`luci-lua-runtime` + `luci-compat`**，控制器仍放在
   `/usr/lib/lua/luci/controller/openclaw.lua`，由 `dispatcher.uc` 的 Lua bridge 加载。
3. **opkg / apk 双兼容**：`lib.sh` 提供 `oc_pkg_install_hint()`，运行时自动按
   `apk` / `opkg` 输出正确的安装命令。

### glibc 支持：**不支持（已确认不可行）**

OpenWrt 官方源（24.10 / 25.12 的 base、packages、luci、routing、telephony、video）以及上游
`openwrt/packages` 中**均不存在** `gcompat` / `glibc` / `libc6-compat`，因此没有可用的 glibc 运行库。
OpenClaw 与 Node.js 统一使用 **musl** 运行时（Node 取 `unofficial-builds.nodejs.org` 的
`linux-x64-musl` / `linux-arm64-musl` 构建）。

## 功能对照

| 能力 | 本实现 |
| --- | --- |
| 原生部署（procd + Node/npm，非 docker） | ✅ `/etc/init.d/openclaw` |
| 安装路径可选（自动检测挂载盘与剩余空间） | ✅ 设置页列出挂载点 + 手动输入，安装前写入探针与空间检查 |
| 在线安装运行环境 | ✅ 一键拉取 Node.js + npm 安装 OpenClaw，实时日志 |
| 端口 / 绑定模式 | ✅ 18789，bind: loopback / lan / auto / tailnet / custom |
| 网关 token 与 Web 控制台入口 | ✅ 状态页直接带 `#token=` 打开 |
| 微信渠道插件 | ✅ 官方 `@tencent-weixin/openclaw-weixin-cli`（含前置检查） |
| 命令行页面 | ✅ 任意 `openclaw <子命令>` |
| 日志 / doctor 体检 | ✅ 含 `doctor --fix` 一键修复 |
| 程序目录固定为 `<安装目录>/openclaw` | ✅ 页面上只读；分离存放需 SSH 写 UCI |
| 一键备份与恢复 | ✅ 归档逐条安全校验 + 还原前自动快照 |
| UCI 配置 `openclaw.main.*` | ✅ `base_dir`、`openclaw_dir`、`port`、`bind`、`enabled` … |
| istorec 接口 `install/start/stop/status/port/token` | ✅ `/usr/libexec/istorec/openclaw.sh`（**可选**，供 iStore 显示与控制） |

## 稳定性设计（对齐 iStoreOS 并修正其缺陷）

首要目标是「跑得稳」。本包独立实现，并参考 iStoreOS 的稳定性经验修正已知缺陷。

### 借鉴 iStoreOS（保留）

| 机制 | 作用 |
| --- | --- |
| `validate_base_dir` | 拒绝在 `/root/*`、`/usr`、`/etc`、`/tmp`、`/var`、`/overlay`、`/rom` 等系统路径上操作 |
| `acquire_lock` + 陈旧检测 | `/tmp/.openclaw/lock`（mkdir 原子锁），持有者进程已退出则自动清理 |
| `ensure_safe_port` | 拒绝 `<=1024` 的特权端口 |
| 下载进度 + 卡死检测 | curl 后台下载，定期汇报；60s 无进展即判定停滞并报错，而不是无限挂着 |
| 缓存校验 `cached_node_archive_ok` | 复用已下载的 Node 压缩包前先 `xz -t` / `tar -tJf` 校验，损坏则重下 |
| `check_space_mb` | 下载前检查目标分区剩余空间 |
| `--allow-unconfigured` | 允许网关在未完成初始化时先起来再配置 |
| 条件化 `--force` | 仅当端口 `>1024` 且系统有 `lsof`/`fuser` 时才加 `--force`，避免端口冲突检查被跳过 |

### 修正 iStoreOS（本版优化）

| iStoreOS 的问题 | 本版做法 |
| --- | --- |
| `stop_service` 用 `pgrep -f openclaw \| kill -9` —— 会误杀同名进程（含用户自己的 openclaw） | 只删 pidfile 并交回 procd，不做模糊匹配强杀 |
| Node 压缩包缓存放在 `/tmp` —— OpenWrt 的 tmpfs 就是内存，几百 MB 直接吃 RAM | 缓存改到 `$BASE_DIR/cache/`，落在数据盘 |
| doctor / repair 同步执行 —— 耗时数分钟，LuCI 请求超时，按钮一直转 | 异步化：`diag-run <name>` 启动 + `diag-poll <name>` 轮询，2s 一次，实时回传已产生的输出 |
| 诊断进程被杀后锁残留，UI 永远显示「运行中」 | 记录 worker 真实 pid（`$!`，不是 `$$`）+ 时间戳；超过 900s 或进程已死则回收锁，`poll` 返回 `rc=124` 并附已有输出 |
| 无防重入 | 所有变更命令（install/start/restart/update/uninstall/repair/doctor --fix）统一取锁，两次点击不会重叠 |
| 日志写在只读 `/var/log` 时报错中断 | `oc_log()` 先输出，仅在目录存在且可写时才落文件 |

另外：`oc_warn()` / `oc_err()` 一律走 **stderr**，避免日志行混进 `info` / `diag-poll` / `install-status` 的 JSON 负载导致 LuCI 解析失败。

## 安全加固

代码审计发现并已修复的问题（均以「假设 LuCI 的管理员凭据可能被滥用」为前提）：

| # | 问题 | 危害 | 修复 |
| --- | --- | --- | --- |
| 1 | `api_run` 把浏览器传来的 `cmd` **不加引号**拼进 shell 字符串 | 任意命令执行（root）。`cmd=status;reboot` 即可 | 首 token 白名单（20 个 openclaw 子命令）+ 每个 token 经 `q()` 单引号转义；`cmd_run` 再拦一次 `$ \` ; \| & < > ( ) { } ! \` |
| 2 | 网关 token 以 `--token <值>` 出现在命令行 | 任何本地用户读 `/proc/<pid>/cmdline` 即可拿到凭据 | 改走 `OPENCLAW_GATEWAY_TOKEN` 环境变量（官方文档等价方式，且优先级高于配置文件） |
| 3 | 临时文件用 `/tmp/openclaw-*` 固定名 | `/tmp` 是 1777，本地用户可预置符号链接 → 以 root 覆写任意文件；预置锁目录 → 管理功能全部被拒绝 | 统一迁入私有目录 `/tmp/.openclaw`（0700、属主校验、启动时回收异常条目） |
| 4 | 状态页把 `d.url` / `d.token` 拼进 `<a href>` | XSS；token 进入浏览器历史与 Referer | 只以 `textContent` 显示 URL，token 仅存在于 JS 变量 |
| 5 | 模型页把 `p.keyUrl`、渠道页把登录输出拼进 `innerHTML` | XSS（`javascript:` URL、插件输出里的标签） | 改 DOM 构建；`keyUrl` 只接受 `http(s)` 才生成链接 |
| 6 | API Key 原样写入 `.env` | 含换行的 Key 会额外注入任意环境变量行 | 校验字符集 → 剥离控制字符 → 只取首行；`.env` 权限 600 |
| 7 | 镜像源 / 代理地址未经校验交给 curl、npm | 以 `-` 开头的值会被当作命令行选项 | 新增 `oc_safe_url()`：仅接受无空白的 `http(s)`；`save` 保存时即拒绝 |
| 8 | `save` 未校验 `bind` / `enabled`；`log` 的 `lines` 未限制 | 写入非法配置 | `bind` 限 `[A-Za-z0-9_.:-]`，`enabled` 限 `0/1`，`lines` 限 1–5000 |
| 9 | `--npm-registry` / `--http-proxy` 在 `save` 里没有对应分支 | 这两项设置**从来没被保存过**（功能缺陷） | 补齐别名分支 |
| 10 | `oc_kill_tree` 用 `pgrep -f openclaw \| kill -9` | 误杀同名进程，卸载时甚至把自己杀掉 | 改为只匹配 `/proc/<pid>/cmdline` 中 argv[0] 为私有 node 且含 `gateway ` 的进程 |

### 第二轮审计（隔离审查流程 + AI 复核）追加修复

| # | 问题 | 危害 | 修复 |
| --- | --- | --- | --- |
| 11 | **`repair.sh` 在安装目录不安全时只打印 FAIL 却继续执行** | **严重**：后续对 `$BASE` 执行 `chown -R` / `chmod -R`，若 base_dir 被改成 `/etc`，「一键修复」会递归接管系统目录 | 打印 FAIL 后立即 `finish` 退出；`finish()` 也在 `FAILS>0` 时返回 1，不再把失败当成功 |
| 12 | `plugin_installed()` 的作用域包名 glob 少一层 | `lib/node_modules/*/"$plugin"` 永远匹配不到 `@scope/name`，已装插件被判未装，反复重装 | 改为直接判断 `lib/node_modules/$plugin` |
| 13 | `require_plugin()` 安装后未失效 `plugins list` 缓存 | 复检读到安装前状态，装成功却判失败并走 npm 回退 | 安装后重置缓存标志 |
| 14 | `apply()` 丢弃 `require_plugin` 的返回值 | 插件装失败仍报「已应用」 | 失败时明确告警，Key 仍写入但提示可重试 |
| 15 | `repair.sh` 用 `grep -q '"token"'` 判断 token 是否存在 | 会被 `"mode": "token"` 命中，缺 token 的配置被判正常，网关随后拒绝启动 | 改为 `'"token"[[:space:]]*:'` |
| 16 | **`api_apply` 把 API Key 作为命令行参数传给 `models.sh`** | 密钥出现在 `/proc/<pid>/cmdline`，本机任意用户可读（与第 2 项同类） | 改为经 `OC_APPLY_KEY` 环境变量传递，argv 中只出现 `-` |
| 17 | `sh()` 丢弃退出码，所有写操作无条件返回 `ok=true` | 脚本失败时前端显示「成功」，排障困难 | 新增 `run_rc()`（`sys.call` 取真实退出码），`service`/`save`/`apply` 返回真实结果；前端据此提示失败 |
| 18 | `install.sh` 用 `tee ... \| head -n 20` 输出插件安装日志 | `head` 提前关闭管道，写端收到 SIGPIPE，**插件安装被中途截断**却仍报成功 | 改为整体追加到安装日志，并检查退出码 |
| 19 | `versions.sh` 的 `check_compat` 在缓存缺失时把「未知」当「兼容」 | `engines.node` 解析不到时仍返回 `ok:true`，可能装上不满足要求的 Node.js | 先确保缓存存在；engines 仍为空则明确判失败 |
| 20 | `install.sh` 的 `--force` 是死参数 | `update --force` 实际不会强制重装 | `--force` 现在会跳过「已存在则复用」的捷径，真正重装 Node.js |
| 21 | `channels.sh` 对**对象**用 `head -n1` | 输出被截成非法 JSON 片段 | 输出完整子树，无 jsonfilter 时退化为有界切片 |
| 22 | `api_ilog` 无上限整读安装日志 | 日志随安装增长，可能耗尽内存 / 撑大响应体 | 上限 256 KiB，超出则保留尾部 |
| 23 | `_cmp_one` 的 `cf` 未声明为局部变量 | 变量泄漏到全局作用域 | 补 `local` |

> 第 11–15、18–19、21 项来自 AI 隔离审查（`tools/audit-suite.sh` 的 `models-channels` 批次），
> 第 16–17、20、22 项来自 AI 对前端控制器的复核 + 人工确认。
> 其中第 16 项与第 2 项同类——修 token 时漏掉了同一模式的 API Key。

### 第三轮审计（备份/恢复 + 新增端点，分 4 批隔离审查）

| # | 问题 | 危害 | 修复 |
| --- | --- | --- | --- |
| 24 | **`"\x1f\x8b"` 在 Lua 5.1 下是语法错误** | **严重**：`\xXX` 转义是 Lua 5.2 才有的；OpenWrt LuCI 常用 5.1，会直接加载失败 → **整个应用 500** | 改为数字比较 `data:byte(1) ~= 0x1f` |
| 25 | **还原中断 → 数据丢失窗口** | **严重**：`mv $data $old` 之后被中断，原数据只剩在 `$old`；而下一次还原会**无条件 `rm -rf $old`** 删掉唯一副本 | `$old` 带 PID；拆分 trap（EXIT 清暂存区 / 信号额外把 `$old` 挪回）；只有 `moved=1` 才删 |
| 26 | **`mv` 失败被吞** | `mv` 失败而 `$data` 仍在时，`cp -a` 会把内容嵌成 `$data/.openclaw`，还原结果静默错误 | `mv` 失败立即中止，绝不进入拷贝分支 |
| 27 | **`oc_backup_resolve` 绝对路径分支未挡 `..`** | `$OC_RUNDIR/../../etc/x` 能通过前缀匹配 → verify/restore 可作用到备份目录之外 | 绝对路径分支与纯文件名分支对称地拒绝 `..` |
| 28 | **`create --name` 缺参时死循环** | `shift 2` 越界不移位 → 挂死一个 root 进程，前端永远等不到 JSON（已实测确认） | `shift; name="${1:-}"; [ $# -eq 0 ] \|\| shift` |
| 29 | **API Key 经 `env` 仍暴露在 cmdline** | 早先改的 `env OC_APPLY_KEY=... cmd` 只是把密钥从 `models.sh` 的 argv 挪到了 `sh`/`env` 的 argv，暴露窗口一样长 | 改为写 0600 临时文件 + `--key-file`，helper 读后即删 |
| 30 | `/tmp/.openclaw` 可被预置符号链接 | 本地用户预置同名链接 → root 把上传内容写进链接指向的文件 | 先 `test -L` 探测，是链接即拒绝 |
| 31 | 归档条目名可伪造清单 | busybox tar 不转义名字，含换行的条目名会拆成两行，伪造出"看似合法"的清单行 | awk 中额外拒绝含控制字符与 ` -> ` 的条目名 |
| 32 | 固定名临时文件（`bk-list.txt`/`bk-tar.err`） | 并发实例互相踩；名字被预置成符号链接时会写穿 | 加 PID 后缀 + 写入前 `rm -f` + 用后清理 |
| 33 | 空间检查查错了文件系统 | 归档不是直接从数据目录生成，而是先 `cp -a` 到 `$OC_RUNDIR`（OpenWrt 上是 tmpfs=RAM），检查漏掉了真正会被写满的目标 | 追加暂存目录所在文件系统的剩余空间检查 |
| 34 | 备份目录 `chmod 700` 失败被静默吞掉 | 与文件级策略不一致，目录可能停在 0755 | `stat` 复核并告警 |
| 35 | `--name` 可含 `..` 造出无法引用的备份 | create 与 resolve 约束不一致，这类备份无法 verify/delete/restore | create 侧同步拒绝 |
| 36 | `api_ilog` 先整份读入内存再截断 | 与"限制内存"的初衷相反 | 改为 `seek` 后只读尾部 256KB |
| 37 | `SAFE_NAME` 过宽（`.`/`..`/前导 `-`） | 会被拼成路径穿越或被 helper 当成选项 | 收紧为首字符必须是字母数字 |
| 38 | 上传 `write`/`close` 失败被吞、同名覆盖 | 写盘失败仍报成功；同秒上传互相覆盖 | 检查返回值并清理半成品；冲突时追加序号 |
| 39 | 状态页多处错误处理缺失 | 保存/安装/诊断/上传失败时静默或按钮永久禁用；`window.open` 未校验协议 | 检查 `r.ok`、`JSON.parse` 加保护、XHR 补 `onerror`/`ontimeout`、导航目标限 `http(s)` |

> 第 24、29 项是**我自己引入的缺陷**：24 是 Lua 版本兼容性（会让整个应用挂掉），
> 29 是"修了但没修到位"——把密钥从一处 argv 挪到了另一处 argv。
> 这两条说明：AI 的复核确实能抓住人工遗漏，尤其是**跨版本的隐式假设**和**"看起来修好了"的假象**。

## 本版本新增 / 强化

### 1. 默认模型增加 DeepSeek 与 Z.AI

- `deepseek`：官方插件 `@openclaw/deepseek-provider`，默认 `deepseek/deepseek-v4-flash`，
  可选 `deepseek-v4-pro`、`deepseek-chat`、`deepseek-reasoner`。
- `zai`：OpenClaw 内置 provider（Z.AI / 智谱 GLM），默认 `zai/glm-5.3`，
  内置 19 个 GLM 模型，支持国际 / 国内 / Coding Plan 端点切换。
- 保留原有 openai、anthropic、google、moonshot、qwen、minimax、openrouter、ollama 与自定义。

### 2. 模型选择联动插件安装与 API Key（新增）

模型页的 provider 下拉直接来自 `openclaw` 自身（`models list --all` + `providers list`），
每个 provider 会标注状态标签：**内置 / 需插件 / 插件已装 / 已配置 / 已有 Key**。

点击绿色按钮 **「安装插件 · 写入 Key · 设为默认」** 一次性完成：

1. 若该 provider 需要插件且未安装 → `openclaw plugins install <plugin>`（失败自动回落
   `npm install -g --prefix <base>/openclaw`）；
2. 把 API Key 写入 `~/.openclaw/.env`（`ENVVAR=key`，权限 600）；
3. `openclaw config set models.providers.<id>.apiKey/baseUrl/api`；
4. `openclaw config set agents.defaults.model.primary <id>/<model>`；
5. 修复属主权限 → 重启网关 → 页面刷新。

模型清单三层兜底：内置精选预设 → `openclaw models list --provider <id>` 在线发现（「刷新模型列表」
按钮）→ 手动输入模型 ID。

### 3. 一键修复 + 一键 doctor（新增）

- **一键修复**（`/usr/libexec/openclaw/repair.sh`，LuCI 状态页绿色按钮）共 13 项检查：
  安装目录存在与可写 → 运行用户 → 目录重建 → Node 可运行 → openclaw 启动脚本重建
  （从 `openclaw.mjs/.js` 重新生成 shim）→ helper 脚本权限 → 配置文件损坏自动备份重建 →
  `.env` 收紧为 600 → 属主与权限 → init 脚本 enable → 端口占用 → CA 证书 → 清 LuCI 缓存 → 重启。
  支持 `--json`（LuCI 消费）与 `--no-restart`。
- **doctor 一键修复**：先跑 `openclaw doctor --fix`，再跑一遍 repair，两条链路合一。
- **doctor**（只读）：`openclaw.sh doctor` 输出体检报告。

### 4. 安装时可选 Node.js 与 OpenClaw 版本，且版本数据全部在线获取

- OpenClaw 版本列表来自 npm registry（官方包元数据，`engines.node` 一并读取），
  支持 `latest` / `extended-stable` / `beta` 与任意历史版本。
- Node.js 列表来自 `unofficial-builds.nodejs.org`（musl）或 `nodejs.org/dist`，可按架构过滤。
- **强制校验**：安装前用纯 POSIX sh 实现的 semver 解析 `engines.node`
  （支持 `>= > <= < = ^ ~` 与 `||`，如 `>=24.16.0 <25 || >=26.1.0`），
  低于要求的 Node.js 在界面中置灰禁用，命令行/后端二次校验不通过直接退出（exit 2）。
- 可切换 npm 源（npmmirror）与 Node 源镜像，可配置 HTTP 代理。

### 5. OpenClaw 使用官方包

`npm install -g openclaw@<version>`，升级只需换版本号重装，便于长期维护。

### 6. 程序目录固定为 `<安装目录>/openclaw`

程序目录已改为只读，页面上不再有下拉或输入框；分离存放时在 SSH 里 `uci set openclaw.main.openclaw_dir=<路径>` 后重新安装（旧目录不会被自动清理，安装前弹确认）。

安全约束（因为这是个会被递归接管属主、递归删除的路径）：

- 保存时用 `oc_validate_base_dir` 校验形状，拒绝系统路径、`..`、符号链接；
- 拒绝把它设成**安装目录本身或它的上级**（否则卸载会连带删掉数据）；
- 卸载与 `oc_fix_perms` 在动手前**再校验一次**（`oc_oc_dir_safe`），
  并在程序目录独立时单独补一次属主修正，否则网关（以 `openclaw` 用户运行）读不到 node_modules。

### 7. 一键备份与恢复（新增）

「备份与恢复」（顶层菜单）页提供「备份与恢复」卡片：

- 一键创建备份，可选备注名、是否包含工作区；
- 查看、下载、校验、删除历史备份；
- 可直接上传 `.tar.gz` 并恢复；恢复前自动再做一份 `pre-restore` 安全快照；
- 备份包含：`home/.openclaw`（配置、模型、渠道、会话、工作区）与 UCI 设置；
- 不包含：Node.js、OpenClaw 程序、npm/cache、日志（这些可重新安装或生成）；
- 备份含 API Key，程序尝试设置权限 `600`，若底层文件系统不支持权限收紧会明确告警；
- 恢复前逐条检查 tar：拒绝绝对路径、`..`、符号链接、硬链接、设备、FIFO、非本程序清单，
  并限制解压体积 512MB；归档先解压到私有暂存区，验证后才替换目标数据；
- 还原中断时自动清理暂存目录，避免 `/tmp` 残留占用空间。

命令行等价接口：

```sh
openclaw.sh backup [--name <备注>] [--no-workspace]
openclaw.sh backups
openclaw.sh backup-verify <文件名>
openclaw.sh backup-delete <文件名>
openclaw.sh backup-path
openclaw.sh restore <文件名> [--no-safety]
```

### 8. iStoreOS 25.12.5 / OpenWrt 25.12 安装注意事项

iStoreOS 25.12.x 基于 OpenWrt 25.12，包管理器是 **apk-tools v3**，请安装：

```sh
apk add --allow-untrusted luci-app-openclaw-1.8.8-r1.apk
```

**不要**装 `...-v2.apk` —— 那是 apk-tools 2.x / Alpine 的格式，不是 OpenWrt 25.12 的
ADB（APK v3）格式，装错会报 `unexpected end of file`。

**本包与 iStoreOS 自带的 `luci-app-openclawmgr` 完全独立**，文件路径没有任何重叠
（见开头对照表），因此：

- **不需要**先卸载 `luci-app-openclawmgr`，两者可以共存；
- 元数据里也**不再声明** `replaces` / `conflicts`，不会出现
  `trying to overwrite ... owned by` 的冲突错误；
- 两者各自安装 Node.js 与 OpenClaw，**数据目录也不同**
  （旧包 `/mnt/data/OpenClawMgr`，本包 `/mnt/data/OpenClaw`）。

如果你希望彻底不保留旧包，可以自行卸载：

```sh
apk del luci-app-openclawmgr
```

> 注意：卸载旧包**可能连带删除它自己的数据目录**。若要保留，先自行备份。

本版本同时修正了 post-install 脚本首行缺少 `#!` 导致的 `execve: Exec format error`。

### 9. 打包格式与可复现构建

三种容器格式**都对齐过官方实际产物**（不是照印象写的）：

| 产物 | 容器结构 | 对齐来源 |
| --- | --- | --- |
| `.ipk` | **`gzip(tar(./debian-binary, ./data.tar.gz, ./control.tar.gz))`** —— 注意**不是 ar 归档** | downloads.openwrt.org 的 23.05.5 / 24.10.0 包 |
| `-v2.apk` | **纯 gzip 段拼接**（control 段 + data 段；有签名则前面多一段）—— **没有 ar 容器** | dl-cdn.alpinelinux.org 的 Alpine v3.20 包 |
| `.apk` | ADB 容器（magic `ADB`，内含 `pckg` schema） | OpenWrt 25.12 官方包 |

> ipk 常被当成"和 deb 一样是 ar" —— 那是 Debian 的布局，OpenWrt 的 ipk **不是**。
> opkg 走 libarchive 两种都能读，但这里跟随上游。

**版本号**：单一来源是 `Makefile` 的 `PKG_VERSION` / `PKG_RELEASE`，
`build_apk.py` 会读取它们（`--version` / `--release` 仍可临时覆盖）。
改版本只改 Makefile，不要在脚本默认值里另写一份。

**可复现构建（有前提）**：构建时间戳统一取自 `SOURCE_DATE_EPOCH`，它会写入 APK v3 的
`builddate`、ipk control 的 `SourceDateEpoch:` 字段，以及所有 tar 成员的 mtime。
**只有同时满足下列条件**，同一份源码两次构建才会得到逐字节一致的产物：

- **设置了 `SOURCE_DATE_EPOCH`**（固定时间戳）。未设置时会退化为取 `root/` + `luasrc/`
  下最新的文件 mtime —— 该值随文件修改时间变化，**跨克隆、换机器、重新 checkout 都不成立**。
- **不加 `--sign`**。签名走 RSA，`openssl genrsa` 每次都会生成新密钥，因此签名版
  `-v2-signed.apk` 天然不可复现；要复现签名产物，必须复用已存在的 `dist/keys/`。
- **相同的 Python / tarfile / zlib 版本**：tar 元数据与 gzip 压缩结果由它们决定。

满足以上条件时，产物 hash 才稳定，校验 MD5 / SHA256 才有意义。

```sh
# 固定时间戳（可复现，推荐）
SOURCE_DATE_EPOCH=1700000000 python3 scripts/build_apk.py

# 用源码最新 mtime（默认行为，跨环境不可复现）
python3 scripts/build_apk.py
```

### 10. 菜单结构与多渠道支持

- **父菜单**：状态 / 设置（基础、安装、迁移、模型、渠道、更新说明）/ **备份与恢复** / 命令行 / 日志。备份与恢复保持顶层菜单，不放进「设置」子菜单；「检测到已有 OpenClaw 安装」独立为「迁移」页（只提供迁移，统一在本插件自己的目录下运行）。
- **状态页**：概览条 + 设备配对一键批准；修复按钮收敛为「体检」与「一键修复」（含 `doctor --fix`）；**设置页**拆成多张卡片，模型页按 Base URL 实时拉取上游模型列表（仅自定义 provider 可见）。
- **多渠道支持**：渠道页统一管理 **Telegram、飞书、Discord、Slack、微信、钉钉、QQ**
  共 7 个平台，可启用渠道、登录并填写凭据；凭据经 0600 临时文件传递，页面不回填明文。

### 11. 系统命令行入口与 unlock

- `/usr/bin/openclaw` 透传真实 CLI，root 调用自动降权到服务用户，SSH 里改的配置与服务同源。
- `openclaw.sh unlock` 清理陈旧操作锁（安装中断后 UI 一直显示「运行中」）；锁存活判定已加固，僵尸进程 / pid 复用不再误判，仍有操作在跑时拒绝执行。

### 12. 百度网盘云备份（新增）

「备份与恢复」页按三步引导完成，任何一步都可单独重做：

1. **安装网盘组件** —— 按设备架构（`aarch64` → arm64、`x86_64` → amd64）自动下载对应的
   静态二进制，约 14 MB，解压后放在数据盘的组件目录里，不依赖 glibc，也不需要额外装依赖。
2. **登录百度账号** —— 点「获取授权链接」打开百度授权页，授权后复制页面给出的授权码
   粘贴回页面完成登录。**授权链接 10 分钟内有效**，过期重新获取即可。登录态保存在私有
   HOME 目录，本插件不会读取或显示其中的 access_token。
3. **备份 / 恢复** —— 手动备份到网盘，或开启定时备份；恢复时从云端列表里选择备份下载回来。

要点：

- **备份范围**：配置 + 会话 + 工作区（与本地备份一致），**不含** OpenClaw 程序与 Node.js 运行时，
  因此归档很小，适合放网盘。
- **口令加密**：可设置口令，上传前用 **AES-256-GCM** 加密，云端只存密文（文件名追加 `.enc`）。
  口令**只保存在本机**（0600 私有文件），插件**不会把口令保存到网盘**；
  **口令丢失后备份无法恢复**，请自行另存。
- **定时备份**：可设每天 / 每周、具体时间与保留份数（1–30）。计划写入系统 crontab，
  只维护一行且行尾带 `# openclaw-cloud` 标记，**不碰其它行**；轮转清理时也只删符合
  `openclaw-*.tar.gz[.enc]` 命名规则的备份，其它文件一律不动。
- 定时任务与安装 / 修复 / 还原共用同一把操作锁，不会重叠执行；失败只记日志，不阻塞后续计划。

## 安装

### apk（OpenWrt 25.12+ / apk-tools 3.x）

```sh
apk add --allow-untrusted luci-app-openclaw-1.8.8-r1.apk
```

### ipk（opkg）—— **OpenWrt 24.10 及更早、iStoreOS 等 opkg 系统**

```sh
opkg install luci-app-openclaw_1.8.8_all.ipk
```

在 LuCI / iStore 界面里也可以直接「手动上传安装」这个 ipk。

### ⚠️ apk v2（apk-tools 2.x）—— OpenWrt 用不到，别装

`luci-app-openclaw-<ver>-r<rel>-v2.apk` 是 apk-tools **2.x** 的格式（Alpine 系）。

**OpenWrt 从未在正式版使用过 apk 2.x**：

| 版本 | 包管理器 | 该装哪个 |
| --- | --- | --- |
| 24.10 及更早 / iStoreOS | **opkg** | `.ipk` |
| 25.12 及更新 | apk-tools **3.x**（ADB 容器） | `.apk`（不带 `-v2`） |

装 `-v2.apk` 会得到 `unexpected end of file` 一类的解析错误：它的 control 段里是
`.PKGINFO`（apk 格式），而 opkg 要的是 `./control`，两边对不上。

（该格式仍然生成，仅供 Alpine 类系统使用；OpenWrt 用户请忽略它。）

### .run 自解压（无需包管理器）

```sh
sh luci-app-openclaw-1.8.8.run
```

### 集成到固件 / SDK 编译

```sh
echo "src-git openclaw <本仓库地址>" >> feeds.conf.default
./scripts/feeds update -a && ./scripts/feeds install -a
make menuconfig   # LuCI → 3. Applications → luci-app-openclaw
make package/luci-app-openclaw/compile V=s
```

### 自行生成安装包（无需 SDK）

```sh
python3 scripts/build_apk.py --version 1.8.8 --release 1 --sign
python3 scripts/verify_apk.py dist/*.apk dist/*.ipk   # 结构自检（v3 / v2 / ipk）
```

### 与 iStoreOS 自带的 OpenClawMgr 共存

本插件（`luci-app-openclaw`）与 iStoreOS 自带的 `luci-app-openclawmgr` **完全独立**：
UCI 配置分别是 `/etc/config/openclaw` 与 `/etc/config/openclawmgr`，服务名与数据目录
也不同，两者可以同时安装。

**但它们可能共用同一份 `openclaw.json`**（位于 `<安装目录>/home/.openclaw/`）。
旧版 openclawmgr 的 `ensure_gateway_config` 每次启动、停止、安装或打开管理页，都会写入
`gateway.controlUi.allowInsecureAuth`、`dangerouslyDisableDeviceAuth`、
`dangerouslyAllowHostHeaderOriginFallback` 这三个键。

OpenClaw 2026.10 起已删除这三个键。配置里只要出现任意一个，整份配置就会被判为无效
（`Unrecognized key`），**网关拒绝启动**。手动删掉一次没有用 —— 下次打开 openclawmgr
的管理页又会被写回来。

本插件会在安装和「一键修复」时自动检测并清理这三个键（仅在已安装
OpenClaw >= 2026.10.0 时执行，清理前会备份成 `openclaw.json.legacy.bak.<时间戳>`）。

如果网关仍然起不来，请查看 `<安装目录>/home/.openclaw/openclaw.json` 里是否还有这三个键；
也可以先停用 openclawmgr，再启动本插件的服务。

## 使用

1. LuCI → 服务 → **OpenClaw 助手** →「设置」：选择安装目录、OpenClaw 版本、Node.js 版本 → 安装。
2. 安装完成后回到「状态」页，点击「打开控制台」（自动带 token）。
3. 「模型」页选择 `DeepSeek` / `Z.AI` 等，填 Key → 一键安装插件并设为默认。
4. 出问题时点「体检」或「一键修复」（后者含 `doctor --fix`）。
5. 「渠道」页安装微信插件；「命令行」页可执行任意 openclaw 子命令。
6. 也可以在 SSH 里直接用 `/usr/bin/openclaw <子命令>`，与「命令行」页等价。

### 命令行

```sh
openclaw.sh info                       # JSON 状态
openclaw.sh versions                   # 在线版本清单
openclaw.sh check 2026.10.3 24.16.0    # 校验 Node 是否满足 engines
openclaw.sh install --oc-version latest --node-version auto --base-dir /mnt/sda1/OpenClaw
openclaw.sh install-bg ...             # 后台安装（LuCI 使用）
openclaw.sh start|stop|restart|status|port|token
openclaw.sh repair [--json] [--no-restart]    # 一键修复
openclaw.sh doctor [--fix]                    # 体检 / 一键修复
openclaw.sh diag-run doctor|doctor-fix|repair # 后台启动诊断（LuCI 使用）
openclaw.sh diag-poll repair                  # {"done":bool,"rc":"0","output":".."}
openclaw.sh models catalog|presets|apply deepseek sk-xxx deepseek-v4-flash
openclaw.sh channels weixin install|weixin login
openclaw.sh run plugins list
openclaw.sh unlock                            # 清理陈旧操作锁
```

## 目录结构

```
Makefile                                  OpenWrt 包定义（feeds / SDK）
luasrc/controller/openclaw.lua            LuCI 路由 + JSON API
luasrc/view/openclaw/*.htm                状态、设置（基础/安装/迁移/模型/渠道/更新说明）、备份与恢复、命令行、日志
root/usr/bin/openclaw                    系统命令行入口（透传 CLI，root 自动降权）
root/etc/config/openclaw                 UCI 默认配置（独立）
root/etc/init.d/openclaw                 procd 服务
root/etc/uci-defaults/99-openclaw        首次安装初始化（用户、目录、默认挂载点）
root/usr/libexec/istorec/openclaw.sh      可选 iStore 控制接口
root/usr/libexec/openclaw/lib.sh       公共库（semver / engines 解析、下载、日志）
root/usr/libexec/openclaw/versions.sh  在线版本发现与兼容性校验
root/usr/libexec/openclaw/install.sh   安装流程
root/usr/libexec/openclaw/models.sh    模型目录、插件安装、Key 写入、设为默认
root/usr/libexec/openclaw/repair.sh    一键修复（13 项检查）
root/usr/libexec/openclaw/backup.sh    备份与恢复（归档安全校验 + 安全快照）
root/usr/libexec/openclaw/cloud.sh     百度网盘云备份（组件安装/登录/加密上传/定时）
root/usr/libexec/openclaw/channels.sh  微信等渠道
root/usr/share/openclaw/model-presets.json
root/usr/share/rpcd/acl.d/luci-app-openclaw.json
scripts/apk3.py                           APK v3（ADB）写出器 —— OpenWrt 25.12
scripts/build_apk.py                      生成 apk v3 / apk v2 / ipk / .run
scripts/verify_apk.py                     三种包格式的结构自检
tools/isolated-review.sh                  隔离审查：AI 只改副本，产出补丁
tools/patch-guard.py                      补丁安全闸门（机械检查，拦截危险改动）
tools/verify-project.sh                   全量回归验证（交付前必须通过）
tools/tests/path-validate.sh              安全不变量回归（路径/端口/URL/JSON 转义）
tools/tests/backup-archive.sh             备份归档安全回归（拒绝越界/链接/设备条目）
tools/REVIEW-FLOW.md                      代码改造流程说明
```

## 代码改造流程

**本项目所有涉及代码改造的任务（含 AI 辅助）都必须走隔离流程**，
不允许直接修改正式目录。详见 [`tools/REVIEW-FLOW.md`](tools/REVIEW-FLOW.md)。

```bash
# 1) 隔离审查：AI 只在副本里工作，产出补丁
tools/isolated-review.sh "只审计并优化 install.sh 的管道吞错与幂等性"

# 2) 人工审核补丁与安全闸门结论
cat ../.review/<时间戳>/artifacts/SUMMARY.md
cat ../.review/<时间戳>/artifacts/guard-report.txt

# 3) 应用
git apply ../.review/<时间戳>/artifacts/changes.patch

# 4) 全量回归（必须通过）
tools/verify-project.sh
```

安全闸门会直接拦截：越界路径、危险路径（`.ssh`、`/etc/passwd`、`.bashrc`）、
新增二进制、`rm -rf`、`curl | sh`、`eval`、写系统账户文件、反弹 shell、
fork 炸弹、明文密钥、删除关键文件。

## 升级与向后兼容（设计规范）

**改动数据目录、文件名、配置键、cron 行、进程布局之前，先读
[`docs/UPGRADE-COMPAT.md`](docs/UPGRADE-COMPAT.md)。**

核心约束（完整规则与实现配方见该文件）：

1. 数据目录与文件名是**公开契约**，改名/移动属于破坏性变更，必须同时提供迁移；
2. 迁移必须**幂等**（断电重跑结果一致），靠状态判断而不是"这次是升级"；
3. 迁移一律**先复制 → 再验证 → 最后切换**，失败保留原数据；
4. 新配置项必须在**代码侧有默认值**，让老配置不迁移也能跑；
5. 清理旧版本遗留物要**列确切路径**，不许通配符扫目录；
6. 配置变更用 `main.config_version` 排序执行，每步只做一件事；
7. 改动了上述任意一项时，除 `verify-project.sh` 外还要手工做一次
   **"上一版数据目录 + 新版本"** 的启动验证 —— 干净安装的回归发现不了升级问题。

## 说明与已知限制

- 架构：x86_64 / aarch64；**musl** 运行时（OpenWrt 无 glibc，见上文）。
- 建议 1.5 GB 以上可用空间；安装目录需可写（写入探针会在下载前失败并给出明确日志）。
- Node.js 版本低于 `engines.node` 一律拒绝安装；`auto` 会自动挑选满足要求的最新可用版本。
- 依赖：`luci-base`、`luci-lua-runtime`、`luci-compat`、`curl`、`tar`、`jsonfilter`；
  解压 `.tar.xz` 若缺少 `xz` 会回退到 busybox tar。
- 网关 token 首次生成后写入 `~/.openclaw/openclaw.json`，状态页可直接带 token 打开控制台。
- 未签名的 apk 需加 `--allow-untrusted`；自建签名见 `build_apk.py --sign`。
