# Test certificates for the SSL tests

These files are for the tests only. Never use them for a real server. The private keys are public in this repository, so the certificates protect nothing.

- `ca.crt` and `ca.key`: the test certificate authority (CA), `CN=dream_pog test CA`.
- `server.crt` and `server.key`: the certificate of the `postgres-ssl` server of `docker-compose.yml`. The test CA signed it. Its only name is `DNS:localhost`, so `localhost` matches it and `127.0.0.1` does not.

Both certificates are valid for 36500 days from 24 November 2026 (UTC), until 31 October 2126. The commands that made them, run in this folder with OpenSSL 4.1.0:

```sh
openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.crt -days 36500 \
  -subj "/CN=dream_pog test CA" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign"
openssl req -newkey rsa:2048 -nodes -keyout server.key -out server.csr -subj "/CN=localhost"
printf 'basicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:localhost\n' > server.ext
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out server.crt -days 36500 -extfile server.ext
rm server.csr server.ext ca.srl
```
