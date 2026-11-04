#!/bin/sh
# models-catalog.sh — 模型清单从「OpenClaw 已发布目录」拿，不再只依赖上游 /models
#
# 背景（用户实测）：内网设备上三个 provider 全部显示「实时获取失败」，下拉里
# 只有随包的 2~3 个预设。根因是旧实现只有两条路：
#   * 有 API Key -> 问 provider 的 /models（内网没有外网 / 没填 Key 就必然失败）
#   * 没有 Key   -> 问 openrouter 公开目录（内网同样不可达）
# 于是"自动获取模型"永远走不到，页面长期停在预设上。
#
# 现在第一层是官方 CLI 的已发布目录：
#   openclaw models list --provider <id> --plain
# 官方文档（docs.openclaw.ai/cli/models）保证：不联网、不需要 Key、不需要
# --all、stdout 一行一个模型 key、诊断只走 stderr。
#
# 本测试守住四件事：
#   1. 目录优先：有目录清单时**不许**再发网络请求（内网/慢网都不该等超时）
#   2. 目录解析：去 provider 前缀、去重排序、丢掉带空格的提示语
#   3. Key 无效（401/403）仍然必须报错，不能被"目录里有模型"盖掉
#   4. 全都拿不到时才报错，并且错误里点名要填的变量
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
import os
import pathlib
import re
import subprocess
import sys
import tempfile

proj = pathlib.Path(sys.argv[1])
NL = chr(10)
src = (proj / 'root/usr/libexec/openclaw/models.sh').read_text(encoding='utf-8')
view = (proj / 'luasrc/view/openclaw/model.htm').read_text(encoding='utf-8')

total = 0
failed = 0


def check(ok, desc, detail=''):
    global total, failed
    total += 1
    print('    %s  %s%s' % ('ok  ' if ok else 'FAIL', desc, ('  ' + detail) if detail else ''))
    if not ok:
        failed += 1


def func(name, text=None):
    text = src if text is None else text
    lines = text.splitlines()
    starts = [(i, m.group(1)) for i, l in enumerate(lines)
              for m in [re.match(r'^([a-z_][a-z0-9_]*)\(\)\s*\{', l)] if m]
    for idx, (ln, nm) in enumerate(starts):
        if nm == name:
            end = starts[idx + 1][0] if idx + 1 < len(starts) else len(lines)
            return NL.join(lines[ln:end])
    raise AssertionError('取不到函数 ' + name)


def code_of(name):
    return NL.join(l.split('#', 1)[0] for l in func(name).splitlines())


work = pathlib.Path(tempfile.mkdtemp())


def P(p):
    s = pathlib.Path(p).as_posix()
    return '/c' + s[2:] if len(s) > 1 and s[1] == ':' else s


# ---------------------------------------------------------------- 静态断言
check('catalog_models()' in src, 'models.sh 新增已发布目录来源 catalog_models')
body = code_of('catalog_models')
check('models list' in body and '--all' in body,
      '目录查询用 models list --all（真机：--provider 对未配置服务商会直接失败）')
check('--provider' not in body,
      '目录查询**不**按 --provider 过滤（未配置的 provider 会让整次调用失败）')
check('--plain' in body, '目录查询用 --plain（一行一个 key，stdout 无噪声）')
check('[ "$rc" -ne 0 ]' in body, '非零退出不解析 stdout（用法说明不是模型清单）')
check('oc_run_q 15' in body, 'node 冷启动给足 15 秒（太短会把"慢"误判成"没有"）')
check('index($0, prov "/") != 1' in body, '按 "<provider>/" 前缀本地过滤')
check('尚未配置' in body, '目录里没有该 provider 时给出可读原因')
check('models list' not in code_of('models_public'),
      '公开目录路径没有混进 CLI 调用')

url = code_of('models_url')
check('catalog_models' in url, 'models_url 会读已发布目录')
check(url.index('catalog_models') < url.index('models_public'),
      '目录优先于公开目录')
check('401|403' in url and 'return 1' in url,
      '上游 401/403 仍然是硬错误（Key 无效不能被掩盖）')
check('--resolve' in url, '能解析到公网地址时仍做地址钉扎')
check('if [ -n "$url_ip" ]' in url,
      '解析不到公网地址时整条不传 --resolve（空 IP 会让 curl 直接报错）')
check('models_json catalog' in url or 'models_json" catalog' in url,
      '返回 JSON 里标 source=catalog')

# 前端：来源文案 + 足够长的超时
# 断言必须锚到具体键名，不能只查 "catalog" 子串 —— 那样只要页面里出现任意
# 一次 catalog（函数名、注释）就恒真，守不住"按 source 分文案"这件事。
check("catalog:" in view and 'catalog:' in view.split('MODEL_SOURCE_TEXT')[1][:400],
      'MODEL_SOURCE_TEXT 里有 catalog 键（按 source 分文案）')
check('45000' in view, '模型请求超时放宽到 45 秒（后端要跑一次 CLI）')
check('已发布目录' in view, '页面说明了清单来源')
check("MODEL_SOURCE_TEXT[r.source]" in view or 'hasKey(MODEL_SOURCE_TEXT, r.source)' in view,
      '文案按服务端返回的 source 查表，而不是硬编码分支')



# ---------------------------------------------------------------- 清单过滤与排序
# 真机反馈：「有些模型可以，有些模型不行」—— 公开目录里带平台专属后缀
# （:batch/:free/:extended/-legal）和非对话模型（embedding/tts/图像）在服务商
# 自己的 API 上根本不存在或不能对话。「默认可选择变为最新」—— 列表要按版本
# 倒序，前端默认选第一项。
rank_script = work / 'rank.sh'
rank_script.write_text(NL.join(['#!/bin/sh', func('models_rank_filter'), 'models_rank_filter', '']),
                       encoding='utf-8', newline=NL)

SAMPLE = NL.join([
    'claude-opus-4.8', 'claude-opus-5.5', 'claude-opus-5', 'claude-haiku-4.5',
    'claude-sonnet-5.5', 'anthropic/claude-opus-5.5:batch', 'qwen3.8-max-prime',
    'qwen3-max', 'qwen3.5-max', 'text-embedding-3-large', 'gpt-4o-audio-preview',
    'dall-e-3', 'gemini-3-pro-image', 'glm-5.3-flashx-legal', 'kimi-k3',
    'kimi-k2.7-code', 'MiniMax-M3', ''])


def rank(text):
    r = subprocess.run(['sh', P(rank_script)], input=text,
                       capture_output=True, text=True)
    return [l for l in r.stdout.strip().splitlines() if l]


out = rank(SAMPLE)
check('qwen3.8-max-prime' in out, '正常的对话模型保留')
check('claude-opus-5.5' in out, 'Anthropic 模型保留')
check('MiniMax-M3' in out, '大小写混合的 id 保留')
check('text-embedding-3-large' not in out, 'embedding 模型被剔除')
check('gpt-4o-audio-preview' not in out, 'audio 模型被剔除')
check('dall-e-3' not in out, '图像生成模型被剔除')
check('gemini-3-pro-image' not in out, 'image 变体被剔除')
check('glm-5.3-flashx-legal' not in out, 'OpenRouter 专属 -legal 变体被剔除')
check(all(':batch' not in x for x in out), '平台专属 :batch 变体被剔除')
check(out[0] == 'qwen3.8-max-prime', '最新版本排在第一（前端默认选它）', repr(out[:3]))
check(out.index('qwen3.5-max') < out.index('qwen3-max'), '同族内 3.5 排在 3 之前')
check(out.index('claude-opus-5.5') < out.index('claude-opus-4.8'), '同族内 5.5 排在 4.8 之前')

# 前端：有实时清单时默认选第一项（最新），而不是预设里写死的旧 defaultModel
check('hasLive' in view and 'upstream[0]' in view,
      '前端默认选中实时清单的第一项（最新）')

# ---------------------------------------------------------------- setkey 回归
# setkey 从本包第一个版本起就是「位置参数传 Key」的对外签名。apply 改成
# 只认 --key-file / $OC_APPLY_KEY 之后，setkey 一度 100% 返回 2（功能直接
# 没了）。这里守住它必须仍然可用，且内部走安全通道。
sk = func('setkey')
check('apply' in sk, 'setkey 仍然委托 apply')
check('--key-file' in sk, 'setkey 内部走 --key-file 安全通道（Key 不进子进程 argv）')
check('OC_APPLY_KEY' in sk, '临时目录不可用时回退到环境变量通道')
check('umask 077' in sk, '写 Key 的临时文件用 umask 077 创建')

# ---------------------------------------------------------------- 内网地址拒绝
# 放宽 DNS 前置条件不等于放开内网：字面量内网地址与解析到内网的域名都必须
# 仍然拒绝（云元数据 169.254.169.254 是典型目标）。
url_body = code_of('models_url')
check('oc_url_ip_private' in url_body, '字面量内网地址仍然被拒绝')
check('oc_url_host_resolves_private' in url_body, '解析到内网的域名仍然被拒绝')



# ---------------------------------------------------------------- 真机回归（2026-11-04）
# 以下三条全部来自真机实测，任何一条回退都会让用户重新看到"实时获取失败"。

# 1) 198.18.0.0/15 是 Clash/sing-box fake-ip 默认段，**不能**判成内网。
#    实测设备：github.com / openrouter.ai / 各家 API 全解析到 198.18.x.x，
#    而 curl 走代理返回 200。误判的后果是整机所有走代理的域名被拒。
lib = (proj / 'root/usr/libexec/openclaw/lib.sh').read_text(encoding='utf-8')
# 只看代码行：注释里会解释"为什么放行 198.18"，那是文档不是实现
ipp = NL.join(l.split('#', 1)[0] for l in func('oc_url_ip_private', lib).splitlines())
check('$2>=18' not in ipp, '198.18.0.0/15 不再被当作内网（fake-ip 代理段）')
check('169 && $2==254' in ipp, '云元数据 169.254.0.0/16 仍然拒绝')
check('$1==10 ' in ipp or '$1==10|' in ipp or '$1==10 ' in ipp, 'RFC1918 10/8 仍然拒绝')
check('$1==127' in ipp, '环回 127/8 仍然拒绝')

# 2) busybox nslookup 的输出首段是 DNS 服务器自己（Address: 127.0.0.1:53）。
#    旧解析把它当 IP 交给 curl --resolve，实测报 (49) Could not parse。
hips = func('oc_url_host_ips', lib)
check('v ~ /\\./ && v ~ /:/' in hips or 'v ~ /\./ && v ~ /:/' in hips,
      'nslookup 解析丢弃 "IPv4:端口" 的服务器行')
check('nslookup' in hips, '仍然使用 nslookup 兜底（内网设备常见）')

# 3) 公开目录必须能覆盖 qwen（实测漏过：没有 Key 的 Qwen 永远拿不到清单）
pp = func('public_prefix')
check('qwen)' in pp and "'qwen'" in pp, 'public_prefix 覆盖 qwen')
for k in ['moonshot', 'anthropic', 'zai', 'minimax', 'google', 'openai', 'deepseek']:
    check(k + ')' in pp, 'public_prefix 覆盖 ' + k)

# ---------------------------------------------------------------- 目录解析
runner = work / 'catalog.sh'
runner.write_text(NL.join([
    '#!/bin/sh',
    'oc_oc_bin() { printf %s /bin/true; }',
    # $1 = timeout，其余是 CLI 参数；输出与退出码都来自环境变量
    'oc_run_q() { printf "%s\\n" "$FAKE_OUT"; exit "${FAKE_RC:-0}"; }',
    func('catalog_models'),
    'catalog_models "$1" && printf "%s\\n" "$OC_CM_OUT"',
    'printf "MSG:%s\\n" "$OC_CM_MSG" >&2',
    '',
]), encoding='utf-8', newline=NL)


def run_catalog(out, rc=0):
    r = subprocess.run(['sh', P(runner), 'moonshot'],
                       capture_output=True, text=True,
                       env=dict(os.environ, FAKE_OUT=out, FAKE_RC=str(rc)))
    lines = [l for l in r.stdout.strip().splitlines() if l]
    return lines


def run_catalog_msg(out, rc=0):
    r = subprocess.run(['sh', P(runner), 'moonshot'],
                       capture_output=True, text=True,
                       env=dict(os.environ, FAKE_OUT=out, FAKE_RC=str(rc)))
    for l in r.stderr.splitlines():
        if l.startswith('MSG:'):
            return l[4:]
    return ''


got = run_catalog('moonshot/kimi-k2.5' + NL + 'moonshot/kimi-k2-turbo-preview' + NL
                  + 'moonshot/kimi-k2.5')
check(got == ['kimi-k2-turbo-preview', 'kimi-k2.5'],
      '带 provider 前缀的 key 被剥掉、去重、排序', repr(got))

# `--all` 会返回所有 provider 的行；只保留当前 provider 的
got = run_catalog('moonshot/kimi-k3' + NL + 'deepseek/deepseek-v4-pro' + NL
                  + 'longai/glm-5.3' + NL + 'moonshot/kimi-k2.5')
check(got == ['kimi-k2.5', 'kimi-k3'],
      '只保留当前 provider 的行，其它 provider 被过滤掉', repr(got))

# 没有前缀的裸 id 不再被采纳（`--all` 的输出一定带前缀；裸行只可能是噪声）
got = run_catalog('kimi-k2.5' + NL + 'MiniMax-M2' + NL + 'moonshot/kimi-k3')
check(got == ['kimi-k3'], '没有 provider 前缀的行被丢弃', repr(got))

got = run_catalog('moonshot/No models found.' + NL
                  + 'moonshot/Usage: openclaw models list' + NL
                  + 'moonshot/kimi-k2.5')
check(got == ['kimi-k2.5'], '带空格的提示语不会被当成模型 id', repr(got))

got = run_catalog('Usage: openclaw models list [options]', rc=1)
check(got == [], '非零退出（版本不认 --plain）不产出任何模型', repr(got))
check('退出码 1' in run_catalog_msg('Usage: openclaw models list [options]', rc=1),
      '非零退出时把退出码记进诊断（页面能看到原因）')

got = run_catalog('')
check(got == [], '空输出不产出模型', repr(got))
check('空清单' in run_catalog_msg(''), '空输出时诊断说明是空清单')

# 目录里没有这个 provider（未配置/未装插件）——真机实测就是这个分支
got = run_catalog('deepseek/deepseek-v4-pro' + NL + 'longai/glm-5.3')
check(got == [], '目录里没有该 provider 时不产出模型', repr(got))
check('尚未配置' in run_catalog_msg('deepseek/deepseek-v4-pro' + NL + 'longai/glm-5.3'),
      '未配置的 provider 给出可读原因（不是"退出码 1"）')

# catalog_models 必须用全局变量回传，否则诊断会在子 shell 里丢失
runner_src = runner.read_text(encoding='utf-8')
check('OC_CM_OUT=' in code_of('catalog_models') and 'OC_CM_MSG=' in code_of('catalog_models'),
      '结果与诊断走全局变量（命令替换会丢诊断）')

# ---------------------------------------------------------------- models_url 端到端
def build_url_harness():
    return NL.join([
        '#!/bin/sh',
        'OC_RUNDIR="$1"',
        'CURL_CALLED="$2"',
        'oc_env() { :; }',
        'oc_warn() { printf "%s\\n" "$*" >&2; }',
        'oc_json_str() { printf "%s" "$1" | sed -e "s/\\\\\\\\/\\\\\\\\\\\\\\\\/g" -e "s/\\"/\\\\\\"/g"; }',
        'oc_safe_url() {',
        '  local u="$1"',
        '  case "$u" in',
        '    https://*) : ;;',
        '    *) return 1 ;;',
        '  esac',
        '  u="${u#https://}"',
        '  OC_URL_HOST="${u%%/*}"',
        '  OC_URL_PORT=443',
        '  return 0',
        '}',
        'oc_url_ip_private() {',
        '  case "$1" in',
        '    127.*|10.*|192.168.*|169.254.169.254) return 0 ;;',
        '    *) return 1 ;;',
        '  esac',
        '}',
        'oc_url_host_resolves_private() { [ "${FAKE_RESOLVES_PRIVATE:-0}" = 1 ]; }',
        # 内网实测：没有可用的 DNS 探测工具 -> 旧代码在这里直接判失败
        'oc_url_resolve_public() { return 1; }',
        'oc_oc_bin() { printf %s /bin/true; }',
        'configured_field() { printf %s "${FAKE_CONF_BASE:-}"; }',
        'preset_field() {',
        '  case "$2" in',
        '    baseUrl) printf %s "https://api.example.com/v1" ;;',
        '    env) printf %s "EXAMPLE_API_KEY" ;;',
        '    *) : ;;',
        '  esac',
        '}',
        'env_key() { printf %s "${FAKE_KEY:-}"; }',
        # 打桩的 catalog_models：与真实实现同一约定 —— 结果走 OC_CM_OUT，
        # 失败原因走 OC_CM_MSG，返回值 0/1。
        'catalog_models() {',
        '  OC_CM_OUT="${FAKE_CATALOG:-}"',
        '  OC_CM_MSG="${FAKE_CATALOG_MSG:-}"',
        '  [ -n "$OC_CM_OUT" ] || return 1',
        '  return 0',
        '}',
        'models_public() { [ "${FAKE_PUBLIC:-0}" = 1 ] && printf \'{"ok":true,"source":"public","baseUrl":"x","models":["pm"]}\\n\' ; }',
        'curl() {',
        '  : > "$CURL_CALLED"',
        '  body=""',
        '  while [ $# -gt 0 ]; do',
        '    case "$1" in',
        '      -o) body="$2"; shift 2 ;;',
        '      *) shift ;;',
        '    esac',
        '  done',
        '  [ -n "$body" ] && printf "%s" "${CURL_BODY:-}" >"$body"',
        '  printf "%s" "${CURL_CODE:-000}"',
        '  exit 0',
        '}',
        'oc_timeout() { shift; "$@"; }',
        # 真实的 JSON 解析器（纯 awk，不依赖 jsonfilter），一起参与验证
        func('json_slice'),
        func('json_model_ids'),
        func('models_url_fail'),
        func('models_rank_filter'),
        func('models_json'),
        func('models_url'),
        'models_url "$3"',
        '',
    ])


def run_url(model='moonshot', **env_extra):
    rundir = work / 'rundir'
    rundir.mkdir(exist_ok=True)
    called = work / 'curl-called'
    if called.exists():
        called.unlink()
    hp = work / 'url.sh'
    hp.write_text(build_url_harness(), encoding='utf-8', newline=NL)
    env = dict(os.environ, CURL_CALLED=P(called))
    env.update({k: str(v) for k, v in env_extra.items()})
    r = subprocess.run(['sh', P(hp), P(rundir), P(called), model],
                       capture_output=True, text=True, env=env)
    out = r.stdout.strip()
    try:
        return json.loads(out), called.exists(), out
    except Exception:
        return None, called.exists(), out


# harness 的 catalog_models 是打桩函数：把 OC_CM_MSG 的典型文本设进去
# （真实实现里由 models.sh 自己赋值）。这里模拟"目录查询失败"的形状。


# 行为级：字面量内网地址必须被拒绝（不是只做字符串检查）
got, curled, raw = run_url(FAKE_KEY='sk-test',
                           FAKE_CONF_BASE='https://169.254.169.254/v1',
                           FAKE_CATALOG='kimi-k2.5', CURL_CODE='200')
check(got is not None and got.get('ok') is False,
      '云元数据地址 169.254.169.254 被拒绝', raw[:110])
check('内网地址' in str(got.get('error', '')) if got else False,
      '拒绝理由点明是内网地址')

got, curled, raw = run_url(FAKE_KEY='sk-test',
                           FAKE_CONF_BASE='https://127.0.0.1/v1',
                           FAKE_CATALOG='', CURL_CODE='200')
check(got is not None and got.get('ok') is False, '环回地址被拒绝', raw[:110])

got, curled, raw = run_url(FAKE_KEY='sk-test',
                           FAKE_CONF_BASE='https://10.0.0.5/v1',
                           FAKE_CATALOG='', CURL_CODE='200')
check(got is not None and got.get('ok') is False, 'RFC1918 地址被拒绝', raw[:110])

# 行为级：域名解析到内网也必须拒绝（oc_url_host_resolves_private 返回 0）
got, curled, raw = run_url(FAKE_KEY='sk-test',
                           FAKE_CONF_BASE='https://rebind.example.com/v1',
                           FAKE_CATALOG='', CURL_CODE='200',
                           FAKE_RESOLVES_PRIVATE='1')
check(got is not None and got.get('ok') is False,
      '解析到内网的域名被拒绝（防 DNS rebinding）', raw[:110])

got, curled, raw = run_url(FAKE_CATALOG='kimi-k2.5' + NL + 'kimi-k2-turbo-preview')
check(isinstance(got, dict) and got.get('ok') is True, '有目录清单时返回 ok:true', raw[:120])
check(got and got.get('source') == 'catalog', '来源标为 catalog')
check(got and got.get('models') == ['kimi-k2.5', 'kimi-k2-turbo-preview'], '目录里的模型全部上位')
check(not curled, '有目录清单时不发任何网络请求（内网也不会等超时）')

# 有 Key + 改过 Base URL -> 问上游；401 必须报错
got, curled, raw = run_url(FAKE_CATALOG='kimi-k2.5', FAKE_KEY='sk-test',
                           FAKE_CONF_BASE='https://my-gw.example.com/v1',
                           CURL_CODE='401')
check(curled, 'Base URL 被改成自定义地址时会问上游')
check(got is not None and got.get('ok') is False, 'Key 无效时不能报成功', raw[:120])
check(got is not None and '拒绝访问' in str(got.get('error', '')), 'Key 无效的错误指向鉴权')
check('401' in str(got.get('error', '')), '错误里带 HTTP 状态码')

# 有 Key + 改过 Base URL -> 200 且返回模型
got, curled, raw = run_url(FAKE_CATALOG='ignored', FAKE_KEY='sk-test',
                           FAKE_CONF_BASE='https://my-gw.example.com/v1',
                           CURL_CODE='200',
                           CURL_BODY='{"data":[{"id":"gw-model-a"},{"id":"gw-model-b"}]}')
check(got is not None and got.get('ok') is True, '上游 200 时返回 ok:true', raw[:120])
check(got and got.get('source') == 'upstream', '来源标为 upstream')
check(got and sorted(got.get('models') or []) == ['gw-model-a', 'gw-model-b'],
      '上游模型被解析出来（顺序按版本倒序，这里只比对集合）')

# 有 Key + 改过 Base URL，上游连不上 -> 退回目录，仍然可用
got, curled, raw = run_url(FAKE_CATALOG='kimi-k2.5', FAKE_KEY='sk-test',
                           FAKE_CONF_BASE='https://my-gw.example.com/v1',
                           CURL_CODE='000')
check(got is not None and got.get('ok') is True and got.get('source') == 'catalog',
      '上游不可达时退回已发布目录，而不是直接失败', raw[:120])
check(got and got.get('models') == ['kimi-k2.5'], '退回目录后仍给出可用模型')

# 没有 Key、没有目录、公开目录也不可用 -> 报错点名要填的变量
got, curled, raw = run_url(FAKE_KEY='', FAKE_CATALOG='', FAKE_PUBLIC='0')
check(got is not None and got.get('ok') is False, '全部来源都失败时返回 ok:false')
check('EXAMPLE_API_KEY' in str(got.get('error', '')), '错误里点名需要保存的变量')

# 目录来源的诊断最具体：CLI 挂了要把原因顶到最前面（live=1 时）。
# 打桩的 catalog_models 失败时会把 OC_CM_MSG 设成 FAKE_CATALOG_MSG（与真实
# 实现一致），所以只要没被上游诊断覆盖，这条原因就会出现在最终错误里。
got, curled, raw = run_url(FAKE_KEY='', FAKE_CATALOG='', FAKE_PUBLIC='0',
                           FAKE_CATALOG_MSG='openclaw models list 退出码 1')
check('退出码 1' in str(got.get('error', '')) if got else False,
      '目录查询失败的原因被透传给页面', raw[:120])

print('    共 %s 项，%s 项失败' % (total, failed))
sys.exit(1 if failed else 0)
PYEOF
