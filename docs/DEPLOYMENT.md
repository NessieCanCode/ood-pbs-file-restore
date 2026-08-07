# Deployment guide

This guide is written for an administrator deploying the application from this repository alone. All hostnames, accounts, datastore names, and keys below are synthetic placeholders.

## 1. Confirm that the supported model fits

The current implementation supports this topology:

    Open OnDemand portal(s)
      |  sudo to the fixed portal client
      |  SSH with a pinned host key and forced command
      v
    broker/storage host with root access to /home
      |  HTTPS API with a read-only token
      v
    Proxmox Backup Server

The broker and portals must resolve the same Unix identities. For each participating account, the canonical NSS home must be exactly `/home/<username>`. The broker must see the same home filesystem where restored content belongs.

The PBS layout must be one shared `host` backup group whose backup ID is configured by `PBS_BACKUP_ID`. Every completed snapshot must contain:

- `root.pxar.didx`, with user homes stored as `/<archive>/<username>/...`
- `catalog.pcat1.didx`

PBS namespaces, per-user backup groups, alternate home roots, and alternate archive layouts are not implemented by this release. Do not deploy it unchanged for those layouts.

## 2. Choose deployment values

Record local values before editing anything:

| Placeholder | Meaning | Example only |
| --- | --- | --- |
| `ood.example.edu` | Open OnDemand portal | `ood.example.edu` |
| `storage.example.edu` | SSH broker and home-storage host | `storage.example.edu` |
| `pbs.example.edu` | PBS API host | `pbs.example.edu` |
| `DATASTORE` | PBS datastore containing home snapshots | `home-backups` |
| `storage-server` | PBS `host` backup ID | `home-nfs` |
| `restore@pbs!openondemand` | Dedicated PBS API token ID | synthetic |
| `canary` | Non-privileged test account with a small backup | synthetic |

Use FQDNs whose forward and reverse resolution are stable. If several portals are deployed, repeat every portal-side step on each one.

Obtain a protected source checkout on each host where files will be installed:

    git clone https://github.com/NessieCanCode/ood-pbs-file-restore.git \
      /root/ood-pbs-file-restore-src
    cd /root/ood-pbs-file-restore-src
    git checkout v1.0.1

Run source-relative commands in this guide from that checkout. Verify the tag
or commit according to local software-supply-chain policy before installing it.

## 3. Prepare a dedicated PBS token

Create a service user and a separate API token in PBS. Grant the token only the read privilege required to list snapshots, read catalogs, and download pxar content from the selected datastore. Do not reuse a backup-writer or administrator token.

PBS command syntax and token privilege-separation behavior vary by release, so use the user-management procedure for the installed PBS version:

- [PBS user management](https://pbs.proxmox.com/docs/user-management.html)
- [PBS access control](https://pbs.proxmox.com/docs/user-management.html#access-control)

At minimum, verify in the PBS UI or CLI that the token:

1. Can audit/read the selected datastore.
2. Cannot modify, prune, delete, or administer backups.
3. Cannot read unrelated datastores unless that access is intentionally required.

Retain the token secret only long enough to install the broker environment file. Never place it on an Open OnDemand portal.

## 4. Install and configure the broker

Perform this section as root on `storage.example.edu`.

### 4.1 Install the broker executable

Copy the repository to a protected administrative checkout, then install the broker:

    install -o root -g root -m 0755 broker.py /usr/local/sbin/pbs-restore-broker

Confirm that neither ordinary users nor the SSH key owner can modify the installed file:

    stat -c '%U:%G %a %n' /usr/local/sbin/pbs-restore-broker

The expected result is `root:root 755`.

### 4.2 Review the compiled layout constants

Review the constants at the top of `broker.py` before installation:

| Constant | Default | Change when |
| --- | --- | --- |
| `BACKUP_TYPE` | `host` | Only after implementing and reviewing another PBS group type |
| `ARCHIVE_NAME` | `root.pxar.didx` | The shared-home pxar archive has another name |
| `CATALOG_NAME` | `catalog.pcat1.didx` | PBS produces another catalog name |
| `ENV_FILE` | `/etc/pbs-home-backup.env` | Site policy requires another protected path |
| `STAGING_ROOT` | `/home/.pbs-restore-staging` | Another root-only staging filesystem is required |

Changing `ARCHIVE_NAME`, the `/home` identity rule, or archive prefix is security-sensitive. Re-run traversal and cross-user confinement tests after any such change.

### 4.3 Install broker configuration

Start from the example file:

    install -o root -g root -m 0600 examples/pbs-home-backup.env.example /etc/pbs-home-backup.env
    editor /etc/pbs-home-backup.env

Set all four values:

    PBS_API_ROOT='https://pbs.example.edu:8007/api2/json/admin/datastore/DATASTORE'
    PBS_AUTH_ID='restore@pbs!openondemand'
    PBS_PASSWORD='REPLACE_WITH_TOKEN_SECRET'
    PBS_BACKUP_ID='storage-server'

`PBS_API_ROOT` ends at the datastore name and must not have a trailing slash. Do not prefix lines with `export`; the broker intentionally ignores exported shell syntax. Confirm protection without printing the file:

    stat -c '%U:%G %a %n' /etc/pbs-home-backup.env

The expected result is `root:root 600`.

### 4.4 Establish PBS TLS trust

The broker uses Python's default certificate validation. A publicly trusted PBS certificate normally requires no extra work. For a private CA, install only the CA certificate into the operating system trust store and refresh that store using the distribution procedure.

Verify TLS and DNS from the broker:

    curl --fail --show-error --silent \
      https://pbs.example.edu:8007/api2/json/version

Do not add an insecure TLS option and do not disable Python certificate verification.

### 4.5 Prepare staging and identity checks

    install -d -o root -g root -m 0700 /home/.pbs-restore-staging
    getent passwd canary
    stat -c '%u:%g %U:%G %a %n' /home/canary

The `getent` home must be `/home/canary`, its UID must be at least 1000, and `/home/canary` must be owned by that user.

## 5. Create the forced-command SSH boundary

### 5.1 Generate one dedicated key on each portal

Perform this as root on each Open OnDemand portal:

    install -d -o root -g root -m 0700 /etc/ood-pbs-restore
    ssh-keygen -t ed25519 \
      -f /etc/ood-pbs-restore/broker_ed25519 \
      -N '' \
      -C 'ood-pbs-restore@ood.example.edu'
    chmod 0600 /etc/ood-pbs-restore/broker_ed25519
    chmod 0644 /etc/ood-pbs-restore/broker_ed25519.pub

Do not reuse a cluster administrator key. For multiple portals, distinct keys make revocation and auditing clearer.

### 5.2 Pin the broker host key

Obtain the broker's SSH host-key fingerprint through a trusted administrative channel. A network scan alone does not establish trust.

Collect the candidate key:

    ssh-keyscan -t ed25519 storage.example.edu > /tmp/storage.example.edu.known_hosts
    ssh-keygen -lf /tmp/storage.example.edu.known_hosts

Compare the displayed fingerprint with the independently verified value. Only after they match:

    install -o root -g root -m 0644 \
      /tmp/storage.example.edu.known_hosts \
      /etc/ood-pbs-restore/known_hosts

### 5.3 Authorize only the broker command

On `storage.example.edu`, append the portal public key to root's authorized keys as one physical line:

    restrict,command="/usr/local/sbin/pbs-restore-broker" ssh-ed25519 REPLACE_WITH_PUBLIC_KEY ood-pbs-restore@ood.example.edu

`restrict` disables PTY allocation and forwarding on supported OpenSSH releases. The explicit forced command prevents a client-supplied command or shell from running. Keep both controls.

The broker currently assumes `root@storage.example.edu`. The SSH server must therefore permit public-key root login for this restricted key while still prohibiting password-based root login. If site policy prohibits root SSH entirely, redesign and review the privileged boundary before deployment; changing only the username is not sufficient.

### 5.4 Prove that the key is constrained

From the portal, an interactive attempt must not produce a shell:

    ssh -i /etc/ood-pbs-restore/broker_ed25519 \
      -o UserKnownHostsFile=/etc/ood-pbs-restore/known_hosts \
      -o StrictHostKeyChecking=yes root@storage.example.edu

The forced broker may return an invalid-request JSON response because no request was supplied. That is acceptable. Receiving a shell is a deployment failure.

## 6. Install the portal client and sudo rule

Perform this as root on every portal.

### 6.1 Configure and install the client

Edit the `SSH` array near the top of `client.py`. Replace only the synthetic broker target if your values differ. Confirm these paths remain aligned with the key files installed above:

    UserKnownHostsFile=/etc/ood-pbs-restore/known_hosts
    /etc/ood-pbs-restore/broker_ed25519
    root@storage.example.edu

Then install it:

    install -o root -g root -m 0755 client.py /usr/local/sbin/pbs-restore-client
    stat -c '%U:%G %a %n' /usr/local/sbin/pbs-restore-client

The expected result is `root:root 755`.

### 6.2 Install the exact sudo policy

Review `sudoers`, then install and validate it:

    install -o root -g root -m 0440 sudoers /etc/sudoers.d/ood-pbs-restore
    visudo -cf /etc/sudoers.d/ood-pbs-restore

The supplied rule allows local users to run only `/usr/local/sbin/pbs-restore-client` as root without arguments. The client independently derives the caller from `SUDO_USER` and `SUDO_UID`, validates NSS, and replaces any submitted `user` field.

If portal access is broader than restore eligibility, replace the first `ALL` in the command rule with a local Unix group or sudoers user alias. Do not broaden the command with wildcards and do not permit direct sudo access to Python, SSH, or the broker key.

### 6.3 Test the complete transport as a canary

Run this while logged in as the non-privileged canary account:

    printf '%s\n' '{"action":"snapshots"}' | \
      sudo -n /usr/local/sbin/pbs-restore-client | python3 -m json.tool

A successful response contains `"ok": true` and at least one completed snapshot. If the response is empty, inspect portal SSH errors and broker logs; do not print the environment file.

## 7. Install the Open OnDemand application

### 7.1 Install dependencies

The portal requires Python 3.9 or later and PyYAML 6.x. Prefer the operating-system PyYAML package when Passenger uses the system Python. Alternatively, provide a site-managed Python environment that Passenger is explicitly configured to use.

Verify the interpreter:

    python3 -c 'import sys, yaml; print(sys.version); print(yaml.__version__)'

### 7.2 Clone the system application

    cd /var/www/ood/apps/sys
    git clone https://github.com/NessieCanCode/ood-pbs-file-restore.git pbs-file-restore
    cd pbs-file-restore
    git checkout v1.0.1
    chown -R root:root .
    find . -type d -exec chmod 0755 {} +
    find . -type f -exec chmod 0644 {} +
    chmod 0755 client.py broker.py validate.py

The runtime app uses `app.py`, `passenger_wsgi.py`, and `manifest.yml` from this checkout. The copies of `client.py` and `broker.py` in the checkout are deployment sources; runtime uses the protected installed copies.

### 7.3 Check dashboard asset compatibility

The application reads the active dashboard's Sprockets manifest so its page uses the installed Open OnDemand CSS and JavaScript. Confirm at least one file matches:

    ls /var/www/ood/apps/sys/dashboard/public/assets/.sprockets-manifest-*.json

If the dashboard lives elsewhere or no Sprockets manifest exists, adapt `render_page()` in `app.py` for that Open OnDemand release before enabling users.

### 7.4 Activate Passenger

Open OnDemand normally discovers the system app without a service restart. If Passenger has cached an earlier copy:

    install -d -o root -g root -m 0755 tmp
    touch tmp/restart.txt

Then restart the canary user's PUN from the dashboard or with the site's supported Open OnDemand administrative procedure. A global portal restart should not normally be necessary.

## 8. Acceptance testing

### 8.1 Static checks

From the checkout:

    python3 -m py_compile app.py passenger_wsgi.py client.py broker.py validate.py
    python3 -c 'import yaml; yaml.safe_load(open("manifest.yml"))'
    visudo -cf /etc/sudoers.d/ood-pbs-restore

### 8.2 Browser checks

Sign in as the canary and open `/pun/sys/pbs-file-restore`. Verify:

1. The page loads without a Python or Passenger error.
2. Available snapshot dates appear.
3. Browsing never shows another user's top-level archive.
4. A small file restores below `/home/canary/.pbs-restores/<date>/<job-id>/`.
5. The original live file is not overwritten.
6. A second restore creates a new job directory.

### 8.3 Confinement checks

The included `validate.py` performs a real small-file restore. It refuses to run unless explicitly enabled. Review it first, ensure the canary has a backed-up file of 1 MiB or less, then run as the canary:

    PBS_RESTORE_ENABLE_LIVE_TEST=YES python3 validate.py

To include a known directory restore:

    PBS_RESTORE_ENABLE_LIVE_TEST=YES \
    PBS_RESTORE_TEST_DIRECTORY='synthetic-test-directory' \
      python3 validate.py

Inspect ownership and confinement after the test:

    find /home/canary/.pbs-restores -xdev -printf '%u:%g %m %p\n'

Do not run the live validator as root or against a real user's account.

## 9. Logs and troubleshooting

The broker writes to the local syslog socket with identifier `pbs-restore-broker`. Depending on the distribution, inspect:

    journalctl -t pbs-restore-broker

Common failures:

| Symptom | Check |
| --- | --- |
| App reports restore service unavailable | Sudo rule, installed client, SSH key modes, pinned host key, forced command |
| Broker reports incomplete environment | Four required `PBS_*` values, file syntax, no `export`, mode `0600` |
| PBS request fails | DNS, TCP 8007, TLS trust, API URL, token ID/secret, datastore ACL |
| No snapshots appear | Backup type/ID, 31-day window, and presence of both required archive files |
| Authenticated account rejected | Matching NSS, UID at least 1000, allowed username syntax, exact `/home/<username>` |
| Directory restore fails | PBS returned ZIP structure, free staging space, symlink/traversal rejection |
| Page cannot find dashboard assets | Open OnDemand version or nonstandard dashboard asset location |

Logs intentionally avoid token secrets and restored contents. Preserve that property when adding diagnostics.

## 10. Upgrades

1. Review `CHANGELOG.md` and compare security-sensitive constants.
2. Test the new tag with a canary on a staging portal when available.
3. Install the new broker and client into their protected paths.
4. Update the system-app checkout to the same tag.
5. Touch `tmp/restart.txt` and restart the canary PUN.
6. Repeat snapshot, browse, small-restore, confinement, and log checks.
7. Deploy serially to remaining portals.

Keep the broker, client, and web app on the same release.

## 11. Disable or roll back

To disable access without deleting user restores:

1. Remove or disable the dashboard/system app checkout.
2. Remove the sudoers rule and confirm `visudo -c` still passes.
3. Remove the portal public key line from the broker's authorized keys.
4. Revoke the dedicated PBS API token.
5. Preserve broker logs according to incident and audit policy.

Do not delete users' `.pbs-restores` trees automatically. They contain user-owned recovered data.

For a version rollback, reinstall the broker and client from the previous signed or reviewed tag, check out the same tag in the system app, restart the canary PUN, and repeat acceptance testing.

## 12. Information safe to include in support requests

Generally safe after review:

- Application version and Open OnDemand/Python/PBS versions
- Sanitized error text
- Whether failure occurs at web app, sudo client, SSH, broker, or PBS stage
- Synthetic host roles such as `portal`, `broker`, and `PBS`
- File ownership and modes without real usernames or internal paths

Never publish:

- PBS token IDs or secrets
- Private/public SSH key material or full host keys
- Internal hostnames, IP addresses, inventories, or certificates
- Production usernames, UIDs, backup paths, catalog responses, or contents
- `/etc/pbs-home-backup.env`

Before production enablement, complete [SECURITY-CHECKLIST.md](SECURITY-CHECKLIST.md).
