#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
#
# Sets up a fresh Ubuntu 26.04 (resolute) box with Docker, Docker Compose, and vim.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  SUDO="sudo"
else
  SUDO=""
fi

export DEBIAN_FRONTEND=noninteractive

echo "==> Updating package index"
$SUDO apt-get update -y

echo "==> Installing prerequisites"
$SUDO apt-get install -y ca-certificates curl gnupg vim jq

echo "==> Adding Docker's official GPG key"
$SUDO install -m 0755 -d /etc/apt/keyrings
$SUDO curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
$SUDO chmod a+r /etc/apt/keyrings/docker.asc

echo "==> Adding Docker's apt repository"
. /etc/os-release
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
  | $SUDO tee /etc/apt/sources.list.d/docker.list > /dev/null

echo "==> Installing Docker Engine and Docker Compose plugin"
$SUDO apt-get update -y
$SUDO apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

echo "==> Enabling and starting Docker"
$SUDO systemctl enable --now docker

echo "==> Adding current user to the docker group"
if [ -n "${SUDO_USER:-}" ]; then
  $SUDO usermod -aG docker "$SUDO_USER"
else
  $SUDO usermod -aG docker "$(whoami)"
fi

echo "==> Done. Versions installed:"
docker --version
docker compose version
vim --version | head -n 1

if [ -n "$SUDO" ]; then
  echo "==> Activating docker group membership for this shell"
  exec sg docker -c "$SHELL"
fi
