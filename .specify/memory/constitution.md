# syslog Container Constitution

> **Version:** 1.1.0
> **Ratified:** 2026-08-23
> **Amended:** 2026-10-02
> **Status:** Active
> **Inherits:** [crunchtools/constitution](https://github.com/crunchtools/constitution) v1.20.0
> **Profile:** Container Image

This file holds what is specific to the syslog image. The fleet rules and the
Container Image profile apply at the inherited version and are checked against
this repo's files by `constitution.yml`. They are not restated here.

## Image Purpose

Central log collector for all crunchtools infrastructure (RT #1460). Container
logs are lost when a container restarts or crashes, which leaves no forensics
and gives Hermes nothing to read before it attempts a remediation. This image
persists every container's output outside the container, under a single
retention policy, in a form the Syslog MCP server can query. Published to
`quay.io/crunchtools/syslog`.

## Image Versioning

The image version tracks this repo's build recipe and module list, not the
upstream rsyslog release. A rebuild that only picks up a newer UBI `rsyslog`
RPM is a PATCH; adding or dropping an rsyslog module is a MINOR, because the
module list is part of the image's contract.

## Base Image Choice

`registry.access.redhat.com/ubi10/ubi-micro`: 24 MB, no package manager, and
ABI-consistent with the RHEL 10 rsyslog RPM. It is *minimal*, not distroless:
it carries bash and ~139 coreutils binaries. The property worth asserting in
tests is the absence of a package manager, not the absence of a shell.

**Hummingbird was evaluated first and rejected on evidence.** The catalog
publishes no syslog image, so the option was to build rsyslog onto
`hi/core-runtime`. That base ships glibc 2.43, in which `modf` became an IFUNC;
RHEL 10's libfastjson is built against glibc 2.39 and segfaults against it
before rsyslogd can print its version. This is a genuine forward-ABI break, and
no `LD_PRELOAD` or link-order workaround resolves it. Revisit if Hummingbird
ever publishes an rsyslog or syslog-ng image.

## Build Model

Two stages. `ubi-minimal` installs `rsyslog` (UBI 10 AppStream, no RHSM
entitlement needed) plus `libzstd`, `lz4-libs` and `xz-libs` into an
installroot; `scripts/assemble-rootfs.sh` copies out `rsyslogd`, an explicit
module list, and the library closure the base does not already provide
(~1.6 MB total). The final stage copies only that rootfs, so no package
manager reaches the shipped image.

Two invariants the build must hold, both enforced in
`scripts/assemble-rootfs.sh` and re-checked in `tests/test-image.sh`:

1. **Never lay a real directory over `/bin`, `/sbin`, `/lib`, `/lib64` or
   `/usr/sbin`.** They are symlinks in the base. A single library dropped into
   `/lib64` replaces the symlink and hides libc from `ld.so`.
2. **`libsystemd` `dlopen()`s its decompressors.** `ldd` cannot see libzstd,
   liblz4 or liblzma, but journal files are zstd-compressed by default.
   Dropping them makes imjournal silently fail on compressed entries.

The module list is deliberately explicit. Shipping the full rsyslog module set
would pull libcurl, krb5, openldap and cyrus-sasl in for outputs that are never
loaded.

## Image Test Assertions

Beyond the build: binary, config, module and dlopen-library presence; base
symlinks intact; no package manager present; `rsyslogd -v` resolves every
dynamic library (the gate that catches base/RPM ABI drift); a syslog message
sent over TCP lands on disk with a non-blank body.

## Ingest Model

Podman has no syslog log driver, so per-container forwarding of the Docker
kind is not available. Every container on the host already uses the journald
driver, and conmon stamps each line with `CONTAINER_NAME`, so `imjournal`
against the bind-mounted host journal covers the whole fleet with no
per-container configuration.

`imudp`/`imptcp` on 514 serve the cases the journal cannot: processes inside
systemd-based containers whose internal logs never reach conmon, and any future
host that forwards over the network.

## SELinux

The container runs as UID 0 and reads `/var/log/journal` read-only under
`--security-opt label=type:container_logreader_t`; confinement comes from
SELinux, not the UID. The journal mount MUST NOT carry `:z` or `:Z`:
relabelling the host journal would break journald itself.

## Output Format

`/logs/<source>/<YYYY-MM-DD>.log`, plain text, one line per message:

```
<rfc3339 timestamp> <host> <source> <program> <SEVERITY> <message>
```

`<source>` resolves per ingest path: `CONTAINER_NAME` for journal messages, the
sender hostname for network-forwarded ones, and the program name for host
services. Network messages MUST key on hostname rather than program name,
otherwise `httpd` from every systemd web container collapses into one directory
and service attribution is lost. `<program>` is kept as its own field so that
distinction survives inside a multi-service container.

Plain text rather than JSON so it stays greppable while the fixed six-field
prefix remains a single regex for the MCP server. Files are bucketed by receipt
time, not sender-claimed time, so a sender with a broken clock cannot create
directories of 1970 files.

## Retention

Date-stamped filenames make rotation implicit. `deploy/prune-logs.sh`, driven
by `syslog-prune.timer` on the host, compresses files after 2 days and expires
them after 90. It runs on the host rather than in the container to keep the
image to a single process.

## Ingest Freshness Monitoring

Nagios must check ingest freshness, not just liveness. A collector that has
stopped reading the journal keeps its container running and its port open
while every log on the box goes missing; `check_syslog_freshness.sh` is the
only check that catches it. Disk usage is also monitored, because centralising
40+ containers onto one filesystem makes `/var` shared fate.

## History

| Version | Date | Changes |
|---------|------|---------|
| 1.0.0 | 2026-08-23 | Initial constitution (RT #1460) |
| 1.1.0 | 2026-10-02 | Manifest under constitution v1.18.0: fleet and profile restatement removed, collector specifics kept |
