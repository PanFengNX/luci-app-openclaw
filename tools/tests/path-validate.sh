#!/bin/sh
# path-validate.sh — oc_validate_base_dir / oc_safe_port / oc_safe_url 回归测试
#
# 这些是"拒绝危险输入"的安全不变量。任何改动 lib.sh 之后都必须重跑，
# 由 tools/verify-project.sh 自动调用。
#
# 退出码：0 = 全部通过；1 = 有失败

LIB="$(dirname "$0")/../../root/usr/libexec/openclaw/lib.sh"
[ -f "$LIB" ] || { echo "找不到 $LIB"; exit 2; }
. "$LIB"

RC=0
N=0
chk() {
	N=$((N + 1))
	if [ "$2" = "$3" ]; then
		printf '    ok    %s\n' "$1"
	else
		printf '    FAIL  %s got=[%s] want=[%s]\n' "$1" "$2" "$3"
		RC=1
	fi
}
expect() {  # expect <desc> <rc> <want>
	chk "$1" "$2" "$3"
}

# ---------------------------------------------------------------- 路径校验
# 允许的形态
oc_validate_base_dir /mnt/data/OpenClaw; expect "接受 /mnt/data/OpenClaw" "$?" 0
oc_validate_base_dir /mnt/sda1/oc;          expect "接受 /mnt/sda1/oc"          "$?" 0
oc_validate_base_dir /mnt/data/OpenClaw/; expect "接受尾部斜杠"             "$?" 0

# 系统路径必须拒绝
for p in / /root /root/x /etc /etc/passwd /usr /usr/lib /bin /sbin /lib \
         /proc /sys /dev /run /tmp /tmp/x /var /var/lib /overlay /rom; do
	oc_validate_base_dir "$p"
	expect "拒绝 $p" "$?" 1
done

# 形态非法必须拒绝
oc_validate_base_dir relative;   expect "拒绝相对路径"     "$?" 1
oc_validate_base_dir ./x;        expect "拒绝 ./x"        "$?" 1
oc_validate_base_dir /a/../b;    expect "拒绝 /a/../b"     "$?" 1
oc_validate_base_dir /a/./b;     expect "拒绝 /a/./b"      "$?" 1
oc_validate_base_dir "";         expect "拒绝空字符串"     "$?" 1

# 解析后的路径仍要过滤（安全控件本体）
oc_validate_base_dir_shape /etc;                  expect "shape 拒绝 /etc"      "$?" 1
oc_validate_base_dir_shape /var;                  expect "shape 拒绝 /var"      "$?" 1
oc_validate_base_dir_shape /mnt/data/OpenClaw; expect "shape 接受正常路径"   "$?" 0

# 不存在的目录必须接受（全新安装场景）
oc_validate_base_dir /mnt/__oc_does_not_exist__/OpenClaw
expect "接受尚不存在的目录" "$?" 0

# 桩注入：模拟符号链接解析结果
mkdir -p /mnt/__oc_real__ 2>/dev/null
if [ -d /mnt/__oc_real__ ]; then
	readlink() { printf '/etc'; }
	oc_validate_base_dir /mnt/__oc_real__
	expect "解析到 /etc 时拒绝" "$?" 1
	unset -f readlink

	readlink() { printf '/mnt/__oc_real__'; }
	oc_validate_base_dir /mnt/__oc_real__
	expect "解析到安全路径时接受" "$?" 0
	unset -f readlink

	readlink() { return 1; }
	oc_canonical_dir() { return 1; }
	oc_validate_base_dir /mnt/__oc_real__
	expect "无法解析时拒绝" "$?" 1
	unset -f readlink oc_canonical_dir

	rmdir /mnt/__oc_real__ 2>/dev/null
fi

# ---------------------------------------------------------------- 端口校验
oc_safe_port 18789 >/dev/null; expect "接受 18789"       "$?" 0
oc_safe_port 1025  >/dev/null; expect "接受 1025"        "$?" 0
oc_safe_port 65535 >/dev/null; expect "接受 65535"       "$?" 0
oc_safe_port 1024  >/dev/null; expect "拒绝特权端口 1024" "$?" 1
oc_safe_port 80    >/dev/null; expect "拒绝特权端口 80"   "$?" 1
oc_safe_port 0     >/dev/null; expect "拒绝 0"           "$?" 1
oc_safe_port 70000 >/dev/null; expect "拒绝 70000"       "$?" 1
oc_safe_port abc   >/dev/null; expect "拒绝非数字"        "$?" 1
oc_safe_port ""    >/dev/null; expect "拒绝空"           "$?" 1
oc_safe_port "80;id" >/dev/null; expect "拒绝注入串"      "$?" 1

# ---------------------------------------------------------------- URL 校验
oc_safe_url "https://registry.npmjs.org"; expect "接受 https"        "$?" 0
oc_safe_url "http://a.b/c";               expect "接受 http"         "$?" 0
oc_safe_url "-o/etc/passwd";              expect "拒绝 - 开头"       "$?" 1
oc_safe_url "https://a b";                expect "拒绝含空格"        "$?" 1
oc_safe_url "ftp://x";                    expect "拒绝非 http(s)"    "$?" 1
oc_safe_url "";                           expect "拒绝空"            "$?" 1
oc_safe_url "file:///etc/passwd";         expect "拒绝 file://"      "$?" 1

# ---------------------------------------------------------------- JSON 转义
chk "转义双引号"   "$(oc_json_str 'a"b')"      'a\"b'
chk "转义反斜杠"   "$(oc_json_str 'a\b')"      'a\\b'
chk "转义制表符"   "$(oc_json_str "$(printf 'a\tb')")" 'a\tb'
# 多行值必须压成单个 JSON 字符串（用 \n 转义），否则会破坏 JSON 结构
chk "多行转 \\n 转义" "$(oc_json_str "$(printf 'a\nb')")" 'a\nb'
chk "单行不变形"     "$(oc_json_str 'hello')"             'hello'

printf '    共 %s 项断言\n' "$N"
exit $RC
