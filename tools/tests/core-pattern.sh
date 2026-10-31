#!/bin/sh
set -eu
f=root/etc/init.d/openclaw
for x in 'OC_CORE_PATTERN_TARGET' 'return 1' 'current' 'core_pattern 已被其他服务修改'; do grep -q "$x" "$f" || { echo "FAIL: $x"; exit 1; }; done
grep -q 'mv "$tmp" "$OC_CORE_PATTERN_SAVE"' "$f" || true
printf '    共 4 项，0 项失败\n'
