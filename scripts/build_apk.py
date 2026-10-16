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
import time
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
DEPEND = [
    "luci-base",
    "luci-lua-runtime",
    "luci-compat",
    "curl",
    "tar",
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
chmod +x /etc/init.d/openclaw 2>/dev/null
chmod +x /usr/libexec/istorec/openclaw.sh 2>/dev/null
chmod +x /usr/libexec/openclaw/*.sh 2>/dev/null
rm -f /tmp/luci-indexcache /tmp/luci-modulecache
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
    out = buf.getvalue()
    # cut the two 512-byte end records (abuild-tar --cut)
    if out.endswith(b"\0" * 1024):
        out = out[:-1024]
    return out


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
    if seg.endswith(b"\0" * 1024):
        seg = seg[:-1024]
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


# --------------------------------------------------------------------------- ar
# ipk 和 APK v2 都是**普通 ar 归档**：必须以 "!<arch>\n" 开头，每个成员前面
# 有 60 字节的 ASCII 头（名字/时间/uid/gid/权限/大小/魔数），成员数据按 2 字节
# 对齐。少了这层容器，opkg / apk 会直接报 "file format is invalid or inconsistent"。
def ar_member(name: str, data: bytes) -> bytes:
    """One ar(5) member: 60-byte header + data + even-byte padding."""
    nm = name.encode()
    if len(nm) > 16:
        raise ValueError(f"ar member name too long ({len(nm)}): {name}")
    hdr = (
        nm.ljust(16, b" ")                      # name (BSD form: space padded)
        + b"0".ljust(12, b" ")                  # mtime
        + b"0".ljust(6, b" ")                   # uid
        + b"0".ljust(6, b" ")                   # gid
        + b"100644".ljust(8, b" ")              # mode
        + str(len(data)).encode().ljust(10, b" ")   # size
        + b"\x60\n"                             # header magic "`\n"
    )
    if len(hdr) != 60:
        raise AssertionError(f"ar header must be 60 bytes, got {len(hdr)}")
    out = hdr + data
    if len(data) % 2:
        out += b"\n"                            # members are 2-byte aligned
    return out


def build_ar_package(segments) -> bytes:
    """Wrap [(name, payload), ...] into a complete ar archive."""
    buf = io.BytesIO()
    buf.write(b"!<arch>\n")
    for name, data in segments:
        buf.write(ar_member(name, data))
    return buf.getvalue()


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
        "Depends: libc, luci-base, luci-lua-runtime, luci-compat, curl, tar, jsonfilter",
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
def build_run(items, version, out: Path):
    payload = gzip.compress(build_data_tar(items), 9)
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
chmod +x /etc/init.d/openclaw 2>/dev/null || true
chmod +x /usr/libexec/istorec/openclaw.sh 2>/dev/null || true
chmod +x /usr/libexec/openclaw/*.sh 2>/dev/null || true
[ -x /etc/uci-defaults/99-openclaw ] && /etc/uci-defaults/99-openclaw
rm -f /tmp/luci-indexcache
echo "installed {PKG_NAME} {version}"
echo "LuCI: 服务 -> OpenClaw 助手"
"""
    out.write_text(script)
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
    build_run(items, version, DIST / f"{PKG_NAME}-{version}.run")

    # sha256 file
    sums = []
    for p in sorted(DIST.glob("*")):
        if p.is_file() and p.suffix != ".sha256":
            sums.append(f"{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}")
    (DIST / "sha256sums.txt").write_text("\n".join(sums) + "\n")
    log("dist/ ready")
    return 0


if __name__ == "__main__":
    sys.exit(main())
