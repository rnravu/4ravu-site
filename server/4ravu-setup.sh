#!/usr/bin/env bash
# 4ravu-setup.sh
#
# One-time setup for 4ravu.com on the Hetzner app server (the same box that
# already runs woodstoneresearch.com, admin.4ravu.com, pgadmin.4ravu.com, and
# analytics.4ravu.com behind a single native Caddy reverse proxy).
# Run AFTER setup-app-server.sh has already been executed.
# Target OS: AlmaLinux / RHEL / CentOS
#
# USAGE:
#   bash 4ravu-setup.sh
#
# WHAT THIS DOES:
#   1. Backs up /etc/caddy/Caddyfile, then (if missing) appends a 4ravu.com
#      block reverse-proxying to the blue slot (:8083), validating before reload
#      so a bad append can never take down the other domains already in this file.
#   2. Installs the 4ravu-caddy-switch helper (zero-downtime slot switching,
#      restricted to ports 8083/8084 only).
#   3. Installs the 4ravu-systemd-update helper (keeps the active slot's
#      systemd unit correct across reboots).
#   4. Grants the deploy user passwordless sudo for podman + these two helpers only.
#   5. Creates /opt/4ravu-site/{blue,green,incoming} and installs 4ravu-deploy.sh there.
#
# No podman secrets are registered — this is a static site with no credentials.

set -euo pipefail

CADDYFILE=/etc/caddy/Caddyfile
CADDY_SWITCH=/usr/local/bin/4ravu-caddy-switch
SYSTEMD_UPDATE=/usr/local/bin/4ravu-systemd-update
DEPLOY_SCRIPT=/opt/4ravu-site/4ravu-deploy.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── 1. Back up the Caddyfile, then add 4ravu.com (if not already present) ──
BACKUP="/etc/caddy/Caddyfile.bak.$(date +%s)"
sudo cp "$CADDYFILE" "$BACKUP"
echo "Backed up $CADDYFILE to $BACKUP"

if grep -q "4ravu.com" "$CADDYFILE" 2>/dev/null; then
    echo "4ravu.com already in Caddyfile. Skipping."
else
    cat << 'EOF' | sudo tee -a "$CADDYFILE" > /dev/null

4ravu.com, www.4ravu.com {
    @www host www.4ravu.com
    redir @www https://4ravu.com{uri} permanent

    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
    }

    reverse_proxy 127.0.0.1:8083 {
        header_up Host {host}
        header_up X-Forwarded-Proto {scheme}
        header_up X-Forwarded-Host {host}
    }
}
EOF
    sudo caddy fmt --overwrite "$CADDYFILE"

    if sudo caddy validate --config "$CADDYFILE" > /dev/null 2>&1; then
        sudo systemctl reload caddy
        echo "4ravu.com added to Caddyfile and Caddy reloaded."
    else
        echo "ERROR: Caddyfile failed validation after adding 4ravu.com." >&2
        echo "Restoring backup from $BACKUP and leaving Caddy untouched." >&2
        sudo cp "$BACKUP" "$CADDYFILE"
        exit 1
    fi
fi

# ── 2. Install the caddy-switch helper ─────────────────────────────────────
# This script is the only way the deploy user can change the Caddy upstream
# port for 4ravu.com. It validates the port before touching the Caddyfile,
# and only ever matches on ports 8083/8084 — which appear nowhere else in
# this file — so it cannot affect any other domain's block.
cat << 'SWITCHEOF' | sudo tee "$CADDY_SWITCH" > /dev/null
#!/usr/bin/env bash
# 4ravu-caddy-switch <port>
# Atomically switches the 4ravu.com Caddy upstream and reloads.
set -euo pipefail
PORT="${1:?Usage: 4ravu-caddy-switch <8083|8084>}"
[[ "$PORT" =~ ^(8083|8084)$ ]] || { echo "Invalid port: $PORT"; exit 1; }
CADDYFILE=/etc/caddy/Caddyfile
sed -i -E "s#reverse_proxy 127\.0\.0\.1:(8083|8084)#reverse_proxy 127.0.0.1:${PORT}#" "$CADDYFILE"
caddy fmt --overwrite "$CADDYFILE"
systemctl reload caddy
echo "Caddy switched to :${PORT} and reloaded."
SWITCHEOF
sudo chmod 755 "$CADDY_SWITCH"
echo "Caddy switch helper installed at $CADDY_SWITCH."

# ── 3. Install the systemd-update helper ───────────────────────────────────
sudo cp "$SCRIPT_DIR/4ravu-systemd-update" "$SYSTEMD_UPDATE"
sudo chmod 755 "$SYSTEMD_UPDATE"
sudo chown root:root "$SYSTEMD_UPDATE"
echo "systemd update helper installed at $SYSTEMD_UPDATE."

# ── 4. Sudoers: deploy user can run podman + these two helpers, no password ─
SUDOERS_FILE=/etc/sudoers.d/deploy-4ravu
cat << SUDOEOF | sudo tee "$SUDOERS_FILE" > /dev/null
deploy ALL=(ALL) NOPASSWD: /usr/bin/podman *
deploy ALL=(ALL) NOPASSWD: $CADDY_SWITCH
deploy ALL=(ALL) NOPASSWD: $SYSTEMD_UPDATE
SUDOEOF
sudo visudo -cf "$SUDOERS_FILE"
sudo chmod 440 "$SUDOERS_FILE"
echo "Sudoers rules installed."

# ── 5. Create /opt/4ravu-site and install the deploy script + Caddyfile ────
sudo mkdir -p /opt/4ravu-site/blue /opt/4ravu-site/green /opt/4ravu-site/incoming
sudo chown -R deploy:deploy /opt/4ravu-site

if [[ -f "$SCRIPT_DIR/4ravu-deploy.sh" ]]; then
    sudo cp "$SCRIPT_DIR/4ravu-deploy.sh" "$DEPLOY_SCRIPT"
    sudo chown deploy:deploy "$DEPLOY_SCRIPT"
    sudo chmod 750 "$DEPLOY_SCRIPT"
    echo "Deploy script installed at $DEPLOY_SCRIPT."
else
    echo "Warning: 4ravu-deploy.sh not found next to this script." >&2
    echo "  Copy it manually: sudo cp 4ravu-deploy.sh $DEPLOY_SCRIPT" >&2
fi

if [[ -f "$SCRIPT_DIR/../Caddyfile" ]]; then
    sudo cp "$SCRIPT_DIR/../Caddyfile" /opt/4ravu-site/Caddyfile
    sudo chown deploy:deploy /opt/4ravu-site/Caddyfile
    echo "Internal Caddyfile installed at /opt/4ravu-site/Caddyfile."
else
    echo "Warning: repo Caddyfile not found at $SCRIPT_DIR/../Caddyfile." >&2
    echo "  Copy it manually: sudo cp Caddyfile /opt/4ravu-site/Caddyfile" >&2
fi

echo ""
echo "======================================================================"
echo " 4ravu setup complete."
echo ""
echo " Next steps:"
echo "   1. Add the GitHub Actions deploy public key to deploy's authorized_keys:"
echo "      echo '<pubkey>' | sudo tee -a /home/deploy/.ssh/authorized_keys"
echo "   2. Verify the other domains still work:"
echo "      curl -I https://woodstoneresearch.com"
echo "      curl -I https://admin.4ravu.com"
echo "      curl -I https://pgadmin.4ravu.com"
echo "      curl -I https://analytics.4ravu.com"
echo "   3. First deploy: bash $DEPLOY_SCRIPT"
echo "======================================================================"
