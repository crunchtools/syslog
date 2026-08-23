#!/bin/bash
# Copy rsyslogd, the modules config/rsyslog.conf actually loads, and any shared
# library the Hummingbird core-runtime base does not already provide, into /out.
#
# Keeping the module list explicit matters: shipping the full rsyslog module set
# would drag libcurl, krb5, openldap and cyrus-sasl into the image for outputs we
# never load.
#
# Every destination path is normalised to the merged-usr layout first. In the
# core-runtime base /lib64, /bin, /sbin and /usr/sbin are all *symlinks* into
# /usr/{bin,lib64}. Laying a real directory over any of them replaces the
# symlink, which orphans the base's own content — dropping a single library into
# /lib64 is enough to hide libc from ld.so and brick the image.
set -euo pipefail

ROOTFS=/rootfs
OUT=/out

MODULES=(
    imjournal    # systemd journal input — the primary ingest path
    imptcp       # plain TCP syslog listener
    imudp        # UDP syslog listener
    impstats     # rsyslog self-statistics, surfaced to Nagios
    mmutf8fix    # scrub invalid UTF-8 out of container output
    lmnet
    lmnetstrms
    lmnsd_ptcp
    lmtcpsrv
    lmtcpclt
    lmregexp     # regex property replacer
    lmzlibw      # zlib compression for the TCP transport
)

# Shared libraries ubi-micro already ships. tests/test-image.sh asserts the
# running image resolves every library, which is what catches this list going
# stale after a base image refresh.
BASE_PROVIDED='^(libc|libm|libmvec|libgcc_s|libcap|libcap-ng|libselinux|libsepol|libaudit|libpcre2-8|libacl|libattr|libeconf|libpam|libncurses|libtinfo|libresolv|libpthread|libdl|librt|libutil|libanl)\.so'

# libsystemd dlopen()s its decompressors rather than linking them, so ldd cannot
# see them. Journal files are zstd-compressed by default; without these,
# imjournal silently fails to read compressed entries.
DLOPEN_LIBS=(
    /usr/lib64/libzstd.so.1
    /usr/lib64/liblz4.so.1
    /usr/lib64/liblzma.so.5
)

install -d "$OUT"

# Map a source path onto the merged-usr layout used by the runtime base.
normalise() {
    case "$1" in
        /lib64/*)    echo "/usr/lib64/${1#/lib64/}" ;;
        /lib/*)      echo "/usr/lib/${1#/lib/}" ;;
        /bin/*)      echo "/usr/bin/${1#/bin/}" ;;
        /sbin/*)     echo "/usr/bin/${1#/sbin/}" ;;
        /usr/sbin/*) echo "/usr/bin/${1#/usr/sbin/}" ;;
        *)           echo "$1" ;;
    esac
}

copy_from_rootfs() {
    local path="$1"
    local src="$ROOTFS$path"
    local dest
    dest="$(normalise "$path")"

    if [ ! -f "$src" ]; then
        echo "assemble-rootfs: missing from rootfs: $path" >&2
        exit 1
    fi
    install -D -m "$(stat -c %a "$src")" "$src" "$OUT$dest"
}

copy_from_rootfs /usr/sbin/rsyslogd
for module in "${MODULES[@]}"; do
    copy_from_rootfs "/usr/lib64/rsyslog/${module}.so"
done

# Resolve the library closure from inside the rootfs. Running ldd on the build
# container's own libraries would miss libestr and libfastjson, which are only
# installed under /rootfs.
ldd_targets="/usr/sbin/rsyslogd"
for module in "${MODULES[@]}"; do
    ldd_targets="$ldd_targets /usr/lib64/rsyslog/${module}.so"
done

mapfile -t closure < <(
    chroot "$ROOTFS" /bin/bash -c "ldd $ldd_targets 2>/dev/null" \
        | awk '{print $3}' | grep '^/' | sort -u
)

if [ "${#closure[@]}" -eq 0 ]; then
    echo "assemble-rootfs: ldd resolved no libraries — refusing to build a broken image" >&2
    exit 1
fi

for lib in "${closure[@]}" "${DLOPEN_LIBS[@]}"; do
    if [[ "${lib##*/}" =~ $BASE_PROVIDED ]]; then
        continue
    fi
    # ldd reports the SONAME, which is normally a symlink to the versioned file.
    # Copy the real file once and recreate the link, rather than shipping two
    # copies of every library.
    target=$(chroot "$ROOTFS" readlink -f "$lib")
    copy_from_rootfs "$target"
    if [ "$target" != "$lib" ]; then
        ln -sf "$(basename "$target")" "$OUT$(normalise "$lib")"
    fi
done

# Guard the invariant the normalise() function exists to protect. If any of these
# ever appear in /out, the COPY into the runtime stage will replace a base
# symlink with a directory and the image will not run.
for forbidden in /lib /lib64 /bin /sbin /usr/sbin; do
    if [ -e "$OUT$forbidden" ]; then
        echo "assemble-rootfs: $OUT$forbidden would clobber a base symlink" >&2
        exit 1
    fi
done

# Runtime directories. /logs and /var/lib/rsyslog are bind-mounted in production,
# but creating them keeps the image runnable standalone so CI can smoke-test it.
install -d -m 0755 "$OUT/var/lib/rsyslog" "$OUT/logs" "$OUT/logs/_collector"

echo "--- assembled rootfs ---"
find "$OUT" -type f -printf '%10s  %p\n' | sort -k2
du -sh "$OUT"
