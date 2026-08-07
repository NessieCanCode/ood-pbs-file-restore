#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

usage() {
  echo "Usage: $0 VERSION DEB_URL DEB_SHA256 BINARY_SHA256" >&2
  exit 2
}

[[ $# -eq 4 ]] || usage
[[ ${EUID} -eq 0 ]] || { echo "Run as root." >&2; exit 1; }
[[ $(uname -m) == x86_64 ]] || { echo "Only x86_64 is supported by this package." >&2; exit 1; }

version=$1
deb_url=$2
deb_sha256=$3
binary_sha256=$4
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Invalid version." >&2; exit 1; }
[[ $deb_sha256 =~ ^[0-9a-f]{64}$ ]] || { echo "Invalid package SHA-256." >&2; exit 1; }
[[ $binary_sha256 =~ ^[0-9a-f]{64}$ ]] || { echo "Invalid binary SHA-256." >&2; exit 1; }

for command in ar curl sha256sum tar; do
  command -v "$command" >/dev/null || { echo "Missing prerequisite: $command" >&2; exit 1; }
done

workdir=$(mktemp -d /var/tmp/pbs-client-static.XXXXXX)
trap 'rm -rf -- "$workdir"' EXIT
package=$workdir/client.deb
candidate=$workdir/proxmox-backup-client

curl --fail --location --show-error --output "$package" "$deb_url"
printf '%s  %s\n' "$deb_sha256" "$package" | sha256sum --check --strict -

member=$(ar t "$package" | awk '/^data[.]tar[.](xz|zst|gz)$/ { print; exit }')
[[ -n $member ]] || { echo "No supported data archive in Debian package." >&2; exit 1; }
case $member in
  *.xz)  ar p "$package" "$member" | tar -xJOf - ./usr/bin/proxmox-backup-client > "$candidate" ;;
  *.zst) ar p "$package" "$member" | tar --zstd -xOf - ./usr/bin/proxmox-backup-client > "$candidate" ;;
  *.gz)  ar p "$package" "$member" | tar -xzOf - ./usr/bin/proxmox-backup-client > "$candidate" ;;
  *)     echo "Unsupported data archive: $member" >&2; exit 1 ;;
esac
printf '%s  %s\n' "$binary_sha256" "$candidate" | sha256sum --check --strict -
chmod 0755 "$candidate"

versioned=/usr/local/sbin/proxmox-backup-client.official-$version
canonical=/usr/local/sbin/proxmox-backup-client
if [[ -e $canonical && ! -L $canonical ]]; then
  echo "$canonical exists and is not a symlink; preserve or relocate it first." >&2
  exit 1
fi
install -o root -g root -m 0755 "$candidate" "$versioned"
ln -sfn "$(basename "$versioned")" "$canonical"
"$canonical" version
sha256sum "$versioned"
