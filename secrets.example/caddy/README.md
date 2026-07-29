# TLS files for Caddy

Copy this directory to `secrets/caddy/` (gitignored) before `gateway migration` or `gateway external`.

Required files for external/migration modes:

- `server.crt` — leaf certificate plus intermediates (full chain)
- `server.key` — private key

Names must match `TLS_CERT_FILE` and `TLS_KEY_FILE` in `.env`.

Permissions on Linux:

```bash
mkdir -p secrets/caddy
chmod 700 secrets/caddy
chmod 600 secrets/caddy/server.key
chmod 644 secrets/caddy/server.crt
```

Never commit real certificates or private keys.
