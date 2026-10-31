#!/bin/sh
# Behavior tests for cloud_bin_secure path ownership and permissions.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
PROJ="$(cd "$HERE/../.." && pwd)"
CLOUD="$PROJ/root/usr/libexec/openclaw/cloud.sh"
TMP="$(mktemp -d 2>/dev/null || echo "/tmp/oc-cloud-bin.$$not")"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

fail=0
check() {
	if [ "$1" = "$2" ]; then printf '  ok    %s\n' "$3"; else printf '  FAIL  %s\n' "$3"; fail=1; fi
}

# The fixture runs on both OpenWrt and unprivileged CI hosts. This stat stub
# supplies root ownership and exact modes where the host cannot chown/chmod.
mkdir -p "$TMP/bin"
cat >"$TMP/bin/stat" <<'EOF'
#!/bin/sh
case "$*" in
	*%u:%g*) [ "${STAT_OWNER:-root}" = root ] && printf '0:0\n' || printf '1000:1000\n' ;;
	*%a*) printf '%s\n' "${STAT_MODE:-700}" ;;
	*) exec /usr/bin/stat "$@" ;;
esac
EOF
chmod +x "$TMP/bin/stat"
export PATH="$TMP/bin:$PATH"

FUNCS="$TMP/functions.sh"
awk '/^cloud_bin_secure\(\)/,/^\}/ { print }' "$CLOUD" >"$FUNCS"
. "$FUNCS"
OC_CLOUD_ROOT="$TMP/cloud"
mkdir -p "$OC_CLOUD_ROOT/bin"
printf '#!/bin/sh\nexit 0\n' >"$OC_CLOUD_ROOT/bin/bdpan"
chmod 700 "$OC_CLOUD_ROOT/bin/bdpan"

STAT_MODE=700; STAT_OWNER=root; export STAT_MODE STAT_OWNER
cloud_bin_secure "$OC_CLOUD_ROOT/bin/bdpan"; check "$?" 0 'root-owned 0700 executable accepted'
STAT_MODE=750; export STAT_MODE
cloud_bin_secure "$OC_CLOUD_ROOT/bin/bdpan"; check "$?" 1 '0750 executable rejected'
STAT_MODE=755; export STAT_MODE
cloud_bin_secure "$OC_CLOUD_ROOT/bin/bdpan"; check "$?" 1 '0755 executable rejected'
STAT_MODE=700; STAT_OWNER=other; export STAT_MODE STAT_OWNER
cloud_bin_secure "$OC_CLOUD_ROOT/bin/bdpan"; check "$?" 1 'non-root executable rejected'
if ln -s "$OC_CLOUD_ROOT/bin/bdpan" "$OC_CLOUD_ROOT/bin/link" 2>/dev/null; then
	STAT_MODE=700 STAT_OWNER=root cloud_bin_secure "$OC_CLOUD_ROOT/bin/link"; check "$?" 1 'symlink executable rejected'
else
	printf '  skip  symlink creation unavailable\n'
fi

[ "$fail" = 0 ]
