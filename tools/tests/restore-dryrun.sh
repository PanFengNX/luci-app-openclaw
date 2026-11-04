#!/bin/sh
# restore-dryrun.sh —— 恢复演练（--dry-run）必须存在，且不能碰线上数据
#
# 为什么需要它：1.8.75 之前，"备份能不能恢复"这件事没人真正验证过 ——
# 只测了"备份能创建"，结果 512MB 上限和符号链接两处让所有备份都恢复不了。
# verify 只能查结构；演练才是"真的解压一遍再核对内容"。
#
# 本测试守住三件事：
#   1. backup.sh 有 --dry-run，且演练分支在写 UCI / 替换数据目录之前返回
#   2. 演练不产生"还原前快照"、不停网关（线上完全无感）
#   3. 命令行与界面都能用到（否则就是死代码）

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
PROJ="$(cd "$HERE/../.." && pwd)"
PY=""
for cand in python3 python "$HOME/.workbuddy/binaries/python/versions/3.13.12/python.exe"; do
	if command -v "$cand" >/dev/null 2>&1 || [ -x "$cand" ]; then PY="$cand"; break; fi
done
[ -n "$PY" ] || { echo "    跳过：找不到 python"; exit 0; }

"$PY" - "$PROJ" <<'PYEOF'
import pathlib
import re
import sys

proj = pathlib.Path(sys.argv[1])
backup = (proj / 'root/usr/libexec/openclaw/backup.sh').read_text(encoding='utf-8')
cli = (proj / 'root/usr/libexec/openclaw/cli.sh').read_text(encoding='utf-8')
ctrl = (proj / 'luasrc/controller/openclaw.lua').read_text(encoding='utf-8')
view = (proj / 'luasrc/view/openclaw/backup.htm').read_text(encoding='utf-8')

total = 0
failed = 0


def check(ok, desc, detail=''):
    global total, failed
    total += 1
    print('    %s  %s%s' % ('ok  ' if ok else 'FAIL', desc, ('  ' + detail) if detail else ''))
    if not ok:
        failed += 1


m = re.search(r'^cmd_restore\(\) \{.*?^\}', backup, re.M | re.S)
body = m.group(0) if m else ''
check(bool(body), '取到 cmd_restore')

check('--dry-run) dry=1' in body, 'restore 解析 --dry-run')
check('"$dry" = "0"' in body, '演练时跳过还原前快照与停服务')

# 演练分支必须在"5) UCI 配置"之前返回
i_dry = body.find('if [ "$dry" = "1" ]; then')
i_uci = body.find('# 5) UCI 配置')
check(i_dry > 0 and i_uci > 0 and i_dry < i_uci,
      '演练分支在写 UCI 配置之前返回（不碰线上配置）')
# 数据目录替换必须在演练之后
i_data = body.find('# 6a) 数据目录')
check(i_data > i_dry > 0, '演练分支在替换数据目录之前返回（不碰线上数据）')

check('dryRun' in body, '演练返回 JSON 里标明 dryRun，前端可区分')
check('oc_rmtree "$stage"' in body, '演练结束清理暂存目录（不留 3GB 垃圾）')

# 命令行入口
check('cmd_backup_dryrun' in cli, 'cli.sh 有 backup-dryrun 子命令')
check('--dry-run' in cli, '子命令把 --dry-run 传给 backup.sh')

# 界面入口
check('api_backup_dryrun' in ctrl, '控制器有 api_backup_dryrun')
check('"backup_dryrun"}, call("api_backup_dryrun")' in ctrl,
      '控制器注册了 backup_dryrun 路由')
check('bkDryRun' in view, '备份页有演练函数')
check("mk('演练'" in view, '备份页有「演练」按钮')
check('backup_dryrun:' in view, '前端有 backup_dryrun 接口地址')

# 前端解析 data 字符串（否则条目数永远不显示）
check('bkParseData' in view, '前端解析 helper 返回的 data 字符串')
check('JSON.parse(rr.data)' in view, 'bkParseData 真的做 JSON.parse')

print('    共 %s 项，%s 项失败' % (total, failed))
sys.exit(1 if failed else 0)
PYEOF
