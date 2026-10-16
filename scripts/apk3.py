#!/usr/bin/env python3
"""
apk3.py - minimal APK v3 (apk-tools >= 3.0) writer.

OpenWrt 25.12 ships apk-tools 3.x whose packages use the new ADB container
format (magic "ADB"), not the old concatenation of gzip streams. This module
produces such packages without needing the `apk mkpkg` binary.

Format (verified against apk-tools src/adb.c, src/adb_comp.c, src/app_mkpkg.c
and against a real OpenWrt 25.12 package):

  file       := "ADB" comp_byte [2 bytes spec] (raw stream)
  comp_byte  := '.' none | 'd' deflate/0 | 'c' custom(+2 bytes: alg,level)
  body       := "ADB." "pckg" block*
  block      := u32(type_size) payload [pad to 8]
  type_size  := (type << 30) | size      when top 2 bits != 0b11
  type       := 0 ADB (meta) | 1 SIG | 2 DATA ; order ADB[,SIG][,DATA]
  ADB payload:= struct adb_hdr{ u8 compat; u8 ver; u16 reserved; u32 root; }
                followed by adb objects; every offset is relative to the
                start of this payload (i.e. relative to adb_hdr).
  adb_val    := (type << 28) | off   ; type: 1 INT, 2 INT_32, 3 INT_64,
                8/9/a BLOB_8/16/32, d ARRAY, e OBJECT
  object     := u32 count (including itself) + (count-1) * u32 slot
  string     := BLOB_8: u8 length + bytes (no NUL)
  PKGINFO id 3 (HASHES) := SHA256(adb payload with those 20 bytes zeroed)[:20]
  DATA block := u32(type_size) u32 path_idx u32 file_idx <content>
                path_idx/file_idx are 1-based into PATHS
"""

import hashlib
import posixpath
import struct
import zlib

TYPE_INT = 0x1
TYPE_INT_32 = 0x2
TYPE_INT_64 = 0x3
TYPE_BLOB_8 = 0x8
TYPE_BLOB_16 = 0x9
TYPE_BLOB_32 = 0xA
TYPE_ARRAY = 0xD
TYPE_OBJECT = 0xE

BLOCK_ADB = 0
BLOCK_SIG = 1
BLOCK_DATA = 2

# PKGINFO field ids
PI_NAME = 1
PI_VERSION = 2
PI_HASHES = 3
PI_DESCRIPTION = 4
PI_ARCH = 5
PI_LICENSE = 6
PI_ORIGIN = 7
PI_MAINTAINER = 8
PI_URL = 9
PI_REPO_COMMIT = 10
PI_BUILD_TIME = 11
PI_INSTALLED_SIZE = 12
PI_FILE_SIZE = 13
PI_PROVIDER_PRIORITY = 14
PI_DEPENDS = 15
PI_PROVIDES = 16
PI_REPLACES = 17
PI_INSTALL_IF = 18
PI_RECOMMENDS = 19
PI_LAYER = 20
PI_TAGS = 21

# package (root object) field ids
PKG_PKGINFO = 1
PKG_PATHS = 2
PKG_SCRIPTS = 3
PKG_TRIGGERS = 4

# dir / file / acl field ids
DI_NAME, DI_ACL, DI_FILES = 1, 2, 3
FI_NAME, FI_ACL, FI_SIZE, FI_MTIME, FI_HASHES, FI_TARGET = 1, 2, 3, 4, 5, 6
ACL_MODE, ACL_USER, ACL_GROUP, ACL_XATTRS = 1, 2, 3, 4

# script field ids
SC_TRIGGER, SC_PREINST, SC_POSTINST, SC_PREDEINST = 1, 2, 3, 4
SC_POSTDEINST, SC_PREUPGRADE, SC_POSTUPGRADE = 5, 6, 7


class AdbWriter:
    def __init__(self):
        # placeholder for struct adb_hdr {u8 compat, u8 ver, u16 reserved, u32 root}
        self.buf = bytearray(8)

    # ------------------------------------------------------------- raw alloc
    def _alloc(self, data: bytes, align: int = 4) -> int:
        while len(self.buf) % align:
            self.buf.append(0)
        off = len(self.buf)
        self.buf.extend(data)
        return off

    # ------------------------------------------------------------- scalars
    def int_val(self, v: int) -> int:
        if 0 <= v <= 0x0FFFFFFF:
            return (TYPE_INT << 28) | v
        off = self._alloc(struct.pack("<I", v & 0xFFFFFFFF))
        return (TYPE_INT_32 << 28) | off

    def int64_val(self, v: int) -> int:
        off = self._alloc(struct.pack("<Q", v))
        return (TYPE_INT_64 << 28) | off

    def blob(self, data: bytes):
        """returns (adb_val, offset_of_length_prefix, header_len)"""
        n = len(data)
        if n <= 0xFF:
            t, hdr = TYPE_BLOB_8, 1
            raw = bytes([n]) + data
        elif n <= 0xFFFF:
            t, hdr = TYPE_BLOB_16, 2
            raw = struct.pack("<H", n) + data
        else:
            t, hdr = TYPE_BLOB_32, 4
            raw = struct.pack("<I", n) + data
        off = self._alloc(raw)
        return (t << 28) | off, off, hdr

    def blob_val(self, data: bytes) -> int:
        return self.blob(data)[0]

    def string(self, s: str) -> int:
        return self.blob_val(s.encode("utf-8"))

    # ------------------------------------------------------------- object
    def obj(self, slots) -> int:
        """slots: iterable of adb_val ints or None (None -> empty slot)"""
        vals = [v if v is not None else 0 for v in slots]
        while len(vals) > 1 and vals[-1] == 0:
            vals.pop()
        count = len(vals) + 1  # ADB counts the count itself
        raw = struct.pack("<I", count) + b"".join(struct.pack("<I", v) for v in vals)
        off = self._alloc(raw)
        return (TYPE_OBJECT << 28) | off


def _block(payload: bytes, btype: int) -> bytes:
    size = 4 + len(payload)
    if size > 0x3FFFFFFF:
        raise ValueError("adb block too large")
    out = bytearray(struct.pack("<I", (btype << 30) | size))
    out += payload
    while len(out) % 8:
        out.append(0)
    return bytes(out)


def build_adb(
    *,
    name: str,
    version: str,
    description: str = "",
    arch: str = "noarch",
    license_: str = "MIT",
    origin: str = "",
    maintainer: str = "",
    url: str = "",
    depends=(),
    provides=(),
    replaces=(),
    files=(),
    scripts=None,
    build_time: int = 0,
):
    """
    files: iterable of dicts {path, data, mode, mtime, target}
           path is absolute in the target root, e.g. "/etc/init.d/openclaw"
           target: symlink destination (optional)
    scripts: dict {slot_id: text}  (use SC_POSTINST / SC_POSTUPGRADE ...)
    returns (adb_payload_bytes, [(path_idx, file_idx, data), ...])
    """
    w = AdbWriter()

    # ---- pkginfo (HASHES filled in later)
    h_val, h_off, h_hdr = w.blob(b"\0" * 20)

    def dep_obj(spec: str) -> int:
        # plain name -> { NAME } only; "name=1.2" -> { NAME, VERSION }
        if "=" in spec:
            n, v = spec.split("=", 1)
            return w.obj([w.string(n), w.string(v)])
        return w.obj([w.string(spec)])

    deps = w.obj([dep_obj(d) for d in depends]) if depends else None
    provs = w.obj([dep_obj(d) for d in provides]) if provides else None
    reps = w.obj([dep_obj(d) for d in replaces]) if replaces else None

    installed_size = sum(len(f["data"]) for f in files) or 1
    file_size = sum(len(f["data"]) for f in files)

    pkginfo = w.obj(
        [
            w.string(name),            # 1 NAME
            w.string(version),         # 2 VERSION
            h_val,                     # 3 HASHES
            w.string(description),     # 4 DESCRIPTION
            w.string(arch),            # 5 ARCH
            w.string(license_),        # 6 LICENSE
            w.string(origin),          # 7 ORIGIN
            w.string(maintainer),      # 8 MAINTAINER
            w.string(url),             # 9 URL
            None,                      # 10 REPO_COMMIT
            w.int_val(build_time),     # 11 BUILD_TIME
            w.int_val(installed_size), # 12 INSTALLED_SIZE
            w.int_val(file_size),      # 13 FILE_SIZE
            None,                      # 14 PROVIDER_PRIORITY
            deps,                      # 15 DEPENDS
            provs,                     # 16 PROVIDES
            reps,                      # 17 REPLACES
            None,                      # 18 INSTALL_IF
            None,                      # 19 RECOMMENDS
            None,                      # 20 LAYER
            None,                      # 21 TAGS
        ]
    )

    # ---- paths
    # apk-tools expects every directory (including every intermediate one and
    # the root, whose stored name is the empty string) to be listed, exactly
    # like real OpenWrt 25.12 packages do.
    by_dir = {}
    all_dirs = {""}
    for f in files:
        d = posixpath.dirname(f["path"]).lstrip("/")
        by_dir.setdefault(d, []).append(f)
        parts = d.split("/") if d else []
        for i in range(1, len(parts)):
            all_dirs.add("/".join(parts[:i]))
        if d:
            all_dirs.add(d)

    dir_objs = []
    data_items = []
    for p_idx, dname in enumerate(sorted(all_dirs), start=1):
        acl = w.obj([w.int_val(0o755), w.string("root"), w.string("root")])
        f_objs = []
        for f_idx, f in enumerate(sorted(by_dir.get(dname, ()), key=lambda x: x["path"]), start=1):
            facl = w.obj([w.int_val(f.get("mode", 0o644)), w.string("root"), w.string("root")])
            data = f["data"]
            target = f.get("target")
            digest = hashlib.sha256(data).digest() if not target else b""
            f_objs.append(
                w.obj(
                    [
                        w.string(posixpath.basename(f["path"])),   # 1 NAME
                        facl,                                      # 2 ACL
                        w.int_val(len(data)),                      # 3 SIZE
                        w.int_val(int(f.get("mtime", 0))),         # 4 MTIME
                        w.blob_val(digest) if digest else None,    # 5 HASHES
                        w.blob_val(target.encode()) if target else None,  # 6 TARGET
                    ]
                )
            )
            if not target and len(data):
                data_items.append((p_idx, f_idx, data))
        dir_objs.append(
            w.obj([w.string(dname), acl, w.obj(f_objs) if f_objs else None])
        )

    paths = w.obj(dir_objs) if dir_objs else None

    # ---- scripts
    scripts_obj = None
    if scripts:
        slots = [None] * (SC_POSTUPGRADE + 1)
        for sid, text in scripts.items():
            if text:
                slots[sid] = w.blob_val(text.encode("utf-8"))
        scripts_obj = w.obj(slots[SC_TRIGGER:])

    # ---- root
    root = w.obj([pkginfo, paths, scripts_obj, None])
    struct.pack_into("<I", w.buf, 4, root)

    # ---- unique id: SHA256 over the payload with the HASHES bytes zeroed
    payload = w.buf
    start = h_off + h_hdr
    saved = bytes(payload[start:start + 20])
    payload[start:start + 20] = b"\0" * 20
    digest = hashlib.sha256(bytes(payload)).digest()[:20]
    payload[start:start + 20] = digest
    assert saved == b"\0" * 20

    return bytes(payload), data_items


def build_apk3(path, *, adb_payload, data_items, level=9):
    """assemble the .apk container"""
    body = bytearray(b"ADB." + b"pckg")
    body += _block(adb_payload, BLOCK_ADB)
    for p_idx, f_idx, data in data_items:
        hdr = struct.pack("<II", p_idx, f_idx)
        body += _block(hdr + data, BLOCK_DATA)

    co = zlib.compressobj(level, zlib.DEFLATED, -zlib.MAX_WBITS)
    comp = co.compress(bytes(body)) + co.flush()
    blob = b"ADBc" + bytes([1, level]) + comp
    with open(path, "wb") as fh:
        fh.write(blob)
    return path


# ------------------------------------------------------------------ reading
def _decompress(blob: bytes) -> bytes:
    if blob[:3] != b"ADB":
        raise ValueError("not an ADB container")
    c = blob[3:4]
    if c == b".":
        return blob[4:]
    if c == b"d":
        return zlib.decompress(blob[4:], -zlib.MAX_WBITS)
    if c == b"c":
        alg, _lvl = blob[4], blob[5]
        raw = blob[6:]
        if alg == 0:
            return raw
        if alg == 1:
            return zlib.decompress(raw, -zlib.MAX_WBITS)
        raise ValueError(f"unsupported compression alg {alg}")
    raise ValueError(f"unknown compression byte {c!r}")


def read_apk3(path):
    """parse back what we wrote - used by the self check"""
    blob = open(path, "rb").read()
    body = _decompress(blob)
    if body[:8] != b"ADB.pckg":
        raise ValueError("bad schema header")
    blocks = []
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
        blocks.append((t, off + hdr, size - hdr))
        off += size
        while off % 8:
            off += 1
    return body, blocks


if __name__ == "__main__":
    import sys

    print(__doc__)
    sys.exit(0)
