# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-11-15
**Upgrading:** nothing to do.

### Changed

- The public repository now changes once per version, as one commit per release. Before, every change was copied there as it landed. Installing from the `stable` branch still works the same way.
- The IP filter hint in rdgen's form now uses documentation addresses (`192.0.2.0/24,198.51.100.5`) as its example.
- The patches in `rdgen/patches` now name the release bot as their author, and their test fixtures use example names instead of real ones.
- CI test dependencies for rdgen moved to Django 6.1.3, Pillow 13.0.0 and certifi 2026.10.23, which fix the known vulnerabilities in the old versions.
- The README now has badges, a Why section, a quick start, a requirements table, a scope note, a table of where settings live, a list of known limits and a repo map, and no longer describes the old mirroring workflow.

### Fixed

- Old project names in the NOTICE file and in script headers now say rustdesk-cortendesk-pve.

[Unreleased]: https://github.com/rob-paprocki/rustdesk-cortendesk-pve/commits/stable
