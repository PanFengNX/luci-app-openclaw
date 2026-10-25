# 请协助处理 `/usr/bin/openclaw-watchdog`

> 转发给：Hermes（有 root 权限）
> 发起方：luci-app-openclaw 插件的维护侧
> 设备：iStoreOS 25.12.6，安装目录 `/SSD/OpenClaw`

## 一、问题现象

系统日志里持续出现：

```
crond[13218]: USER root pid 7797 cmd /usr/bin/openclaw-watchdog
```

这是 `cron.err` 级别的记录 —— crond 尝试以 root 执行该命令但**失败**（通常是文件不存在、不可执行，或脚本内部报错）。它会按 cron 周期反复出现，污染日志。

## 二、先确认归属：这不是本插件装的

本插件（`luci-app-openclaw`）安装的可执行文件**只有两个**：

| 路径 | 用途 |
| --- | --- |
| `/usr/bin/openclaw` | 转发到真实 OpenClaw 二进制的包装器 |
| `/etc/init.d/openclaw` | procd 服务脚本 |

本插件在 crontab 里**只维护一行**，且行尾一定带标记：

```cron
<分钟> <时> * * * <命令> # openclaw-cloud
```

`openclaw-watchdog` 不在上表内，crontab 行也不带 `# openclaw-cloud` 标记 —— 所以它来自别处（很可能是早期为「网关挂了自动拉起」手写的脚本）。判断它属于谁、还要不要，需要你来确认。

## 三、诊断（只读，安全）

以下命令都不修改任何东西，请先执行并看输出：

```sh
# 1) 文件是否还在、是什么类型、多大、什么时候改的
ls -la /usr/bin/openclaw-watchdog 2>&1
file /usr/bin/openclaw-watchdog 2>&1

# 2) 内容（是脚本的话直接看）
head -n 40 /usr/bin/openclaw-watchdog 2>&1

# 3) crontab 里哪一行引用了它（root 的 crontab）
grep -n 'openclaw-watchdog' /etc/crontabs/root 2>&1

# 4) 是否还有其它地方引用（init 脚本、其他 crontab、开机项）
grep -rn 'openclaw-watchdog' /etc/crontabs/ /etc/init.d/ /etc/rc.local 2>/dev/null

# 5) 当前是否有进程在跑
ps w | grep -i 'openclaw-watchdog' | grep -v grep

# 6) 它有没有留下自己的日志
ls -la /var/log/ 2>/dev/null | grep -i watchdog
```

## 四、判断标准

| 情况 | 结论 |
| --- | --- |
| 文件**不存在**，只有 crontab 行 | 直接删掉那行即可（残留引用） |
| 文件存在，是「检查网关进程，不在就拉起」这类逻辑 | **大概率已经多余** —— 本插件的 procd 服务已配置 `respawn 3600 5 0`（`retry=0` 表示永不放弃），网关异常退出由 procd 负责拉起。若它直接执行 `openclaw gateway run`，会与 procd 的实例抢同一个端口；若它调 `/etc/init.d/openclaw start`，procd 视为已在运行、属于空操作。两种都不需要它 |
| 文件存在，但 `head` 里引用了本插件不存在的老路径（如 `/SSD/OpenClaw/data`、`/etc/init.d/openclawmgr`） | 已经失效，属于残留，应删 |
| 文件存在，且确实承担了 procd 做不到的检查（例如外部探活、告警推送） | **保留**，但需要修掉执行失败的原因，而不是让它继续报错 |

**关键点**：本插件的网关由 `/etc/init.d/openclaw` 通过 procd 管理，配置了 `respawn`。如果 `openclaw-watchdog` 也在做「进程不在就启动」，两者会竞争 —— 这是**建议移除**的主要理由，不只是日志噪音。

## 五、清理步骤（确认可删之后）

请按顺序执行，每步都可回滚。**第 1 步与第七节的 `sed` 已用样例 crontab 实测过**：
只影响目标行，本插件的 `# openclaw-cloud` 行与其它第三方任务均保持不变。

```sh
# 0) 备份 crontab（必须做，出问题能立刻还原）
cp -p /etc/crontabs/root /etc/crontabs/root.bak-$(date +%Y%m%d-%H%M%S)

# 1) 只删含 openclaw-watchdog 的那一行，其余原样保留
#    用同目录临时文件 + mv：crond 正在读这个文件，不能原地覆盖
grep -v 'openclaw-watchdog' /etc/crontabs/root > /etc/crontabs/root.new
mv /etc/crontabs/root.new /etc/crontabs/root
chmod 600 /etc/crontabs/root

# 2) 让 crond 重新加载
/etc/init.d/cron reload 2>/dev/null || /etc/init.d/cron restart

# 3) 确认那一行已经没了，且本插件的行还在
grep -n 'openclaw-watchdog' /etc/crontabs/root   # 应该无输出
grep -n 'openclaw-cloud'    /etc/crontabs/root   # 应该仍在（如果有定时云备份）

# 4) 删除二进制（确认第三步无输出后再删）
rm -f /usr/bin/openclaw-watchdog

# 5) 观察日志：之后不应再出现 watchdog 的 cron.err
logread | grep -i 'openclaw-watchdog'
```

## 六、绝对不要动的文件

请**不要**删除或修改下面这些 —— 它们是本插件的组成部分，删了会直接导致 LuCI 页面报错或服务起不来：

```
/usr/bin/openclaw                        ← 包装器（不是 watchdog）
/etc/init.d/openclaw                     ← procd 服务脚本
/usr/libexec/openclaw/                   ← 全部脚本（cli.sh / install.sh / lib.sh / backup.sh / cloud.sh …）
/usr/lib/lua/luci/controller/openclaw.lua
/usr/lib/lua/luci/view/openclaw/
/etc/config/openclaw                     ← 插件配置（含端口、安装目录、token 等）
/SSD/OpenClaw/                           ← 整个安装目录（程序 + 数据 + 会话）
```

特别注意：`/usr/bin/openclaw` 和 `/usr/bin/openclaw-watchdog` 名字很像，但**只有后者要删**。前者是本插件的入口，删掉会让「OpenClaw 助手」整个不可用。

## 七、如果判断不准

不确定它是否还在起作用时，**先停掉观察，不要直接删**：

```sh
# 只注释掉那一行（保留文件，随时可恢复）
# 注意：这条命令连跑两次会变成 "##..."，仍属注释、不影响功能，但会难看。
cp -p /etc/crontabs/root /etc/crontabs/root.bak-$(date +%Y%m%d-%H%M%S)
sed -i 's|^\([^#].*openclaw-watchdog.*\)$|#\1|' /etc/crontabs/root
/etc/init.d/cron reload

# 观察 24 小时：网关是否会自己挂掉不恢复？
# 本插件状态页会显示运行状态；也可以用：
/usr/libexec/openclaw/cli.sh info
```

若 24 小时内网关一直正常（procd 的 respawn 生效），就可以按第五节彻底删除。

## 八、需要反馈的内容

请把第三节 6 条命令的输出贴回来，特别是：

1. `ls -la` 与 `file` 的结果（文件在不在）
2. `head -n 40` 的内容（它到底做什么）
3. `grep -n 'openclaw-watchdog' /etc/crontabs/root` 的那一行原文

有了这三项就能确定是「删掉」还是「保留但修好」。
