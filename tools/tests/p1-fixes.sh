#!/bin/sh
# Focused regression checks for P1 repair/state/path boundaries.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
PROJ="$(cd "$HERE/../.." && pwd)"
LIB="$PROJ/root/usr/libexec/openclaw/lib.sh"
INIT="$PROJ/root/etc/init.d/openclaw"
RC=0

check() {
	if [ "$1" = "$2" ]; then
		printf '    ok    %s\n' "$3"
	else
		printf '    FAIL  %s got=%s want=%s\n' "$3" "$1" "$2"
		RC=1
	fi
}

ROOT="$(mktemp -d "$PROJ/.p1-path.XXXXXX")" || exit 1
trap 'rm -rf "$ROOT"' EXIT HUP INT TERM
SAFE="$ROOT/mnt/custom/state"
mkdir -p "$SAFE/real" "$ROOT/target"

# Load the actual lib.sh implementation, not a text/count surrogate.
. "$LIB"
oc_validate_base_dir "$SAFE/new"
check "$?" 0 'lib: safe new leaf accepted'
oc_validate_base_dir /etc
check "$?" 1 'lib: /etc rejected'
oc_validate_base_dir /tmp
check "$?" 1 'lib: /tmp rejected'

if ln -s "$ROOT/target" "$ROOT/mnt/link" 2>/dev/null; then
	oc_validate_base_dir "$ROOT/mnt/link/new"
	check "$?" 1 'lib: intermediate symlink rejected'
else
	printf '    skip  lib: intermediate symlink creation unavailable\n'
fi
if ln -s "$SAFE/real" "$ROOT/final-link" 2>/dev/null; then
	oc_validate_base_dir "$ROOT/final-link"
	check "$?" 1 'lib: final symlink rejected'
else
	printf '    skip  lib: final symlink creation unavailable\n'
fi

# Extract and execute the init.d state path functions. Sourcing init.d itself
# invokes rc.common on OpenWrt, so only the real function definitions are loaded.
INIT_FUNCS="$ROOT/init-state-fns.sh"
awk '
/^_state_dir_shape_ok\(\)/ { keep=1 }
keep && /^oc_home\(\)/ { exit }
keep { print }
' "$INIT" >"$INIT_FUNCS"
. "$INIT_FUNCS"
_state_dir_safe "$SAFE/new"
check "$?" 0 'init: safe new leaf accepted'
_state_dir_safe /etc
check "$?" 1 'init: /etc rejected'
_state_dir_safe /tmp
check "$?" 1 'init: /tmp rejected'
if [ -L "$ROOT/mnt/link" ]; then
	_state_dir_safe "$ROOT/mnt/link/new"
	check "$?" 1 'init: intermediate symlink rejected'
else
	printf '    skip  init: intermediate symlink creation unavailable\n'
fi
if [ -L "$ROOT/final-link" ]; then
	_state_dir_safe "$ROOT/final-link"
	check "$?" 1 'init: final symlink rejected'
else
	printf '    skip  init: final symlink creation unavailable\n'
fi

printf '    focused P1 path assertions complete\n'
exit "$RC"
