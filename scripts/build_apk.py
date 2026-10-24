#!/usr/bin/env python3
"""
build_apk.py - build installable packages for OpenWrt out of the source tree,
without requiring the OpenWrt SDK.

Outputs (into dist/):
  luci-app-openclaw-<ver>-r<rel>.apk        APK v3 / ADB  (OpenWrt 25.12+, apk-tools 3.x)
  luci-app-openclaw-<ver>-r<rel>-v2.apk     APK v2        (apk-tools 2.x / Alpine; NOT for OpenWrt)
  luci-app-openclaw-<ver>-r<rel>-signed.apk APK v2 signed (only with --sign)
  luci-app-openclaw_<ver>_all.ipk           classic opkg package
  luci-app-openclaw-<ver>.run               self extracting installer

APK v3 layout (written by apk3.py):
  "ADB" + compression byte + [alg,level] + raw deflate stream of
      "ADB." "pckg" <ADB block> <DATA block>...
APK v2 layout (verified against apk-tools):
  [ signature gzip ]  optional, tar segment with .SIGN.RSA.<key>.rsa.pub
  [ control  gzip ]   tar segment: .PKGINFO (+ optional scripts)
  [ data     gzip ]   tarball, PAX header APK-TOOLS.checksum.SHA1 per file
"""

import argparse
import gzip
import hashlib
import io
import os
import re
import shutil
import subprocess
import sys
import tarfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
DIST = ROOT / "dist"

sys.path.insert(0, str(HERE))
import apk3  # noqa: E402  (APK v3 / ADB writer, OpenWrt 25.12)

PKG_NAME = "luci-app-openclaw"
PKG_DESC = "OpenClaw 助手 (openclaw) - official OpenClaw on OpenWrt"
PKG_URL = "https://github.com/openclaw/openclaw"
PKG_LICENSE = "MIT"
PKG_ARCH = "noarch"
# luci-lua-runtime / luci-compat are mandatory on OpenWrt 25.12: the Lua
# controller bridge was split out of luci-base there.
# 依赖必须覆盖"代码里真的会调用"的东西，而不能只列最常用的那几个。
# 这两条是从 iStoreOS 的 luci-app-openclawmgr 学来的（它们把 xz-utils / ca-bundle
# 显式写进 Depends），对照本包发现自己漏了：
#
#   xz-utils   Node.js 官方包是 .tar.xz。install.sh 里 `tar -xJf` 需要 xz；
#              没有 xz 时它退化成 `tar -xf`，而 busybox tar 多半没编进 -J，
#              结果是"解压失败（tar）"—— 一个完全看不出根因的错误。
#              之前的 preflight 只是 oc_warn 一句"将尝试 busybox tar 直接解压"，
#              等于把可能的失败留给用户。
#   ca-bundle  nodejs.org / registry.npmjs.org / 百度网盘 CDN 全是 https。
#              缺 CA 证书时 curl 报 "SSL certificate problem"，repair.sh 也只是
#              给一句提示。这是本包功能的硬前提，该由包管理器装好。
DEPEND = [
    "luci-base",
    "luci-lua-runtime",
    "luci-compat",
    "curl",
    "tar",
    "xz-utils",
    "ca-bundle",
    "jsonfilter",
]

# 本包与 iStoreOS 自带的那个同名管理器包 **完全独立**：不复用它的任何文件路径、
# UCI 段名、服务名、运行用户或数据目录，因此两者可以共存，也就不需要
# replaces / conflicts 声明。

EXEC_SUFFIX = (".sh",)
EXEC_NAMES = {"openclaw", "99-openclaw"}
EXEC_DIRS = ("init.d", "libexec")

SCRIPTS = """#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] && exit 0
# /etc/config/openclaw 不再随包发布 —— 包里带这个文件时，升级会用默认值
# 整份覆盖用户配置（定时备份、加密开关这些全会丢）。改成"只在不存在时
# 从模板生成"，升级就永远不碰用户已有的配置。
# 模板放在 /usr/share 下，覆盖它无害。
if [ ! -f /etc/config/openclaw ] && [ -f /usr/share/openclaw/config.default ]; then
	cp /usr/share/openclaw/config.default /etc/config/openclaw 2>/dev/null
	chmod 600 /etc/config/openclaw 2>/dev/null
fi
chmod +x /etc/init.d/openclaw 2>/dev/null
chmod +x /usr/libexec/openclaw/cli.sh 2>/dev/null
chmod +x /usr/libexec/openclaw/*.sh 2>/dev/null
chmod +x /usr/bin/openclaw 2>/dev/null
rm -f /tmp/luci-indexcache /tmp/luci-modulecache
# 本包发自己的 ACL 文件（/usr/share/rpcd/acl.d/luci-app-openclaw.json）。
# rpcd 只在启动时读 ACL，装完不 reload 的话新会话仍按旧权限表判定，
# 表现为"页面能打开、接口一律 403"，而清 LuCI 缓存治不了这个。
# iStoreOS 的 luci-app-openclawmgr 在 postinst 里做了同样的事。
[ -x /etc/init.d/rpcd ] && /etc/init.d/rpcd reload >/dev/null 2>&1
# 上面的 chmod 都带 2>/dev/null：只读 /usr、overlay 写满时它们会静默失败，
# 用户看到的是"命令不存在"而不是安装失败。这里统一复核一次可执行位，
# 缺了就报错退出，让包管理器把这次安装标成失败。
missing=""
for f in /usr/bin/openclaw /etc/init.d/openclaw /usr/libexec/openclaw/cli.sh; do
	[ -x "$f" ] || missing="$missing $f"
done
for f in /usr/libexec/openclaw/*.sh; do
	[ -x "$f" ] || missing="$missing $f"
done
if [ -n "$missing" ]; then
	echo "openclaw: 以下文件缺少可执行权限，安装不完整：$missing" >&2
	exit 1
fi
exit 0
"""


def log(msg):
    print(f"[build] {msg}")


# --------------------------------------------------------------------------- collect
def collect_files():
    """Return list of (abs_path, arc_rel_path, mode)."""
    items = []

    def walk(src: Path, prefix: str):
        if not src.exists():
            return
        for p in sorted(src.rglob("*")):
            if p.is_dir():
                continue
            rel = p.relative_to(src).as_posix()
            arc = f"{prefix}/{rel}" if prefix else rel
            mode = file_mode(p, arc)
            items.append((p, arc, mode))

    walk(ROOT / "root", "")            # root/* -> /usr/..., /etc/...
    walk(ROOT / "luasrc", "usr/lib/lua/luci")
    return items


def file_mode(p: Path, arc: str) -> int:
    if p.suffix in EXEC_SUFFIX or p.name in EXEC_NAMES:
        return 0o755
    parts = arc.split("/")
    if any(d in EXEC_DIRS for d in parts):
        return 0o755
    return 0o644


def dirs_for(items):
    out = set()
    for _, arc, _ in items:
        parts = arc.split("/")[:-1]
        for i in range(1, len(parts) + 1):
            out.add("/".join(parts[:i]))
    return sorted(out)


# --------------------------------------------------------------------------- tar
def add_dir(tf, name, sde=0):
    ti = tarfile.TarInfo(name)
    ti.type = tarfile.DIRTYPE
    ti.mode = 0o755
    ti.uid = ti.gid = 0
    ti.mtime = sde
    ti.uname = ti.gname = "root"
    ti.pax_headers = {"atime": "0", "ctime": "0"}
    tf.addfile(ti)


def add_file(tf, path: Path, arc: str, mode: int, sde=0):
    data = path.read_bytes()
    ti = tarfile.TarInfo(arc)
    ti.size = len(data)
    ti.mode = mode
    ti.uid = ti.gid = 0
    ti.mtime = sde
    ti.uname = ti.gname = "root"
    ti.type = tarfile.REGTYPE
    ti.pax_headers = {
        "atime": "0",
        "ctime": "0",
        "APK-TOOLS.checksum.SHA1": hashlib.sha1(data).hexdigest(),
    }
    tf.addfile(ti, io.BytesIO(data))


def build_data_tar(items, sde: int = 0) -> bytes:
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w", format=tarfile.PAX_FORMAT) as tf:
        for d in dirs_for(items):
            add_dir(tf, d, sde)
        for path, arc, mode in items:
            add_file(tf, path, arc, mode, sde)
    return buf.getvalue()


def cut_tar_end(blob: bytes) -> bytes:
    """Drop every trailing all-zero 512-byte block (abuild-tar --cut).

    tarfile pads the archive up to a 10240-byte blocking factor, so chopping
    the final 1024 bytes alone still leaves thousands of zero bytes behind.
    Scan block-wise from the end and stop at the first all-zero block
    (content blocks kept).  Every tar segment we emit -- control and
    signature -- must go through this helper so the two can never drift
    apart again.
    """
    end = len(blob)
    while end >= 512 and blob[end - 512:end] == b"\0" * 512:
        end -= 512
    return blob[:end]


def build_control_tar(pkginfo: str, with_script: bool, sde: int = 0) -> bytes:
    """tar *segment*: no trailing end-of-archive records."""
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w", format=tarfile.PAX_FORMAT) as tf:
        raw = pkginfo.encode()
        ti = tarfile.TarInfo(".PKGINFO")
        ti.size = len(raw)
        ti.mode = 0o644
        ti.uid = ti.gid = 0
        ti.mtime = sde
        ti.uname = ti.gname = "root"
        tf.addfile(ti, io.BytesIO(raw))
        if with_script:
            raw = SCRIPTS.encode()
            ti = tarfile.TarInfo(".post-install")
            ti.size = len(raw)
            ti.mode = 0o755
            ti.uid = ti.gid = 0
            ti.mtime = sde
            ti.uname = ti.gname = "root"
            tf.addfile(ti, io.BytesIO(raw))
    return cut_tar_end(buf.getvalue())


def gz(data: bytes) -> bytes:
    buf = io.BytesIO()
    with gzip.GzipFile(fileobj=buf, mode="wb", compresslevel=9, mtime=0) as f:
        f.write(data)
    return buf.getvalue()


# --------------------------------------------------------------------------- signature
def sign_control(control_gz: bytes, keydir: Path, keyname: str):
    keydir.mkdir(parents=True, exist_ok=True)
    priv = keydir / f"{keyname}-key.rsa"
    pub = keydir / f"{keyname}.rsa.pub"
    if not priv.exists():
        subprocess.run(["openssl", "genrsa", "-out", str(priv), "2048"],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run(["openssl", "rsa", "-in", str(priv), "-pubout", "-out", str(pub)],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    ctl_file = keydir / "control.gz"
    ctl_file.write_bytes(control_gz)
    sig = subprocess.run(
        ["openssl", "dgst", "-sha1", "-sign", str(priv), str(ctl_file)],
        check=True, capture_output=True).stdout

    # signature tar segment
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w", format=tarfile.PAX_FORMAT) as tf:
        ti = tarfile.TarInfo(f".SIGN.RSA.{keyname}.rsa.pub")
        ti.size = len(sig)
        ti.mode = 0o644
        ti.uid = ti.gid = 0
        ti.mtime = 0
        ti.uname = ti.gname = "root"
        tf.addfile(ti, io.BytesIO(sig))
    seg = buf.getvalue()
    # Same trailing-zero handling as the control segment: tarfile pads to a
    # 10240-byte blocking factor, so the old "strip the last 1024 bytes"
    # version left thousands of zero bytes behind.  Must stay in sync with
    # build_control_tar() -- both call cut_tar_end().
    seg = cut_tar_end(seg)
    ctl_file.unlink(missing_ok=True)
    return gz(seg), pub


# --------------------------------------------------------------------------- apk v3
def build_apk_v3(items, pkgver, out: Path, sde: int = 0):
    """APK v3 (ADB container) - the format apk-tools 3.x on OpenWrt 25.12 eats."""
    files = []
    for path, arc, mode in items:
        files.append({
            "path": "/" + arc.lstrip("/"),
            "data": path.read_bytes(),
            "mode": mode,
            "mtime": 0,
        })

    payload, data_items = apk3.build_adb(
        name=PKG_NAME,
        version=pkgver,
        description=PKG_DESC,
        arch=PKG_ARCH,
        license_=PKG_LICENSE,
        origin=PKG_NAME,
        maintainer="openclaw",
        url=PKG_URL,
        depends=DEPEND,
        provides=(),
        files=files,
        scripts={apk3.SC_POSTINST: SCRIPTS},
        build_time=sde,
    )
    apk3.build_apk3(str(out), adb_payload=payload, data_items=data_items)
    log(f"apk3 -> {out.name} (OpenWrt 25.12+, install: apk add --allow-untrusted {out.name})")
    return out


# --------------------------------------------------------------------------- ipk
def build_ipk(items, version, release, sde: int, out: Path):
    """Classic opkg package (OpenWrt 24.10 and earlier).

    Real OpenWrt ipks are **not** ar archives.  Verified against
    downloads.openwrt.org (23.05.5 / 24.10.0): the file is a gzip'd tar holding

        ./debian-binary      contents "2.0\n"
        ./data.tar.gz        the payload
        ./control.tar.gz     ./control + ./postinst

    opkg reads it through libarchive, which would also accept the older
    Debian-style ar layout, but we follow upstream so the package matches what
    every opkg release was actually built to consume.
    """
    size = sum(p.stat().st_size for p, _, _ in items)
    control = "\n".join([
        f"Package: {PKG_NAME}",
        f"Version: {version}-r{release}",
        # 从 DEPEND 派生：依赖只有一处定义，改 DEPEND 就够。
        # 曾经在这里另写一份字符串，改 DEPEND 后包里的 Depends 没变，
        # 而构建输出一切正常 —— 只有解包才能发现。
        "Depends: libc, " + ", ".join(DEPEND),
        "Source: %s" % PKG_URL,
        "Section: luci",
        "Maintainer: openclaw",
        "Architecture: all",
        f"Installed-Size: {(size + 1023) // 1024}",
        f"SourceDateEpoch: {sde}",
        f"Description: {PKG_DESC}",
        "",
    ])
    ctl = io.BytesIO()
    with tarfile.open(fileobj=ctl, mode="w", format=tarfile.GNU_FORMAT) as tf:
        for name, content, mode in (("control", control, 0o644),
                                    ("postinst", SCRIPTS, 0o755)):
            raw = content.encode()
            ti = tarfile.TarInfo(f"./{name}")
            ti.size = len(raw)
            ti.mode = mode
            ti.mtime = sde
            ti.uid = ti.gid = 0
            ti.uname = ti.gname = "root"
            tf.addfile(ti, io.BytesIO(raw))

    outer = io.BytesIO()
    with tarfile.open(fileobj=outer, mode="w", format=tarfile.GNU_FORMAT) as tf:
        for name, blob in (("./debian-binary", b"2.0\n"),
                           ("./data.tar.gz", gz(build_data_tar(items, sde))),
                           ("./control.tar.gz", gz(ctl.getvalue()))):
            ti = tarfile.TarInfo(name)
            ti.size = len(blob)
            ti.mode = 0o644
            ti.mtime = sde
            ti.uid = ti.gid = 0
            ti.uname = ti.gname = "root"
            tf.addfile(ti, io.BytesIO(blob))
    out.write_bytes(gz(outer.getvalue()))
    log(f"ipk  -> {out.name}")


# --------------------------------------------------------------------------- run
def build_run(items, version, out: Path, sde: int = 0):
    # 必须走 gz()：gzip.compress 默认会把当前时间写进 gzip 头，
    # 那样每次重建 .run 的 hash 都不同。
    payload = gz(build_data_tar(items, sde))
    import base64
    b64 = base64.b64encode(payload).decode()
    lines = [b64[i:i + 100] for i in range(0, len(b64), 100)]
    body = "\n".join(lines)
    script = f"""#!/bin/sh
# self extracting installer for {PKG_NAME} {version}
set -e
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
cat >"$T/payload.b64" <<'__PAYLOAD__'
{body}
__PAYLOAD__
base64 -d "$T/payload.b64" >"$T/payload.tgz"
echo "extracting ..."
tar -xzf "$T/payload.tgz" -C /
# 同上：只在缺失时生成配置，绝不覆盖用户已有的 /etc/config/openclaw
if [ ! -f /etc/config/openclaw ] && [ -f /usr/share/openclaw/config.default ]; then
	cp /usr/share/openclaw/config.default /etc/config/openclaw 2>/dev/null || true
	chmod 600 /etc/config/openclaw 2>/dev/null || true
fi
chmod +x /etc/init.d/openclaw 2>/dev/null || true
chmod +x /usr/libexec/openclaw/cli.sh 2>/dev/null || true
chmod +x /usr/libexec/openclaw/*.sh 2>/dev/null || true
chmod +x /usr/bin/openclaw 2>/dev/null || true
[ -x /etc/uci-defaults/99-openclaw ] && /etc/uci-defaults/99-openclaw
rm -f /tmp/luci-indexcache
echo "installed {PKG_NAME} {version}"
echo "LuCI: 服务 -> OpenClaw 助手"
"""
    # 二进制写入：Windows 上 write_text() 会把 \n 转成 \r\n，
    # 那样 shebang 就成了 "#!/bin/sh\r"，设备上直接跑不起来。
    out.write_bytes(script.encode("utf-8"))
    out.chmod(0o755)
    log(f"run  -> {out.name}")


# --------------------------------------------------------------------------- versions
def read_makefile_versions() -> tuple:
    """(version, release) from Makefile — the single source of truth.

    早先版本号在 Makefile 和本脚本的 argparse 默认值里各写一份，容易不同步
    （改了 Makefile 忘了改这里，打出来的包版本号就是错的）。
    """
    ver, rel = "0.0.0", "1"
    mk = ROOT / "Makefile"
    if mk.exists():
        for line in mk.read_text(encoding="utf-8").splitlines():
            m = re.match(r"\s*PKG_VERSION\s*:?=\s*(\S+)", line)
            if m:
                ver = m.group(1)
            m = re.match(r"\s*PKG_RELEASE\s*:?=\s*(\S+)", line)
            if m:
                rel = m.group(1)
    return ver, rel


def source_date_epoch() -> int:
    """Reproducible-build timestamp.

    SOURCE_DATE_EPOCH if the caller set it (that is what OpenWrt itself uses),
    otherwise the newest mtime among the packaged sources.  Without this every
    rebuild produced a different builddate and therefore a different hash,
    which made "check the MD5" useless for the user.
    """
    env = os.environ.get("SOURCE_DATE_EPOCH", "").strip()
    if env.isdigit():
        return int(env)
    newest = 0
    for sub in ("root", "luasrc"):
        d = ROOT / sub
        if not d.exists():
            continue
        for f in d.rglob("*"):
            if f.is_file():
                try:
                    newest = max(newest, int(f.stat().st_mtime))
                except OSError:
                    pass
    return newest or 0


# --------------------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser()
    _ver, _rel = read_makefile_versions()
    ap.add_argument("--version", default=_ver,
                    help=f"package version (default: Makefile PKG_VERSION = {_ver})")
    ap.add_argument("--release", default=_rel,
                    help=f"package release (default: Makefile PKG_RELEASE = {_rel})")
    ap.add_argument("--sign", action="store_true", help="also produce an RSA signed apk")
    args = ap.parse_args()

    version = args.version
    pkgver = f"{version}-r{args.release}"
    sde = source_date_epoch()
    DIST.mkdir(exist_ok=True)
    log(f"version {pkgver}, SOURCE_DATE_EPOCH {sde}")

    items = collect_files()
    if not items:
        log("no files collected, aborting")
        return 1
    log(f"collected {len(items)} files")

    installed_size = sum(p.stat().st_size for p, _, _ in items)

    data_tar = build_data_tar(items, sde)
    data_gz = gz(data_tar)
    datahash = hashlib.sha256(data_gz).hexdigest()

    pkginfo = "\n".join([
        f"# Generated by openclaw build_apk.py",
        f"# using fakeroot none",
        f"pkgname = {PKG_NAME}",
        f"pkgver = {pkgver}",
        f"pkgdesc = {PKG_DESC}",
        f"url = {PKG_URL}",
        f"builddate = {sde}",
        f"packager = openclaw builder",
        f"size = {installed_size}",
        f"arch = {PKG_ARCH}",
        f"origin = {PKG_NAME}",
        f"license = {PKG_LICENSE}",
    ] + [f"depend = {d}" for d in DEPEND] + [
        f"datahash = {datahash}",
        "",
    ])

    control_gz = gz(build_control_tar(pkginfo, with_script=True, sde=sde))

    # --- APK v3 (primary: OpenWrt 25.12 / apk-tools 3.x) -------------------
    build_apk_v3(items, pkgver, DIST / f"{PKG_NAME}-{version}-r{args.release}.apk", sde)

    # --- APK v2 (apk-tools 2.x / Alpine) -----------------------------------
    # APK v2 是**纯 gzip 段拼接**，没有 ar 容器：control 段 + data 段依次相连。
    # 实测 Alpine v3.20 的 .apk 就是这个结构（有签名时前面多一段签名）。
    # 早先误按 Debian 的 ar 布局生成，那是错的。
    apk_name = f"{PKG_NAME}-{version}-r{args.release}-v2.apk"
    apk_path = DIST / apk_name
    apk_path.write_bytes(control_gz + data_gz)
    log(f"apk2 -> {apk_name} (apk-tools 2.x / Alpine 专用；OpenWrt 请用 .ipk 或 v3 .apk)")

    if args.sign:
        keyname = f"openclaw-builder-{hashlib.sha1(PKG_NAME.encode()).hexdigest()[:8]}"
        sig_gz, pub = sign_control(control_gz, DIST / "keys", keyname)
        signed = DIST / apk_name.replace("-v2.apk", "-v2-signed.apk")
        # 签名段在最前，其后仍是 control + data，三段依次拼接。
        signed.write_bytes(sig_gz + control_gz + data_gz)
        shutil.copy(pub, DIST / pub.name)
        log(f"apk2 -> {signed.name} (signed; copy {pub.name} to /etc/apk/keys/)")

    build_ipk(items, version, args.release, sde, DIST / f"{PKG_NAME}_{version}_all.ipk")
    build_run(items, version, DIST / f"{PKG_NAME}-{version}.run", sde)

    # sha256 file
    sums = []
    for p in sorted(DIST.glob("*")):
        if p.is_file() and p.name != "sha256sums.txt":
            sums.append(f"{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}")
    (DIST / "sha256sums.txt").write_text("\n".join(sums) + "\n")
    log("dist/ ready")
    return 0


if __name__ == "__main__":
    sys.exit(main())
