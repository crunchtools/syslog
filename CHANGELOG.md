# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/) and this project adheres to
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- **Overlay hosts can ship logs here** (RT#1628). The collector also
  publishes 514/tcp on gloval's WireGuard address, `10.44.0.1`, so hosts on the
  Crunchtools overlay forward to it; the first is Exedore. Gloval's firewall
  already accepts the overlay, and each host's messages land under its own FQDN
  directory. Deployed and verified with a probe from Exedore. Unit file only.

## [1.0.1] - 2026-11-11

### Changed

- Constitution is now a v1.18.0 manifest: it holds only what is specific to
  this repo; fleet and profile rules apply by reference.
- Constitution validation is pinned to the inherited release via
  `.github/workflows/constitution.yml`.
- Dependabot auto-merges GitHub Actions minor and patch updates.
- Gourmand CI gate and pre-commit hook (RT #1509). The stale NRPE plugin and
  command copies under `deploy/nagios/` are removed; crunchtools/nagios-agent
  ships and wires them. Constitution now inherits v1.17.0.

## [1.0.0] - 2026-09-20

First tagged release. This image has been running in production since before
it had version control; this release marks the current state as the baseline
going forward.
