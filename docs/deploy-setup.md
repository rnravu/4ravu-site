# 4ravu.com deploy setup — one-time runbook

Run this from a machine that already has working `deploy@5.161.206.200` SSH
access (your laptop, not the desktop that hit `Permission denied`). This is a
one-time setup; after this, every `git push` to `main` auto-deploys.

app-server = `5.161.206.200`, the same Hetzner box that runs
woodstoneresearch.com, admin.4ravu.com, pgadmin.4ravu.com, and
analytics.4ravu.com behind one shared Caddy instance.

---

## 1. Generate a dedicated SSH keypair for GitHub Actions

Do **not** reuse wood-stone's `gh-actions-deploy` key — a leak in one repo's
secrets shouldn't grant deploy access to both sites.

```bash
ssh-keygen -t ed25519 -f 4ravu-gh-actions-deploy -C "github-actions-4ravu" -N ""
```

This creates two files:
- `4ravu-gh-actions-deploy` — private key, goes into a GitHub secret (step 5), never committed anywhere
- `4ravu-gh-actions-deploy.pub` — public key, goes on the server (step 2)

## 2. Register the new public key on app-server

Using your laptop's already-working key:

```bash
cat 4ravu-gh-actions-deploy.pub | ssh deploy@5.161.206.200 "cat >> ~/.ssh/authorized_keys"
```

## 3. Get the SSH known-hosts value

If you've SSH'd to `5.161.206.200` **by that exact IP** before:

```bash
grep "5.161.206.200" ~/.ssh/known_hosts
```

Otherwise fetch it fresh:

```bash
ssh-keyscan -H 5.161.206.200
```

Drop any lines starting with `#` — keep only the lines that look like
`|1|...|...= ssh-ed25519 AAAA...`. Save these three lines; they go into a
GitHub secret in step 5.

## 4. Copy the setup files to the server

From the repo root (`4ravu-site/`):

```bash
scp -r server deploy@5.161.206.200:/tmp/4ravu-server
scp Caddyfile deploy@5.161.206.200:/tmp/Caddyfile
```

## 5. Run the one-time setup script on the server

```bash
ssh deploy@5.161.206.200
sudo bash /tmp/4ravu-server/4ravu-setup.sh
```

This script (idempotent, safe to re-run):
- backs up `/etc/caddy/Caddyfile` before touching it
- appends a `4ravu.com` / `www.4ravu.com` block (reverse-proxying to the
  blue slot, port 8083), **validates** the Caddyfile before reloading —
  aborts and restores the backup if validation fails, so it can't take down
  woodstoneresearch.com/admin/pgadmin/analytics
- installs `/usr/local/bin/4ravu-caddy-switch` and
  `/usr/local/bin/4ravu-systemd-update`
- installs `/etc/sudoers.d/deploy-4ravu` (scoped to `podman *` + those two
  helpers only — validated with `visudo -cf` first)
- creates `/opt/4ravu-site/{blue,green,incoming}` and installs
  `4ravu-deploy.sh` + the internal `Caddyfile` there

## 6. Verify the shared Caddy still serves everything else

Do this **before** trusting the new 4ravu.com block:

```bash
curl -I https://woodstoneresearch.com
curl -I https://admin.4ravu.com
curl -I https://pgadmin.4ravu.com
curl -I https://analytics.4ravu.com
```

All four should respond exactly as they did before step 5.

## 7. Add GitHub repository secrets

Go to `https://github.com/rnravu/4ravu-site/settings/secrets/actions` and add:

| Secret | Value |
|---|---|
| `SSH_HOST` | `5.161.206.200` |
| `SSH_USER` | `deploy` |
| `SSH_PRIVATE_KEY` | full contents of `4ravu-gh-actions-deploy` (private key), including the `-----BEGIN OPENSSH PRIVATE KEY-----` / `-----END OPENSSH PRIVATE KEY-----` lines |
| `SSH_KNOWN_HOSTS` | the lines saved in step 3 |

## 8. Trigger the first deploy

Either push a commit to `main`, or go to the repo's **Actions** tab → *Deploy*
workflow → **Run workflow**.

## 9. Verify the live site

```bash
curl -I https://4ravu.com
curl -I https://www.4ravu.com
ssh deploy@5.161.206.200 "podman ps"
ssh deploy@5.161.206.200 "cat /opt/4ravu-site/active-slot"
```

`podman ps` should show exactly one of `4ravu-blue` / `4ravu-green` running,
matching whatever `active-slot` says.

---

## Troubleshooting

**`Permission denied (publickey,gssapi-keyex,gssapi-with-mic)` on `ssh`/`scp`**
— the key your machine is offering isn't in `deploy`'s `authorized_keys`.
Check which key actually works with `ssh -vvv -i ~/.ssh/<key> deploy@5.161.206.200`
and look for `Offering public key` / whether the server accepts or rejects it.
If nothing local works, use the Hetzner Cloud console (VNC/serial, bypasses
SSH) to get in and inspect/fix `/home/deploy/.ssh/authorized_keys` directly.

**Workflow fails at the `ssh`/`rsync` step with a host-key error** — the
`SSH_KNOWN_HOSTS` secret doesn't match what the server actually presents.
Re-run `ssh-keyscan -H 5.161.206.200` and replace the secret value.

**One of the four pre-existing domains breaks after step 5** — restore the
timestamped backup `4ravu-setup.sh` made
(`/etc/caddy/Caddyfile.bak.<timestamp>`) and `sudo systemctl reload caddy`,
then investigate before re-running.

---

## mail.4ravu.com (Roundcube webmail)

Self-hosted [Roundcube](https://roundcube.net/) on the same box, giving a
single unified inbox across every company domain. It holds no mail itself —
it's a web UI logging into Purelymail's IMAP/SMTP with one consolidated
"hub" mailbox (`ops@4ravu.com`). Purelymail routing rules (configured in the
Purelymail dashboard, not here) funnel every domain's mail into that one
mailbox; Roundcube's per-mailbox Identities feature is what lets replies go
out looking like `contact@4ravu.com`, `hello@matchvane.com`, etc.

**One-time setup:**

```bash
scp server/mail-setup.sh server/mail-update.sh deploy@5.161.206.200:/tmp/
ssh deploy@5.161.206.200
sudo bash /tmp/mail-setup.sh <basicauth-user> <basicauth-bcrypt-hash>
```

The bcrypt hash comes from `caddy hash-password --plaintext '<password>'` —
generate it fresh, never store the plaintext password in this repo. The
script is idempotent: creates `/opt/mail-roundcube/{db,config}`, installs
and enables the `container-mail-roundcube.service` systemd unit (podman,
port `127.0.0.1:8085`), and appends the `mail.4ravu.com` Caddy block
(validated before reload, same backup/restore-on-failure behavior as
`4ravu-setup.sh`). Add `mail.4ravu.com` → `A` → `5.161.206.200` in
Cloudflare (proxied) for Caddy to obtain its certificate.

**Updating Roundcube to a newer image:**

```bash
ssh deploy@5.161.206.200 "sudo bash /opt/mail-roundcube/mail-update.sh"
```

(Copy `mail-update.sh` to the server once, e.g. alongside the deploy
script, or re-`scp` it each time — it just pulls `roundcube/roundcubemail:latest`
and restarts the systemd unit. Mail/config state lives on the host volumes,
so recreating the container is safe.)
