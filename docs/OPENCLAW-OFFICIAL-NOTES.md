# OpenClaw 官方依据：状态锁与离线维护（2026-10-28 查证）

> 用途：本项目修改前的官方文档核对记录。任何涉及 state 锁 / doctor / sqlite 维护的改动，
> 必须先对照本文，不得凭历史经验或旧日志推断。

## 来源

- https://docs.openclaw.ai/gateway/gateway-lock （英文现行版）
- https://docs.openclaw.ai/zh-CN/gateway/gateway-lock （中文，含「2026.10 前旧实现」的描述，注意区分）
- https://docs.openclaw.ai/zh-CN/cli/doctor 与 sqlite-maintenance 文档

⚠️ 中文页存在两种口径：一种描述**旧版**（每配置锁 + SQLite 协调器，5 秒重试），
另一种描述**2026.10 现行版**（state 所有权锁 + 兼容投影，等待 5 分钟）。
判断依据：现行版明确提到 `$OPENCLAW_STATE_DIR/tmp/openclaw-<uid>/state.<hash>.lock`。
以**提到该路径的那一版**为准。

## 现行版（2026.10+）关键事实

1. **三层机制**：状态所有权锁 → 兼容投影 → 套接字绑定。每层独立失败。
2. **锁位置**：`$OPENCLAW_STATE_DIR/tmp/openclaw-<uid>/state.<hash>.lock`
   （hash 由解析后的 shared-state 数据库路径决定；**TMPDIR 不影响**该命名空间）。
3. **兼容投影**：`$OPENCLAW_STATE_DIR/tmp/openclaw-<uid>/gateway.state.lock`，
   内含 owner PID / 进程启动标识 / role / port，供旧版网关识别当前进程。
   新运行时**不再创建**历史上那种 per-config 锁，也不创建 `.sqlite` 伴生锁。
4. **启动自动回收**：锁文件缺失、或记录的所有者进程已不存在 → 启动过程**自行回收并继续**。
   「即使崩溃或 SIGKILL，也不会留下过期的锁文件。」
5. **崩溃/外来 owner 的人工恢复**：必须用
   ```
   openclaw gateway recover-lock
   openclaw gateway recover-lock --confirm <fingerprint>
   ```
   它通过 fs-safe 的 remove-if-unchanged 协议回收 sidecar，
   **并在独占状态所有权下清除匹配的 SQLite / PostgreSQL Gateway owner lease**。
   官方原话：*“inspect again instead of removing lock files by hand.”*
6. **等待时间**：启动/重启最多等另一个 OpenClaw 进程释放状态所有权 5 分钟，
   每 250ms 检查一次普通竞争；等待期间每 30 秒报告维护 PID 与 role。
   **等待过程绝不会杀掉维护进程、不会回收活锁、不会重复已受理的探索工作。**
7. **离线维护**：`openclaw doctor --state-sqlite compact` 与网关启动抢**同一把锁**；
   维护期间 `auto_vacuum`、VACUUM、integrity_check 全程持有该锁。
   它从不被正常网关动作调用，也不属于 `openclaw doctor --fix`。
8. **不可验证的 owner**：无论心跳多久都不予回收，必须人工按 fingerprint 确认。

## 由此得出的本项目约束（必须遵守）

| 禁止 | 原因 |
| --- | --- |
| 手工 `rm -f` state 锁 / gateway.state.lock | 官方明确不允许；只删 sidecar 不清 lease，会让状态更僵 |
| 清理 `$state_dir/tmp/openclaw-*` 目录 | 该目录住着状态锁与兼容投影，删目录 = 抽走锁 |
| 在启动路径强杀维护进程 | 官方等待逻辑明确不杀维护进程 |
| 把 `doctor --fix` 当作能解维护锁的手段 | 维护锁会挡住 doctor 本身，需先等维护结束或用 recover-lock |

## 已知的本项目偏差（待修）

- `lib.sh` 的 `oc_clear_stale_state_lock()` 直接 `rm -f` 锁文件 —— **与官方方向相反**。
  正确做法：调用 `openclaw gateway recover-lock` 拿到 fingerprint，再 `--confirm`。
- 1.8.47 的 `oc_sweep_stale_tmp()` 已不再扫 `state_dir/tmp`（这一半是对的，保留）。

## 维护者注意

「未生成网关 token，拒绝启动」的判据必须区分明文 token 与 SecretRef（`{"source":"store",...}`）。
官方 gateway 文档：`gateway.auth.token` 由 SecretRef 管理时，`gateway install` 只验证可解析，
**不会**把解析后的令牌写入服务环境；无法解析时安装 fail-closed。
因此存在 SecretRef 时网关可以正常启动，不能被当成"没有 token"。