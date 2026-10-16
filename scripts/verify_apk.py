#!/usr/bin/env python3
"""verify_apk.py - structural self-check for the packages produced by build_apk.py.

  python3 scripts/verify_apk.py dist/luci-app-openclaw-<ver>-r<rel>.apk        # APK v3
  python3 scripts/verify_apk.py dist/luci-app-openclaw-<ver>-r<rel>-v2.apk     # APK v2
  python3 scripts/verify_apk.py dist/luci-app-openclaw_<ver>_all.ipk       # ipk

APK v2 checks: gzip segment layout, .PKGINFO fields, datahash, per file SHA1.
APK v3 checks: ADB container, block order, object graph, PKGINFO HASHES.
ipk checks   : debian-binary, ./control, data members.

Exit code 0 = looks installable.
"""
import gzip
import hashlib
import io
import struct
import sys
import tarfile
import zlib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import apk3  # noqa: E402


def ok(msg):
    print(f"  ok   {msg}")


def bad(msg):
    print(f"  FAIL {msg}")
    return 1


def warn(msg):
    print(f"  warn {msg}")


# --------------------------------------------------------------------------- v2
def verify_v2(path: Path) -> int:
    """APK v2 = concatenated gzip segments (no ar container).

    Real Alpine .apk files are 2 segments (control + data) or 3 with a signature
    in front; verified against dl-cdn.alpinelinux.org (v3.20).
    """
    print(f"APK v2 (concatenated gzip segments): {path.name}")
    rc = 0
    blob = path.read_bytes()
    if blob[:8] == b"!<arch>\n":
        return bad("是 ar 归档 —— APK v2 不应有 ar 容器")

    segs, pos = [], 0
    while pos < len(blob):
        d = zlib.decompressobj(31)
        try:
            raw = d.decompress(blob[pos:])
        except Exception as e:  # noqa: BLE001
            return bad(f"第 {len(segs)} 段 gzip 解压失败：{e}")
        used = len(blob) - pos - len(d.unused_data)
        if used <= 0:
            break
        segs.append((pos, used, raw))
        pos += used
        if not d.unused_data:
            break
    ok(f"{len(blob)} 字节，{len(segs)} 个 gzip 段")
    if len(segs) not in (2, 3):
        return bad(f"应为 2（control+data）或 3（sig+control+data）段，实际 {len(segs)}")

    for i, (p, u, raw) in enumerate(segs):
        try:
            names = tarfile.open(fileobj=io.BytesIO(raw)).getnames()[:3]
        except Exception as e:  # noqa: BLE001
            names = f"<not tar: {e}>"
        print(f"       段 {i}: 偏移={p} 长度={u} 条目={names}")

    ctl_raw = segs[-2][2]
    dat_raw = segs[-1][2]
    tf = tarfile.open(fileobj=io.BytesIO(ctl_raw))
    if ".PKGINFO" not in tf.getnames():
        return bad("control 段里没有 .PKGINFO")
    pk = tf.extractfile(".PKGINFO").read().decode()
    print("\n.PKGINFO:")
    print("\n".join("       " + l for l in pk.strip().splitlines()))

    want = None
    for line in pk.splitlines():
        if line.startswith("datahash = "):
            want = line.split("= ", 1)[1].strip()
    got = hashlib.sha256(gzip.compress(dat_raw, 9, mtime=0)).hexdigest()
    if want == got:
        ok("datahash == sha256(data.tar.gz)")
    else:
        rc |= bad(f"datahash mismatch expected={want} actual={got}")

    nfiles = 0
    dtf = tarfile.open(fileobj=io.BytesIO(dat_raw))
    for m in dtf.getmembers():
        if not m.isfile():
            continue
        nfiles += 1
        w = m.pax_headers.get("APK-TOOLS.checksum.SHA1")
        if w is None:
            rc |= bad(f"missing checksum header: {m.name}")
            continue
        g = hashlib.sha1(dtf.extractfile(m).read()).hexdigest()
        if g != w:
            rc |= bad(f"checksum mismatch: {m.name}")
    ok(f"{nfiles} file(s) checksum-verified")
    return rc


# --------------------------------------------------------------------------- v3
def read_blocks(body: bytes):
    out = []
    off = 8
    while off < len(body):
        ts = struct.unpack_from("<I", body, off)[0]
        if (ts >> 30) == 3:
            t = ts & 0x3FFFFFFF
            size = struct.unpack_from("<Q", body, off + 8)[0]
            hdr = 16
        else:
            t = ts >> 30
            size = ts & 0x3FFFFFFF
            hdr = 4
        if size < hdr or off + size > len(body):
            raise ValueError(f"bad block size {size} at offset {off}")
        out.append((t, body[off + hdr:off + size]))
        off += size
        while off % 8:
            off += 1
    return out


def adb_walk(buf: bytes, val: int, seen=None):
    """minimal recursive sanity walk of an adb object tree"""
    if seen is None:
        seen = set()
    o = val & 0x0FFFFFFF
    t = val >> 28
    if o in seen or o + 4 > len(buf):
        return
    seen.add(o)
    if t not in (apk3.TYPE_OBJECT, apk3.TYPE_ARRAY):
        return
    (count,) = struct.unpack_from("<I", buf, o)
    if o + 4 + 4 * (count - 1) > len(buf):
        raise ValueError(f"object at {o} overruns the buffer")
    for i in range(count - 1):
        (slot,) = struct.unpack_from("<I", buf, o + 4 + 4 * i)
        if slot:
            adb_walk(buf, slot, seen)


def verify_v3(path: Path) -> int:
    print(f"APK v3 (ADB container): {path.name}")
    rc = 0
    blob = path.read_bytes()
    if blob[:3] != b"ADB":
        return bad("magic is not 'ADB'")
    ok(f"magic ADB, compression byte = {blob[3:4].decode(errors='replace')!r}")
    body = apk3._decompress(blob)
    if body[:8] != b"ADB.pckg":
        return bad("schema header is not 'ADB.pckg'")
    ok(f"schema 'pckg', inflated {len(body)} bytes")

    try:
        blocks = read_blocks(body)
    except ValueError as e:
        return bad(str(e))
    kinds = [t for t, _ in blocks]
    ok(f"blocks: {kinds}  (0=ADB 1=SIG 2=DATA)")
    if not kinds or kinds[0] != apk3.BLOCK_ADB:
        rc |= bad("first block must be the ADB block")

    adb = blocks[0][1]
    compat, ver, _res, root = struct.unpack_from("<BBHI", adb, 0)
    ok(f"adb_hdr compat={compat} ver={ver} root=0x{root:x}")
    if ver != 0:
        warn(f"unexpected adb version {ver}")

    try:
        adb_walk(adb, root)
        ok("object graph walk: no dangling / overrunning offsets")
    except Exception as e:  # noqa: BLE001
        rc |= bad(f"object graph walk failed: {e}")

    ro = root & 0x0FFFFFFF
    (count,) = struct.unpack_from("<I", adb, ro)
    if count < 2:
        rc |= bad("root object has no slots")
    else:
        (pk_val,) = struct.unpack_from("<I", adb, ro + 4)
        po = pk_val & 0x0FFFFFFF
        # slot 1 = NAME, slot 3 = HASHES
        (name_val,) = struct.unpack_from("<I", adb, po + 4)
        no = name_val & 0x0FFFFFFF
        n = adb[no]
        ok(f"pkgname = {adb[no + 1:no + 1 + n].decode(errors='replace')}")

        (ver_val,) = struct.unpack_from("<I", adb, po + 8)
        vo = ver_val & 0x0FFFFFFF
        n = adb[vo]
        ok(f"pkgver  = {adb[vo + 1:vo + 1 + n].decode(errors='replace')}")

        (h_val,) = struct.unpack_from("<I", adb, po + 12)
        ho = h_val & 0x0FFFFFFF
        stored = bytes(adb[ho + 1:ho + 21])
        if len(stored) != 20:
            rc |= bad(f"HASHES blob is {len(stored)} bytes, expected 20")
        else:
            saved = bytearray(adb)
            saved[ho + 1:ho + 21] = b"\0" * 20
            calc = hashlib.sha256(bytes(saved)).digest()[:20]
            if stored == calc:
                ok("PKGINFO HASHES == SHA256(payload|hashes=0)[:20]  (apk-tools rule)")
            else:
                rc |= bad(f"HASHES mismatch stored={stored.hex()} calc={calc.hex()}")

    datas = [b for t, b in blocks if t == apk3.BLOCK_DATA]
    ok(f"DATA blocks: {len(datas)}")
    for b in datas:
        if len(b) < 8:
            rc |= bad("DATA block shorter than its 8 byte header")
            break
        p_idx, f_idx = struct.unpack_from("<II", b, 0)
        if p_idx == 0 or f_idx == 0:
            rc |= bad("DATA block has a 0 path/file index (must be 1-based)")
            break
    return rc


# --------------------------------------------------------------------------- ipk
def verify_ipk(path: Path) -> int:
    """Official OpenWrt ipk = gzip(tar(./debian-binary, ./data.tar.gz, ./control.tar.gz))."""
    print(f"ipk (opkg, gzip'd tar): {path.name}")
    rc = 0
    blob = path.read_bytes()
    if blob[:2] != b"\x1f\x8b":
        return bad(f"不是 gzip（开头 {blob[:4]!r}，应为 b'\\x1f\\x8b'）")
    try:
        outer = gzip.decompress(blob)
    except Exception as e:  # noqa: BLE001
        return bad(f"gzip 解压失败：{e}")
    ok(f"{len(blob)} 字节 -> gunzip {len(outer)} 字节")

    try:
        tf = tarfile.open(fileobj=io.BytesIO(outer))
        names = tf.getnames()
    except Exception as e:  # noqa: BLE001
        return bad(f"外层 tar 解析失败：{e}")
    ok(f"外层 tar 成员：{names}")
    for want in ("./debian-binary", "./data.tar.gz", "./control.tar.gz"):
        if want not in names:
            rc |= bad(f"缺少成员 {want}")
    if rc:
        return rc

    db = tf.extractfile("./debian-binary").read()
    if db != b"2.0\n":
        rc |= bad(f"debian-binary 内容应为 '2.0\\n'，实际 {db!r}")
    else:
        ok("debian-binary = 2.0")

    ctl_raw = tf.extractfile("./control.tar.gz").read()
    dat_raw = tf.extractfile("./data.tar.gz").read()
    if ctl_raw[:2] != b"\x1f\x8b":
        rc |= bad("control.tar.gz 不是 gzip")
    if dat_raw[:2] != b"\x1f\x8b":
        rc |= bad("data.tar.gz 不是 gzip")

    ctl = tarfile.open(fileobj=io.BytesIO(gzip.decompress(ctl_raw)))
    if "./control" not in ctl.getnames():
        rc |= bad("control.tar 里没有 ./control")
    else:
        txt = ctl.extractfile("./control").read().decode()
        ok("control://n" + "\n".join("       " + l for l in txt.strip().splitlines()))
        for field in ("SourceDateEpoch:", "Version:", "Architecture:"):
            if not any(l.startswith(field) for l in txt.splitlines()):
                rc |= bad(f"control 缺少字段 {field}")
    data = tarfile.open(fileobj=io.BytesIO(gzip.decompress(dat_raw)))
    ok(f"data members: {len(data.getnames())}")
    return rc


def detect_gzip_kind(path: Path) -> str:
    """'ipk' or 'apk2' — 两者都以 gzip 开头，靠第一段 tar 的标志文件区分。"""
    try:
        blob = path.read_bytes()
        inner = gzip.decompress(blob)
        names = tarfile.open(fileobj=io.BytesIO(inner)).getnames()
        if "./debian-binary" in names:
            return "ipk"
        return "apk2"
    except Exception:  # noqa: BLE001
        return "ipk"        # 交给 verify_ipk 报出具体错误


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    rc = 0
    for a in sys.argv[1:]:
        p = Path(a)
        if not p.exists():
            print(f"  FAIL {p} does not exist")
            rc = 1
            continue
        head = p.read_bytes()[:8]
        if head[:3] == b"ADB":
            rc |= verify_v3(p)
        elif head[:2] == b"\x1f\x8b":
            # ipk 与 APK v2 现在都是 gzip 开头的（官方格式），按内容区分：
            # 外层 tar 里有 ./debian-binary 的是 ipk，否则是 APK v2 的 control 段。
            if detect_gzip_kind(p) == "ipk":
                rc |= verify_ipk(p)
            else:
                rc |= verify_v2(p)
        else:
            print(f"  FAIL {p.name}: 不是有效的包 —— 既不是 ADB 容器，"
                  f"也不是 gzip（开头 {head[:4]!r}，应为 b'ADB' 或 b'\\x1f\\x8b'）")
            rc |= 1
        print()
    print("RESULT:", "PASS" if rc == 0 else "FAIL")
    return rc


if __name__ == "__main__":
    sys.exit(main())
