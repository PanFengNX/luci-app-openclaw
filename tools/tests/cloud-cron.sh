#!/bin/sh
# cloud-cron.sh — 云备份定时任务（crontab 重写）的回归测试
#
# 这一段的危险点不在"能不能写进去"，而在"写的时候会不会顺手把别人的
# 定时任务弄丢"。crontab - 是一次整表读入 / 整表写出，任何一处过滤写错，
# 用户的其它定时任务就静默消失，而我们的那一行照样写得进去 —— 看起来
# 一切正常。所以断言的重点是**别人的行必须原样还在**。
#
# 另外回归一条历史事故：BD3 与 BD5 两个批次各写了一整套同名函数，
# cloud.sh 里 17 个函数被定义了两次。shell 不报错，后一份静默覆盖前一份，
# 而生效的那份恰好丢了 cloud_cron_count_other 这道校验。
# 所以"没有重复定义"本身也是一条断言。
#
# 用 python 做两件事：解析 cloud.sh 取出待测函数、把函数拼成可执行的
# 小脚本喂给 bash。断言在 python 里做，结果按统一格式打印。
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

# bash 用来执行抽出来的函数（cloud.sh 本身是 ash 语法，但函数体在 bash 下同样可跑）
command -v bash >/dev/null 2>&1 || { echo "    跳过：找不到 bash"; exit 0; }

"$PY" - "$PROJ" <<'PYEOF'
import pathlib, re, subprocess, sys, tempfile, shutil, collections

proj = pathlib.Path(sys.argv[1])
src = (proj / 'root/usr/libexec/openclaw/cloud.sh').read_text(encoding='utf-8')

total = 0
failed = 0


def check(ok, desc, detail=''):
    global total, failed
    total += 1
    if ok:
        print('    ok    %s' % desc)
    else:
        failed += 1
        print('    FAIL  %s%s' % (desc, ('（%s）' % detail) if detail else ''))


# ---- 断言 0：没有重复定义（历史事故的直接回归） -------------------------
fns = re.findall(r'(?m)^([a-zA-Z_][a-zA-Z0-9_]*)\(\)\s*\{', src)
dups = sorted(k for k, v in collections.Counter(fns).items() if v > 1)
check(not dups, 'cloud.sh 无重复函数定义',
      ('重复：%s' % ' '.join(dups)) if dups else '')

# ---- 取出待测函数 -------------------------------------------------------
names = ('cloud_cron_count', 'cloud_cron_count_mark',
         'cloud_cron_count_other', 'cloud_cron_write')


def grab(n):
    m = re.search(r'(?ms)^' + re.escape(n) + r'\(\)\s*\{.*?\n\}', src)
    return m.group(0) if m else ''


parts = {n: grab(n) for n in names}
missing = [k for k, v in parts.items() if not v]
check(not missing, '定时相关的四个函数都在',
      ('缺：%s' % ' '.join(missing)) if missing else '')

if missing:
    print('    共 %s 项' % total)
    print('    %s 项失败' % failed)
    sys.exit(1)

m = re.search(r'(?m)^OC_CRON_MARK=.*$', src)
check(m is not None, 'OC_CRON_MARK 已定义')
if not m:
    print('    共 %s 项' % total)
    print('    %s 项失败' % failed)
    sys.exit(1)
mark = m.group(0)

work = pathlib.Path(tempfile.mkdtemp())
try:
    cron = work / 'crontab'
    # 夹具：别人的定时任务、注释、空行、以及我们自己的旧行
    cron.write_text(
        '0 3 * * * /usr/bin/other-job\n'
        '# user comment\n'
        '\n'
        '*/5 * * * * /usr/bin/keepme\n'
        '30 4 * * * /usr/libexec/openclaw/cloud.sh backup-run # openclaw-cloud\n',
        encoding='utf-8', newline='\n')

    def read():
        return cron.read_text(encoding='utf-8').splitlines()

    def norm(lines):
        # 重写后文件末尾多一个换行是正常的，比较时忽略尾部空行；
        # 文件**中间**的空行必须原样保留，所以只在尾部裁。
        out = list(lines)
        while out and out[-1] == '':
            out.pop()
        return out

    def foreign(lines):
        return [l for l in lines if 'openclaw-cloud' not in l]

    def ours(lines):
        return [l for l in lines if 'openclaw-cloud' in l]

    base = read()
    base_foreign = norm(foreign(base))

    def run(line):
        h = work / 'harness.sh'
        h.write_text(
            '#!/bin/sh\n'
            'oc_warn(){ echo "WARN: $*" >&2; }\n'
            '%s\n'
            'OC_CRONTAB="%s"\n'
            '%s\n%s\n%s\n%s\n'
            'cloud_cron_write "%s"\n'
            % (mark, cron.as_posix(),
               parts['cloud_cron_count'], parts['cloud_cron_count_mark'],
               parts['cloud_cron_count_other'], parts['cloud_cron_write'],
               line),
            encoding='utf-8', newline='\n')
        return subprocess.run(['bash', h.as_posix()],
                              capture_output=True, text=True)

    NEW = '0 5 * * 1 /usr/libexec/openclaw/cloud.sh backup-run # openclaw-cloud'

    r = run(NEW)
    after = read()
    check(r.returncode == 0, '写入返回成功',
          (r.stderr.strip()[:120] or 'rc=%s' % r.returncode))
    check(norm(foreign(after)) == base_foreign, '写入后别人的行原样保留',
          '别人的行被改动')
    check(len(ours(after)) == 1, '写入后我们恰好一行',
          '实际 %s 行' % len(ours(after)))
    check(NEW in after, '写入的确实是新时间')

    # 幂等：再写一次不应产生第二行
    run(NEW)
    check(read() == after, '二次执行幂等（不多一行、不重排）')

    # 清空：只删我们的行
    run('')
    final = read()
    check(len(ours(final)) == 0, '清空后我们的行数为 0',
          '实际 %s 行' % len(ours(final)))
    check(norm(foreign(final)) == base_foreign, '清空后别人的行完好')
finally:
    shutil.rmtree(work, ignore_errors=True)

print('    共 %s 项' % total)
if failed:
    print('    %s 项失败' % failed)
    sys.exit(1)
sys.exit(0)
PYEOF

rc=$?
[ "$rc" -eq 0 ] || exit 1
exit 0
