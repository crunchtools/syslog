# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/) and this project adheres to
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed

- Gourmand CI gate and pre-commit hook (RT #1509). The stale NRPE plugin and
  command copies under `deploy/nagios/` are removed; crunchtools/nagios-agent
  ships and wires them. Constitution now inherits v1.17.0.

## [1.0.0] - 2026-09-20

First tagged release. This image has been running in production since before
it had version control; this release marks the current state as the baseline
going forward.
