#!/bin/sh
# Regression checks for cloud backup listing and installer URL/version handling.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
PROJ="$(cd "$HERE/../.." && pwd)"
CLOUD="$PROJ/root/usr/libexec/openclaw/cloud.sh"
python3 - "$CLOUD" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text(encoding='utf-8')
checks = [
    ('3.8.4:amd64' in s and '02050e9a5ed5c5ddc314bf920c103238a669366a130e3bd43a125d83fdd00548' in s, '3.8.4 amd64 hash is pinned'),
    ('3.8.4:arm64' in s and 'abb39a1f7dc0bf44883bbb30b057e6e65c5db64ffdce7c2ae92dea60a136362a' in s, '3.8.4 arm64 hash is pinned'),
    ('cloud_installer_url()' in s and 'cloud_norm_version' in s, 'installer URL path uses normalized versions'),
    ('cloud_ls_tsv' in s and 'server_filename' in s and 'isdir' in s, 'remote list parser handles bdpan JSON fields'),
    ('stat -c \'%a\' "$b"' in s and '[ -x "$b" ]' in s, 'existing binary permission safety check is present'),
]
fail=0
for ok,msg in checks:
    print(('  ok    ' if ok else '  FAIL  ')+msg)
    fail |= not ok
print('    共 %d 项，%d 项失败' % (len(checks), int(fail)))
sys.exit(fail)
PY
