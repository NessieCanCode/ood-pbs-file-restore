# Open OnDemand PBS File Restore

## Overview

PBS File Restore is an Open OnDemand companion application that lets an
authenticated user browse recent Proxmox Backup Server snapshots and restore
files or directories from their own archived home directory. Restores are
written beneath a new, non-overwriting destination in the user's home.

The design keeps PBS credentials and root filesystem access outside the user's
Passenger process. A constrained client binds every request to `SUDO_USER`, and
a forced-command SSH broker performs identity, archive-path, and destination
validation before communicating with PBS.

## Architecture

```text
Browser
  -> Open OnDemand Passenger app in the user's PUN
  -> sudo-confined client
  -> forced-command SSH connection
  -> privileged broker on the storage host
  -> Proxmox Backup Server API
  -> /home/<user>/.pbs-restores/<date>/<job-id>/
```

The Passenger application never receives the PBS API token, broker SSH private
key, authority to select another username, or a general-purpose root command.

## Features

- Date-based PBS snapshot selection and catalog browsing
- Authenticated-user confinement enforced independently at three layers
- File and directory restoration without overwriting existing data
- Revalidation of PBS catalog paths and downloaded archive paths
- `O_NOFOLLOW` destination traversal and ownership checks
- Root-only staging followed by placement into the user's restore directory
- Audit logging through syslog/journald
- Browser interface styled with the active Open OnDemand dashboard assets

## Requirements

For a clean installation, start with the complete
[deployment guide](docs/DEPLOYMENT.md). It includes the topology assumptions,
PBS permissions, SSH forced command, file modes, portal installation,
acceptance tests, troubleshooting, upgrades, and rollback.

### Open OnDemand portal

- Open OnDemand 4.x with Passenger application support
- Python 3.9 or later
- Passwordless sudo for only the installed broker client command
- A dedicated SSH key restricted to the broker forced command

### Broker/storage host

- Python 3.9 or later recommended
- NSS resolution for the same users and numeric IDs as Open OnDemand
- Direct access to the managed home filesystem
- TLS connectivity to Proxmox Backup Server
- A dedicated PBS API token scoped as narrowly as the backup layout permits

The reference implementation expects one shared-home `host` backup whose pxar
archive contains a top-level directory per username. Other layouts require a
mapping adapter with equivalent identity and path validation.

### Live-tested versions

The reference workflow was checked live on 2026-08-07 with:

| Role | Live-tested versions |
| --- | --- |
| Open OnDemand portal | Rocky Linux 9.8, Open OnDemand 4.2.3, Python 3.9.25, PyYAML 5.4.1, OpenSSH 9.9p1 |
| Broker and backup source | Red Hat Enterprise Linux 8.10, Python 3.6.8, OpenSSH 8.0p1 |
| Static backup client | `proxmox-backup-client` 4.2.3 on RHEL 8.9/8.10 and Rocky Linux 9.8 x86_64 |
| PBS server | Debian 13, PBS runtime 4.2.2 with server package 4.2.5-1 installed |

Python 3.6.8 describes the current live broker, but it is end-of-life and is
not recommended for a new deployment. Other comparable Rocky Linux and
AlmaLinux systems remain compatibility candidates rather than claimed
live-tested combinations. See the
[backup producer guide](docs/CREATING-SHARED-HOME-BACKUPS.md) for the precise
test boundary and checksum-pinned installation.

## Repository layout

| Path | Purpose |
| --- | --- |
| `app.py` | Passenger WSGI application and browser interface |
| `passenger_wsgi.py` | Passenger entry point |
| `manifest.yml` | Open OnDemand application metadata |
| `client.py` | Sudo-confined portal-side broker client |
| `broker.py` | Privileged storage-side PBS broker |
| `sudoers` | Example constrained sudo policy |
| `validate.py` | Live confinement and restore validation client |
| `docs/DEPLOYMENT.md` | End-to-end clean installation, testing, upgrade, and rollback |
| `docs/SECURITY-CHECKLIST.md` | Production security review checklist |
| `docs/CREATING-SHARED-HOME-BACKUPS.md` | Optional static-client and backup-producer setup |
| `examples/` | Sanitized deployment configuration examples |
| `PORTABILITY.md` | Security and portability review |

## Configuration

### Broker environment

Create `/etc/ood-pbs-file-restore.env` on the broker with mode `0600`:

```bash
PBS_API_ROOT='https://pbs.example.edu:8007/api2/json/admin/datastore/DATASTORE'
PBS_AUTH_ID='restore@pbs!openondemand'
PBS_PASSWORD='REPLACE_WITH_TOKEN_SECRET'
PBS_BACKUP_ID='storage-server'
```

Never commit this file or expose it to portal hosts. Use a dedicated token and
limit its ACL to the required datastore or namespace.

The restore application does not invoke `proxmox-backup-client`; it consumes
existing snapshots through the PBS HTTPS API. Sites that still need to create
the expected shared-home snapshots can follow
[Creating shared-home backups](docs/CREATING-SHARED-HOME-BACKUPS.md). That
optional guide includes checksum-pinned installation of the official static
client on Enterprise Linux systems.

Review these centralized site values before deployment:

| File | Setting |
| --- | --- |
| `broker.py` | Backup type, archive filenames, environment-file path, home root, staging root, retention window |
| `client.py` | Broker hostname, SSH key path, and pinned known-hosts path |
| `sudoers` | Installed client path and permitted invoking users |
| `app.py` | Optional navigation and branding |

## Installation outline

1. Install `broker.py` root-owned and non-writable on the storage host.
2. Configure a dedicated forced-command SSH key that permits no shell, PTY,
   forwarding, agent forwarding, or user-supplied command.
3. Install the pinned broker host key and private key on every portal.
4. Install `client.py` root-owned on every portal.
5. Install and validate the constrained sudo rule.
6. Clone this repository into `/var/www/ood/apps/sys/pbs-file-restore`.
7. Stage or restart the Passenger application using the procedure appropriate
   for the installed Open OnDemand version.

The exact forced-command and deployment configuration is security-sensitive.
Follow [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md), then review
[docs/SECURITY-CHECKLIST.md](docs/SECURITY-CHECKLIST.md) before enabling users.

## Security invariants

- The effective username comes from the Unix process and `SUDO_USER`.
- The canonical home must match `/home/<username>`.
- User input cannot choose a PBS backup group or archive prefix.
- Absolute paths, traversal components, NULs, and unsafe archive names fail closed.
- Catalog responses are confined again after PBS returns them.
- Restore destinations are traversed relative to validated directory descriptors.
- Existing destination paths are never overwritten.
- Successful restores and rejected operations are auditable.

## Validation

Run syntax validation before deployment:

```bash
python3 -m py_compile app.py passenger_wsgi.py client.py broker.py validate.py
```

Then use a non-privileged canary account to verify snapshot listing, directory
browsing, absolute-path rejection, file restore, directory restore, ownership,
mode, and destination confinement. Never test with production credentials in a
development checkout.

## Known limitations

- Only the shared-home archive layout is implemented.
- Restore requests are synchronous.
- There are no built-in per-user byte quotas or rate limits.
- Individual symbolic links must be restored through their parent directory.
- Restored standalone files are intentionally reduced to mode `0600`.
- The privileged broker requires an institution-specific security review.

## Support and contributing

Use [GitHub Issues](https://github.com/NessieCanCode/ood-pbs-file-restore/issues)
for bugs and deployment questions. Security-sensitive reports should not include
tokens, backup contents, private keys, or user data.

## License

Copyright © 2026 Sqoia Labs LLC.

This project is licensed under the
[GNU Affero General Public License v3.0 or later](LICENSE). Organizations that
need different licensing terms may contact Sqoia Labs LLC regarding a separate
commercial license.
