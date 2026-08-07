#!/usr/bin/env python3
"""Sudo-confined OOD client that binds requests to the invoking Unix user."""

import json
import os
import pwd
import subprocess
import sys


MAX_REQUEST = 65536
SSH = [
    "/usr/bin/ssh",
    "-T",
    "-o",
    "BatchMode=yes",
    "-o",
    "IdentitiesOnly=yes",
    "-o",
    "StrictHostKeyChecking=yes",
    "-o",
    "UserKnownHostsFile=/etc/ood-pbs-restore/known_hosts",
    "-i",
    "/etc/ood-pbs-restore/broker_ed25519",
    "root@storage.example.edu",
]


def fail(message):
    print(json.dumps({"ok": False, "error": message}))
    raise SystemExit(1)


def main():
    sudo_user = os.environ.get("SUDO_USER")
    sudo_uid = os.environ.get("SUDO_UID")
    if not sudo_user or not sudo_uid:
        fail("broker client must be invoked through sudo")
    try:
        account = pwd.getpwnam(sudo_user)
    except KeyError:
        fail("invoking account does not exist")
    if str(account.pw_uid) != sudo_uid or account.pw_uid < 1000:
        fail("invalid invoking identity")

    raw = sys.stdin.buffer.readline(MAX_REQUEST + 1)
    if not raw or len(raw) > MAX_REQUEST or sys.stdin.buffer.read(1):
        fail("invalid request size")
    try:
        request = json.loads(raw.decode("utf-8"))
    except (UnicodeError, ValueError):
        fail("invalid JSON request")
    if not isinstance(request, dict):
        fail("request must be an object")
    request["user"] = sudo_user
    encoded = (json.dumps(request, separators=(",", ":")) + "\n").encode("utf-8")
    completed = subprocess.run(
        SSH,
        input=encoded,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=86500,
    )
    if completed.stdout:
        sys.stdout.buffer.write(completed.stdout)
    else:
        fail("restore broker was unavailable")
    raise SystemExit(completed.returncode)


if __name__ == "__main__":
    try:
        main()
    except subprocess.TimeoutExpired:
        fail("restore broker timed out")
