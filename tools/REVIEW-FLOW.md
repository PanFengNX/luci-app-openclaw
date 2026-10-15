# 代码改造流程（AI 隔离审查 + 补丁审核）

> 适用范围：**本项目今后所有涉及代码改造的任务**。
> 无论是人工修改还是 AI 修改，都走这条链路。

## 为什么这么做

本项目是路由器上跑的软件包，`root/usr/libexec/` 下的脚本以 **root 身份**执行，
`root/etc/init.d/openclaw` 由 procd 拉起。一次误改可能导致设备无法启动。
因此：**AI 不允许直接写正式项目目录。**

## 流程总览

```text
正式项目 luci-app-openclaw/
        │
        │  ① 复制到隔离副本（自动排除 dist/ .tmp/ .workbuddy/ .git/）
        ▼
.review/<时间戳>/sandbox/        ← AI 只在这里工作
        │
        │  ② 副本内 git init + baseline 提交
        │  ③ AI 受限执行（acceptEdits + 工具白名单 + 无子代理）
        ▼
        │  ④ git diff → changes.patch
        │  ⑤ patch-guard.py 安全闸门
        ▼
.review/<时间戳>/artifacts/      ← 只产出产物，不碰正式项目
        │
        │  ⑥ 人工阅读 patch 与闸门报告
        ▼
正式项目（git apply）
        │
        │  ⑦ verify-project.sh 全量回归
        ▼
交付
```

## 三个工具

| 工具 | 作用 | 会修改文件吗 |
| --- | --- | --- |
| `tools/isolated-review.sh` | 建副本、跑 AI、出补丁、跑闸门 | 只改副本，正式项目需显式 `--apply` |
| `tools/patch-guard.py` | 补丁安全闸门（机械检查） | 否，只读 |
| `tools/verify-project.sh` | 全量回归验证 | 否，只读（构建会写 `dist/`） |

## 标准用法

### 1. 发起一次改造（默认不应用）

```bash
cd luci-app-openclaw
tools/isolated-review.sh "只审计并优化 install.sh 的管道吞错与幂等性"
```

产物在 `../.review/<时间戳>/artifacts/`：

| 文件 | 内容 |
| --- | --- |
| `SUMMARY.md` | 本次结论总览 |
| `ai-report.md` | AI 的自述（问题、原因、改了哪些文件、自检结果） |
| `changes.patch` | **待审核的补丁**（unified diff） |
| `changed-files.txt` | 变更文件清单与统计 |
| `guard-report.txt` | 安全闸门结论 |
| `sandbox-verify.log` | 副本内回归日志 |
| `ai-stderr.log` | AI 运行日志（排查失败用） |

### 2. 人工审核

```bash
cd luci-app-openclaw

# 先看结论与闸门
cat ../.review/<时间戳>/artifacts/SUMMARY.md
cat ../.review/<时间戳>/artifacts/guard-report.txt

# 再看补丁本身（必须逐段读，不要只看摘要）
less ../.review/<时间戳>/artifacts/changes.patch

# 检查补丁能否干净应用（不实际应用）
git apply --check ../.review/<时间戳>/artifacts/changes.patch
```

### 3. 应用

```bash
git apply ../.review/<时间戳>/artifacts/changes.patch
```

### 4. 回归

```bash
tools/verify-project.sh
```

**必须全部通过才能交付。**

### 5. 一条命令走完（补丁通过闸门才应用）

```bash
tools/isolated-review.sh "任务描述" --apply
```

即使加了 `--apply`，只要闸门判定 `BLOCK`，就**不会**应用。

## 安全闸门（patch-guard）判定规则

### 直接拦截（BLOCK，禁止应用）

| 类别 | 说明 |
| --- | --- |
| 越界路径 | 改动不在 `root/ luasrc/ htdocs/ scripts/ tools/ Makefile README.md` 内 |
| 危险路径 | `../`、绝对路径、`~/.ssh/`、`authorized_keys`、`.claude`、`/etc/passwd`、`.bashrc` |
| 新增二进制 | 新增 `.exe/.dll/.so/.node/.bin/.apk/.ipk/...` |
| 递归删除 | `rm -rf` 类 |
| 管道执行 | `curl ... \| sh` 类 |
| eval | `eval` 执行 |
| 写账户文件 | 写 `/etc/passwd`、`/etc/shadow`、`authorized_keys` |
| 反弹 shell | `/dev/tcp/`、`nc -e`、`bash -i >&` |
| fork 炸弹 | `:(){ :\|:& };:` |
| 明文密钥 | 补丁中出现 `sk-...` 或 `-----BEGIN ... PRIVATE KEY-----` |

### 需人工确认（WARN，不拦截）

`chmod 777`、`kill -9`、关闭 TLS 校验、改 crontab、改 `init.d`/`rc.d`、
环境变量外传、新增下载动作。

> `kill -9` 在本项目里是**已知的合理用法**（`oc_kill_tree` 需要强杀网关进程），
> 所以只做 WARN 提醒，由人工判断。

## 任务拆分要求（重要）

实测结论：**长任务必然失败**，原因有两个——

1. AI 会自行 spawn 后台子代理，`-p` 模式有 10 分钟 BG 等待上限，到点全杀掉并退出；
2. 会话配额会在长任务中途触发，把工具调用截断。

因此：

- **一次只做一个主题**，理想时长 2–5 分钟；
- 好的任务：「只改 `repair.sh` 的幂等性判断」
- 坏的任务：「审计整个项目并修复所有问题」
- 脚本已设置 `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0` 并禁止子代理，
  但仍应主动拆小；
- 默认超时 900s，可按需 `--timeout` 调整。

### 报告优先原则（关键）

脚本已强制 AI 按这个顺序工作：

```text
第一步：先审计，把发现的问题按 严重/中等/轻微 分级写入 review-report.md
第二步：再改代码，每修完一项在报告里标注「已修复」
第三步：有余力才做语法自检
```

**为什么必须这样**：AI 默认会把报告写在最后。一旦超时被中断，前面所有分析全部丢失。
实测中 6 个批次全部在 420s 处超时，产出的报告**全是 0 字节**，白跑了 54 分钟——
而每个批次其实都已经找到了真实缺陷（事后从残缺补丁里抢救出 5 个，其中 1 个很严重）。

报告优先后，即使被中断，审计结论仍然完整可用。

### 全项目审计：拆批

`tools/audit-suite.sh` 把全项目审计拆成 6 个批次（核心库 / 安装与版本 /
服务与初始化 / 模型与渠道 / 前端 / 打包），逐批走隔离流程：

```bash
tools/audit-suite.sh                    # 全部批次
tools/audit-suite.sh 1 3                # 只跑第 1、3 批
TIMEOUT_PER_BATCH=900 tools/audit-suite.sh   # 调大单批超时
```

产物汇总在 `.review/suite-<时间戳>/SUITE-SUMMARY.md`。

注意：`isolated-review.sh` 的外层超时是 `AI 超时 + 300s`。
这个余量是必须的——沙箱自检、git diff、安全闸门都要时间；
上一版只留 120s，结果 AI 超时后整个脚本也被杀掉，连闸门结论都没写出来。

## 权限边界（脚本已内置）

| 项 | 配置 |
| --- | --- |
| 工作目录 | 隔离副本（AI 的 cwd 就是副本根） |
| 权限模式 | `acceptEdits`（自动接受文件编辑，不做全权限绕过） |
| 工具白名单 | Read/Write/Edit/Glob/Grep + `sh -n`、`node --check`、`py_compile`、`grep`、`find`、`diff` 等只读命令 |
| 禁止 | 联网安装、下载、子代理、后台任务、写密钥 |
| 正式项目 | AI 完全接触不到 |

## 已知环境限制

这些是**本机环境**的限制，不是流程缺陷，但会影响使用体验：

| 现象 | 原因 | 应对 |
| --- | --- | --- |
| 命令被标记为失败，但产物完整 | 沙箱安全策略拦截 `reg.exe`（AI CLI 是原生二进制，会读注册表）。拦截信息会让整条命令被判定失败 | 看 `SUMMARY.md` 与产物目录判断实际结果，不要只看命令状态 |
| `ln -s` 建出来的是普通目录 | MSYS 设了 `winsymlinks:nativestrict`，但本机无开发者模式/管理员权限，符号链接退化为复制 | 符号链接相关逻辑改用桩函数测试（见 `tools/tests/path-validate.sh` 的做法） |
| 无法用 `wsl.exe` 做交叉验证 | `wsl.exe` 也在沙箱黑名单里 | 需要真机 POSIX 验证时，在 OpenWrt 设备或独立 Linux 环境上跑 |
| 长任务中途被截断 | 会话配额 + AI 自身后台子代理的 10 分钟上限 | 拆小任务；脚本已设 `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0` |

### 关于「报告文件」

AI 会把自述写入 `review-report.md`。脚本会在生成补丁**之前**把它剥离到
`artifacts/ai-self-report.md`，并从补丁中移除。

原因：报告不是代码改动。若不剥离，安全闸门会把它当成越界路径直接拦下整份补丁
（这是实测踩到的坑）。

## 常见问题

**Q: 补丁为空怎么办？**
AI 可能只做了分析没改代码，或任务被中断。看 `ai-stderr.log`，并把任务拆得更小。

**Q: `git apply --check` 失败？**
说明正式项目在生成补丁之后被改过。重新跑一次审查，或在副本里 rebase 后重新出补丁。

**Q: 正式项目不是 git 仓库，`git apply` 能用吗？**
可以，`git apply` 本身是独立的补丁工具，不要求当前目录是仓库。
但建议尽快 `git init`，这样回滚成本最低。

**Q: 闸门误报了怎么办？**
优先改任务描述或让 AI 换写法，而不是关掉闸门。
确需跳过时用 `--no-guard`，并**必须**在提交说明里写明原因。

## 变更记录

| 日期 | 变更 |
| --- | --- |
| 2026-10-15 | 建立流程：`isolated-review.sh` / `patch-guard.py` / `verify-project.sh` / `tests/path-validate.sh` |
| 2026-10-15 | 首次端到端实测；修正两处流程缺陷（报告文件未剥离、沙箱 git 的 autocrlf 会污染行尾） |

## 首次实测记录（2026-10-15）

**背景**：本次流程建立前，曾直接让 AI 改正式项目，那次运行在 27 分钟后失败，
但**已经在正式项目里留下了未完成的改动**（`lib.sh` 中新增 `oc_component_is_link()`，
其 `case` 模式里含未加引号的空格，属语法错误，导致整个 `lib.sh` 无法解析）。

这正好验证了隔离流程的必要性。事后处置：

| AI 的改动 | 评价 | 处置 |
| --- | --- | --- |
| 新增 `oc_canonical_dir()` | 正确 | 保留 |
| 新增 `oc_validate_base_dir_shape()` | 正确（把纯字符串校验抽出来复用） | 保留 |
| `oc_validate_base_dir` 增加符号链接解析 | **思路正确**（堵住 `/mnt/data/OpenClaw -> /etc` 绕过，否则后续 `chown -R` 会递归改到 `/etc`） | 重写：原实现有语法错误，且要求整条路径必须可解析，会导致**全新安装必失败** |
| 新增 `oc_component_is_link()` | 有语法错误 | 删除（被上面重写后的逻辑覆盖） |
| `oc_json_str` 多行处理改为输出 `\n` 转义 | 正确（原先多行值会被静默拼接，破坏 JSON） | 保留 |

**教训**：AI 的技术判断往往是对的，但产出需要逐行验证——语法检查、边界用例、
以及"这个改动会不会让正常流程走不通"。
