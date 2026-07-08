#!/usr/bin/env bash
# 4ravu-deploy.sh
#
# Zero-downtime blue-green deploy for 4ravu.com.
# Run on the app server as the 'deploy' user (invoked over SSH by GitHub
# Actions, or by hand):
#
#   bash /opt/4ravu-site/4ravu-deploy.sh
#
# Expects new site content to already be sitting in /opt/4ravu-site/incoming/
# (rsynced there by the caller before this script runs). On each run it syncs
# that content into the idle slot, starts the new container, waits for a
# health check, atomically switches Caddy to the new slot, then removes the
# old container. No requests are dropped — Caddy holds in-flight connections
# during reload.
#
# REQUIREMENTS (done by 4ravu-setup.sh):
#   • /usr/local/bin/4ravu-caddy-switch — wrapper allowed in sudoers
#   • /usr/local/bin/4ravu-systemd-update — wrapper allowed in sudoers
#   • deploy user can: sudo podman *, sudo 4ravu-caddy-switch, sudo 4ravu-systemd-update

set -euo pipefail

IMAGE="${IMAGE:-docker.io/library/caddy:2-alpine}"
SITE_ROOT=/opt/4ravu-site
INCOMING_DIR="$SITE_ROOT/incoming"
ACTIVE_SLOT_FILE="$SITE_ROOT/active-slot"   # contains "blue" or "green"
HEALTH_TIMEOUT=60   # seconds to wait for health check before rollback

# ── Slot definitions ────────────────────────────────────────────────────────
declare -A SLOT_PORT=([blue]=8083 [green]=8084)
declare -A SLOT_NAME=([blue]=4ravu-blue [green]=4ravu-green)

log() { echo "[deploy] $(date '+%Y-%m-%d %H:%M:%S')  $*"; }

# ── Determine active and idle slots ────────────────────────────────────────
if [[ -f "$ACTIVE_SLOT_FILE" ]]; then
    ACTIVE_SLOT=$(< "$ACTIVE_SLOT_FILE")
else
    ACTIVE_SLOT=none
fi

case "$ACTIVE_SLOT" in
    blue)  IDLE_SLOT=green ;;
    green) IDLE_SLOT=blue  ;;
    *)     IDLE_SLOT=blue  ;;   # first ever deploy
esac

IDLE_PORT="${SLOT_PORT[$IDLE_SLOT]}"
IDLE_NAME="${SLOT_NAME[$IDLE_SLOT]}"
ACTIVE_NAME="${SLOT_NAME[$ACTIVE_SLOT]:-}"

log "Active slot : ${ACTIVE_SLOT} (${ACTIVE_NAME:-none})"
log "Deploying to: ${IDLE_SLOT} (${IDLE_NAME} on :${IDLE_PORT})"

# ── 1. Sync freshly landed content into the idle slot ──────────────────────
if [[ ! -d "$INCOMING_DIR" ]] || [[ -z "$(ls -A "$INCOMING_DIR" 2>/dev/null)" ]]; then
    echo "ERROR: $INCOMING_DIR is missing or empty. Nothing to deploy." >&2
    exit 1
fi
log "Syncing $INCOMING_DIR -> $SITE_ROOT/$IDLE_SLOT ..."
rsync -a --delete "$INCOMING_DIR"/ "$SITE_ROOT/$IDLE_SLOT"/

# ── 2. Start new container on the idle slot ────────────────────────────────
log "Starting $IDLE_NAME on port $IDLE_PORT ..."
sudo podman stop "$IDLE_NAME" 2>/dev/null || true
sudo podman rm   "$IDLE_NAME" 2>/dev/null || true

sudo podman run -d \
    --name "$IDLE_NAME" \
    --restart always \
    -v "$SITE_ROOT/$IDLE_SLOT":/srv:ro \
    -v "$SITE_ROOT/Caddyfile":/etc/caddy/Caddyfile:ro \
    -p "127.0.0.1:${IDLE_PORT}:80" \
    "$IMAGE"

# ── 3. Health check with rollback on failure ───────────────────────────────
log "Waiting for health check on :${IDLE_PORT} (timeout ${HEALTH_TIMEOUT}s) ..."
DEADLINE=$(( $(date +%s) + HEALTH_TIMEOUT ))
until curl -sf "http://127.0.0.1:${IDLE_PORT}/" > /dev/null 2>&1; do
    if [[ $(date +%s) -ge $DEADLINE ]]; then
        log "ERROR: Health check timed out. Rolling back ..."
        sudo podman stop "$IDLE_NAME" 2>/dev/null || true
        sudo podman rm   "$IDLE_NAME" 2>/dev/null || true
        exit 1
    fi
    sleep 2
done
log "Health check passed."

# ── 3a. Hand the idle container off to systemd, while it's still idle ──────
# This is done *before* the Caddy switch, on purpose: 4ravu-systemd-update
# restarts the container (via podman's --replace) so systemd actually
# supervises it and it survives a reboot, instead of just being enabled for
# next boot. Doing that replace now — while this slot isn't receiving live
# traffic yet — means the brief restart it causes never affects a real
# request. Re-check health afterward since the container was just replaced.
log "Handing $IDLE_NAME to systemd (container-4ravu.service) ..."
if sudo /usr/local/bin/4ravu-systemd-update "$IDLE_NAME"; then
    SYSTEMD_DEADLINE=$(( $(date +%s) + 20 ))
    until curl -sf "http://127.0.0.1:${IDLE_PORT}/" > /dev/null 2>&1; do
        if [[ $(date +%s) -ge $SYSTEMD_DEADLINE ]]; then
            log "ERROR: Health check failed after systemd handoff. Rolling back ..."
            sudo systemctl stop container-4ravu.service 2>/dev/null || true
            sudo podman stop "$IDLE_NAME" 2>/dev/null || true
            sudo podman rm   "$IDLE_NAME" 2>/dev/null || true
            exit 1
        fi
        sleep 1
    done
    log "systemd handoff verified healthy."
else
    log "WARNING: systemd service update failed; deploy will continue on the raw podman container, but restart-on-reboot may still point at the previous slot. Re-run 4ravu-setup.sh on the server."
fi

# ── 4. Switch Caddy to the new slot (zero-downtime reload) ─────────────────
log "Switching Caddy upstream to port $IDLE_PORT ..."
sudo /usr/local/bin/4ravu-caddy-switch "$IDLE_PORT"
log "Caddy reloaded."

# ── 5. Record the new active slot ──────────────────────────────────────────
echo "$IDLE_SLOT" > "$ACTIVE_SLOT_FILE"

# ── 6. Remove the old container ────────────────────────────────────────────
if [[ "$ACTIVE_SLOT" != "none" ]]; then
    log "Removing old container $ACTIVE_NAME ..."
    sudo podman stop "$ACTIVE_NAME" 2>/dev/null || true
    sudo podman rm   "$ACTIVE_NAME" 2>/dev/null || true
fi

# ── 7. Prune dangling images ────────────────────────────────────────────────
sudo podman image prune -f > /dev/null

log "Deploy complete. Active slot: $IDLE_SLOT (:$IDLE_PORT)"
