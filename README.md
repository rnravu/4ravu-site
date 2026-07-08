# 4ravu-site

Static corporate site for 4Ravu L.L.C., deployed via blue-green podman
containers behind a shared Caddy instance on Hetzner. See
[docs/deploy-setup.md](docs/deploy-setup.md) for the full deploy/ops
runbook, including the self-hosted Roundcube webmail setup.

## Infrastructure notes

- **Email**: hosted on [Purelymail](https://purelymail.com) (`purelymail.com/manage`
  for the admin portal). All company domains (4ravu.com, matchvane.com, and
  others as they're added) route into one consolidated hub mailbox,
  `ops@4ravu.com`, read via a self-hosted Roundcube instance at
  `mail.4ravu.com` — see [docs/deploy-setup.md](docs/deploy-setup.md#mail4ravucom-roundcube-webmail).
- **Server**: `5.161.206.200` (Hetzner), also runs woodstoneresearch.com,
  admin/pgadmin/analytics.4ravu.com.
