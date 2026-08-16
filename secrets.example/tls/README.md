# TLS files for the nginx gateway

Copy this directory to `secrets/tls/` (gitignored). Its name must match `TLS_CERTS_DIR` in `.env`.

## Internal mode

Nothing to place here by hand. `model.sh gateway internal` issues a local CA into this
directory and reuses it on every later run:

- `internal-ca.crt` — root certificate, install it into every client trust store
- `internal-ca.key` — CA private key, never leaves this host
- `internal.crt` / `internal.key` — gateway certificate covering every configured hostname
- `internal.san`, `internal-ca.srl` — bookkeeping for reissue decisions

The leaf is reissued automatically when hostnames change or when it is within 30 days of
expiry. The CA is created once; deleting `internal-ca.key` forces a new CA and invalidates
trust on every client.

## External and migration modes

Required files, named after `TLS_CERT_FILE` and `TLS_KEY_FILE` in `.env`:

- `server.crt` — leaf certificate plus intermediates (full chain, no root)
- `server.key` — private key

Permissions on Linux. nginx runs as UID 101 inside the container and must be able to read
the key, so a root-only `0600` key makes the gateway fail to start:

```bash
mkdir -p secrets/tls
chmod 700 secrets/tls
sudo chown 0:101 secrets/tls/server.key
sudo chmod 0640 secrets/tls/server.key
chmod 0644 secrets/tls/server.crt
```

`model.sh gateway external` verifies this before restarting anything.

Never commit real certificates or private keys.
