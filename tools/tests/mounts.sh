#!/bin/sh
# mounts.sh — 安装目录候选（oc_mounts）的过滤规则
#
# 真机上出现过下拉里列出 /boot（vfat，119 MB）的情况：用户选中后必然在
# 安装阶段失败，而且 /boot 是引导分区，写满会影响启动。所以候选列表要满足：
#
#   1. 系统前缀（/、/rom、/overlay、/tmp、/var、/usr、/etc、/dev、/proc、
#      /sys、/run）不列 —— 与安装时同一套校验；
#   2. /boot、/efi 不列 —— 引导分区，容量与用途都不对；
#   3. 只读挂载不列；
#   4. 可用空间小于 512 MB 不列 —— Node 运行时 + OpenClaw 本体约 400 MB。
#
# 用假的 /proc/mounts（OC_PROC_MOUNTS 覆盖）与桩 df 喂数据，不碰真实系统。
# 退出码：0 = 全部通过；1 = 有失败

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
import shutil
import subprocess
import sys
import tempfile

proj = pathlib.Path(sys.argv[1])
src = (proj / 'root/usr/libexec/openclaw/lib.sh').read_text(encoding='utf-8')

total = 0
failed = 0


def check(ok, desc):
    global total, failed
    total += 1
    print('    %s  %s' % ('ok  ' if ok else 'FAIL', desc))
    if not ok:
        failed += 1


m = re.search(r'(?ms)^oc_mounts\(\)\s*\{.*?\n\}', src)
assert m, '取不到 oc_mounts'
fn = m.group(0)

work = pathlib.Path(tempfile.mkdtemp())


def P(p):
    s = pathlib.Path(p).as_posix()
    mm = re.match(r'^([A-Za-z]):/', s)
    return '/' + mm.group(1).lower() + s[2:] if mm else s


try:
    mounts = work / 'mounts'
    mounts.write_text("\n".join([
        '/dev/mmcblk0p1 /boot vfat rw,relatime 0 0',
        '/dev/mmcblk0p1 /boot/efi vfat rw,relatime 0 0',
        '/dev/mmcblk0p2 /efi vfat rw,relatime 0 0',
        '/dev/sda1 /mnt/data ext4 rw,relatime 0 0',
        '/dev/sda2 /mnt/tiny ext4 rw,relatime 0 0',
        '/dev/sdb1 /mnt/ro ext4 ro,relatime 0 0',
        '/dev/sdc1 /mnt/exfat exfat rw,relatime 0 0',
        'tmpfs /tmp tmpfs rw 0 0',
        'overlayfs /overlay overlay rw 0 0',
        'rootfs / squashfs ro 0 0',
        '',
    ]), encoding='utf-8', newline='\n')

    bindir = work / 'bin'
    bindir.mkdir()
    df = bindir / 'df'
    df.write_text("\n".join([
        '#!/bin/sh',
        'case "$2" in',
        '  /boot) f=119 ;; /boot/efi) f=64 ;; /efi) f=64 ;;',
        '  /mnt/data) f=63111 ;; /mnt/tiny) f=200 ;;',
        '  /mnt/ro) f=9000 ;; /mnt/exfat) f=2048 ;; *) f=1000 ;;',
        'esac',
        'printf "Filesystem 1M-blocks Used Available Use%% Mounted\\n/dev/x 999 1 %s 1%% %s\\n" "$f" "$2"',
        '',
    ]), encoding='utf-8', newline='\n')
    df.chmod(0o755)

    runner = work / 'm.sh'
    runner.write_text("\n".join([
        '#!/bin/sh',
        "OC_PROC_MOUNTS='" + P(mounts) + "'",
        "export PATH='" + P(bindir) + "':$PATH",
        'oc_validate_base_dir() { return 0; }',
        fn,
        'oc_mounts',
        '',
    ]), encoding='utf-8', newline='\n')

    r = subprocess.run(['sh', P(runner)], capture_output=True, text=True)
    rows = [l.split('\t') for l in r.stdout.strip().splitlines() if l]
    got = [x[0] for x in rows]

    check('/boot' not in got, '/boot（引导分区，119 MB）不出现在候选里')
    check('/boot/efi' not in got, '/boot/efi 同样不出现')
    check('/efi' not in got, '/efi 不出现')
    check('/mnt/tiny' not in got, '可用 200 MB 的分区被容量下限挡掉')
    check('/mnt/ro' not in got, '只读挂载不出现')
    check('/tmp' not in got, 'tmpfs 不出现')
    check('/overlay' not in got, 'overlay 不出现')
    check('/mnt/data' in got, '/mnt/data（63111 MB, ext4）保留')
    check('/mnt/exfat' in got, 'exfat 数据盘保留（2048 MB）')
    check(got == sorted(got, key=lambda p: -dict((x[0], int(x[1])) for x in rows)[p]),
          '按可用空间从大到小排序')
    check(all(len(x) == 3 for x in rows), '每行三列：挂载点 / 可用MB / 文件系统')
finally:
    shutil.rmtree(work, ignore_errors=True)

print('    共 %s 项，%s 项失败' % (total, failed))
sys.exit(1 if failed else 0)
PYEOF
