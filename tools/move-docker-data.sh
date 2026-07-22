#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
#
# Moves both Docker's data-root and containerd's root to new directories,
# typically on a separate volume, and points both daemons at them.
#
# docker-ce always depends on the separate containerd.io package/service.
# dockerd's data-root (/var/lib/docker, via daemon.json) only holds Docker-
# level bookkeeping - volumes, network config, buildkit cache, repository
# metadata. The actual image layers and snapshots are owned and stored by
# containerd, under containerd's own "root" setting in
# /etc/containerd/config.toml. Moving daemon.json's data-root alone does
# not relocate image storage; containerd's root has to move too.
#
# containerd's config is TOML, where a bare "root = ..." key only binds at
# the top level if it appears before the first [section] header - that's
# a structural rule of the TOML format itself, not something specific to
# any one box's current file. So the edit strips any existing top-level
# root assignment (commented or not) and prepends a fresh one as the very
# first line of the file, which is always valid placement regardless of
# what sections/comments follow.
#
# Old data roots are renamed to <old>.bak rather than deleted, so there's
# a rollback path. Existing daemon.json settings (log driver, registry
# mirrors, etc.) are preserved - only the data-root key is added/updated.
# containerd's config.toml is backed up before editing.
#
# Usage: ./tools/move-docker-data.sh <new-docker-root> <new-containerd-root>
#   new-docker-root      Target directory for Docker's data, e.g. /mnt/data/docker
#   new-containerd-root  Target directory for containerd's data, e.g. /mnt/data/containerd
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "Usage: $0 <new-docker-root> <new-containerd-root>" >&2
  exit 1
fi

NEW_DOCKER_ROOT="$1"
NEW_CONTAINERD_ROOT="$2"
OLD_DOCKER_ROOT=/var/lib/docker
OLD_CONTAINERD_ROOT=/var/lib/containerd
DAEMON_JSON=/etc/docker/daemon.json
CONTAINERD_CONFIG=/etc/containerd/config.toml

echo "==> Stopping Docker and containerd"
sudo systemctl stop docker docker.socket containerd

if [ -d "$OLD_DOCKER_ROOT" ]; then
  echo "==> Moving existing Docker data to $NEW_DOCKER_ROOT"
  sudo mkdir -p "$NEW_DOCKER_ROOT"
  sudo rsync -aP "$OLD_DOCKER_ROOT/" "$NEW_DOCKER_ROOT/"
  sudo mv "$OLD_DOCKER_ROOT" "$OLD_DOCKER_ROOT.bak"
else
  echo "==> $OLD_DOCKER_ROOT already gone, skipping (already moved)"
fi

if [ -d "$OLD_CONTAINERD_ROOT" ]; then
  echo "==> Moving existing containerd data to $NEW_CONTAINERD_ROOT"
  sudo mkdir -p "$NEW_CONTAINERD_ROOT"
  sudo rsync -aP "$OLD_CONTAINERD_ROOT/" "$NEW_CONTAINERD_ROOT/"
  sudo mv "$OLD_CONTAINERD_ROOT" "$OLD_CONTAINERD_ROOT.bak"
else
  echo "==> $OLD_CONTAINERD_ROOT already gone, skipping (already moved)"
fi

echo "==> Pointing dockerd at $NEW_DOCKER_ROOT"
sudo mkdir -p "$(dirname "$DAEMON_JSON")"
if [ -f "$DAEMON_JSON" ]; then
  sudo cp "$DAEMON_JSON" "$DAEMON_JSON.bak"
fi
python3 - "$DAEMON_JSON" "$NEW_DOCKER_ROOT" <<'EOF'
import json, sys, os

path, new_root = sys.argv[1], sys.argv[2]
config = {}
if os.path.exists(path):
    with open(path) as f:
        content = f.read().strip()
        if content:
            config = json.loads(content)
config["data-root"] = new_root

with open(path, "w") as f:
    json.dump(config, f, indent=2)
    f.write("\n")
EOF

echo "==> Pointing containerd at $NEW_CONTAINERD_ROOT"
sudo cp "$CONTAINERD_CONFIG" "$CONTAINERD_CONFIG.bak"
awk '
  BEGIN { in_top = 1 }
  /^\[/ { in_top = 0 }
  in_top && /^[[:space:]]*#?[[:space:]]*root[[:space:]]*=/ { next }
  { print }
' "$CONTAINERD_CONFIG.bak" > /tmp/containerd-config.toml.new
{ printf 'root = "%s"\n' "$NEW_CONTAINERD_ROOT"; cat /tmp/containerd-config.toml.new; } \
  | sudo tee "$CONTAINERD_CONFIG" > /dev/null
rm -f /tmp/containerd-config.toml.new

echo "==> Restarting containerd and Docker"
sudo systemctl start containerd
sudo systemctl start docker

echo "==> Verifying"
echo "Docker root:     $(docker info --format '{{.DockerRootDir}}')"
echo "containerd root: $(awk '/^root[[:space:]]*=/{print; exit}' "$CONTAINERD_CONFIG")"
