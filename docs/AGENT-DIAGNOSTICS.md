# 让 OpenClaw agent 自己看日志

## 结论先说

**不能让 agent 改插件代码，但可以让它读日志。** 两件事的可行性完全不同：

| 想法 | 能不能做 | 原因 |
| --- | --- | --- |
| agent 在运行时修改插件代码 | **不能** | 包内文件是 `root:root 755/644`，网关以 `uid=998(openclaw)` 运行，**没有写权限**。要给它这个权限，就等于让网关能改 LuCI 控制器，而 LuCI 以 root 执行 —— 这是一条直接的提权链：网关里任何一次提示注入都会变成 root 代码执行。 |
| agent 读取日志与状态 | **能，而且推荐** | 把快照写进**网关自己的数据目录**（`<state_dir>/diagnostics/`）。那个目录本来就属于网关用户，agent 天生有读权限。不需要任何新权限，也不需要开端口。 |

所以本插件采用的方案是：**不新增权限、不新增端口，只把信息放到 agent 已经能读的地方。**

## 怎么用

### 面板操作

「日志」页 → **生成给 OpenClaw 的诊断快照**。生成后页面会显示落地目录。

### 命令行

```sh
# 默认写到 <state_dir>/diagnostics/
/usr/libexec/openclaw/cli.sh diag-export

# 指定目录与行数
/usr/libexec/openclaw/cli.sh diag-export --out /mnt/data/OpenClaw/diag --lines 800

# 只读的即时快照（不落盘，stdout 一个 JSON）
/usr/libexec/openclaw/cli.sh snapshot 200
```

### 让 agent 读

在 OpenClaw 对话里直接指向那个目录即可，例如：

> 读一下 `<state_dir>/diagnostics/README.txt`，然后按里面的顺序看
> `gateway-log-tail.txt`，告诉我网关为什么起来了又退出。

## 落地的文件

| 文件 | 内容 | 什么时候看它 |
| --- | --- | --- |
| `snapshot.json` | `status`（是否运行 / 端口是否应答）、`paths`（各目录与日志位置）、`logs`（网关与系统日志尾部）、`crash`（崩溃线索） | 先看这个定位方向 |
| `gateway-log-tail.txt` | **网关进程自己写的日志**尾部 | 闪退、插件加载失败、schema 迁移问题 —— 真正的错误只在这里 |
| `manager-log-tail.txt` | 管理器动作记录（安装 / 升级 / 修复 / 备份） | 回答「谁在什么时候做了什么」 |
| `crash.txt` | `dmesg` 里 segfault / OOM 相关行 + `core_pattern` | 判断是不是原生崩溃 |
| `README.txt` | 给 agent 或人的读取指引 | 第一份要读的 |

`snapshot.json` 的字段含义：

```json
{
  "ok": true,
  "status": {
    "state": "running",        // running | stopped
    "installed": true,
    "reachable": true,         // 端口是否真的应答（false = 在初始化或启动失败）
    "port": "18789"
  },
  "paths": {
    "base_dir": "...",         // 安装目录
    "state_dir": "...",        // 数据目录（配置、会话、这个 diagnostics 也在其下）
    "gateway_log": "..."       // 网关日志的真实路径
  },
  "logs":  { "gateway": "...", "syslog": "..." },
  "crash": { "core_pattern": "...", "dmesg": "..." }
}
```

## 为什么用文件而不是 HTTP 接口

1. **不引入新权限**。写 HTTP 路由要么改上游 npm 包（明令不做），要么让网关能访问我们的接口 —— 后者又要给它权限。
2. **agent 本来就能读**。`<state_dir>` 已 `chown` 给网关用户，读文件不需要任何额外授权。
3. **离线可查**。文件在那里，人用 SSH、agent 用文件读取、以后拷走分析都行。
4. **无端口暴露**。不新增监听，不扩大攻击面。

## 为什么不做「agent 自动改代码」

除了权限问题，还有两个更实际的理由：

- **改了不生效也要重启**。LuCI 的 Lua 控制器确实是每次请求重新加载（root 改完文件、清模板缓存就生效），但网关自己的 Node 代码改动必须重启进程。让 agent 自动重启服务，等于把「随手改一下」升级成「可能把服务改坏」。
- **出了错没人知道改了什么**。自动改代码需要完整的审计链（改了什么、为什么、怎么回滚）。现在这套流程里，代码改动走的是「隔离副本 → 安全闸门 → 异源复核 → 全量回归」，任何一个环节都不能省。

需要改代码时，正确路径仍然是：SSH 里以 root 改文件 → 清 LuCI 缓存（控制器改动）→ 或 `stop` + `start`（网关改动，注意 `restart` 不重读 initscript）。

## 相关命令

```sh
cli.sh snapshot [lines]                    # 只读 JSON 快照
cli.sh diag-export [--out DIR] [--lines N] # 落盘到数据目录，供 agent 读取
cli.sh export [path]                       # 完整诊断包（tar.gz，含脱敏配置）
cli.sh log [n] [gateway|file|syslog|all]   # 日志尾部
```

`diagnostics/` 已从备份中排除：它是可重建的诊断产物，进归档只会让备份变大。