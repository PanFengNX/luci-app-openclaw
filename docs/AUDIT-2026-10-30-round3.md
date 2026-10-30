# 第三轮深度审计报告

- 审计日期：2026-10-30
- 审计基线：luci-app-openclaw v1.8.56（提交 `6178013`）
- 审计性质：只读审计结论；本文件不把未修项目描述为已修复
- 范围：第三轮遗留项、状态目录与锁恢复兼容性
- 官方依据：
  - Gateway lock：<https://docs.openclaw.ai/gateway/gateway-lock>
  - 迁移指南：<https://docs.openclaw.ai/zh-CN/install/migrating>

## 一、已确认问题

### 1. cloud 目录属主矩阵未完整落实

证据：`root/usr/libexec/openclaw/cloud.sh:244-253` 只对 `cloud/`、`cloud/bin`、`cloud/home` 执行 `mkdir`/`chmod 700`，没有恢复 root 属主；`root/usr/libexec/openclaw/lib.sh:1768-1786` 的 `oc_harden_root_paths()` 只收紧 `secure`、`cloud/pass` 和 `backups`。`cloud.sh:816-872` 中临时口令文件的 `chown` 失败也被忽略。

结论：`cloud`、`cloud/bin`、`cloud/home` 的最终属主依赖创建者，`cloud/pass` 也没有形成完整的目录级 root-only 矩阵。实际设备上的安装、更新和登录态迁移结果尚未验证，但代码层面的加固缺口已确认。

### 2. 备份归档文件解析仍可能跟随最终符号链接

证据：`root/usr/libexec/openclaw/backup.sh:143-180` 的 `oc_backup_resolve()` 对纯文件名使用 `[ -f "$d/$in" ]`，未拒绝最终对象为 symlink，也没有 no-follow 打开或真实路径约束。

结论：归档内部条目检查（`backup.sh:183-239`）不能替代备份目录中归档文件本身的 no-follow 检查。`backups` 目录被 root-only 收紧会降低攻击面，但不能修复解析器语义。

### 3. `api_run` 只按首个子命令授权

证据：`luasrc/controller/openclaw.lua:731-801` 仅检查 `argv[1]` 是否在 `RUN_CMDS`，其余参数转义后继续传给 CLI。

结论：`mcp add ...`、`devices approve ...` 等完整命令形状均共享首 token 授权；这是命令级最小授权缺失。当前证据不足以确认 shell 注入，现有 `q()` 和 CLI 元字符防护仍在生效。

### 4. cloud 未收录版本哈希只告警并继续执行

证据：`root/usr/libexec/openclaw/cloud.sh:1148-1164`、`1540-1582` 对未收录版本记录告警后继续架构检查、下载、安装或执行。

结论：未收录版本没有 fail-closed。若发布源或传输链被污染，组件仍可能以 root 安装或运行。

### 5. 缺少 `timeout` 时的关键降级路径可能无限执行

证据：`root/usr/libexec/openclaw/lib.sh:1105-1115` 的 Node 版本探测缺少 `timeout` 时直接执行候选二进制；`root/usr/libexec/openclaw/install.sh:252-261` 的 `run_with_timeout()` 缺少 `timeout` 时直接执行目标命令。

结论：这些路径没有 TERM/KILL/wait 兜底。其他已统一使用 `oc_timeout` 的路径不属于本项缺陷。

### 6. `core_pattern` 全局修改后不恢复

证据：`root/etc/init.d/openclaw:730-752` 写入 `/proc/sys/kernel/core_pattern`，但 `stop_service()`（约 `760-765`）和关闭开关路径没有保存、恢复旧值。

结论：开启 core dump 排障开关会改变系统级行为，并可能影响其他进程；真实设备影响尚未测量。

### 7. `dist-web` 发布页引用过期资产

证据：`dist-web/index.html:31-45` 仍引用 `luci-app-openclaw-1.0.1-r1.apk`、旧大小和 MD5；当前目录资产为 1.6.0 系列，页面链接目标不存在。

结论：部署该页会产生 404 或引导安装错误版本。

### 8. Lua RUNDIR 检查与写入之间仍有 TOCTOU 窗口

证据：`luasrc/controller/openclaw.lua:222-243` 已检查 `/tmp` 与 `/tmp/.openclaw` 的 symlink、类型、root 属主和 0700 权限，但后续 `api_apply()` 在约 `707-723` 使用 `io.open(keyfile, "wb")` 写入临时文件，检查与写入之间没有目录 fd/no-follow 原子语义。

结论：旧审计中“完全不检查属主和类型”的说法已是误报；竞态残余仍确认存在，但真实设备上的可利用性未验证。

### 9. 项目记录的锁清理实现与官方 gateway-lock 规范不一致

证据：`docs/OPENCLAW-OFFICIAL-NOTES.md:17-56` 记录官方要求使用 `openclaw gateway recover-lock`，确认 holder 已停止后再使用官方 `--confirm <fingerprint>`，不得手工 `rm -f`；该文件同时记录项目 `oc_clear_stale_state_lock()` 曾直接删除锁文件的偏差。当前代码应以实际行为测试为准，不能仅凭注释宣布兼容。

结论：升级兼容必须保留整个 state 目录并使用同一 state 目录，不能只迁移配置文件；迁移和锁恢复的真机行为仍需验证。

## 二、误报或当前已修复项

1. `repair.sh` 忽略自定义 `main.state_dir`：当前 `root/usr/libexec/openclaw/repair.sh:34-49` 使用 `DATA="$(oc_state_dir)"` 并进行安全校验。
2. 普通 repair 完全绕过 `oc_harden_root_paths()`：当前普通路径已在 `repair.sh` 权限处理后调用 `oc_harden_root_paths`。
3. Lua `need_dir()` 完全不检查 root 属主、类型和权限：当前已检查；仍保留上述 TOCTOU 残余。
4. 备份恢复先删除暂存目录导致 schedule/plugins 永远不恢复：当前 `backup.sh` 已调整为先读取清单再回收暂存目录。

## 三、未验证项

- BusyBox `readlink -f` 在中间 symlink、末端不存在时的具体行为。
- Lua RUNDIR 目录替换竞态在真实 OpenWrt 设备上的可利用性。
- cloud 组件真实安装、更新和登录态迁移的最终属主。
- OpenWrt 缺少 `timeout` 时 Node 探测和安装器的实际阻塞表现。
- `core_pattern` 对其他进程 core dump 行为的真实影响。
- base 外自定义 state 目录在真机 repair 中的完整权限结果。
- 当前 `oc_clear_stale_state_lock()` 在所有部署布局中是否都能调用到正确的官方 CLI，以及官方 CLI 各类非零退出码的精确分类。
- 本轮实际新增的锁测试覆盖了无锁、CLI 不可用、输出 confirm 线索三态；官方真实 CLI 的 rc=0/未知错误输出仍需真机补测。

## 四、本轮备份扩展与锁修复边界

本轮目标是让加密备份恢复后尽量可直接使用。整体加密归档新增：

- `./secure/delpass`：删除密码哈希；
- `./cloud/pass`：云备份加密口令；
- `./cloud/home/`：百度网盘登录态/授权缓存；
- `./cloud/bin/`：普通文件形式的云组件可执行文件；
- `./plugins/`：程序目录中排除 OpenClaw 核心、npm、cache、`.bin` 后的 provider/skill 插件目录；
- 状态目录原有的 `openclaw.json`、`.env`、agents、credentials、sessions、workspace 等继续全量保留。

恢复目标始终由当前设备的 BASE、OC_DIR 和 STATE_DIR 推导，不覆盖备份中的路径配置；旧归档缺少新增目录时保持兼容。新增内容复制失败会终止备份，防止生成“看似成功但缺少 Key”的不完整归档。恢复失败时回滚数据目录与 cloud/bin 旧目录。

锁恢复方面，`oc_clear_stale_state_lock()` 现在返回 0（无锁/检查无待人工恢复线索）、1（官方输出明确包含 confirm/fingerprint/holder 等人工恢复线索）或 2（CLI 不可用、未知输出/检查失败）；`repair.sh` 区分“发现锁需人工恢复”和“检查失败”，两者均 fail-closed 跳过 doctor。完整官方输出继续进入日志，不解析 fingerprint、不自动确认、不杀 PID、不手工删除锁。

## 五、仍未完成的审计项

以下问题本轮仍未修改：

1. cloud/home 的真实运行用户和 root-only 权限兼容性仍需 OpenWrt/bdpan 真机矩阵验证；
2. api_run 首 token 授权过宽；
3. 未收录云组件版本哈希只告警继续 root 执行；
4. timeout 缺失时部分路径的真实 BusyBox 行为；
5. core_pattern 全局修改不恢复；
6. dist-web 过期发布页；
7. Lua RUNDIR TOCTOU 竞态；
8. 归档解析与真实 BusyBox/GNU tar 的双环境验证；
9. recover-lock 官方真实 rc=0/未知错误语义需真机补测。
