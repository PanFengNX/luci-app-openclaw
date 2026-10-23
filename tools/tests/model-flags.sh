#!/bin/sh
# model-flags.sh — 模型页三颗状态药丸（插件已装 / 已配置 / 已有 Key）的判定
#
# 用户实测：插件还没装、Key 也没配，三颗药丸全绿。根因是三处都用了过松的
# 文本匹配：
#
#   plugin_installed()   最后一条兜底是 `grep -q "$p" "$(oc_conf)"` ——
#                        provider id 在 openclaw.json 里出现过就算"已安装"。
#                        默认模型写成 "deepseek/deepseek-v4.1-flash-1017"
#                        就含 deepseek 子串，于是插件没装也显示「插件已装」。
#   provider_configured() `grep -q "\"$1\"" "$(oc_conf)"` —— 同上，只要求
#                        id 以带引号形式出现过，不要求在 models.providers 下。
#   provider_has_key()    拿 provider_configured 当代理 —— 配了 baseUrl /
#                        models 但没有 Key 也会说「已有 Key」。
#
# 断言（全部用真实的解析函数跑真实 JSON，只把"路径"打桩）：
#   1. 只有默认模型（"deepseek/xxx"）时：三项全 false
#   2. 有 models.providers.deepseek 但没有 apiKey：已配置 true、Key false
#   3. apiKey 非空：两项都 true
#   4. .env 里空赋值不算有 Key；有值才算
#   5. 任何情况下都不会因为"配置里出现过 deepseek"就判定插件已装
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

"$PY" - "$PROJ" <<'PYEOF'
import json
import pathlib
import re
import subprocess
import sys
import tempfile

proj = pathlib.Path(sys.argv[1])
NL = chr(10)
src = (proj / 'root/usr/libexec/openclaw/models.sh').read_text(encoding='utf-8')

total = 0
failed = 0


def check(ok, desc, detail=''):
    global total, failed
    total += 1
    print('    %s  %s%s' % ('ok  ' if ok else 'FAIL', desc, ('  ' + detail) if detail else ''))
    if not ok:
        failed += 1


def func(name):
    lines = src.splitlines()
    starts = [(i, m.group(1)) for i, l in enumerate(lines)
              for m in [re.match(r'^([a-z_][a-z0-9_]*)\(\)\s*\{', l)] if m]
    for idx, (ln, nm) in enumerate(starts):
        if nm == name:
            end = starts[idx + 1][0] if idx + 1 < len(starts) else len(lines)
            return NL.join(lines[ln:end])
    raise AssertionError('取不到函数 ' + name)


work = pathlib.Path(tempfile.mkdtemp())


def P(p):
    s = pathlib.Path(p).as_posix()
    return '/c' + s[2:] if len(s) > 1 and s[1] == ':' else s


# ---------------------------------------------------------------- 静态断言
def code_of(name):
    return NL.join(l.split('#', 1)[0] for l in func(name).splitlines())


check('configured_has' in code_of('provider_configured'),
      'provider_configured 走 configured_has（不靠 grep 全文件）')
check('grep' not in code_of('provider_configured'),
      'provider_configured 里没有 grep')
check('configured_field' in code_of('provider_has_key'),
      'provider_has_key 直接读 providers.<id>.apiKey')
check('provider_configured' not in code_of('provider_has_key'),
      'provider_has_key 不再拿"已配置"当代理')
check('grep -q "$p"' not in code_of('plugin_installed'),
      'plugin_installed 没有"id 出现在配置里就算已装"的兜底')

# ---------------------------------------------------------------- 行为断言
# 真实的解析函数 + 打桩的路径
runner = work / 'run.sh'
runner.write_text(NL.join([
    '#!/bin/sh',
    'CONF="$1"; ENVF="$2"; HOME_DIR="$3"',
    'oc_conf() { printf "%s" "$CONF"; }',
    'oc_data_dir() { printf "%s" "$HOME_DIR"; }',
    'oc_oc_dir() { printf "%s" "$HOME_DIR/nonexistent-openclaw"; }',
    'oc_oc_bin() { printf "%s" "$HOME_DIR/nonexistent-bin"; }',
    'plugins_list_cached() { :; }',
    # deepseek 的 env 变量名；其余 provider 没有
    'preset_field() {',
    '  case "$1:$2" in',
    '    deepseek:env) printf "DEEPSEEK_API_KEY" ;;',
    '    *) : ;;',
    '  esac',
    '}',
    func('json_slice'),
    func('json_keys'),
    func('json_scalar'),
    func('configured_providers'),
    func('configured_field'),
    func('configured_list'),
    func('configured_has'),
    func('provider_configured'),
    func('provider_has_key'),
    func('plugin_installed'),
    'f() { "$1" deepseek >/dev/null 2>&1 && echo true || echo false; }',
    'printf "%s %s %s\\n" "$(f plugin_installed)" "$(f provider_configured)" "$(f provider_has_key)"',
    '',
]), encoding='utf-8', newline=NL)


def run(conf_obj, env_text=''):
    cf = work / 'openclaw.json'
    cf.write_text(json.dumps(conf_obj, ensure_ascii=False), encoding='utf-8')
    home = work / 'home'
    home.mkdir(parents=True, exist_ok=True)
    # 真实布局：oc_data_dir() 本身就是 <base>/home/.openclaw，.env 直接放在它下面
    ef = home / '.env'
    ef.write_text(env_text, encoding='utf-8')
    r = subprocess.run(['sh', P(runner), P(cf), P(ef), P(home)],
                       capture_output=True, text=True, timeout=60)
    return r.stdout.strip()


def flags(s):
    parts = s.split()
    return parts if len(parts) == 3 else ['?', '?', '?']


# 1) 只有默认模型，没有 providers 段
inst, conf, key = flags(run({
    "agents": {"defaults": {"model": {"primary": "deepseek/deepseek-v4.1-flash-1017"}}}
}))
check(inst == 'false', '只有默认模型 → 插件未装', 'installed=%s' % inst)
check(conf == 'false', '只有默认模型 → 未配置', 'configured=%s' % conf)
check(key == 'false', '只有默认模型 → 无 Key', 'hasKey=%s' % key)

# 2) 有 provider 段但没有 apiKey
inst, conf, key = flags(run({
    "models": {"providers": {"deepseek": {"baseUrl": "https://api.deepseek.com"}}}
}))
check(inst == 'false', '有 provider 段但无包 → 插件仍未装', 'installed=%s' % inst)
check(conf == 'true', '有 provider 段 → 已配置', 'configured=%s' % conf)
check(key == 'false', '没有 apiKey → 无 Key', 'hasKey=%s' % key)

# 3) apiKey 非空
inst, conf, key = flags(run({
    "models": {"providers": {"deepseek": {"apiKey": "sk-abc123"}}}
}))
check(conf == 'true', 'apiKey 非空 → 已配置', 'configured=%s' % conf)
check(key == 'true', 'apiKey 非空 → 有 Key', 'hasKey=%s' % key)

# 4) .env 空赋值不算有 Key
inst, conf, key = flags(run(
    {"models": {"providers": {"deepseek": {"baseUrl": "https://api.deepseek.com"}}}},
    env_text='DEEPSEEK_API_KEY=\n'))
check(key == 'false', '.env 空赋值 → 无 Key', 'hasKey=%s' % key)

# 5) .env 有值才算
inst, conf, key = flags(run(
    {"models": {"providers": {"deepseek": {"baseUrl": "https://api.deepseek.com"}}}},
    env_text='DEEPSEEK_API_KEY=sk-from-env\n'))
check(key == 'true', '.env 有值 → 有 Key', 'hasKey=%s' % key)

# 6) 配置里到处都有 deepseek 字样，也不能算插件已装
inst, conf, key = flags(run({
    "agents": {"defaults": {"model": {"primary": "deepseek/deepseek-v4.1-flash-1017"}}},
    "note": "deepseek",
    "models": {"providers": {"deepseek": {"apiKey": "sk-x"}}},
}))
check(inst == 'false', '配置里到处是 deepseek → 插件仍未装', 'installed=%s' % inst)

print('    共 %s 项，%s 项失败' % (total, failed))
sys.exit(1 if failed else 0)
PYEOF
