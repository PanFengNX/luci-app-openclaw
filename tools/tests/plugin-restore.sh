#!/bin/sh
set -eu
f=root/usr/libexec/openclaw/backup.sh
grep -q 'stage/plugins"/\*' "$f"
grep -q '\.restore\.\$\$' "$f"
grep -q 'cp -a "\$_plugin" "\$_plugin_target"' "$f"
! grep -q 'oc_rmtree "\$_dst"' "$f"
printf '    共 3 项，0 项失败\n'
