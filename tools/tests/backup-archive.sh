#!/bin/sh
# backup-archive.sh — 备份归档安全校验的回归测试
#
# 还原路径上最关键的一道防线是 oc_archive_inspect()：它必须拒绝
#   * 绝对路径条目
#   * 含 .. 的条目
#   * 符号链接 / 硬链接 / 设备 / FIFO 条目
#   * 缺少 BACKUP-INFO 的归档（不是本程序生成的）
#
# 用例归档由 Python 的 tarfile 构造（MSYS 上无法创建符号链接，
# 只有 tarfile 能造出链接/设备条目）。
#
# 注意：MSYS 的 /tmp 与 Windows 原生程序看到的 /tmp 不是同一个目录，
# 所以临时目录必须建在项目内，并把"MSYS 形式"和"Windows 形式"两种路径
# 分别传给 shell 与 python。否则 python 写的归档 shell 根本看不到，
# 所有用例都会"因为找不到文件而拒绝"——即假通过。
#
# 退出码：0 = 全部通过；1 = 有失败

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
PROJ="$(cd "$HERE/../.." && pwd)"

PY=""
for cand in python3 python "$HOME/.workbuddy/binaries/python/versions/3.13.12/python.exe"; do
	if command -v "$cand" >/dev/null 2>&1 || [ -x "$cand" ]; then PY="$cand"; break; fi
done
[ -n "$PY" ] || { echo "    跳过：找不到 python"; exit 0; }

SBX="$PROJ/.tmp/backup-test.$$"
if command -v cygpath >/dev/null 2>&1; then
	SBX_WIN="$(cygpath -m "$SBX")"
else
	SBX_WIN="$(printf '%s' "$SBX" | sed 's|^/\([a-zA-Z]\)/|\1:/|')"
fi

rm -rf "$SBX"
mkdir -p "$SBX/libexec" "$SBX/cases" "$SBX/rundir" || exit 2

sed "s#/usr/libexec/openclaw/#$SBX/libexec/#g" \
	"$PROJ/root/usr/libexec/openclaw/lib.sh" >"$SBX/libexec/lib.sh"
sed "s#/usr/libexec/openclaw/#$SBX/libexec/#g" \
	"$PROJ/root/usr/libexec/openclaw/backup.sh" >"$SBX/libexec/backup.sh"

# 让 rundir 指向测试目录：oc_backup_resolve 只接受 rundir 下的绝对路径
cat >>"$SBX/libexec/lib.sh" <<EOF

OC_RUNDIR="$SBX/rundir"
OC_LOCK_DIR="\$OC_RUNDIR/lock"
EOF

"$PY" - "$SBX_WIN" <<'PYEOF' || { echo "    生成测试归档失败"; rm -rf "$SBX"; exit 1; }
import io, os, sys, tarfile

sbx = sys.argv[1]
cases = os.path.join(sbx, "cases")
os.makedirs(cases, exist_ok=True)


def build(name, entries, manifest=True):
    path = os.path.join(cases, name)
    with tarfile.open(path, "w:gz") as tf:
        def add_bytes(n, data):
            ti = tarfile.TarInfo(n)
            b = data.encode()
            ti.size = len(b)
            ti.mode = 0o644
            tf.addfile(ti, io.BytesIO(b))

        if manifest:
            add_bytes("./BACKUP-INFO", "format=1\ncreated=test\n")

        for n, d in entries:
            if d == "DIR":
                ti = tarfile.TarInfo(n)
                ti.type = tarfile.DIRTYPE
                ti.mode = 0o755
                tf.addfile(ti)
            elif d.startswith("SYMLINK:"):
                ti = tarfile.TarInfo(n)
                ti.type = tarfile.SYMTYPE
                ti.linkname = d.split(":", 1)[1]
                tf.addfile(ti)
            elif d.startswith("HARDLINK:"):
                ti = tarfile.TarInfo(n)
                ti.type = tarfile.LNKTYPE
                ti.linkname = d.split(":", 1)[1]
                tf.addfile(ti)
            elif d == "CHRDEV":
                ti = tarfile.TarInfo(n)
                ti.type = tarfile.CHRTYPE
                ti.devmajor, ti.devminor = 1, 3
                tf.addfile(ti)
            elif d == "FIFO":
                ti = tarfile.TarInfo(n)
                ti.type = tarfile.FIFOTYPE
                tf.addfile(ti)
            else:
                add_bytes(n, d)


GOOD = [
    ("./etc/config/openclaw", "config openclaw\n\toption port '18789'\n"),
    ("./home/.openclaw/openclaw.json", '{"gateway":{"port":18789}}\n'),
    ("./home/.openclaw/.env", "DEEPSEEK_API_KEY=sk-test\n"),
]

build("good.tar.gz", GOOD)
build("good-with-dirs.tar.gz", [("./etc", "DIR"), ("./etc/config", "DIR")] + GOOD)
build("no-manifest.tar.gz", GOOD, manifest=False)
build("abs-path.tar.gz", GOOD + [("/etc/passwd", "root:x:0:0\n")])
build("dotdot.tar.gz", GOOD + [("./home/../../etc/passwd", "x\n")])
build("symlink.tar.gz", GOOD + [("./home/.openclaw/evil", "SYMLINK:/etc")])
build("hardlink.tar.gz", GOOD + [("./home/.openclaw/hard", "HARDLINK:./etc/config/openclaw")])
build("chrdev.tar.gz", GOOD + [("./home/.openclaw/null", "CHRDEV")])
build("fifo.tar.gz", GOOD + [("./home/.openclaw/pipe", "FIFO")])
build("no-dot-slash.tar.gz", GOOD + [("etc/config/other", "x\n")])

with open(os.path.join(cases, "plain.tar.gz"), "wb") as fh:
    fh.write(b"this is not a gzip archive at all\n")

print(len(os.listdir(cases)))
PYEOF

FAILED=0
TOTAL=0

expect() {
	file="$1"; want="$2"; desc="$3"
	TOTAL=$((TOTAL + 1))
	cp "$SBX/cases/$file" "$SBX/rundir/$file" 2>/dev/null || {
		printf '    FAIL  %s（用例文件缺失）\n' "$desc"
		FAILED=$((FAILED + 1)); return
	}
	out="$(sh "$SBX/libexec/backup.sh" verify "$SBX/rundir/$file" 2>&1)"
	rc=$?
	if [ "$want" = "PASS" ]; then
		if [ "$rc" -eq 0 ]; then
			printf '    ok    %s\n' "$desc"
		else
			printf '    FAIL  %s（应通过却失败：%s）\n' "$desc" "$out"
			FAILED=$((FAILED + 1))
		fi
	else
		if [ "$rc" -ne 0 ]; then
			printf '    ok    %s（已拒绝）\n' "$desc"
		else
			printf '    FAIL  %s（应拒绝却通过了！）\n' "$desc"
			FAILED=$((FAILED + 1))
		fi
	fi
}

expect good.tar.gz            PASS   "正常归档（含清单与配置）"
expect good-with-dirs.tar.gz  PASS   "正常归档（含目录条目）"
expect no-manifest.tar.gz     REJECT "缺少 BACKUP-INFO"
expect abs-path.tar.gz        REJECT "含绝对路径条目 /etc/passwd"
expect dotdot.tar.gz          REJECT "含 .. 的条目"
expect symlink.tar.gz         REJECT "含符号链接条目（可指向 /etc）"
expect hardlink.tar.gz        REJECT "含硬链接条目"
expect chrdev.tar.gz          REJECT "含字符设备条目"
expect fifo.tar.gz            REJECT "含 FIFO 条目"
expect no-dot-slash.tar.gz    REJECT "非 ./ 开头的相对路径条目"
expect plain.tar.gz           REJECT "不是 gzip 归档"

# 清理。Windows/MSYS 下项目绝对路径经过 rm 安全垫片时可能被当作
# trash 目标而失败；测试目录是本项目内的临时夹具，用 Python 直接清理更可靠。
"$PY" - "$SBX_WIN" <<'PYEOF'
import shutil, sys
shutil.rmtree(sys.argv[1], ignore_errors=True)
PYEOF

printf '    共 %s 项\n' "$TOTAL"
[ "$FAILED" -eq 0 ] || { printf '    %s 项失败\n' "$FAILED"; exit 1; }
exit 0
