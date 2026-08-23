# syslog.crunchtools.com — central log collector for the crunchtools fleet.
#
# Project Hummingbird publishes no syslog image (verified against the live
# catalog API). Building rsyslog onto Hummingbird's core-runtime was tried first
# and does not work: core-runtime ships glibc 2.43, where `modf` became an IFUNC,
# and RHEL 10's libfastjson (glibc 2.39) segfaults against it before rsyslogd can
# print its version. That is a genuine forward-ABI break, not a packaging fault.
#
# ubi-micro is the minimal base that *is* ABI-consistent with the RPM: 24 MB, no
# package manager, same el10 userspace. Stage 1 assembles rsyslog from RHEL 10
# content, stage 2 keeps only the ~1.6 MB that matters.

FROM registry.access.redhat.com/ubi10/ubi-minimal:latest AS build

# rsyslog lives in the UBI 10 AppStream repo, so no RHSM entitlement is needed.
RUN microdnf install -y \
        --noplugins \
        --config=/etc/dnf/dnf.conf \
        --setopt=reposdir=/etc/yum.repos.d \
        --setopt=varsdir=/etc/dnf/vars \
        --setopt=cachedir=/var/cache/dnf \
        --installroot=/rootfs \
        --releasever=10 \
        --setopt=install_weak_deps=0 \
        --nodocs \
        rsyslog libzstd lz4-libs xz-libs \
    && microdnf clean all

COPY scripts/assemble-rootfs.sh /usr/local/bin/assemble-rootfs.sh
RUN bash /usr/local/bin/assemble-rootfs.sh

FROM registry.access.redhat.com/ubi10/ubi-micro:latest

COPY --from=build /out /
COPY config/rsyslog.conf /etc/rsyslog.conf

# rsyslog must read /var/log/journal, which is root:systemd-journal 0640.
# Confinement comes from SELinux (container_logreader_t) rather than the UID —
# see the systemd unit in deploy/.
USER 0

LABEL maintainer="fatherlinux <scott.mccarty@crunchtools.com>"
LABEL description="Central syslog collector — rsyslog on a minimal UBI 10 micro base"
LABEL org.opencontainers.image.source=https://github.com/crunchtools/syslog
LABEL org.opencontainers.image.description="rsyslog log collector for crunchtools infrastructure. Ingests the lotor systemd journal (every podman container's stdout/stderr) plus network syslog on 514, and writes per-source plain-text log files."
LABEL org.opencontainers.image.licenses=AGPL-3.0-or-later

EXPOSE 514/udp
EXPOSE 514/tcp

STOPSIGNAL SIGTERM

# /usr/bin, not /usr/sbin: scripts/assemble-rootfs.sh normalises every path into
# the merged-usr layout, because /bin, /sbin, /lib and /lib64 are symlinks in the
# base and a COPY would otherwise replace one with a directory.
ENTRYPOINT ["/usr/bin/rsyslogd", "-n", "-f", "/etc/rsyslog.conf"]
