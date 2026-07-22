#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
#
# Resolves an AWS-requested EBS device name to its real Linux device path
# (handles the /dev/sdX -> /dev/xvdX rename on Xen instances, and the NVMe
# rename on Nitro instances when no xvd udev symlink is present), formats
# it if blank, mounts it at the target directory, and persists the mount
# via /etc/fstab (by UUID) so it survives a reboot.
#
# Formatting only happens when blkid finds no filesystem at all on the
# resolved device - an existing, recognized filesystem is never touched.
#
# Idempotent: safe to re-run. Skips mkfs if a filesystem is already there,
# skips mount if the target is already mounted, skips the fstab line if
# the UUID is already present.
#
# Usage: ./tools/mount.sh <device-name> <target-dir> [fs-type]
#   device-name  AWS device name as requested at attach time, e.g. sdd or /dev/sdd
#   target-dir   Directory to mount the volume at, e.g. /mnt/data
#   fs-type      Filesystem to create if the device is blank (default: ext4)
set -euo pipefail

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  echo "Usage: $0 <device-name> <target-dir> [fs-type]" >&2
  echo "error"
  exit 1
fi

REQUESTED="$1"
TARGET="$2"
FSTYPE="${3:-ext4}"
NAME="${REQUESTED#/dev/}"

DEVICE=""
for CANDIDATE in "/dev/$NAME" "/dev/xvd${NAME#sd}"; do
  if [ -e "$CANDIDATE" ]; then
    DEVICE=$(readlink -f "$CANDIDATE")
    break
  fi
done

if [ -z "$DEVICE" ]; then
  for N in /dev/nvme*n1; do
    [ -e "$N" ] || continue
    if sudo nvme id-ctrl -v "$N" 2>/dev/null | grep -q "$NAME"; then
      DEVICE="$N"
      break
    fi
  done
fi

if [ -z "$DEVICE" ]; then
  echo "error"
  exit 1
fi

if ! sudo blkid "$DEVICE" >/dev/null 2>&1; then
  if ! sudo mkfs -t "$FSTYPE" "$DEVICE" >/dev/null 2>&1; then
    echo "error"
    exit 1
  fi
fi

sudo mkdir -p "$TARGET"

if ! mountpoint -q "$TARGET"; then
  if ! sudo mount "$DEVICE" "$TARGET" >/dev/null 2>&1; then
    echo "error"
    exit 1
  fi
fi

UUID=$(sudo blkid -s UUID -o value "$DEVICE")
if [ -z "$UUID" ]; then
  echo "error"
  exit 1
fi

if ! grep -q "UUID=$UUID" /etc/fstab 2>/dev/null; then
  echo "UUID=$UUID $TARGET $FSTYPE defaults,nofail 0 2" | sudo tee -a /etc/fstab >/dev/null
fi

echo "success"
