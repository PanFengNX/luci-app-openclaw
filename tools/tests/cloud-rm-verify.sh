#!/bin/sh
# cloud-rm-verify.sh — 云端备份删除的「假成功」回归
#
# 现场问题：点云端备份删除、输完密码，界面提示已删除，刷新后文件还在。
# 根因是只看 bdpan 删除命令的退出码：某些版本对不存在的路径也返回 0，
# help 里探测到的子命令也可能与实际不符。修复后必须以远端列表复验为准。
#
# 第二轮：仅看「目标是否还在」仍不够 —— ls 若分页/截断，后面的文件会补进
# 第一页，目标从列表里消失但文件其实还在。因此还要求删除后条数恰好少 1。
#
# 用桩模拟 bdpan（不联网、不碰真实网盘），逐场景验证 cloud_rm_remote 的
# 返回值与错误文案。可传项目根做反向验证（用修改前的代码应 FAIL）。
#
# 退出码：0 = 全部通过；1 = 有失败

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
PROJ="${1:-$(cd "$HERE/../.." && pwd)}"
PY=""
for cand in python3 python "${HOME:-}/.workbuddy/binaries/python/versions/3.13.12/python.exe"; do
	if command -v "$cand" >/dev/null 2>&1 || [ -x "$cand" ]; then PY="$cand"; break; fi
done
[ -n "$PY" ] || { echo "    跳过：找不到 python"; exit 0; }
"$PY" - "$PROJ" <<'PYEOF'
import pathlib
import subprocess
import sys
import tempfile

PROJ = pathlib.Path(sys.argv[1])
SRC = PROJ / 'root/usr/libexec/openclaw/cloud.sh'
CTRL = PROJ / 'luasrc/controller/openclaw.lua'
fails = []
total = 0


def check(name, cond):
    global total
    total += 1
    print(('  ok   ' if cond else '  FAIL ') + name)
    if not cond:
        fails.append(name)


def func(src, name):
    i = src.find('\n' + name + '() {')
    if i < 0:
        return ''
    i += 1
    j = src.find('\n}\n', i)
    return src[i:j + 3] if j > i else ''


src = SRC.read_text(encoding='utf-8') if SRC.exists() else ''
ctrl = CTRL.read_text(encoding='utf-8') if CTRL.exists() else ''

# ---------------------------------------------------------------- 静态契约
check('cloud_rm_remote 存在', 'cloud_rm_remote() {' in src)
check('新增 cloud_rm_list 列表读取函数', 'cloud_rm_list() {' in src)
check('新增 cloud_rm_stat 条数统计函数', 'cloud_rm_stat() {' in src)
check('新增 cloud_rm_verify 复验函数', 'cloud_rm_verify() {' in src)
check('复验以远端列表为判据', 'cloud_rm_list' in func(src, 'cloud_rm_verify'))
check('不再单凭 rc 宣布成功', '[ "$rc" -eq 0 ] && return 0' not in func(src, 'cloud_rm_remote'))
check('失败文案说明文件仍在', '远端仍存在' in src)
check('分页护栏：删除后条数必须恰好少 1', 'bc - 1' in func(src, 'cloud_rm_verify'))
check('删除前基线必须包含目标', '删除前的列表里没有' in src)
check('help 探测到子命令仍兜底其余命名', 'set -- "$sub"' in src)
check('ls 失败时报「无法确认」而不是成功', '无法读取远端列表确认结果' in src)
check('未启用 set -e（赋值失败不会被静默吞掉）', '\nset -e' not in src)
check('delpass_status 改走 cli.sh',
      'cloud_reply(sh(SH .. " delpass-status"))' in ctrl)
check('delpass_status 不再误调 cloud.sh',
      'cloud_reply(cloud_exec("delpass-status"))' not in ctrl)

# ---------------------------------------------------------------- 行为场景
# state 每行一个远端文件名；STUB_PAGE>0 时 ls 只返回前 N 行（模拟分页）；
# STUB_ADD=1 时删除动作同时追加一条新文件（模拟并发上传）。
STUB = r'''#!/bin/sh
sub="$1"; shift
case "$sub" in
  # %b：help 文本里的 \n 要解释成换行（判据只认行首命令名）
  help|--help) printf '%b\n' "$STUB_HELP" ;;
  ls)
    [ "$STUB_LS_FAIL" = "1" ] && { printf 'ls failed\n'; exit 7; }
    n=0
    printf '['
    while IFS= read -r f || [ -n "$f" ]; do
      [ -n "$f" ] || continue
      n=$((n+1))
      if [ "$STUB_PAGE" -gt 0 ] && [ "$n" -gt "$STUB_PAGE" ]; then break; fi
      [ "$n" -gt 1 ] && printf ','
      printf '{"server_filename":"%s","size":123}' "$f"
    done < "$STUB_STATE"
    printf ']'
    ;;
  rm|delete|remove)
    if [ "$STUB_EFFECT" = "$sub" ] || [ "$STUB_EFFECT" = "any" ]; then
      awk -v t="$STUB_TARGET" '$0 != t' "$STUB_STATE" > "$STUB_STATE.new" 2>/dev/null
      mv "$STUB_STATE.new" "$STUB_STATE"
      if [ "$STUB_ADD" = "1" ]; then
        printf '%s\n' 'concurrent-upload.enc' >> "$STUB_STATE"
      fi
    fi
    printf '%s\n' "$STUB_RM_OUT"
    exit "$STUB_RM_RC"
    ;;
esac
exit 0
'''

NAMES = ('cloud_valid_remote_name', 'cloud_ls_tsv', 'cloud_rm_list',
         'cloud_rm_stat', 'cloud_rm_verify', 'cloud_rm_attempt',
         'cloud_rm_remote')
BODY = '\n'.join(func(src, n) for n in NAMES)
HAVE_ALL = all(func(src, n) for n in NAMES)


def run_case(name, state, help_text, effect, rm_out='ok', rm_rc=0,
             ls_fail=0, page=0, add=0,
             target='openclaw-backup-20261111-000000.tar.gz.enc',
             expect_rc=None, expect_err=None):
    if not HAVE_ALL:
        check(name + '（缺函数，判失败）', False)
        return
    with tempfile.TemporaryDirectory() as td:
        d = pathlib.Path(td)
        stub = d / 'stub'
        state_f = d / 'state.txt'
        stub.write_bytes(STUB.encode())
        stub.chmod(0o755)
        state_f.write_bytes(state.encode())
        judge = d / 'judge.sh'
        # 桩是 judge 的子进程：所有 STUB_* 必须 export，否则桩读到空值，
        # ls 会返回空列表，把「文件仍在」误判成「已删除」。
        # Windows 临时目录是反斜杠，MSYS sh 里统一换成正斜杠。
        posix = lambda p: str(p).replace('\\', '/')
        lines = [
            '#!/bin/sh',
            'export OC_RUNDIR=' + repr(posix(d)),
            'OC_CLOUD_REMOTE="openclaw-backups"',
            'export STUB_BIN=' + repr(posix(stub)),
            'export STUB_STATE=' + repr(posix(state_f)),
            'export STUB_HELP=' + repr(help_text),
            'export STUB_EFFECT=' + repr(effect),
            'export STUB_RM_OUT=' + repr(rm_out),
            'export STUB_RM_RC=' + repr(str(rm_rc)),
            'export STUB_LS_FAIL=' + repr(str(ls_fail)),
            'export STUB_PAGE=' + repr(str(page)),
            'export STUB_ADD=' + repr(str(add)),
            'export STUB_TARGET=' + repr(target),
            'cloud_run() { t="$1"; shift; "$@"; }',
            'cloud_bin_ready() { printf %s "$STUB_BIN"; }',
            'cloud_redact() { cat; }',
            # 1.8.90 起 CLI 三候选失败后会落到接口通道；本用例专测 CLI 侧，
            # 这里给一个「不可用且不给原因」的桩，行为保持确定性。
            'cloud_api_delete() { return 1; }',
            'oc_cut_utf8() { head -c "${1:-800}"; }',
            BODY,
            'cloud_rm_remote ' + repr(target),
            'rc=$?',
            'printf "RC=%s\\nERR=%s\\n" "$rc" "$OC_RM_ERR"',
        ]
        judge.write_bytes(('\n'.join(lines) + '\n').encode())
        judge.chmod(0o755)
        p = subprocess.run(['sh', str(judge)], capture_output=True, text=True,
                           timeout=60)
        out = p.stdout
        rc = None
        for line in out.splitlines():
            if line.startswith('RC='):
                try:
                    rc = int(line[3:])
                except ValueError:
                    pass
        err = out.split('ERR=', 1)[1] if 'ERR=' in out else ''
        good = True
        if expect_rc is not None:
            good = good and rc == expect_rc
        if expect_err is not None:
            good = good and expect_err in err
        check(name, good)
        if not good:
            print('       got RC=%s ERR=%s' % (rc, err[:180]))


TARGET = 'openclaw-backup-20261111-000000.tar.gz.enc'
OTHER1 = 'openclaw-backup-20261110-000000.tar.gz.enc'
OTHER2 = 'openclaw-backup-20261109-000000.tar.gz.enc'
HELP_RM = 'Commands://n  ls       list files\n  rm       delete a file\n  upload   add a file'
THREE = TARGET + '\n' + OTHER1 + '\n' + OTHER2 + '\n'

# 1. 现场复现：CLI 返回 0 但文件还在 —— 必须失败，不能报「已删除」
run_case('删除命令返回 0 但远端仍在 -> 报失败', TARGET + '\n', HELP_RM,
         'none', expect_rc=1, expect_err='删除失败')

# 2. 真删掉了 -> 成功
run_case('远端确实消失 -> 成功', TARGET + '\n', HELP_RM, 'rm', expect_rc=0)

# 3. 删除命令退出码非 0，但文件确实没了 -> 以复验为准
run_case('rc 非 0 但文件已消失 -> 以复验为准', TARGET + '\n', HELP_RM,
         'rm', rm_rc=1, expect_rc=0)

# 4. help 里一个删除命令都没有（bdpan 3.8.9 实况）-> 1.8.91 起不再跑三个
#    注定失败的 CLI 候选，直接走开放平台接口。本用例把接口桩成不可用，
#    所以结果是失败、且原因指向接口通道，而不是「unknown command」。
run_case('help 无删除命令 -> 直接走接口，不试 CLI 候选', TARGET + '\n',
         'usage: bdpan <command>', 'delete', expect_rc=1,
         expect_err='网盘删除接口')

# 5. help 无子命令且都不支持 -> 明确提示，不谎报成功
run_case('CLI 不支持删除 -> 明确提示', TARGET + '\n',
         'usage: bdpan <command>', 'none',
         rm_out='unknown command rm', expect_rc=1, expect_err='删除失败')

# 6. 列表读不到 -> 明确说「无法确认」，绝不静默当成功
run_case('远端列表读取失败 -> 报无法确认', TARGET + '\n', HELP_RM,
         'rm', ls_fail=1, expect_rc=1, expect_err='无法读取远端列表')

# 7. 非法文件名仍在进入 CLI 之前被拒
run_case('路径穿越文件名被拒', TARGET + '\n', HELP_RM, 'rm',
         target='../evil', expect_rc=1, expect_err='不合法')

# 8. 删除唯一文件后远端为空 -> 成功（空列表不能被误判成「仍在」）
run_case('删除后远端为空 -> 成功', TARGET + '\n', HELP_RM, 'any', expect_rc=0)

# 9. 分页/截断：目标从第一页消失，但后面的文件补进来，条数没少。
#    只看「目标不在列表里」会假成功；必须判「无法确认」。
run_case('列表只返回前 2 条（分页）-> 不假报成功', THREE, HELP_RM,
         'rm', page=2, expect_rc=1, expect_err='无法确认')

# 10. help 里写 rm、实际只有 delete 生效 -> 探测结果排前但其余命名仍兜底
run_case('help 探测到 rm 但真实是 delete -> 兜底成功', TARGET + '\n',
         HELP_RM, 'delete', expect_rc=0)

# 11. 删除前列表里根本没有目标（重复删除 / 列表不全）-> 无法确认
run_case('删除前列表不含目标 -> 不假报成功', OTHER1 + '\n', HELP_RM,
         'any', expect_rc=1, expect_err='远端列表里没有')

# 12. 删除期间并发上传：条数没减少 -> 无法确认，不猜
run_case('删除并发上传导致条数异常 -> 不假报成功',
         TARGET + '\n' + OTHER1 + '\n', HELP_RM,
         'rm', add=1, expect_rc=1, expect_err='无法确认')

print('\n共 %d 项，失败 %d 项' % (total, len(fails)))
sys.exit(1 if fails else 0)
PYEOF
