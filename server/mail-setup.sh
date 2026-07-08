#!/usr/bin/env bash
# mail-setup.sh
#
# One-time setup for the self-hosted Roundcube webmail (mail.4ravu.com) on the
# Hetzner app server (the same box that already runs woodstoneresearch.com,
# 4ravu.com, admin.4ravu.com, pgadmin.4ravu.com, and analytics.4ravu.com
# behind a single native Caddy reverse proxy).
#
# Roundcube itself holds no mail — it's a web UI that logs into Purelymail's
# IMAP/SMTP (imap.purelymail.com / smtp.purelymail.com) using the hub
# mailbox's own credentials (e.g. ops@4ravu.com). Purelymail routing rules
# are configured separately, in the Purelymail dashboard, to funnel every
# domain's mail into that one hub mailbox — see docs/deploy-setup.md.
#
# Idempotent, safe to re-run. To pull a newer Roundcube release afterwards,
# use mail-update.sh instead of re-running this script.
#
# USAGE:
#   sudo bash mail-setup.sh <basicauth-user> <basicauth-bcrypt-hash>
#
# The bcrypt hash is generated with: caddy hash-password --plaintext '<pw>'
# Never pass the plaintext password to this script or commit it anywhere —
# only the hash is stored, in /etc/caddy/Caddyfile.

set -euo pipefail

BASICAUTH_USER="${1:?Usage: mail-setup.sh <basicauth-user> <basicauth-bcrypt-hash>}"
BASICAUTH_HASH="${2:?Usage: mail-setup.sh <basicauth-user> <basicauth-bcrypt-hash>}"

DATA_DIR=/opt/mail-roundcube
CADDYFILE=/etc/caddy/Caddyfile
UNIT_FILE=/etc/systemd/system/container-mail-roundcube.service
CONTAINER_PORT=8085

# ── 1. Data directories ─────────────────────────────────────────────────────
sudo mkdir -p "$DATA_DIR/db" "$DATA_DIR/config"
sudo chown -R deploy:deploy "$DATA_DIR"
echo "Data directories ready at $DATA_DIR."

# ── 2. Systemd unit (podman --replace recreates the container on start) ────
cat << UNITEOF | sudo tee "$UNIT_FILE" > /dev/null
[Unit]
Description=Podman container-mail-roundcube.service
Documentation=man:podman-generate-systemd(1)
Wants=network-online.target
After=network-online.target
RequiresMountsFor=%t/containers

[Service]
Environment=PODMAN_SYSTEMD_UNIT=%n
Restart=always
TimeoutStopSec=70
ExecStart=/usr/bin/podman run \\
	--cidfile=%t/%n.ctr-id \\
	--cgroups=no-conmon \\
	--rm \\
	--sdnotify=conmon \\
	--replace \\
	-d \\
	--name mail-roundcube \\
	-p 127.0.0.1:${CONTAINER_PORT}:80 \\
	-v ${DATA_DIR}/db:/var/roundcube/db:Z \\
	-v ${DATA_DIR}/config:/var/roundcube/config:Z \\
	-e ROUNDCUBEMAIL_DB_TYPE=sqlite \\
	-e ROUNDCUBEMAIL_DEFAULT_HOST=ssl://imap.purelymail.com \\
	-e ROUNDCUBEMAIL_DEFAULT_PORT=993 \\
	-e ROUNDCUBEMAIL_SMTP_SERVER=tls://smtp.purelymail.com \\
	-e ROUNDCUBEMAIL_SMTP_PORT=465 \\
	-e ROUNDCUBEMAIL_SKIN=elastic docker.io/roundcube/roundcubemail:latest
ExecStop=/usr/bin/podman stop \\
	--ignore -t 10 \\
	--cidfile=%t/%n.ctr-id
ExecStopPost=/usr/bin/podman rm \\
	-f \\
	--ignore -t 10 \\
	--cidfile=%t/%n.ctr-id
Type=notify
NotifyAccess=all

[Install]
WantedBy=default.target
UNITEOF

sudo systemctl daemon-reload
sudo systemctl enable --now container-mail-roundcube.service
echo "container-mail-roundcube.service enabled and started."

sleep 5
if curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${CONTAINER_PORT}/" | grep -q 200; then
    echo "Roundcube responding on 127.0.0.1:${CONTAINER_PORT}."
else
    echo "WARNING: Roundcube did not respond with 200 on 127.0.0.1:${CONTAINER_PORT}. Check: sudo journalctl -u container-mail-roundcube.service" >&2
fi

# ── 3. Add mail.4ravu.com to the shared Caddyfile (if not already present) ─
BACKUP="/etc/caddy/Caddyfile.bak.$(date +%s)"
sudo cp "$CADDYFILE" "$BACKUP"
echo "Backed up $CADDYFILE to $BACKUP"

if grep -qE "^mail\.4ravu\.com" "$CADDYFILE" 2>/dev/null; then
    echo "mail.4ravu.com already in Caddyfile. Skipping."
else
    cat << EOF | sudo tee -a "$CADDYFILE" > /dev/null

mail.4ravu.com {
    basicauth {
        ${BASICAUTH_USER} ${BASICAUTH_HASH}
    }

    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
    }

    reverse_proxy 127.0.0.1:${CONTAINER_PORT} {
        header_up Host {host}
        header_up X-Forwarded-Proto {scheme}
        header_up X-Forwarded-Host {host}
    }
}
EOF
    sudo caddy fmt --overwrite "$CADDYFILE"

    if sudo caddy validate --config "$CADDYFILE" > /dev/null 2>&1; then
        sudo systemctl reload caddy
        echo "mail.4ravu.com added to Caddyfile and Caddy reloaded."
    else
        echo "ERROR: Caddyfile failed validation after adding mail.4ravu.com." >&2
        echo "Restoring backup from $BACKUP and leaving Caddy untouched." >&2
        sudo cp "$BACKUP" "$CADDYFILE"
        exit 1
    fi
fi

echo ""
echo "======================================================================"
echo " mail.4ravu.com setup complete."
echo ""
echo " Next steps:"
echo "   1. Point DNS: mail.4ravu.com -> A -> this server's IP (Cloudflare, proxied)."
echo "   2. Verify the other domains still work:"
echo "      curl -I https://woodstoneresearch.com"
echo "      curl -I https://4ravu.com"
echo "      curl -I https://admin.4ravu.com"
echo "      curl -I https://pgadmin.4ravu.com"
echo "      curl -I https://analytics.4ravu.com"
echo "   3. Log into https://mail.4ravu.com (Basic Auth, then the Purelymail"
echo "      hub mailbox credentials) and add Identities under Settings ->"
echo "      Identities for each address you reply from."
echo "======================================================================"
