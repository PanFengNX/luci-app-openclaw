#!/bin/sh
# Behavior tests for cloud_bin_secure ownership, path, and permission policy.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
PROJ="$(cd "$HERE/../.." && pwd)"
CLOUD="$PROJ/root/usr/libexec/openclaw/cloud.sh"
TMP="$(mktemp -d 2>/dev/null || echo "/tmp/oc-cloud-bin.$$not")"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

fail=0
skip=0
check() {
	if [ "$1" = "$2" ]; then printf '  ok    %s\n' "$3"; else printf '  FAIL  %s\n' "$3"; fail=1; fi
}
skip_case() { printf '  skip  %s\n' "$1"; skip=$((skip + 1)); }

# Source the real policy and real cloud_bin lookup.  No stat/path stub is used:
# accepted cases require a genuinely root-owned fixture, while unprivileged hosts
# still exercise every rejection that does not require changing ownership.
FUNCS="$TMP/functions.sh"
awk '
function count_braces(s,   t) {
	t = s
	sub(/#.*/, "", t)
	return gsub(/{/, "", t) - gsub(/}/, "", t)
}
/^cloud_bin\(\)|^cloud_bin_ready\(\)|^cloud_bin_secure\(\)/ {
	wanted = 1
	depth = 0
}
wanted {
	print
	depth += count_braces($0)
	if (depth == 0) wanted = 0
}' "$CLOUD" >"$FUNCS"
. "$FUNCS"
OC_CLOUD_ROOT="$TMP/cloud"
OC_CLOUD_DIR="$OC_CLOUD_ROOT/bin"
OC_CLOUD_BIN="$OC_CLOUD_DIR/bdpan"
mkdir -p "$OC_CLOUD_DIR"
printf '#!/bin/sh\nexit 0\n' >"$OC_CLOUD_BIN"

# chown is deliberately not faked.  If this host cannot create root-owned
# files, accepted-mode checks are reported as skips rather than false passes.
if chown 0:0 "$OC_CLOUD_ROOT" "$OC_CLOUD_DIR" "$OC_CLOUD_BIN" 2>/dev/null &&
	[ "$(stat -c '%u:%g' "$OC_CLOUD_ROOT" 2>/dev/null)" = '0:0' ] &&
	[ "$(stat -c '%u:%g' "$OC_CLOUD_BIN" 2>/dev/null)" = '0:0' ]; then
	HAS_ROOT_FIXTURE=1
else
	HAS_ROOT_FIXTURE=0
	skip_case 'root-owned acceptance matrix unavailable on this host'
fi

set_chain_mode() {
	chmod "$1" "$OC_CLOUD_ROOT" "$OC_CLOUD_DIR" "$OC_CLOUD_BIN" 2>/dev/null
}
run_ready() {
	cloud_bin_ready >/dev/null 2>&1
}

if [ "$HAS_ROOT_FIXTURE" = 1 ]; then
	# Original accepted modes and the explicitly added installer combinations.
	for mode in 700 710 750 755 701 711 751; do
		set_chain_mode "$mode"
		run_ready; check "$?" 0 "root-owned mode $mode accepted through cloud_bin_ready"
	done
else
	# Still verify that the real owner check rejects the fixture.
	chmod 700 "$OC_CLOUD_ROOT" "$OC_CLOUD_DIR" "$OC_CLOUD_BIN"
	run_ready; check "$?" 1 'non-root component rejected'
fi

# Explicitly exercise the owner check even on a host that can make root-owned
# fixtures.  Restore root ownership immediately so later cases remain valid.
if [ "$HAS_ROOT_FIXTURE" = 1 ] && chown 1000:1000 "$OC_CLOUD_BIN" 2>/dev/null; then
	chmod 700 "$OC_CLOUD_BIN"
	run_ready; check "$?" 1 'non-root component rejected'
	chown 0:0 "$OC_CLOUD_BIN" 2>/dev/null || true
elif [ "$HAS_ROOT_FIXTURE" = 1 ]; then
	skip_case 'non-root ownership fixture unavailable'
fi

# The file and directory policies are independently exercised.  A write bit in
# any group/other position is rejected; special bits are rejected even if mode
# text otherwise resembles an allowed combination.
for mode in 720 702 770 706 4700 2700 1700; do
	set_chain_mode 700
	chmod "$mode" "$OC_CLOUD_BIN"
	run_ready; check "$?" 1 "component mode $mode rejected"
done
for mode in 720 702 770 706 4700 2700 1700; do
	set_chain_mode 700
	chmod "$mode" "$OC_CLOUD_DIR"
	run_ready; check "$?" 1 "directory mode $mode rejected"
done

# Restore the fixture before structural cases.
set_chain_mode 700
if ln -s "$OC_CLOUD_BIN" "$OC_CLOUD_ROOT/bin/file-link" 2>/dev/null; then
	cloud_bin_secure "$OC_CLOUD_ROOT/bin/file-link"; check "$?" 1 'component symlink rejected'
else
	skip_case 'component symlink creation unavailable'
fi
if ln -s "$OC_CLOUD_DIR" "$OC_CLOUD_ROOT/dir-link" 2>/dev/null; then
	cloud_bin_secure "$OC_CLOUD_ROOT/dir-link/bdpan"; check "$?" 1 'directory symlink rejected'
else
	skip_case 'directory symlink creation unavailable'
fi

OUTSIDE="$TMP/outside"
mkdir -p "$OUTSIDE"
printf '#!/bin/sh\nexit 0\n' >"$OUTSIDE/bdpan"
chmod 700 "$OUTSIDE" "$OUTSIDE/bdpan"
cloud_bin_secure "$OUTSIDE/bdpan"; check "$?" 1 'root outside path rejected'
cloud_bin_secure "$OC_CLOUD_ROOT/../outside/bdpan"; check "$?" 1 'traversal outside path rejected'

# A complete lookup must still resolve the expected component path on a secure
# root-owned fixture; this is the business chain used by the backup list path.
if [ "$HAS_ROOT_FIXTURE" = 1 ]; then
	set_chain_mode 700
	resolved="$(cloud_bin_ready 2>/dev/null)"
	check "$resolved" "$OC_CLOUD_BIN" 'cloud_bin_ready resolves secure installed component'
fi

[ "$fail" = 0 ]
