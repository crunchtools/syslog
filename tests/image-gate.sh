#!/bin/bash
# Boot gate for the syslog image, run INSIDE the image sdlc builds from this PR.
#
# Usage (from [tool.sdlc.ci.boot-gate]): bash tests/image-gate.sh
#
# This is tests/test-image.sh with the container runtime taken out. sdlc's
# `command` check starts ONE container from the built image (repo read-only at
# /repo, tmpfs /tmp, no network but loopback, all capabilities dropped). The
# static assertions that test-image.sh made against an exported tarball are made
# here against the live filesystem, and the runtime test starts rsyslogd in the
# background on loopback port 5514 with state under /tmp. ubi-micro ships bash,
# so the client is bash's /dev/tcp; it has no grep, so matching is bash too. The image is built unmodified; no variant.
#
# Not reproduced: "entrypoint is rsyslogd" (it reads image metadata via
# `podman inspect`, which does not exist inside the container), and the
# container "still running" check is replaced by a pid liveness check.

set -uo pipefail

PASS=0
FAIL=0
TMP="$(mktemp -d /tmp/syslog-gate.XXXXXX)"
RSYSLOGD_PID=""

cleanup() {
    [ -n "$RSYSLOGD_PID" ] && kill "$RSYSLOGD_PID" 2>/dev/null
    rm -rf "$TMP"
}
trap cleanup EXIT

check() {
    local desc="$1"
    shift
    local output
    if output=$("$@" 2>&1); then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc"
        [ -n "$output" ] && echo "        $output"
        FAIL=$((FAIL + 1))
    fi
}

present() { [ -e "$1" ]; }
absent()  { local f; for f in "$@"; do [ ! -e "/usr/bin/$f" ] || { echo "found /usr/bin/$f"; return 1; }; done; }
symlink() { [ -L "$1" ]; }

echo "=== Static tests ==="
check "rsyslogd binary present"     present /usr/bin/rsyslogd
check "rsyslog.conf present"        present /etc/rsyslog.conf
for m in imjournal imudp imptcp impstats mmutf8fix; do
    check "$m module present"       present "/usr/lib64/rsyslog/$m.so"
done
check "libestr present"             present /usr/lib64/libestr.so.0.0.0
check "libfastjson present"         present /usr/lib64/libfastjson.so.4.3.0

# libsystemd dlopen()s these; ldd cannot see them.
check "libzstd present (journal decompression)" present /usr/lib64/libzstd.so.1.5.5
check "liblz4 present (journal decompression)"  present /usr/lib64/liblz4.so.1.9.4

# A real directory laid over any of these would hide the base's own content.
for d in lib lib64 bin sbin; do
    check "/$d left as base symlink" symlink "/$d"
done

check "no package manager in image" absent dnf microdnf rpm yum

echo "=== Runtime tests ==="
# Every dynamic library must resolve: a mismatch is a SIGSEGV before rsyslogd
# prints anything.
version_ok() { local o; o="$(/usr/bin/rsyslogd -v 2>&1)"; [[ "$o" == rsyslogd\ * ]]; }
check "rsyslogd starts and reports its version" version_ok

mkdir -p "$TMP/logs" "$TMP/state"
# Mirrors the message normalisation in config/rsyslog.conf so the delimiter
# guarantee is exercised, not just the transport.
cat > "$TMP/net.conf" <<EOF
global(workDirectory="$TMP/state")
module(load="imptcp")
input(type="imptcp" port="5514")
template(name="t" type="list") {
  property(name="programname")
  constant(value=" ")
  property(name="\$.msg")
  constant(value="\n")
}
set \$.msg = rtrim(ltrim(\$msg));
action(type="omfile" file="$TMP/logs/net.log" template="t")
EOF

/usr/bin/rsyslogd -n -f "$TMP/net.conf" -i "$TMP/rsyslogd.pid" >"$TMP/rsyslogd.out" 2>&1 &
RSYSLOGD_PID=$!

listening() { (exec 3<>/dev/tcp/127.0.0.1/5514) 2>/dev/null; }
tries=15
until listening; do
    tries=$((tries - 1))
    [ "$tries" -le 0 ] && break
    sleep 1
done

check "rsyslogd still running after start" kill -0 "$RSYSLOGD_PID"

# End-to-end: a syslog line in on 5514 must come out as a file on disk.
# ubi-micro has no grep; read the file with bash.
has()      { [[ "$(cat "$TMP/logs/net.log" 2>/dev/null)" == *"$1"* ]]; }
has_line() { local l; while IFS= read -r l; do [ "$l" = "$1" ] && return 0; done <"$TMP/logs/net.log"; return 1; }

send() {
    exec 3<>/dev/tcp/127.0.0.1/5514 || return 1
    printf '<14>Jan  1 00:00:00 testhost citest: RUNTIME_CANARY\n' >&3
    exec 3<&-
}
send
tries=10
until has RUNTIME_CANARY; do
    tries=$((tries - 1))
    [ "$tries" -le 0 ] && break
    sleep 1
done

check "network syslog message written to disk" has RUNTIME_CANARY

# Guards the spifno1stsp trap: a template option that renders as a bare space
# produces a well-formed line with an empty body.
check "message body is not blank" has_line "citest RUNTIME_CANARY"

if [ "$FAIL" -gt 0 ]; then
    echo "  --- DEBUG ---"
    tail -20 "$TMP/rsyslogd.out" 2>/dev/null
    cat "$TMP/logs/net.log" 2>/dev/null
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
