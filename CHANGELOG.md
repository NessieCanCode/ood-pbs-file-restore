# Changelog

All notable changes to this project are documented here. The project follows
[Semantic Versioning](https://semver.org/).

## [1.0.2] - 2026-08-07

### Added

- Live-tested portal, broker, PBS server, and static-client version matrix.
- Optional shared-home backup producer guide and checksum-enforcing static-client installer.
- Sanitized backup writer command and separate writer environment example.

### Changed

- Clarified that the restore application uses the PBS HTTPS API and does not require `proxmox-backup-client` at runtime.
- Separated the read-only restore environment from the more privileged backup-writer environment.

## [1.0.1] - 2026-08-07

### Added

- Sanitized end-to-end deployment, validation, upgrade, and rollback guidance.
- Production security checklist and broker environment example.

### Changed

- Removed an unused broker environment requirement.
- Replaced deployment-specific navigation branding with generic Open OnDemand branding.

## [1.0.0] - 2026-08-07

### Added

- Initial public companion-app release.
- User-bound PBS snapshot browsing and restore workflow.
- Privileged broker with forced-command SSH confinement.
- Path, archive, symlink, ownership, and destination validation.
- Non-overwriting restores under each authenticated user's home directory.
