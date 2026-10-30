#!/bin/sh
# Behavior tests for the fail-closed gateway recover-lock state machine.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
PROJ="$(cd "$HERE/../.." && pwd)"
LIBSH="$PROJ/root/usr/libexec/openclaw/lib.sh"
TMP="$(mktemp -d 2>/dev/null || echo "/tmp/oc-lock-test.$$")"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

fail=0
pass() { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; fail=1; }

run_case() {
	name="$1"; expected="$2"; cli="$3"; output="$4"
	if (
		base="$TMP/$name"
		mkdir -p "$base/state/tmp/openclaw-1000"
		printf '{"pid":1234}\n' > "$base/state/tmp/openclaw-1000/state.test.lock"
		if [ "$cli" = "yes" ]; then
			cat > "$base/oc" <<EOF
#!/bin/sh
printf '%s\\n' '$output'
exit 1
EOF
			chmod +x "$base/oc"
			ocbin="$base/oc"
		else
			ocbin="$base/missing"
		fi
		# Each case is a separate shell: sourced functions and overrides cannot leak.
		# shellcheck disable=SC1090
		. "$LIBSH" >/dev/null 2>&1
		oc_home_dir() { printf '%s' "$base/home"; }
		oc_as_user() { shift; env "$@"; }
		oc_warn() { printf '%s\n' "$*" >> "$base/log"; }
		oc_clear_stale_state_lock "$base/state" "$ocbin"
		rc=$?
		[ "$rc" = "$expected" ] || {
			printf '    expected rc=%s, got rc=%s\n' "$expected" "$rc" >&2
			exit 1
		}
	if [ "$cli" = "yes" ]; then
		grep -q '官方 recover-lock 检查已返回人工恢复线索' "$base/log" || exit 1
		grep -q -- "$output" "$base/log" || exit 1
		else
			grep -q '无法执行官方 recover-lock 检查' "$base/log" || exit 1
		fi
	); then
		pass "$name"
	else
		fail "$name"
	fi
}

run_case human-recovery 1 yes '需要确认：gateway recover-lock --confirm fp-test'
run_case cli-missing 2 no ''

# No lock is the only path that permits doctor to proceed.
base="$TMP/no-lock"
mkdir -p "$base/state/tmp"
. "$LIBSH" >/dev/null 2>&1
oc_clear_stale_state_lock "$base/state" "$base/missing"
[ "$?" = 0 ] && pass 'no lock permits doctor' || fail 'no lock must return 0'

printf '\n'
[ "$fail" = 0 ]
