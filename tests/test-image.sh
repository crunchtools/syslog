#!/bin/bash
# Test suite for quay.io/crunchtools/syslog
# Usage: ./test-image.sh --static <image>
#        ./test-image.sh --runtime <image>

set -uo pipefail

RUNTIME="${CONTAINER_RUNTIME:-docker}"
PASS=0
FAIL=0

check() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc"
        FAIL=$((FAIL + 1))
    fi
}

# Assertions run against the exported filesystem. The manifest is materialised
# once rather than re-piped per check: `tar | grep -q` looks right but grep exits
# on first match, tar takes SIGPIPE, and pipefail then reports every successful
# match as a failure.
export_image() {
    local image="$1"
    local cid
    cid=$($RUNTIME create "$image" 2>/dev/null)
    $RUNTIME export "$cid" > "$TARBALL"
    $RUNTIME rm -f "$cid" >/dev/null 2>&1
    tar -tf "$TARBALL" > "$FILELIST"
}

in_tar()     { grep -qx "$1" "$FILELIST"; }
not_in_tar() { ! grep -qE "$1" "$FILELIST"; }

static_tests() {
    local image="$1"
    echo "=== Static tests for $image ==="

    TARBALL=$(mktemp)
    FILELIST=$(mktemp)
    trap 'rm -f "$TARBALL" "$FILELIST"' EXIT
    export_image "$image"

    check "rsyslogd binary present"        in_tar "usr/bin/rsyslogd"
    check "rsyslog.conf present"           in_tar "etc/rsyslog.conf"
    check "imjournal module present"       in_tar "usr/lib64/rsyslog/imjournal.so"
    check "imudp module present"           in_tar "usr/lib64/rsyslog/imudp.so"
    check "imptcp module present"          in_tar "usr/lib64/rsyslog/imptcp.so"
    check "impstats module present"        in_tar "usr/lib64/rsyslog/impstats.so"
    check "mmutf8fix module present"       in_tar "usr/lib64/rsyslog/mmutf8fix.so"
    check "libestr present"                in_tar "usr/lib64/libestr.so.0.0.0"
    check "libfastjson present"            in_tar "usr/lib64/libfastjson.so.4.3.0"

    # libsystemd dlopen()s these; ldd cannot see them, so nothing but an explicit
    # assertion stops a refactor from dropping them and breaking journal reads of
    # compressed entries.
    check "libzstd present (journal decompression)"  in_tar "usr/lib64/libzstd.so.1.5.5"
    check "liblz4 present (journal decompression)"   in_tar "usr/lib64/liblz4.so.1.9.4"

    # Laying a real directory over any of these would replace a base-image
    # symlink and hide the base's own content from ld.so.
    for d in lib lib64 bin sbin; do
        check "/$d left as base symlink" not_in_tar "^$d/.+"
    done

    # ubi-micro carries a shell and ~139 coreutils binaries, so "no shell" is not
    # a property this image has. What it does guarantee is no package manager,
    # which is what keeps the CVE surface and the tamper surface down.
    check "no package manager in image" not_in_tar "^usr/bin/(dnf|microdnf|rpm|yum)"

    check "entrypoint is rsyslogd" \
        bash -c "$RUNTIME inspect '$image' --format '{{index .Config.Entrypoint 0}}' | grep -qx /usr/bin/rsyslogd"
}

runtime_tests() {
    local image="$1"
    local container="syslog-test-$$"
    local workdir
    workdir=$(mktemp -d)
    echo "=== Runtime tests for $image ==="

    trap "$RUNTIME rm -f $container >/dev/null 2>&1; rm -rf '$workdir'" EXIT

    # Every dynamic library must resolve. This is the gate that catches the
    # base image and the RPM drifting apart — the failure mode is a SIGSEGV
    # before rsyslogd prints anything, which is easy to misread as a config bug.
    check "rsyslogd starts and reports its version" \
        bash -c "$RUNTIME run --rm --entrypoint /usr/bin/rsyslogd '$image' -v 2>&1 | grep -q '^rsyslogd '"

    # Validate the shipped config without the journal mount CI cannot provide.
    mkdir -p "$workdir/logs" "$workdir/state"
    # Mirrors the message normalisation in config/rsyslog.conf so the delimiter
    # guarantee is exercised, not just the transport.
    cat > "$workdir/net.conf" <<'EOF'
global(workDirectory="/var/lib/rsyslog")
module(load="imptcp")
input(type="imptcp" port="5514")
template(name="t" type="list") {
  property(name="programname")
  constant(value=" ")
  property(name="$.msg")
  constant(value="\n")
}
set $.msg = rtrim(ltrim($msg));
action(type="omfile" file="/logs/net.log" template="t")
EOF

    $RUNTIME run -d --name "$container" \
        -v "$workdir/net.conf:/etc/net.conf:ro,Z" \
        -v "$workdir/logs:/logs:Z" \
        -v "$workdir/state:/var/lib/rsyslog:Z" \
        -p 127.0.0.1:5514:5514 \
        --entrypoint /usr/bin/rsyslogd "$image" -n -f /etc/net.conf >/dev/null

    sleep 4

    check "container still running after start" \
        bash -c "[ \"\$($RUNTIME inspect '$container' --format '{{.State.Status}}')\" = running ]"

    # End-to-end: a syslog line in on 5514 must come out as a file on disk.
    printf '<14>Jan  1 00:00:00 testhost citest: RUNTIME_CANARY\n' \
        > /dev/tcp/127.0.0.1/5514 2>/dev/null \
        || bash -c 'exec 3<>/dev/tcp/127.0.0.1/5514; printf "<14>Jan  1 00:00:00 testhost citest: RUNTIME_CANARY\n" >&3; exec 3<&-'
    sleep 3

    check "network syslog message written to disk" \
        grep -q RUNTIME_CANARY "$workdir/logs/net.log"

    # Guards the spifno1stsp trap: a template option that renders as a bare space
    # produces a well-formed line with an empty body, which every other check
    # here would happily pass.
    check "message body is not blank" \
        grep -qE '^citest RUNTIME_CANARY$' "$workdir/logs/net.log"

    if [ $FAIL -gt 0 ]; then
        echo "  --- DEBUG ---"
        $RUNTIME logs "$container" 2>&1 | tail -20 || true
        cat "$workdir/logs/net.log" 2>/dev/null || true
    fi
}

case "${1:-}" in
    --static)  static_tests "${2:?image required}" ;;
    --runtime) runtime_tests "${2:?image required}" ;;
    *)
        static_tests "${2:?image required}"
        runtime_tests "$2"
        ;;
esac

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
