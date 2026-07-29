# Optional private CA for remote observability

If the remote LGTM uses a private CA, place `root.crt` here and set:

```dotenv
REMOTE_CA_DIR=./secrets/remote-ca
REMOTE_CA_FILE=/etc/alloy/remote-ca/root.crt
```

For public CA chains keep the default:

```dotenv
REMOTE_CA_FILE=/etc/ssl/certs/ca-certificates.crt
```

Copy this directory to `secrets/remote-ca/` before starting remote mode with a private CA.
Do not commit private CA material unless it is intentionally shared laboratory material.
