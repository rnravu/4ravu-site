#!/usr/bin/env bash
# mail-update.sh
#
# Pulls the latest roundcube/roundcubemail image and recreates the running
# container from it. Config/mail state lives outside the container (SQLite
# DB + config under /opt/mail-roundcube), so recreation is safe — nothing
# is lost.
#
# USAGE:
#   sudo bash mail-update.sh

set -euo pipefail

IMAGE=docker.io/roundcube/roundcubemail:latest
CONTAINER_PORT=8085

echo "Pulling $IMAGE ..."
sudo podman pull "$IMAGE"

echo "Restarting container-mail-roundcube.service ..."
sudo systemctl restart container-mail-roundcube.service

sleep 5
if curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${CONTAINER_PORT}/" | grep -q 200; then
    echo "Roundcube back up and responding on 127.0.0.1:${CONTAINER_PORT}."
else
    echo "WARNING: Roundcube did not respond with 200 after update. Check: sudo journalctl -u container-mail-roundcube.service" >&2
    exit 1
fi

echo "Pruning old, now-unused images ..."
sudo podman image prune -f

echo "Update complete."
