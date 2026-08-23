# syslog.crunchtools.com

Central log collector for crunchtools infrastructure on lotor. rsyslog on a
minimal UBI 10 micro base — about 1.6 MB of content on a 24 MB image, idling
around 3–5 MB RSS.

Built for RT #1460. It exists so that container logs survive a restart, so there
is one retention policy instead of forty, and so Hermes can read *why* a service
failed before it decides how to fix it.

## How logs get here

Podman has no syslog log driver — only `k8s-file`, `journald`, `none` and
`passthrough`. The per-container forwarding that works on Docker is simply not
available, so this collector taps the fleet one level down instead:

```
40+ containers ──stdout/stderr──> conmon ──> host systemd journal
                                                     │
                                        (bind-mounted read-only)
                                                     ▼
                                          rsyslog imjournal
                                                     │
                                                     ▼
                          /srv/syslog.crunchtools.com/data/logs/<source>/<date>.log
                                                     ▲
                                                     │
     app-level senders ──syslog udp/tcp 514──────────┘
```

Every container on lotor already uses the journald log driver, and conmon stamps
each line with `CONTAINER_NAME`. That means the journal path covers the whole
fleet with **no per-container configuration** — nothing to add to 40 systemd
units, nothing to keep in sync.

The network listener on 514 covers what the journal cannot: processes inside
systemd-based containers, whose internal logs never reach conmon and so never
reach the journal, plus any future host that is not lotor.

## Output format

```
/srv/syslog.crunchtools.com/data/logs/<source>/<YYYY-MM-DD>.log
```

```
2026-08-23T15:16:44.380222+00:00 lotor.dc3.crunchtools.com mcp-memory INFO INFO:httpx:HTTP Request: POST https://... "HTTP/1.1 200 OK"
└─ rfc3339 timestamp ──────────┘ └─ host ──────────────┘ └ source ─┘ └sev┘ └─ message ─────────────────────────────────────────────┘
```

`<source>` is the container name where one exists, otherwise the program name —
so host services (`sshd`, `systemd`, `podman`) land here too.

Plain text, not JSON: it stays greppable with ordinary tools, and the fixed
five-field prefix is a single regex for the MCP server to parse. Embedded
newlines are escaped as `#012`, so one record is always one line.

## Deploying

```bash
# On lotor, as root
install -D -m 0644 config/rsyslog.conf /srv/syslog.crunchtools.com/config/rsyslog.conf
install -d -m 0755 /srv/syslog.crunchtools.com/data/logs/_collector \
                   /srv/syslog.crunchtools.com/data/state

install -m 0644 deploy/syslog.crunchtools.com.service /etc/systemd/system/
install -m 0644 deploy/syslog-prune.service deploy/syslog-prune.timer /etc/systemd/system/
# /usr is read-only under bootc image mode, so host helpers live in /srv
install -D -m 0755 deploy/prune-logs.sh /srv/syslog.crunchtools.com/bin/prune-logs.sh

systemctl daemon-reload
systemctl enable --now syslog.crunchtools.com.service syslog-prune.timer
```

Two runtime details that are not optional:

- `--security-opt label=type:container_logreader_t` — the SELinux type
  container-selinux provides for containers that read host logs. Without it the
  journal read is denied.
- The journal mount is `:ro` with **no** `:z` or `:Z`. Relabelling
  `/var/log/journal` would break journald itself.

## Monitoring

```bash
# Nagios server
install -m 0644 deploy/nagios/syslog.cfg /srv/nagios.crunchtools.com/config/services/
# add ctr-syslog.crunchtools.com to the `infrastructure` hostgroup in container-hosts.cfg

# Nagios agent
install -m 0755 deploy/nagios/check_syslog_freshness.sh \
                deploy/nagios/check_syslog_disk.sh \
                /srv/nagios-agent.crunchtools.com/config/scripts/
cat deploy/nagios/nrpe-commands.cfg >> /srv/nagios-agent.crunchtools.com/config/nrpe.cfg
```

Both config directories are bind-mounted `:ro,Z`, so a newly installed file lands
as `var_t` and Nagios cannot read it. Match the label of the files already there:

```bash
chcon --reference=/srv/nagios.crunchtools.com/config/services/container-hosts.cfg \
      /srv/nagios.crunchtools.com/config/services/syslog.cfg
```

The failure is worth recognising: Nagios reports it as
`Could not open config directory member`, and then *cascades* into unrelated
errors about other hosts. Validate with
`podman exec nagios.crunchtools.com nagios -v /etc/nagios/nagios.cfg` and fix the
open failure first.

The agent also needs the log root mounted read-only so the freshness and disk
checks can see it:

```
-v /srv/syslog.crunchtools.com/data/logs:/srv/syslog.crunchtools.com/data/logs:ro
```

**Ingest freshness is the check that matters.** A collector that has stopped
reading the journal keeps its container running and its port open, so the
container and TCP checks both stay green while every log on the box is silently
dropped. Only "are bytes still landing on disk" catches that.

## Retention

Date-stamped filenames make rotation implicit; `syslog-prune.timer` compresses
after 2 days and expires after 90. Tune via `Environment=` in
`syslog-prune.service`.

## Building

```bash
podman build -t quay.io/crunchtools/syslog:latest .
./tests/test-image.sh --static  quay.io/crunchtools/syslog:latest
./tests/test-image.sh --runtime quay.io/crunchtools/syslog:latest
```

`CONTAINER_RUNTIME=podman` if you are not on the CI's docker.

## Why not Hummingbird

The catalog has no syslog image, so the option was to build rsyslog onto
`hi/core-runtime`. That was tried and fails: core-runtime ships glibc 2.43, where
`modf` became an IFUNC, and RHEL 10's libfastjson (glibc 2.39) segfaults against
it before rsyslogd prints its version. A forward-ABI break, not a packaging
mistake — `LD_PRELOAD` and `LD_BIND_NOW` do not help. `ubi-micro` gets the CVE
surface down to something comparable, with a matching userspace. It is minimal
rather than truly distroless — no package manager, but bash and coreutils are
still there. Worth revisiting if Hummingbird ever ships rsyslog or syslog-ng.

## Related

- RT #1460 — this work
- RT #1459 — Nagios migration; the paging chain this feeds
- `crunchtools/mcp-syslog` — the MCP server that queries these files
