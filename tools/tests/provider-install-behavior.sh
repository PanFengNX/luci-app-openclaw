#!/bin/sh
# provider-install-behavior.sh — 默认安装不预装 provider，升级保留已有 UCI 值
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
PROJ="$(cd "$HERE/../.." && pwd)"
PY=""
HOME_DIR="${HOME:-}"
for cand in python3 python \
    "$HOME_DIR/.workbuddy/binaries/python/versions/3.13.12/python.exe"; do
	if command -v "$cand" >/dev/null 2>&1 || [ -x "$cand" ]; then PY="$cand"; break; fi
done
[ -n "$PY" ] || { echo "    跳过：找不到 python"; exit 0; }
"$PY" - "$PROJ" <<'PYEOF'
import pathlib, re, sys
p = pathlib.Path(sys.argv[1])
uci = (p / 'root/etc/uci-defaults/99-openclaw').read_text(encoding='utf-8')
defaults = (p / 'root/usr/share/openclaw/config.default').read_text(encoding='utf-8')
install = (p / 'root/usr/libexec/openclaw/install.sh').read_text(encoding='utf-8')
models = (p / 'root/usr/libexec/openclaw/models.sh').read_text(encoding='utf-8')
total = failed = 0
def check(ok, msg):
    global total, failed
    total += 1
    print('    %s  %s' % ('ok  ' if ok else 'FAIL', msg))
    failed += not ok

def empty_option(src, name):
    return bool(re.search(r"option\s+%s\s+''" % re.escape(name), src))
def empty_uci_default(src, name):
    return bool(re.search(r"uci -q set openclaw\.main\.%s=" % re.escape(name), src)) and not bool(re.search(r"uci -q set openclaw\.main\.%s=deepseek" % re.escape(name), src))
check(empty_option(defaults, 'preinstall_providers'), 'config.default 的 preinstall_providers 默认为空')
check(empty_uci_default(uci, 'preinstall_providers'), 'uci-defaults 的 preinstall_providers 默认为空')
check('uci -q get openclaw.main.preinstall_providers >/dev/null 2>&1 ||' in uci, '升级仅在 UCI 键不存在时写入默认')
check('uci_get main.preinstall_providers \'\'' in install, 'install.sh 读取空默认而非 DeepSeek')
check('if [ -z "$pre" ]; then' in install, '空值跳过预装')
check('require_plugin "$provider"' in models, '模型页应用仍通过 require_plugin 处理显式 provider')
check('preinstall_providers=deepseek' not in uci + defaults + install, '未残留 DeepSeek 默认值')
print('    共 %s 项，%s 项失败' % (total, failed))
sys.exit(1 if failed else 0)
PYEOF
