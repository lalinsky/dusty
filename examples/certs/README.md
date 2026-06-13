# Test certificates

Self-signed certificate and private key for **local testing only**.

- `cert.pem` — self-signed X.509 certificate, `CN=localhost`, SAN `localhost` + `127.0.0.1`
- `key.pem` — EC P-256 private key (unencrypted)

They are committed so the TLS examples and `config.tls` work out of the box:

```sh
zig build examples
./zig-out/bin/tls_server-example          # uses these certs by default
curl -k https://127.0.0.1:8443/           # -k: the cert is self-signed
```

> ⚠️ **Never use these in production.** The private key is public (it's in the
> repo), and the certificate is self-signed. They exist purely to exercise the
> TLS code path during development.

Regenerate (10-year validity):

```sh
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
  -keyout key.pem -out cert.pem -days 3650 \
  -subj "/CN=localhost" -addext "subjectAltName=DNS:localhost,IP:127.0.0.1"
```
