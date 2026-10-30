#!/bin/sh
# model-page-source.sh — 模型页只从当前 provider 的 models_url 拉取，失败仅回退随包预设
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
src = (p / 'luasrc/view/openclaw/model.htm').read_text(encoding='utf-8')
total = failed = 0
def check(ok, msg):
    global total, failed
    total += 1
    print('    %s  %s' % ('ok  ' if ok else 'FAIL', msg))
    failed += not ok

check('models_url:' in src, '页面保留 provider models_url API')
check(not re.search(r"\bmodels:\s*['\"]<%=[^\n]*['\"]", src), '页面删除本机 models API')
check('btn-discover' not in src, '页面删除本机模型列表按钮')
check('function fetchLocalModels' not in src, '页面删除 fetchLocalModels')
check(not re.search(r"API\.models(?!_url)", src), '页面不再调用本机 models API')
check('fetchUpstream(true)' not in src and 'fetchLocalModels(' not in src, '失败路径不再回退本机模型列表')
check('可能不是最新' in src or '可能过时' in src, '预设回退明确提示模型列表可能过时')
check('（上游）' not in src and '（本机）' not in src, '模型选项不拼接来源后缀')
check('上游 → 本机 OpenClaw' not in src and '来自本机 OpenClaw' not in src, '页面不保留本机模型来源文案')
check('get(API.models_url' in src, '模型列表请求使用当前 provider 的 models_url')
check('fillModels(UPSTREAM, false)' in src, '实时 API 成功时不混入静态预设')
check('includePreset !== false' in src, 'API 失败时保留随包预设')
print('    共 %s 项，%s 项失败' % (total, failed))
sys.exit(1 if failed else 0)
PYEOF
